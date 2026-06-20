# routes/users.cr - User routes for Crystal Aggregator

require "json"
require "kemal"

# Get user profile by username
get "/api/users/:username" do |env|
  username = env.params.url["username"]

  if username.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Username is required",
    }.to_json
  end

  user = UserDB.find_by_username(username)

  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found",
    }.to_json
  end

  user.delete("password_hash")

  user_id = user["id"].as_i64
  stats = AlgoDB.get_user_stats(user_id)
  activity = UserAlgorithms.get_user_activity_pattern(user_id)
  favorite_sources = UserAlgorithms.get_favorite_sources(user_id, 5)
  favorite_tags = UserAlgorithms.get_favorite_tags(user_id, 5)

  env.response.status_code = 200
  {
    "status"   => "success",
    "user"     => user,
    "stats"    => stats,
    "activity" => {
      "peak_hour"      => activity["peak_hour"],
      "avg_hourly"     => activity["avg_hourly"],
      "total_activity" => activity["total_activity"],
    },
    "favorites" => {
      "sources" => favorite_sources,
      "tags"    => favorite_tags,
    },
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
      "message" => "Username is required",
    }.to_json
  end

  if limit > 100
    limit = 100
  end

  user = UserDB.find_by_username(username)
  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found",
    }.to_json
  end

  user_id = user["id"].as_i64

  result = POOL.query(
    "SELECT id, title, url, content, source, score, comment_count, created_at
     FROM posts
     WHERE user_id = $1 AND is_user_post = true
     ORDER BY created_at DESC
     LIMIT $2 OFFSET $3",
    user_id, limit, offset
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
    content = result.read(String?)
    if content
      post["content"] = JSON::Any.new(content)
    else
      post["content"] = JSON::Any.new("")
    end
    post["source"] = JSON::Any.new(result.read(String))
    post["score"] = JSON::Any.new(result.read(Int32))
    post["comment_count"] = JSON::Any.new(result.read(Int32))
    post["created_at"] = JSON::Any.new(result.read(Time).to_s)
    posts << post
  end

  env.response.status_code = 200
  {
    "status"     => "success",
    "username"   => username,
    "results"    => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => posts.size,
    },
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
      "message" => "Username is required",
    }.to_json
  end

  if limit > 100
    limit = 100
  end

  user = UserDB.find_by_username(username)
  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found",
    }.to_json
  end

  user_id = user["id"].as_i64

  result = POOL.query(
    "SELECT c.id, c.post_id, c.content, c.score, c.created_at,
            p.title as post_title
     FROM comments c
     LEFT JOIN posts p ON c.post_id = p.id
     WHERE c.user_id = $1
     ORDER BY c.created_at DESC
     LIMIT $2 OFFSET $3",
    user_id, limit, offset
  )

  comments = [] of Hash(String, JSON::Any)
  result.each do
    comment = Hash(String, JSON::Any).new
    comment["id"] = JSON::Any.new(result.read(Int64))
    comment["post_id"] = JSON::Any.new(result.read(Int64))
    comment["content"] = JSON::Any.new(result.read(String))
    comment["score"] = JSON::Any.new(result.read(Int32))
    comment["created_at"] = JSON::Any.new(result.read(Time).to_s)
    post_title = result.read(String?)
    if post_title
      comment["post_title"] = JSON::Any.new(post_title)
    else
      comment["post_title"] = JSON::Any.new("unknown")
    end
    comments << comment
  end

  env.response.status_code = 200
  {
    "status"     => "success",
    "username"   => username,
    "results"    => comments,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => comments.size,
    },
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
      "message" => "Username is required",
    }.to_json
  end

  if limit > 100
    limit = 100
  end

  user = UserDB.find_by_username(username)
  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found",
    }.to_json
  end

  user_id = user["id"].as_i64

  valid, current_user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  is_own_profile = valid && current_user_id == user_id

  if !is_own_profile
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "You can only view your own saved posts",
    }.to_json
  end

  saved_posts = SaveDB.get_user_saves(user_id, limit, offset)

  env.response.status_code = 200
  {
    "status"     => "success",
    "username"   => username,
    "results"    => saved_posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => saved_posts.size,
    },
  }.to_json
end

