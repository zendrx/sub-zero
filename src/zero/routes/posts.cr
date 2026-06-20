# routes/posts.cr - Post routes for Crystal Aggregator

require "json"
require "kemal"

# Get feed based on type
get "/api/posts" do |env|
  feed_type = env.params.query["feed"]?.try &.to_s || "hot"
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if limit > 100
    limit = 100
  end
  
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
                   else RecommendationEngine::FeedType::Hot
                   end
  
  if (feed_type_enum == RecommendationEngine::FeedType::Personalized || 
      feed_type_enum == RecommendationEngine::FeedType::Discovery ||
      feed_type_enum == RecommendationEngine::FeedType::Collaborative ||
      feed_type_enum == RecommendationEngine::FeedType::Mixed) && !valid
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

# Get single post by ID
get "/api/posts/:id" do |env|
  id = env.params.url["id"].to_i64?
  
  if id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid post ID"
    }.to_json
  end
  
  post = PostDB.find(id)
  
  if post.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "Post not found"
    }.to_json
  end
  
  comments = CommentDB.get_for_post(id, 50, 0)
  
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  user_vote = nil
  if valid && user_id
    user_vote = VoteDB.get_post_vote(user_id, id)
  end
  
  env.response.status_code = 200
  {
    "status" => "success",
    "post" => post,
    "comments" => comments,
    "user_vote" => user_vote
  }.to_json
end

# Create a new post (user-submitted)
post "/api/posts" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  
  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required"
    }.to_json
  end
  
  begin
    body = env.request.body
    if body.nil?
      env.response.status_code = 400
      next {
        "status"  => "error",
        "message" => "Request body is empty"
      }.to_json
    end
    
    json_params = JSON.parse(body)
    
    title = json_params["title"]?.try &.as_s || ""
    url = json_params["url"]?.try &.as_s || ""
    content = json_params["content"]?.try &.as_s || ""
    
    if title.empty?
      env.response.status_code = 400
      next {
        "status"  => "error",
        "message" => "Title is required"
      }.to_json
    end
    
    if url.empty? && content.empty?
      env.response.status_code = 400
      next {
        "status"  => "error",
        "message" => "Either URL or content is required"
      }.to_json
    end
    
    result = POOL.query(
      "INSERT INTO posts (title, url, content, source, user_id, is_user_post) 
       VALUES ($1, $2, $3, 'user', $4, true) RETURNING id",
      title, url, content, user_id
    )
    result.move_next
    post_id = result.read(Int64)
    
    env.response.status_code = 201
    {
      "status"  => "success",
      "message" => "Post created successfully",
      "post_id" => post_id
    }.to_json
  rescue e : Exception
    env.response.status_code = 500
    {
      "status"  => "error",
      "message" => "Internal server error: #{e.message}"
    }.to_json
  end
end

# Edit a post (only author or admin)
put "/api/posts/:id" do |env|
  id = env.params.url["id"].to_i64?
  
  if id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid post ID"
    }.to_json
  end
  
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  
  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required"
    }.to_json
  end
  
  result = POOL.query(
    "SELECT user_id, is_user_post FROM posts WHERE id = $1",
    id
  )
  if !result.move_next
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "Post not found"
    }.to_json
  end
  
  post_user_id = result.read(Int64?)
  is_user_post = result.read(Bool?) || false
  
  if !is_user_post
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "Cannot edit external posts"
    }.to_json
  end
  
  is_admin = Auth.is_admin?(user_id)
  if post_user_id != user_id && !is_admin
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "You don't have permission to edit this post"
    }.to_json
  end
  
  begin
    body = env.request.body
    if body.nil?
      env.response.status_code = 400
      next {
        "status"  => "error",
        "message" => "Request body is empty"
      }.to_json
    end
    
    json_params = JSON.parse(body)
    
    title = json_params["title"]?.try &.as_s
    url = json_params["url"]?.try &.as_s
    content = json_params["content"]?.try &.as_s
    
    updates = [] of String
    params = [] of String | Int64
    
    if title && !title.empty?
      updates << "title = $#{params.size + 1}"
      params << title
    end
    
    if url
      updates << "url = $#{params.size + 1}"
      params << url
    end
    
    if content
      updates << "content = $#{params.size + 1}"
      params << content
    end
    
    if updates.empty?
      env.response.status_code = 400
      next {
        "status"  => "error",
        "message" => "No fields to update"
      }.to_json
    end
    
    updates << "updated_at = NOW()"
    params << id
    
    POOL.exec(
      "UPDATE posts SET #{updates.join(", ")} WHERE id = $#{params.size}",
      args: params
    )
    
    env.response.status_code = 200
    {
      "status"  => "success",
      "message" => "Post updated successfully"
    }.to_json
  rescue e : Exception
    env.response.status_code = 500
    {
      "status"  => "error",
      "message" => "Internal server error"
    }.to_json
  end
end

