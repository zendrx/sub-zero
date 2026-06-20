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

puts "🚀 Starting Sub Zero..."
puts "📊 Connecting to database..."

POOL = begin
  PG.connect(DB_URL)
rescue e : Exception
  puts "❌ Failed to connect to database: #{e.message}"
  puts "💡 Make sure PostgreSQL is running and DATABASE_URL is correct"
  puts "📊 DB_URL: #{DB_URL.gsub(/:[^:@]*@/, ":****@")}"
  exit(1)
end

puts "✅ Database connected successfully!"

require "./zero/db/*"
require "./zero/routes/*"
require "./zero/algo/*"
require "./zero/aggregate/*"
require "./zero/auth"

def start_reddit_scheduler
  spawn do
    loop do
      begin
        puts "🔄 Reddit: Starting fetch..."
        saved = RedditFetcher.full_fetch
        puts "✅ Reddit: Saved #{saved} posts"
      rescue e : Exception
        puts "❌ Reddit scheduler error: #{e.message}"
      end
      sleep 5.minutes
    end
  end
end

def start_hn_scheduler
  spawn do
    loop do
      begin
        puts "🔄 HN: Starting fetch..."
        saved = HNFetcher.full_fetch
        puts "✅ HN: Saved #{saved} stories"
      rescue e : Exception
        puts "❌ HN scheduler error: #{e.message}"
      end
      sleep 10.minutes
    end
  end
end

def start_devto_scheduler
  spawn do
    loop do
      begin
        puts "🔄 Dev.to: Starting fetch..."
        saved = DevToFetcher.full_fetch
        puts "✅ Dev.to: Saved #{saved} articles"
      rescue e : Exception
        puts "❌ Dev.to scheduler error: #{e.message}"
      end
      sleep 15.minutes
    end
  end
end

def start_prune_scheduler
  spawn do
    loop do
      sleep 5.days.total_seconds
      puts "🧹 Running scheduled prune (every 5 days)..."
      pruned = PostDB.prune_old_posts(50000)
      puts "🧹 Pruned #{pruned} old external posts" if pruned > 0
    end
  end
end

start_reddit_scheduler
start_hn_scheduler
start_devto_scheduler
start_prune_scheduler

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
  puts "✅ Database tables verified"
rescue e : Exception
  puts "❌ Database setup error: #{e.message}"
  puts "💡 Make sure PostgreSQL is running and DATABASE_URL is set correctly"
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

def logged_in?(env)
  value = env.get("logged_in")
  value.is_a?(Bool) ? value : false
end

def current_user(env)
  value = env.get("current_user")
  if value.is_a?(String)
    begin
      JSON.parse(value)
    rescue
      {} of String => JSON::Any
    end
  else
    {} of String => JSON::Any
  end
end

def flash(env)
  value = env.get("flash")
  if value.is_a?(String)
    begin
      JSON.parse(value).as_h.transform_values(&.as_s)
    rescue
      {} of String => String
    end
  else
    {} of String => String
  end
end

get "/" do |env|
  valid, user_id, user = Auth.validate_session(env.request.headers, env.request.cookies)
  env.set "logged_in", valid && user_id ? true : false
  env.set "current_user", user.to_json
  env.set "flash", "{}"
  render "views/index.ecr"
end

get "/signup" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  if valid && user_id
    env.redirect "/"
    next
  end
  env.set "flash", "{}"
  render "views/signup.ecr"
end

get "/login" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  if valid && user_id
    env.redirect "/"
    next
  end
  env.set "flash", "{}"
  render "views/login.ecr"
end

get "/settings" do |env|
  valid, user_id, user = Auth.validate_session(env.request.headers, env.request.cookies)
  if !valid || !user_id
    env.redirect "/login"
    next
  end
  env.set "current_user", user.to_json
  env.set "flash", "{}"
  render "views/settings.ecr"
end

get "/post/:id" do |env|
  env.set "flash", "{}"
  render "views/post.ecr"
end

get "/user/:username" do |env|
  env.set "flash", "{}"
  render "views/user.ecr"
end

get "/search" do |env|
  env.set "flash", "{}"
  render "views/search.ecr"
end

get "/feed/hot" do |env|
  env.set "flash", "{}"
  render "views/feed.ecr"
end

get "/feed/new" do |env|
  env.set "flash", "{}"
  render "views/feed.ecr"
end

get "/feed/top" do |env|
  env.set "flash", "{}"
  render "views/feed.ecr"
end

get "/feed/mixed" do |env|
  env.set "flash", "{}"
  render "views/feed.ecr"
end

get "/feed/personalized" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  if !valid || !user_id
    env.redirect "/login"
    next
  end
  env.set "flash", "{}"
  render "views/feed.ecr"
end

get "/feed/trending" do |env|
  env.set "flash", "{}"
  render "views/feed.ecr"
end

post "/logout" do |env|
  cookie = Auth.logout
  env.response.cookies << cookie
  env.redirect "/"
end

port = ENV["PORT"]?.try &.to_i || 3000

puts "✅ Starting Kemal server on http://localhost:#{port}"
puts "Sources: Reddit, Hacker News, Dev.to"
puts "Press Ctrl+C to stop"

Kemal.run(port: port)