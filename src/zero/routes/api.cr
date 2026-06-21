require "json"
require "kemal"

# Simple in-memory rate limiter
module RateLimiter
  REQUESTS = {} of String => Array(Time)
  LOCK = Mutex.new

  def self.allowed?(key : String, max_requests : Int32, window_seconds : Int32) : Bool
    LOCK.synchronize do
      now = Time.utc
      window_start = now - window_seconds.seconds
      timestamps = REQUESTS[key]? || [] of Time
      timestamps = timestamps.select { |t| t > window_start }

      if timestamps.size >= max_requests
        REQUESTS[key] = timestamps
        return false
      end

      timestamps << now
      REQUESTS[key] = timestamps
      true
    end
  end

  def self.status(key : String, max_requests : Int32, window_seconds : Int32) : Tuple(Int32, Time)
    LOCK.synchronize do
      now = Time.utc
      window_start = now - window_seconds.seconds
      timestamps = REQUESTS[key]? || [] of Time
      timestamps = timestamps.select { |t| t > window_start }
      remaining = {max_requests - timestamps.size, 0}.max
      reset_at = timestamps.empty? ? now + window_seconds.seconds : timestamps.first + window_seconds.seconds
      {remaining, reset_at}
    end
  end
end

def rate_limit_key(env) : String
  ip = env.request.headers["X-Forwarded-For"]?.try(&.split(",").first.strip) ||
       env.request.headers["X-Real-IP"]?.try(&.strip) ||
       env.request.remote_address.to_s rescue "unknown"
  ip
end

def check_rate_limit(env, key : String, max : Int32, window : Int32)
  unless RateLimiter.allowed?(key, max, window)
    remaining, reset_at = RateLimiter.status(key, max, window)
    env.response.status_code = 429
    env.response.headers["X-RateLimit-Limit"] = max.to_s
    env.response.headers["X-RateLimit-Remaining"] = "0"
    env.response.headers["X-RateLimit-Reset"] = reset_at.to_unix.to_s
    env.response.headers["Retry-After"] = (reset_at - Time.utc).total_seconds.to_i.to_s
    next {
      "status" => "error",
      "message" => "Rate limit exceeded. Try again later.",
      "retry_after" => (reset_at - Time.utc).total_seconds.to_i,
    }.to_json
  end

  remaining, reset_at = RateLimiter.status(key, max, window)
  env.response.headers["X-RateLimit-Limit"] = max.to_s
  env.response.headers["X-RateLimit-Remaining"] = remaining.to_s
  env.response.headers["X-RateLimit-Reset"] = reset_at.to_unix.to_s
end

# ============================================================
# /api/db - Raw database query endpoint
# No auth, mad max rate limiting
# ============================================================

get "/api/db" do |env|
  check_rate_limit(env, rate_limit_key(env), 10, 60)

  query = env.params.query["q"]?.try &.to_s || ""

  if query.empty?
    env.response.status_code = 400
    next {
      "status" => "error",
      "message" => "Query parameter 'q' is required",
    }.to_json
  end

  # Only allow SELECT queries
  stripped = query.strip.upcase
  unless stripped.starts_with?("SELECT")
    env.response.status_code = 403
    next {
      "status" => "error",
      "message" => "Only SELECT queries are allowed",
    }.to_json
  end

  begin
    result = POOL.query(query)

    columns = result.column_count > 0 ? (0...result.column_count).map { |i| result.column_name(i) } : [] of String
    rows = [] of Array(JSON::Any)

    result.each do
      row = [] of JSON::Any
      columns.each_with_index do |_, idx|
        val = result.read(JSON::Any)
        row << val
      end
      rows << row
    end

    env.response.status_code = 200
    {
      "status" => "success",
      "columns" => columns,
      "rows" => rows,
      "count" => rows.size,
    }.to_json
  rescue e : Exception
    env.response.status_code = 400
    {
      "status" => "error",
      "message" => "Query failed: #{e.message}",
    }.to_json
  end
end
