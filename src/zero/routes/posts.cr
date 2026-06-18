# routes/posts.cr - Post routes for Crystal Aggregator
# Handles all post operations including CRUD, voting, saving, and feed generation

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
                   else RecommendationEngine::FeedType::Hot
                   end
  
  # If feed requires authentication and user is not logged in
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
  
  # Get comments for this post
  comments = CommentDB.get_for_post(id, 50, 0)
  
  # Check if user has voted on this post
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
    title = env.params.json["title"]?.try &.as(String) || ""
    url = env.params.json["url"]?.try &.as(String) || ""
    content = env.params.json["content"]?.try &.as(String) || ""
    
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
    
    # Insert post with user_id
    result = POOL.exec(
      "INSERT INTO posts (title, url, content, source, user_id, is_user_post) 
       VALUES ($1, $2, $3, 'user', $4, true) RETURNING id",
      title, url, content, user_id
    )
    
    post_id = result.rows.first?[0]?.try &.to_i64
    
    if post_id
      env.response.status_code = 201
      {
        "status"  => "success",
        "message" => "Post created successfully",
        "post_id" => post_id
      }.to_json
    else
      env.response.status_code = 500
      {
        "status"  => "error",
        "message" => "Failed to create post"
      }.to_json
    end
  rescue e : Exception
    env.response.status_code = 500
    {
      "status"  => "error",
      "message" => "Internal server error"
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
  
  valid, user_id, user = Auth.validate_session(env.request.headers, env.request.cookies)
  
  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required"
    }.to_json
  end
  
  # Check if post exists and belongs to user or user is admin
  result = POOL.exec(
    "SELECT user_id, is_user_post FROM posts WHERE id = $1",
    id
  )
  row = result.rows.first?
  
  if row.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "Post not found"
    }.to_json
  end
  
  post_user_id = row[0]?.try &.to_i64
  is_user_post = row[1]?.try &.to_bool || false
  
  # Only allow editing if it's a user post
  if !is_user_post
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "Cannot edit external posts"
    }.to_json
  end
  
  # Check if user is author or admin
  is_admin = Auth.is_admin?(user_id)
  if post_user_id != user_id && !is_admin
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "You don't have permission to edit this post"
    }.to_json
  end
  
  begin
    title = env.params.json["title"]?.try &.as(String)
    url = env.params.json["url"]?.try &.as(String)
    content = env.params.json["content"]?.try &.as(String)
    
    # Build update query dynamically
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
  
  # Check if post exists and belongs to user or user is admin
  result = POOL.exec(
    "SELECT user_id, is_user_post FROM posts WHERE id = $1",
    id
  )
  row = result.rows.first?
  
  if row.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "Post not found"
    }.to_json
  end
  
  post_user_id = row[0]?.try &.to_i64
  is_user_post = row[1]?.try &.to_bool || false
  
  # Only allow deleting user posts
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
  
  result = POOL.exec(
    "SELECT id, title, url, source, score, comment_count, created_at
     FROM posts
     WHERE source = $1 AND is_user_post = false
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
  
  # Get user votes if authenticated
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  user_votes = {} of Int64 => Int32
  if valid && user_id
    comments.each do |comment|
      vote = VoteDB.get_comment_vote(user_id, comment["id"].to_i64)
      user_votes[comment["id"].to_i64] = vote if vote
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
  
  result = POOL.exec(
    "SELECT id, title, url, source, score, comment_count, created_at
     FROM posts
     WHERE is_user_post = false
     ORDER BY RANDOM()
     LIMIT $1",
    limit
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
    "results" => posts
  }.to_json
end
