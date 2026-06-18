# routes/users.cr - User routes for Crystal Aggregator
# Handles user profiles, posts, comments, and activity

require "json"
require "kemal"

# Get user profile by username
get "/api/users/:username" do |env|
  username = env.params.url["username"]
  
  if username.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Username is required"
    }.to_json
  end
  
  # Get user data
  user = UserDB.find_by_username(username)
  
  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found"
    }.to_json
  end
  
  # Remove sensitive data
  user.delete("password_hash")
  
  # Get user stats
  stats = AlgoDB.get_user_stats(user["id"].to_i64)
  
  # Get user's activity pattern
  activity = UserAlgorithms.get_user_activity_pattern(user["id"].to_i64)
  
  # Get user's favorite sources
  favorite_sources = UserAlgorithms.get_favorite_sources(user["id"].to_i64, 5)
  
  # Get user's favorite tags
  favorite_tags = UserAlgorithms.get_favorite_tags(user["id"].to_i64, 5)
  
  # Check if current user is following this user (if you add follow feature)
  # For now, just return basic profile
  
  env.response.status_code = 200
  {
    "status" => "success",
    "user" => user,
    "stats" => stats,
    "activity" => {
      "peak_hour" => activity["peak_hour"],
      "avg_hourly" => activity["avg_hourly"],
      "total_activity" => activity["total_activity"]
    },
    "favorites" => {
      "sources" => favorite_sources,
      "tags" => favorite_tags
    }
  }.to_json
end

# Get user's posts
get "/api/users/:username/posts" do |env|
  username = env.params.url["username"]
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if username.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Username is required"
    }.to_json
  end
  
  if limit > 100
    limit = 100
  end
  
  # Get user ID
  user = UserDB.find_by_username(username)
  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found"
    }.to_json
  end
  
  user_id = user["id"].to_i64
  
  result = POOL.exec(
    "SELECT id, title, url, content, source, score, comment_count, created_at
     FROM posts
     WHERE user_id = $1 AND is_user_post = true
     ORDER BY created_at DESC
     LIMIT $2 OFFSET $3",
    user_id, limit, offset
  )
  
  posts = result.rows.map do |row|
    {
      "id"            => row[0].to_i64,
      "title"         => row[1].to_s,
      "url"           => row[2]?.try &.to_s || "",
      "content"       => row[3]?.try &.to_s || "",
      "source"        => row[4].to_s,
      "score"         => row[5].to_i,
      "comment_count" => row[6].to_i,
      "created_at"    => row[7].to_s
    }
  end
  
  env.response.status_code = 200
  {
    "status" => "success",
    "username" => username,
    "results" => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => posts.size
    }
  }.to_json
end

# Get user's comments
get "/api/users/:username/comments" do |env|
  username = env.params.url["username"]
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if username.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Username is required"
    }.to_json
  end
  
  if limit > 100
    limit = 100
  end
  
  # Get user ID
  user = UserDB.find_by_username(username)
  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found"
    }.to_json
  end
  
  user_id = user["id"].to_i64
  
  result = POOL.exec(
    "SELECT c.id, c.post_id, c.content, c.score, c.created_at,
            p.title as post_title
     FROM comments c
     LEFT JOIN posts p ON c.post_id = p.id
     WHERE c.user_id = $1
     ORDER BY c.created_at DESC
     LIMIT $2 OFFSET $3",
    user_id, limit, offset
  )
  
  comments = result.rows.map do |row|
    {
      "id"         => row[0].to_i64,
      "post_id"    => row[1].to_i64,
      "content"    => row[2].to_s,
      "score"      => row[3].to_i,
      "created_at" => row[4].to_s,
      "post_title" => row[5]?.try &.to_s || "unknown"
    }
  end
  
  env.response.status_code = 200
  {
    "status" => "success",
    "username" => username,
    "results" => comments,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => comments.size
    }
  }.to_json
end

# Get user's saved posts
get "/api/users/:username/saved" do |env|
  username = env.params.url["username"]
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if username.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Username is required"
    }.to_json
  end
  
  if limit > 100
    limit = 100
  end
  
  # Get user ID
  user = UserDB.find_by_username(username)
  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found"
    }.to_json
  end
  
  user_id = user["id"].to_i64
  
  # Check if current user is viewing their own saved posts
  valid, current_user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  is_own_profile = valid && current_user_id == user_id
  
  # Only allow users to see their own saved posts
  if !is_own_profile
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "You can only view your own saved posts"
    }.to_json
  end
  
  saved_posts = SaveDB.get_user_saves(user_id, limit, offset)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "username" => username,
    "results" => saved_posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => saved_posts.size
    }
  }.to_json
end

