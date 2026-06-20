# routes/feed.cr - Feed routes for Crystal Aggregator

require "json"
require "kemal"

# Main feed endpoint - returns mixed feed by default
get "/api/feed" do |env|
  feed_type = env.params.query["feed"]?.try &.to_s || "mixed"
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if limit > 100
    limit = 100
  end
  
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  
  feed_type_enum = case feed_type
                   when "hot" then FeedType::Hot
                   when "new" then FeedType::New
                   when "top" then FeedType::Top
                   when "personalized" then FeedType::Personalized
                   when "trending" then FeedType::Trending
                   when "discovery" then FeedType::Discovery
                   when "collaborative" then FeedType::Collaborative
                   when "mixed" then FeedType::Mixed
                   else FeedType::Mixed
                   end
  
  if (feed_type_enum == FeedType::Personalized || 
      feed_type_enum == FeedType::Discovery ||
      feed_type_enum == FeedType::Collaborative) && !valid
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required for this feed type"
    }.to_json
  end
  
  posts = RecommendationEngine.get_feed(user_id, feed_type_enum, limit, offset)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "feed_type" => feed_type,
    "results" => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => posts.size
    }
  }.to_json
end

# Hot feed
get "/api/feed/hot" do |env|
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if limit > 100
    limit = 100
  end
  
  posts = RecommendationEngine.get_feed(nil, FeedType::Hot, limit, offset)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "feed_type" => "hot",
    "results" => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => posts.size
    }
  }.to_json
end

# New feed
get "/api/feed/new" do |env|
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if limit > 100
    limit = 100
  end
  
  posts = RecommendationEngine.get_feed(nil, FeedType::New, limit, offset)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "feed_type" => "new",
    "results" => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => posts.size
    }
  }.to_json
end

# Top feed
get "/api/feed/top" do |env|
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if limit > 100
    limit = 100
  end
  
  posts = RecommendationEngine.get_feed(nil, FeedType::Top, limit, offset)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "feed_type" => "top",
    "results" => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => posts.size
    }
  }.to_json
end

# Personalized feed
get "/api/feed/personalized" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  
  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required for personalized feed"
    }.to_json
  end
  
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if limit > 100
    limit = 100
  end
  
  posts = RecommendationEngine.get_feed(user_id, FeedType::Personalized, limit, offset)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "feed_type" => "personalized",
    "results" => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => posts.size
    }
  }.to_json
end

# Trending feed
get "/api/feed/trending" do |env|
  limit = env.params.query["limit"]?.try &.to_i || 20
  
  if limit > 50
    limit = 50
  end
  
  posts = RecommendationEngine.get_feed(nil, FeedType::Trending, limit, 0)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "feed_type" => "trending",
    "results" => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => 0,
      "count"  => posts.size
    }
  }.to_json
end

# Discovery feed
get "/api/feed/discovery" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  
  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required for discovery feed"
    }.to_json
  end
  
  limit = env.params.query["limit"]?.try &.to_i || 20
  
  if limit > 50
    limit = 50
  end
  
  posts = RecommendationEngine.get_feed(user_id, FeedType::Discovery, limit, 0)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "feed_type" => "discovery",
    "results" => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => 0,
      "count"  => posts.size
    }
  }.to_json
end

# Collaborative feed
get "/api/feed/collaborative" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  
  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required for collaborative feed"
    }.to_json
  end
  
  limit = env.params.query["limit"]?.try &.to_i || 20
  
  if limit > 50
    limit = 50
  end
  
  posts = RecommendationEngine.get_feed(user_id, FeedType::Collaborative, limit, 0)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "feed_type" => "collaborative",
    "results" => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => 0,
      "count"  => posts.size
    }
  }.to_json
end

# Mixed feed
get "/api/feed/mixed" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  limit = env.params.query["limit"]?.try &.to_i || 50
  
  if limit > 100
    limit = 100
  end
  
  posts = RecommendationEngine.get_feed(user_id, FeedType::Mixed, limit, 0)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "feed_type" => "mixed",
    "results" => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => 0,
      "count"  => posts.size
    }
  }.to_json
end

# Feed by source
get "/api/feed/source/:source" do |env|
  source = env.params.url["source"]
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if limit > 100
    limit = 100
  end
  
  valid_sources = ["reddit", "hackernews", "devto", "user"]
  if !valid_sources.includes?(source)
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid source. Must be one of: #{valid_sources.join(", ")}"
    }.to_json
  end
  
  result = POOL.query(
    "SELECT id, title, url, source, score, comment_count, created_at
     FROM posts
     WHERE source = $1
     ORDER BY created_at DESC
     LIMIT $2 OFFSET $3",
    source, limit, offset
  )
  
  posts = [] of Hash(String, JSON::Any)
  result.each do
    post = Hash(String, JSON::Any).new
    post["id"] = JSON::Any.new(result.read(Int64))
    post["title"] = JSON::Any.new(result.read(String))
    url = result.read(String?)
    if url
      post["url"] = JSON::Any.new(url)
    else
      post["url"] = JSON::Any.new("")
    end
    post["source"] = JSON::Any.new(result.read(String))
    post["score"] = JSON::Any.new(result.read(Int32))
    post["comment_count"] = JSON::Any.new(result.read(Int32))
    post["created_at"] = JSON::Any.new(result.read(Time).to_s)
    posts << post
  end
  
  env.response.status_code = 200
  {
    "status" => "success",
    "source" => source,
    "results" => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => posts.size
    }
  }.to_json