# Get user's activity stats
get "/api/users/:username/stats" do |env|
  username = env.params.url["username"]

  if username.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Username is required",
    }.to_json
  end

  user = UserDB.find_by_username(username)
  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found",
    }.to_json
  end

  user_id = user["id"].as_i64

  stats = AlgoDB.get_user_stats(user_id)
  engagement_score = UserAlgorithms.calculate_user_engagement_score(user_id)
  activity = UserAlgorithms.get_user_activity_pattern(user_id)
  favorite_sources = UserAlgorithms.get_favorite_sources(user_id, 5)
  favorite_tags = UserAlgorithms.get_favorite_tags(user_id, 5)

  post_result = POOL.query(
    "SELECT COUNT(*) FROM posts WHERE user_id = $1 AND is_user_post = true",
    user_id
  )
  post_result.move_next
  post_count = post_result.read(Int64)

  comment_result = POOL.query(
    "SELECT COUNT(*) FROM comments WHERE user_id = $1",
    user_id
  )
  comment_result.move_next
  comment_count = comment_result.read(Int64)

  vote_result = POOL.query(
    "SELECT COALESCE(SUM(score), 0) FROM posts WHERE user_id = $1 AND is_user_post = true",
    user_id
  )
  vote_result.move_next
  total_votes = vote_result.read(Int64)

  user_result = POOL.query(
    "SELECT created_at, last_login FROM users WHERE id = $1",
    user_id
  )
  user_result.move_next
  joined_at = user_result.read(Time).to_s
  last_login = user_result.read(Time?)
  last_active = last_login ? last_login.to_s : ""

  env.response.status_code = 200
  {
    "status"   => "success",
    "username" => username,
    "stats"    => {
      "posts" => {
        "total" => post_count,
        "score" => stats["posts_interacted"]?.try &.as_i64 || 0,
      },
      "comments" => {
        "total" => comment_count,
        "score" => stats["comments"]?.try &.as_i64 || 0,
      },
      "votes" => {
        "upvotes"        => stats["upvotes"]?.try &.as_i64 || 0,
        "downvotes"      => stats["downvotes"]?.try &.as_i64 || 0,
        "total_received" => total_votes,
      },
      "engagement" => {
        "score"        => engagement_score,
        "saves"        => stats["saves"]?.try &.as_i64 || 0,
        "sources_used" => stats["sources_used"]?.try &.as_i64 || 0,
      },
      "activity" => {
        "joined_at"      => joined_at,
        "last_active"    => last_active,
        "peak_hour"      => activity["peak_hour"],
        "avg_hourly"     => activity["avg_hourly"],
        "total_activity" => activity["total_activity"],
      },
      "favorites" => {
        "sources" => favorite_sources,
        "tags"    => favorite_tags,
      },
    },
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
      "message" => "Username is required",
    }.to_json
  end

  if days > 30
    days = 30
  end

  user = UserDB.find_by_username(username)
  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found",
    }.to_json
  end

  user_id = user["id"].as_i64

  valid, current_user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  is_own_profile = valid && current_user_id == user_id

  if !is_own_profile
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "You can only view your own history",
    }.to_json
  end

  history = UserAlgorithms.get_engagement_history(user_id, days)

  env.response.status_code = 200
  {
    "status"   => "success",
    "username" => username,
    "days"     => days,
    "history"  => history,
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
      "message" => "Username is required",
    }.to_json
  end

  if limit > 50
    limit = 50
  end

  user = UserDB.find_by_username(username)
  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found",
    }.to_json
  end

  user_id = user["id"].as_i64

  valid, current_user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  is_own_profile = valid && current_user_id == user_id

  if !is_own_profile
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "You can only view your own recommendations",
    }.to_json
  end

  recommendations = UserAlgorithms.get_recommendations(user_id, limit)

  env.response.status_code = 200
  {
    "status"   => "success",
    "username" => username,
    "results"  => recommendations,
    "count"    => recommendations.size,
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
      "message" => "Username is required",
    }.to_json
  end

  if post_id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid post ID",
    }.to_json
  end

  if limit > 20
    limit = 20
  end

  user = UserDB.find_by_username(username)
  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found",
    }.to_json
  end

  user_id = user["id"].as_i64

  valid, current_user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  is_own_profile = valid && current_user_id == user_id

  if !is_own_profile
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "You can only view your own recommendations",
    }.to_json
  end

  recommendations = UserAlgorithms.get_related_recommendations(user_id, post_id, limit)

  env.response.status_code = 200
  {
    "status"   => "success",
    "username" => username,
    "post_id"  => post_id,
    "results"  => recommendations,
    "count"    => recommendations.size,
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
      "message" => "Both usernames are required",
    }.to_json
  end

  user = UserDB.find_by_username(username)
  if user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "User not found",
    }.to_json
  end

  other_user = UserDB.find_by_username(other_username)
  if other_user.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "Other user not found",
    }.to_json
  end

  user_id = user["id"].as_i64
  other_user_id = other_user["id"].as_i64

  valid, current_user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  is_own_profile = valid && current_user_id == user_id

  if !is_own_profile
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "You can only view your own similarity",
    }.to_json
  end

  similarity = UserAlgorithms.calculate_user_similarity(user_id, other_user_id)

  env.response.status_code = 200
  {
    "status"           => "success",
    "username"         => username,
    "other_username"   => other_username,
    "similarity_score" => similarity.round(4),
  }.to_json
end
