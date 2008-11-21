require 'rubygems'
require 'sinatra'
require 'sequel'
require 'json'

configure do
	Sequel.connect(ENV['DATABASE_URL'] || 'sqlite:/')

	$LOAD_PATH.unshift(File.dirname(__FILE__) + '/lib')
	require 'session'
end

error do
	e = request.env['sinatra.error']
	puts e.to_s
	puts e.backtrace.join("\n")
	"Application error"
end

post '/sessions' do
	# todo: authenticate

	key = rand(9999999999).to_s
	database_url = Sinatra.application.options.database_url || request.body.string

	Session.create(:key => key, :database_url => database_url, :started_at => Time.now, :last_access => Time.now)

	"/sessions/#{key}"
end

post '/sessions/:key/:table' do
	session = Session.filter(:key => params[:key]).first
	stop 404 unless session

	data = JSON.parse request.body.string

	db = session.connection
	table = db[params[:table].to_sym]

	db.transaction do
		data.each { |row| table << row }
	end

	"#{data.size} records loaded"
end

get '/sessions/:key/:table' do
	session = Session.filter(:key => params[:key]).first
	stop 404 unless session

	page = params[:page] || 1
	chunk_size = 10

	db = session.connection
	table = db[params[:table].to_sym]
	rows = table.order(:id).paginate(page, chunk_size).all

	rows.to_json
end

delete '/sessions/:key' do
	session = Session.filter(:key => params[:key]).first
	stop 404 unless session

	session.disconnect
	session.destroy

	"ok"
end
