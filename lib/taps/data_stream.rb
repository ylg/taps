require 'taps/monkey'
require 'taps/multipart'
require 'taps/utils'
require 'taps/log'
require 'json'

module Taps

class DataStream
	class CorruptedData < Exception; end

	attr_reader :db, :state

	def initialize(db, state)
		@db = db
		@state = {
			:offset => 0,
			:avg_chunksize => 0,
			:num_chunksize => 0,
			:total_chunksize => 0,
		}.merge(state)
		@complete = false
	end

	def log
		Taps.log
	end

	def error=(val)
		state[:error] = val
	end

	def error
		state[:error] || false
	end

	def table_name
		state[:table_name].to_sym
	end

	def to_hash
		state.merge(:klass => self.class.to_s)
	end

	def to_json
		to_hash.to_json
	end

	def string_columns
		@string_columns ||= Taps::Utils.incorrect_blobs(db, table_name)
	end

	def table
		@table ||= db[table_name]
	end

	def order_by(name=nil)
		@order_by ||= begin
			name ||= table_name
			Taps::Utils.order_by(db, name)
		end
	end

	def increment(row_count)
		state[:offset] += row_count
	end

	# keep a record of the average chunksize within the first few hundred thousand records, after chunksize
	# goes below 100 or maybe if offset is > 1000
	def fetch_rows
		state[:chunksize] = fetch_chunksize
		ds = table.order(*order_by).limit(state[:chunksize], state[:offset])
		log.debug "DataStream#fetch_rows SQL -> #{ds.sql}"
		rows = Taps::Utils.format_data(ds.all, string_columns)
		update_chunksize_stats
		rows
	end

	def max_chunksize_training
		20
	end

	def fetch_chunksize
		chunksize = state[:chunksize]
		return chunksize if state[:num_chunksize] < max_chunksize_training
		return chunksize if state[:avg_chunksize] == 0
		return chunksize if state[:error]
		state[:avg_chunksize] > chunksize ? state[:avg_chunksize] : chunksize
	end

	def update_chunksize_stats
		return if state[:num_chunksize] >= max_chunksize_training
		state[:total_chunksize] += state[:chunksize]
		state[:num_chunksize] += 1
		state[:avg_chunksize] = state[:total_chunksize] / state[:num_chunksize] rescue state[:chunksize]
	end

	def compress_rows(rows)
		Taps::Utils.gzip(Marshal.dump(rows))
	end

	def fetch
		log.debug "DataStream#fetch state -> #{state.inspect}"

		t1 = Time.now
		rows = fetch_rows
		gzip_data = compress_rows(rows)
		t2 = Time.now
		elapsed_time = t2 - t1

		@complete = rows == { }

		[gzip_data, (@complete ? 0 : rows[:data].size), elapsed_time]
	end

	def complete?
		@complete
	end

	def fetch_remote(resource, headers)
		params = fetch_from_resource(resource, headers)
		gzip_data = params[:gzip_data]
		json = params[:json]

		rows = parse_gzip_data(gzip_data, json[:checksum])
		@complete = rows == { }

		# update local state
		state.merge!(json[:state].merge(:chunksize => state[:chunksize]))

		unless @complete
			import_rows(rows)
			rows[:data].size
		else
			0
		end
	end

	# this one is used inside the server process
	def fetch_remote_in_server(params)
		json = self.class.parse_json(params[:json])
		gzip_data = params[:gzip_data]

		rows = parse_gzip_data(gzip_data, json[:checksum])
		@complete = rows == { }

		unless @complete
			import_rows(rows)
			rows[:data].size
		else
			0
		end
	end

	def fetch_from_resource(resource, headers)
		res = nil
		log.debug "DataStream#fetch_from_resource state -> #{state.inspect}"
		state[:chunksize] = Taps::Utils.calculate_chunksize(state[:chunksize]) do |c|
			state[:chunksize] = c
			res = resource.post({:state => self.to_json}, headers)
		end

		begin
			params = Taps::Multipart.parse(res)
			params[:json] = self.class.parse_json(params[:json]) if params.has_key?(:json)
			return params
		rescue JSON::Parser
			raise DataStream::CorruptedData.new("Invalid JSON Received")
		end
	end

	def self.parse_json(json)
		hash = JSON.parse(json).symbolize_keys
		hash[:state].symbolize_keys! if hash.has_key?(:state)
		hash
	end

	def parse_gzip_data(gzip_data, checksum)
		raise DataStream::CorruptedData.new("Checksum Failed") unless Taps::Utils.valid_data?(gzip_data, checksum)

		begin
			return Marshal.load(Taps::Utils.gunzip(gzip_data))
		rescue Object => e
			puts "Error encountered loading data, wrote the data chunk to dump.#{Process.pid}.gz"
			File.open("dump.#{Process.pid}.gz", "w") { |f| f.write(gzip_data) }
			raise
		end
	end

	def import_rows(rows)
		table.import(rows[:header], rows[:data])
		state[:offset] += rows[:data].size
	end

	def self.factory(db, state)
		if state.has_key?(:klass)
			return eval(state[:klass]).new(db, state)
		end

		if Taps::Utils.single_integer_primary_key(db, state[:table_name].to_sym)
			DataStreamKeyed.new(db, state)
		else
			DataStream.new(db, state)
		end
	end
end


class DataStreamKeyed < DataStream
	attr_accessor :buffer

	def initialize(db, state)
		super(db, state)
		@state = { :primary_key => order_by(state[:table_name]).first, :filter => 0 }.merge(state)
		@buffer = []
	end

	def primary_key
		state[:primary_key].to_sym
	end

	def buffer_limit
		if state[:last_fetched] and state[:last_fetched] < state[:filter] and self.buffer.size == 0
			state[:last_fetched]
		else
			state[:filter]
		end
	end

	def load_buffer(chunksize)
		num = 0
		loop do
			limit = (chunksize * 1.1).ceil - num
			ds = table.order(*order_by).filter("#{primary_key} > #{buffer_limit}").limit(limit)
			log.debug "DataStreamKeyed#load_buffer SQL -> #{ds.sql}"
			data = ds.all
			self.buffer += data
			num += data.size
			if data.size > 0
				# keep a record of the last primary key value in the buffer
				state[:filter] = self.buffer.last[ primary_key ]
			end

			break if num >= chunksize or data.size == 0
		end
	end

	def fetch_buffered(chunksize)
		load_buffer(chunksize) if self.buffer.size < chunksize
		rows = buffer.slice(0, chunksize)
		state[:last_fetched] = if rows.size > 0
			rows.last[ primary_key ]
		else
			nil
		end
		rows
	end

	def import_rows(rows)
		table.import(rows[:header], rows[:data])
	end

	def fetch_rows
		chunksize = state[:chunksize]
		Taps::Utils.format_data(fetch_buffered(chunksize) || [], string_columns)
	end

	def increment(row_count)
		# pop the rows we just successfully sent off the buffer
		@buffer.slice!(0, row_count)
	end
end

end