end

# Feed by tag
get "/api/feed/tag/:tag" do |env|
  tag = env.params.url["tag"]
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if limit > 100
    limit = 100
  end
  
  result = POOL.query(
    "SELECT id, title, url, source, score, comment_count, created_at
     FROM posts
     WHERE title ILIKE $1
     ORDER BY created_at DESC
     LIMIT $2 OFFSET $3",
    "%#{tag}%", limit, offset
  )
  
  posts = [] of Hash(String, JSON::Any)
  result.each do
    post = Hash(String, JSON::Any).new
    post["id"] = JSON::Any.new(result.read(Int64))
    post["title"] = JSON::Any.new(result.read(String))
    url = result.read(String?)
    if url
      post["url"] = JSON::Any.new(url)
    else
      post["url"] = JSON::Any.new("")
    end
    post["source"] = JSON::Any.new(result.read(String))
    post["score"] = JSON::Any.new(result.read(Int32))
    post["comment_count"] = JSON::Any.new(result.read(Int32))
    post["created_at"] = JSON::Any.new(result.read(Time).to_s)
    posts << post
  end
  
  env.response.status_code = 200
  {
    "status" => "success",
    "tag" => tag,
    "results" => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => posts.size
    }
  }.to_json
end

# Feed by date range
get "/api/feed/date" do |env|
  from_date = env.params.query["from"]?
  to_date = env.params.query["to"]?
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if limit > 100
    limit = 100
  end
  
  if from_date.nil? || to_date.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Both 'from' and 'to' date parameters are required (format: YYYY-MM-DD)"
    }.to_json
  end
  
  result = POOL.query(
    "SELECT id, title, url, source, score, comment_count, created_at
     FROM posts
     WHERE created_at >= $1 AND created_at <= $2
     ORDER BY created_at DESC
     LIMIT $3 OFFSET $4",
    from_date, to_date, limit, offset
  )
  
  posts = [] of Hash(String, JSON::Any)
  result.each do
    post = Hash(String, JSON::Any).new
    post["id"] = JSON::Any.new(result.read(Int64))
    post["title"] = JSON::Any.new(result.read(String))
    url = result.read(String?)
    if url
      post["url"] = JSON::Any.new(url)
    else
      post["url"] = JSON::Any.new("")
    end
    post["source"] = JSON::Any.new(result.read(String))
    post["score"] = JSON::Any.new(result.read(Int32))
    post["comment_count"] = JSON::Any.new(result.read(Int32))
    post["created_at"] = JSON::Any.new(result.read(Time).to_s)
    posts << post
  end
  
  env.response.status_code = 200
  {
    "status" => "success",
    "from_date" => from_date,
    "to_date" => to_date,
    "results" => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => posts.size
    }
  }.to_json
end

# Feed statistics
get "/api/feed/stats" do |env|
  total_result = POOL.query("SELECT COUNT(*) FROM posts WHERE is_user_post = false")
  total_result.move_next
  total_posts = total_result.read(Int64)
  
  source_result = POOL.query(
    "SELECT source, COUNT(*) as count FROM posts WHERE is_user_post = false GROUP BY source ORDER BY count DESC"
  )
  source_counts = [] of Hash(String, JSON::Any)
  source_result.each do
    source = Hash(String, JSON::Any).new
    source["source"] = JSON::Any.new(source_result.read(String))
    source["count"] = JSON::Any.new(source_result.read(Int64))
    source_counts << source
  end
  
  day_result = POOL.query(
    "SELECT DATE(created_at) as day, COUNT(*) as count 
     FROM posts 
     WHERE created_at > NOW() - INTERVAL '7 days'
     GROUP BY DATE(created_at) 
     ORDER BY day DESC"
  )
  daily_counts = [] of Hash(String, JSON::Any)
  day_result.each do
    day = Hash(String, JSON::Any).new
    day["date"] = JSON::Any.new(day_result.read(Time).to_s)
    day["count"] = JSON::Any.new(day_result.read(Int64))
    daily_counts << day
  end
  
  score_result = POOL.query("SELECT COALESCE(AVG(score), 0) FROM posts WHERE is_user_post = false")
  score_result.move_next
  avg_score = score_result.read(Float64)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "stats" => {
      "total_posts" => total_posts,
      "avg_score" => avg_score.round(2),
      "by_source" => source_counts,
      "daily" => daily_counts
    }
  }.to_json
end

# Refresh feed
post "/api/feed/refresh" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  
  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required"
    }.to_json
  end
  
  env.response.status_code = 200
  {
    "status" => "success",
    "message" => "Feed refreshed successfully"
  }.to_json
end
