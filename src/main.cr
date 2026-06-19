# main.cr - Main entry point for Sub Zero aggregator

require "kemal"
require "pg"
require "json"
require "crypto/bcrypt/password"
require "jwt"
require "time"

if File.exists?(".env")
  File.read_lines(".env").each do |line|
    next if line.starts_with?("#") || line.strip.empty?
    key, value = line.split("=", 2)
    ENV[key] = value.strip
  end
end

DB_URL = ENV["DATABASE_URL"]? || "postgresql://postgres:password@localhost:5432/subzero"
JWT_SECRET = ENV["JWT_SECRET"]? || "your-super-secret-key-change-in-production"

POOL = PG.connect(DB_URL)

require "./zero/db/*"
require "./zero/routes/*"
require "./zero/algo/*"
require "./zero/aggregate/*"
require "./zero/auth"

start_reddit_scheduler
start_hn_scheduler
start_devto_scheduler

error 404 do |env|
  env.response.content_type = "application/json"
  { "status" => "error", "message" => "Not found" }.to_json
end

error 500 do |env|
  env.response.content_type = "application/json"
  { "status" => "error", "message" => "Internal server error" }.to_json
end

begin
  setup_database
  setup_algo_tables
  puts "Database tables verified"
rescue e : Exception
  puts "Database setup error: #{e.message}"
  puts "Make sure PostgreSQL is running and DATABASE_URL is set correctly"
  exit(1)
end

get "/health" do |env|
  env.response.content_type = "application/json"
  {
    "status" => "ok",
    "time"   => Time.utc.to_rfc3339,
    "db"     => db_healthy?
  }.to_json
end

get "/" do |env|
  valid, user_id, user = Auth.validate_session(env.request.headers, env.request.cookies)
  env.set "logged_in", valid && user_id ? true : false
  env.set "current_user", user || {} of String => JSON::Type
  render "views/index.ecr"
end

get "/signup" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  if valid && user_id
    env.redirect "/"
    next
  end
  render "views/signup.ecr"
end

get "/login" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  if valid && user_id
    env.redirect "/"
    next
  end
  render "views/login.ecr"
end

get "/settings" do |env|
  valid, user_id, user = Auth.validate_session(env.request.headers, env.request.cookies)
  if !valid || !user_id
    env.redirect "/login"
    next
  end
  env.set "current_user", user || {} of String => JSON::Type
  render "views/settings.ecr"
end

get "/post/:id" do |env|
  render "views/post.ecr"
end

get "/user/:username" do |env|
  render "views/user.ecr"
end

get "/search" do |env|
  render "views/search.ecr"
end

get "/feed/hot" do |env|
  render "views/feed.ecr"
end

get "/feed/new" do |env|
  render "views/feed.ecr"
end

get "/feed/top" do |env|
  render "views/feed.ecr"
end

get "/feed/mixed" do |env|
  render "views/feed.ecr"
end

get "/feed/personalized" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  if !valid || !user_id
    env.redirect "/login"
    next
  end
  render "views/feed.ecr"
end

get "/feed/trending" do |env|
  render "views/feed.ecr"
end

post "/logout" do |env|
  cookie = Auth.logout
  env.response.cookies << cookie
  env.redirect "/"
end

def logged_in?(env)
  value = env.get("logged_in")
  value.is_a?(Bool) ? value : false
end

def current_user(env)
  value = env.get("current_user")
  value.is_a?(Hash(String, JSON::Type)) ? value : {} of String => JSON::Type
end

port = ENV["PORT"]?.try &.to_i || 3000

puts "Sub Zero Aggregator"
puts "Starting server on http://localhost:#{port}"
puts "Sources: Reddit, Hacker News, Dev.to"
puts "Press Ctrl+C to stop"

Kemal.run(port: port)