# Delete a post (only author or admin)
delete "/api/posts/:id" do |env|
  id = env.params.url["id"].to_i64?
  
  if id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid post ID"
    }.to_json
  end
  
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  
  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required"
    }.to_json
  end
  
  result = POOL.query(
    "SELECT user_id, is_user_post FROM posts WHERE id = $1",
    id
  )
  if !result.move_next
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "Post not found"
    }.to_json
  end
  
  post_user_id = result.read(Int64?)
  is_user_post = result.read(Bool?) || false
  
  if !is_user_post
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "Cannot delete external posts"
    }.to_json
  end
  
  is_admin = Auth.is_admin?(user_id)
  if post_user_id != user_id && !is_admin
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "You don't have permission to delete this post"
    }.to_json
  end
  
  POOL.exec("DELETE FROM posts WHERE id = $1", id)
  
  env.response.status_code = 200
  {
    "status"  => "success",
    "message" => "Post deleted successfully"
  }.to_json
end

# Upvote a post
post "/api/posts/:id/upvote" do |env|
  id = env.params.url["id"].to_i64?
  
  if id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid post ID"
    }.to_json
  end
  
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  
  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required"
    }.to_json
  end
  
  success = VoteDB.cast_post_vote(user_id, id, 1)
  
  if success
    env.response.status_code = 200
    {
      "status"  => "success",
      "message" => "Upvoted successfully"
    }.to_json
  else
    env.response.status_code = 500
    {
      "status"  => "error",
      "message" => "Failed to cast vote"
    }.to_json
  end
end

# Downvote a post
post "/api/posts/:id/downvote" do |env|
  id = env.params.url["id"].to_i64?
  
  if id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid post ID"
    }.to_json
  end
  
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  
  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required"
    }.to_json
  end
  
  success = VoteDB.cast_post_vote(user_id, id, -1)
  
  if success
    env.response.status_code = 200
    {
      "status"  => "success",
      "message" => "Downvoted successfully"
    }.to_json
  else
    env.response.status_code = 500
    {
      "status"  => "error",
      "message" => "Failed to cast vote"
    }.to_json
  end
end

# Save a post
post "/api/posts/:id/save" do |env|
  id = env.params.url["id"].to_i64?
  
  if id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid post ID"
    }.to_json
  end
  
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  
  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required"
    }.to_json
  end
  
  success = SaveDB.save(user_id, id)
  
  if success
    env.response.status_code = 200
    {
      "status"  => "success",
      "message" => "Post saved successfully"
    }.to_json
  else
    env.response.status_code = 500
    {
      "status"  => "error",
      "message" => "Failed to save post"
    }.to_json
  end
end

# Unsave a post
delete "/api/posts/:id/save" do |env|
  id = env.params.url["id"].to_i64?
  
  if id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid post ID"
    }.to_json
  end
  
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  
  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required"
    }.to_json
  end
  
  success = SaveDB.unsave(user_id, id)
  
  if success
    env.response.status_code = 200
    {
      "status"  => "success",
      "message" => "Post unsaved successfully"
    }.to_json
  else
    env.response.status_code = 500
    {
      "status"  => "error",
      "message" => "Failed to unsave post"
    }.to_json
  end
end

# Get saved posts for current user
get "/api/posts/saved" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  
  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required"
    }.to_json
  end
  
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if limit > 100
    limit = 100
  end
  
  saved_posts = SaveDB.get_user_saves(user_id, limit, offset)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "results" => saved_posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => saved_posts.size
    }
  }.to_json
end

# Get posts by source
get "/api/posts/source/:source" do |env|
  source = env.params.url["source"]
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if limit > 100
    limit = 100
  end
  
  result = POOL.query(
    "SELECT id, title, url, source, score, comment_count, created_at
     FROM posts
     WHERE source = $1 AND is_user_post = false
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

# Get user's posts
get "/api/posts/user/:user_id" do |env|
  user_id = env.params.url["user_id"].to_i64?
  
  if user_id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid user ID"
    }.to_json
  end
  
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if limit > 100
    limit = 100
  end
  
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
    "status" => "success",
    "user_id" => user_id,
    "results" => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => posts.size
    }
  }.to_json
end

# Get post comments with pagination
get "/api/posts/:id/comments" do |env|
  id = env.params.url["id"].to_i64?
  
  if id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid post ID"
    }.to_json
  end
  
  limit = env.params.query["limit"]?.try &.to_i || 50
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if limit > 100
    limit = 100
  end
  
  comments = CommentDB.get_for_post(id, limit, offset)
  
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  user_votes = {} of Int64 => Int32
  if valid && user_id
    comments.each do |comment|
      vote = VoteDB.get_comment_vote(user_id, comment["id"].as_i64)
      if vote
        user_votes[comment["id"].as_i64] = vote
      end
    end
  end
  
  env.response.status_code = 200
  {
    "status" => "success",
    "post_id" => id,
    "results" => comments,
    "user_votes" => user_votes,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => comments.size
    }
  }.to_json
end

# Get random posts (discovery)
get "/api/posts/random" do |env|
  limit = env.params.query["limit"]?.try &.to_i || 10
  
  if limit > 50
    limit = 50
  end
  
  result = POOL.query(
    "SELECT id, title, url, source, score, comment_count, created_at
     FROM posts
     WHERE is_user_post = false
     ORDER BY RANDOM()
     LIMIT $1",
    limit
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
    "results" => posts
  }.to_json
end