# Get user's activity stats
get "/api/users/:username/stats" do |env|
  username = env.params.url["username"]
  
  if username.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Username is required"
    }.to_json
  end
  
  # Get user ID
  user = UserDB.find_by_username(username)
  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found"
    }.to_json
  end
  
  user_id = user["id"].to_i64
  
  # Get comprehensive stats
  stats = AlgoDB.get_user_stats(user_id)
  engagement_score = UserAlgorithms.calculate_user_engagement_score(user_id)
  activity = UserAlgorithms.get_user_activity_pattern(user_id)
  favorite_sources = UserAlgorithms.get_favorite_sources(user_id, 5)
  favorite_tags = UserAlgorithms.get_favorite_tags(user_id, 5)
  
  # Get post count
  post_result = POOL.exec(
    "SELECT COUNT(*) FROM posts WHERE user_id = $1 AND is_user_post = true",
    user_id
  )
  post_count = post_result.rows.first?[0].to_i64
  
  # Get comment count
  comment_result = POOL.exec(
    "SELECT COUNT(*) FROM comments WHERE user_id = $1",
    user_id
  )
  comment_count = comment_result.rows.first?[0].to_i64
  
  # Get total vote count on user's posts
  vote_result = POOL.exec(
    "SELECT COALESCE(SUM(score), 0) FROM posts WHERE user_id = $1 AND is_user_post = true",
    user_id
  )
  total_votes = vote_result.rows.first?[0].to_i64
  
  # Get user's join date and last active
  user_result = POOL.exec(
    "SELECT created_at, last_login FROM users WHERE id = $1",
    user_id
  )
  user_row = user_result.rows.first?
  joined_at = user_row ? user_row[0].to_s : ""
  last_active = user_row ? user_row[1]?.try &.to_s : ""
  
  env.response.status_code = 200
  {
    "status" => "success",
    "username" => username,
    "stats" => {
      "posts" => {
        "total" => post_count,
        "score" => stats["posts_interacted"]? || 0
      },
      "comments" => {
        "total" => comment_count,
        "score" => stats["comments"]? || 0
      },
      "votes" => {
        "upvotes" => stats["upvotes"]? || 0,
        "downvotes" => stats["downvotes"]? || 0,
        "total_received" => total_votes
      },
      "engagement" => {
        "score" => engagement_score,
        "saves" => stats["saves"]? || 0,
        "sources_used" => stats["sources_used"]? || 0
      },
      "activity" => {
        "joined_at" => joined_at,
        "last_active" => last_active,
        "peak_hour" => activity["peak_hour"],
        "avg_hourly" => activity["avg_hourly"],
        "total_activity" => activity["total_activity"]
      },
      "favorites" => {
        "sources" => favorite_sources,
        "tags" => favorite_tags
      }
    }
  }.to_json
end

# Get user's engagement history (timeline)
get "/api/users/:username/history" do |env|
  username = env.params.url["username"]
  days = env.params.query["days"]?.try &.to_i || 7
  
  if username.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Username is required"
    }.to_json
  end
  
  if days > 30
    days = 30
  end
  
  # Get user ID
  user = UserDB.find_by_username(username)
  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found"
    }.to_json
  end
  
  user_id = user["id"].to_i64
  
  # Check if current user is viewing their own history
  valid, current_user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  is_own_profile = valid && current_user_id == user_id
  
  # Only allow users to see their own history
  if !is_own_profile
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "You can only view your own history"
    }.to_json
  end
  
  history = UserAlgorithms.get_engagement_history(user_id, days)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "username" => username,
    "days" => days,
    "history" => history
  }.to_json
end

# Get user's recommendations
get "/api/users/:username/recommendations" do |env|
  username = env.params.url["username"]
  limit = env.params.query["limit"]?.try &.to_i || 20
  
  if username.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Username is required"
    }.to_json
  end
  
  if limit > 50
    limit = 50
  end
  
  # Get user ID
  user = UserDB.find_by_username(username)
  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found"
    }.to_json
  end
  
  user_id = user["id"].to_i64
  
  # Check if current user is viewing their own recommendations
  valid, current_user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  is_own_profile = valid && current_user_id == user_id
  
  # Only allow users to see their own recommendations
  if !is_own_profile
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "You can only view your own recommendations"
    }.to_json
  end
  
  recommendations = UserAlgorithms.get_recommendations(user_id, limit)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "username" => username,
    "results" => recommendations,
    "count" => recommendations.size
  }.to_json
end

# Get "because you liked X" recommendations
get "/api/users/:username/recommendations/related/:post_id" do |env|
  username = env.params.url["username"]
  post_id = env.params.url["post_id"].to_i64?
  limit = env.params.query["limit"]?.try &.to_i || 10
  
  if username.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Username is required"
    }.to_json
  end
  
  if post_id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid post ID"
    }.to_json
  end
  
  if limit > 20
    limit = 20
  end
  
  # Get user ID
  user = UserDB.find_by_username(username)
  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found"
    }.to_json
  end
  
  user_id = user["id"].to_i64
  
  # Check if current user is viewing their own recommendations
  valid, current_user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  is_own_profile = valid && current_user_id == user_id
  
  # Only allow users to see their own recommendations
  if !is_own_profile
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "You can only view your own recommendations"
    }.to_json
  end
  
  recommendations = UserAlgorithms.get_related_recommendations(user_id, post_id, limit)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "username" => username,
    "post_id" => post_id,
    "results" => recommendations,
    "count" => recommendations.size
  }.to_json
end

# Get user similarity to another user
get "/api/users/:username/similarity/:other_username" do |env|
  username = env.params.url["username"]
  other_username = env.params.url["other_username"]
  
  if username.empty? || other_username.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Both usernames are required"
    }.to_json
  end
  
  # Get user IDs
  user = UserDB.find_by_username(username)
  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found"
    }.to_json
  end
  
  other_user = UserDB.find_by_username(other_username)
  if other_user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "Other user not found"
    }.to_json
  end
  
  user_id = user["id"].to_i64
  other_user_id = other_user["id"].to_i64
  
  # Check if current user is viewing their own similarity
  valid, current_user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  is_own_profile = valid && current_user_id == user_id
  
  # Only allow users to see their own similarity
  if !is_own_profile
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "You can only view your own similarity"
    }.to_json
  end
  
  similarity = UserAlgorithms.calculate_user_similarity(user_id, other_user_id)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "username" => username,
    "other_username" => other_username,
    "similarity_score" => similarity.round(4)
  }.to_json
end
