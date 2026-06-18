# routes/feed.cr - Feed routes for Crystal Aggregator
# Handles all feed generation and content discovery endpoints

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
  
  # Check if user is authenticated for personalized feeds
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  
  feed_type_enum = case feed_type
                   when "hot" then RecommendationEngine::FeedType::Hot
                   when "new" then RecommendationEngine::FeedType::New
                   when "top" then RecommendationEngine::FeedType::Top
                   when "personalized" then RecommendationEngine::FeedType::Personalized
                   when "trending" then RecommendationEngine::FeedType::Trending
                   when "discovery" then RecommendationEngine::FeedType::Discovery
                   when "collaborative" then RecommendationEngine::FeedType::Collaborative
                   when "mixed" then RecommendationEngine::FeedType::Mixed
                   else RecommendationEngine::FeedType::Mixed
                   end
  
  # If feed requires authentication and user is not logged in
  if (feed_type_enum == RecommendationEngine::FeedType::Personalized || 
      feed_type_enum == RecommendationEngine::FeedType::Discovery ||
      feed_type_enum == RecommendationEngine::FeedType::Collaborative) && !valid
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

# Hot feed - Reddit-style time decay
get "/api/feed/hot" do |env|
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if limit > 100
    limit = 100
  end
  
  posts = RecommendationEngine.get_feed(nil, RecommendationEngine::FeedType::Hot, limit, offset)
  
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

# New feed - most recent first
get "/api/feed/new" do |env|
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if limit > 100
    limit = 100
  end
  
  posts = RecommendationEngine.get_feed(nil, RecommendationEngine::FeedType::New, limit, offset)
  
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

# Top feed - highest scoring posts
get "/api/feed/top" do |env|
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if limit > 100
    limit = 100
  end
  
  posts = RecommendationEngine.get_feed(nil, RecommendationEngine::FeedType::Top, limit, offset)
  
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

# Personalized feed - based on user preferences
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
  
  posts = RecommendationEngine.get_feed(user_id, RecommendationEngine::FeedType::Personalized, limit, offset)
  
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

# Trending feed - posts with recent engagement spikes
get "/api/feed/trending" do |env|
  limit = env.params.query["limit"]?.try &.to_i || 20
  
  if limit > 50
    limit = 50
  end
  
  posts = RecommendationEngine.get_feed(nil, RecommendationEngine::FeedType::Trending, limit, 0)
  
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

# Discovery feed - new sources the user hasn't explored
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
  
  posts = RecommendationEngine.get_feed(user_id, RecommendationEngine::FeedType::Discovery, limit, 0)
  
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

# Collaborative feed - what similar users like
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
  
  posts = RecommendationEngine.get_feed(user_id, RecommendationEngine::FeedType::Collaborative, limit, 0)
  
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

# Mixed feed - combines multiple feed types
get "/api/feed/mixed" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  limit = env.params.query["limit"]?.try &.to_i || 50
  
  if limit > 100
    limit = 100
  end
  
  # If user is authenticated, use personalized mixed feed
  if valid && user_id
    posts = RecommendationEngine.get_feed(user_id, RecommendationEngine::FeedType::Mixed, limit, 0)
  else
    # For anonymous users, mix hot and new
    hot_posts = RecommendationEngine.get_feed(nil, RecommendationEngine::FeedType::Hot, limit // 2, 0)
    new_posts = RecommendationEngine.get_feed(nil, RecommendationEngine::FeedType::New, limit - (limit // 2), 0)
    posts = (hot_posts + new_posts).shuffle
  end
  
  env.response.status_code = 200
  {
    "status" => "success",
    "feed_type" => "mixed",
    "results" => posts.first(limit),
    "pagination" => {
      "limit"  => limit,
      "offset" => 0,
      "count"  => posts.first(limit).size
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
  
  # Validate source
  valid_sources = ["reddit", "hackernews", "devto", "user"]
  if !valid_sources.includes?(source)
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid source. Must be one of: #{valid_sources.join(", ")}"
    }.to_json
  end
  
  result = POOL.exec(
    "SELECT id, title, url, source, score, comment_count, created_at
     FROM posts
     WHERE source = $1
     ORDER BY created_at DESC
     LIMIT $2 OFFSET $3",
    source, limit, offset
  )
  
  posts = result.rows.map do |row|
    {
      "id"            => row[0].to_i64,
      "title"         => row[1].to_s,
      "url"           => row[2]?.try &.to_s || "",
      "source"        => row[3].to_s,
      "score"         => row[4].to_i,
      "comment_count" => row[5].to_i,
      "created_at"    => row[6].to_s
    }
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
  
  result = POOL.exec(
    "SELECT id, title, url, source, score, comment_count, created_at
     FROM posts
     WHERE title ILIKE $1
     ORDER BY created_at DESC
     LIMIT $2 OFFSET $3",
    "%#{tag}%", limit, offset
  )
  
  posts = result.rows.map do |row|
    {
      "id"            => row[0].to_i64,
      "title"         => row[1].to_s,
      "url"           => row[2]?.try &.to_s || "",
      "source"        => row[3].to_s,
      "score"         => row[4].to_i,
      "comment_count" => row[5].to_i,
      "created_at"    => row[6].to_s
    }
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
  
  result = POOL.exec(
    "SELECT id, title, url, source, score, comment_count, created_at
     FROM posts
     WHERE created_at >= $1 AND created_at <= $2
     ORDER BY created_at DESC
     LIMIT $3 OFFSET $4",
    from_date, to_date, limit, offset
  )
  
  posts = result.rows.map do |row|
    {
      "id"            => row[0].to_i64,
      "title"         => row[1].to_s,
      "url"           => row[2]?.try &.to_s || "",
      "source"        => row[3].to_s,
      "score"         => row[4].to_i,
      "comment_count" => row[5].to_i,
      "created_at"    => row[6].to_s
    }
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
  # Get total post count
  total_result = POOL.exec("SELECT COUNT(*) FROM posts WHERE is_user_post = false")
  total_posts = total_result.rows.first?[0].to_i64
  
  # Get count by source
  source_result = POOL.exec(
    "SELECT source, COUNT(*) as count FROM posts WHERE is_user_post = false GROUP BY source ORDER BY count DESC"
  )
  source_counts = source_result.rows.map do |row|
    {
      "source" => row[0].to_s,
      "count"  => row[1].to_i64
    }
  end
  
  # Get posts by day (last 7 days)
  day_result = POOL.exec(
    "SELECT DATE(created_at) as day, COUNT(*) as count 
     FROM posts 
     WHERE created_at > NOW() - INTERVAL '7 days'
     GROUP BY DATE(created_at) 
     ORDER BY day DESC"
  )
  daily_counts = day_result.rows.map do |row|
    {
      "date"  => row[0].to_s,
      "count" => row[1].to_i64
    }
  end
  
  # Get average score
  score_result = POOL.exec("SELECT COALESCE(AVG(score), 0) FROM posts WHERE is_user_post = false")
  avg_score = score_result.rows.first?[0].to_f64
  
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

# Refresh feed (regenerate recommendations)
post "/api/feed/refresh" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  
  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required"
    }.to_json
  end
  
  # Clear cached recommendations for this user
  # If using Redis, you'd delete the cache key here
  # For now, just return success
  
  env.response.status_code = 200
  {
    "status" => "success",
    "message" => "Feed refreshed successfully"
  }.to_json
end
