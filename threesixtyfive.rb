#!/usr/bin/ruby

require 'sinatra'
require "sinatra/reloader" if development?
require "sinatra/config_file"
require 'instagram'
require 'date'
require 'sequel'

$db = Sequel.connect(ENV['DATABASE_URL'] || 'sqlite://threesixtyfive.db')
$db.create_table? :photos do
  primary_key :id
  Int :year
  Int :year_index
  Time :registered_at
  Time :created_at
  String :instagram_id
  String :photo_url
  String :thumb_url
  String :link_url
end rescue nil

class Photo < Sequel::Model
end

enable :sessions
config_file 'threesixtyfive.yaml'

Instagram.configure do |config|
  config.client_id = ENV["THREESIXTYFIVE_CLIENT_ID"] || settings.instagram[:client_id]
  config.client_secret = ENV["THREESIXTYFIVE_CLIENT_SECRET"] || settings.instagram[:client_secret]
end

get "/" do
  @photos = Photo.reverse_order(:created_at).all
  erb :index
end

get "/work" do
  unless session[:access_token]
    return '<a href="/work/connect">Connect with Instagram</a>'
  end

  "<h1>Work!</h1><a href='/work/check'>Check now</a> (#{Photo.count} photos)"
end

get "/work/db/truncate" do
  Photo.truncate
  redirect "/work"
end

get "/work/check" do
  now = Date.today
  year = now.year
  check year
end

get "/work/check/:year" do |year|
  check year.to_i
end

get "/work/connect" do
  redirect Instagram.authorize_url(:redirect_uri => "#{request.base_url}/work/callback")
end

get "/work/callback" do
  response = Instagram.get_access_token(params[:code], :redirect_uri => "#{request.base_url}/work/callback")
  session[:access_token] = response.access_token
  redirect "/work"
end

def check(year)
  client = Instagram.client(:access_token => session[:access_token])

  tomorrow = DateTime.now.next_day.beginning_of_day
  puts tomorrow
  beginning_of_year = DateTime.new(year, 1, 1, 0, 0, 0, '+1')
  last_photo = Photo.reverse_order(:id).first

  if last_photo.nil?
    # first photo
    result = "Cannot find the first photo"
    all_media = at_least(client, 365, { :min_timestamp => beginning_of_year.to_time.to_i })
    all_media.sort { |a, b| a.created_time.to_i <=> b.created_time.to_i }.select! { |m| t = Time.at(m.created_time.to_i).to_datetime; t >= beginning_of_year && t < tomorrow }

    first_day = beginning_of_year
    while all_media.any? { |m| date_time(m.created_time).yday <= first_day.yday }
      media = all_media.select { |m| date_time(m.created_time).yday == first_day.yday }
      if media.count > 0
        media_item = select_best_photo(media)
        photo = photo_from_media_item(media_item)
        photo.save

        result = "Saved the first photo: <img src='#{photo.photo_url}'>\n"
        break
      end
      first_day = first_day.next_day
    end
  else
    min_id = last_photo.instagram_id
    result = "Completing since #{min_id}"

    all_media = at_least(client, 365, { :min_id => min_id })
    all_media.select! { |m| t = date_time(m.created_time); t > last_photo.created_at.to_datetime && t < tomorrow }

    last_day = last_photo.created_at.to_datetime.next_day.beginning_of_day
    while last_day < tomorrow && all_media.any? { |m| date_time(m.created_time).yday <= last_day.yday }
      media = all_media.select { |m| date_time(m.created_time).yday == last_day.yday }
      if media.count > 0
        media_item = select_best_photo(media)
        photo = photo_from_media_item(media_item)
        photo.save

        result << "Saved a photo: <img src='#{photo.photo_url}'><br>\n"
      end
      last_day = last_day.next_day
    end
  end

  result
end

def date_time(time)
  x = 1
  offset = (x * 3600) - Time.now.utc_offset
  puts offset
  Time.at(time.to_i + offset).to_datetime
end

def at_least(client, num, options = {})
  result = []
  options[:count] = 20
  while true
    puts options
    page = client.user_recent_media(options)
    max_id = page.pagination[:next_max_id]
    puts max_id
    result += page
    break if max_id.nil?
    options[:max_id] = max_id
  end
  result
end

def select_best_photo(media)
  media = media.sort { |a,b| b.likes[:count] <=> a.likes[:count] }
  puts media.map { |m| "#{m.id} #{m.likes[:count]}" }
  return media.first
end

def photo_from_media_item(media_item)
  puts media_item.images.inspect
  photo = Photo.new()
  photo.instagram_id = media_item.id
  photo.thumb_url = media_item.images.thumbnail.url
  photo.photo_url = media_item.images.standard_resolution.url
  photo.link_url = media_item.link
  photo.registered_at = DateTime.now
  photo.created_at = date_time(media_item.created_time)
  photo.year = photo.created_at.year
  photo.year_index = photo.created_at.yday
  return photo
end

class DateTime
  def beginning_of_day
    return DateTime.new(self.year, self.month, self.day, 0, 0, 0, self.zone)
  end
end
