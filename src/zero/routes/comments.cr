# routes/comments.cr - Comment routes for Crystal Aggregator

require "json"
require "kemal"

# Create a new comment
post "/api/comments" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  
  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required"
    }.to_json
  end
  
  begin
    json_params = env.params.json
    
    # Extract post_id safely
    post_id_value = json_params["post_id"]?
    post_id = if post_id_value.is_a?(Array(JSON::Any))
                post_id_value.first?.try &.as_i64
              else
                post_id_value.try &.as_i64
              end
    
    # Extract content safely
    content_value = json_params["content"]?
    content = if content_value.is_a?(Array(JSON::Any))
                content_value.first?.try &.as_s || ""
              else
                content_value.try &.as_s || ""
              end
    
    # Extract parent_id safely
    parent_id_value = json_params["parent_id"]?
    parent_id = if parent_id_value.is_a?(Array(JSON::Any))
                  parent_id_value.first?.try &.as_i64
                else
                  parent_id_value.try &.as_i64
                end
    
    if post_id.nil?
      env.response.status_code = 400
      next {
        "status"  => "error",
        "message" => "Post ID is required"
      }.to_json
    end
    
    if content.empty?
      env.response.status_code = 400
      next {
        "status"  => "error",
        "message" => "Comment content is required"
      }.to_json
    end
    
    if content.size > 10000
      env.response.status_code = 400
      next {
        "status"  => "error",
        "message" => "Comment is too long (max 10000 characters)"
      }.to_json
    end
    
    # Check if post exists
    post_result = POOL.query("SELECT id FROM posts WHERE id = $1", post_id)
    if !post_result.move_next
      env.response.status_code = 404
      next {
        "status"  => "error",
        "message" => "Post not found"
      }.to_json
    end
    
    comment_id = CommentDB.create(post_id, user_id, content, parent_id)
    
    if comment_id
      env.response.status_code = 201
      {
        "status"     => "success",
        "message"    => "Comment created successfully",
        "comment_id" => comment_id
      }.to_json
    else
      env.response.status_code = 500
      {
        "status"  => "error",
        "message" => "Failed to create comment"
      }.to_json
    end
  rescue e : Exception
    env.response.status_code = 500
    {
      "status"  => "error",
      "message" => "Internal server error: #{e.message}"
    }.to_json
  end
end

# Get a single comment by ID
get "/api/comments/:id" do |env|
  id = env.params.url["id"].to_i64?
  
  if id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid comment ID"
    }.to_json
  end
  
  comment = CommentDB.find(id)
  
  if comment.nil?
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "Comment not found"
    }.to_json
  end
  
  # Get user info for this comment
  user_result = POOL.query(
    "SELECT username FROM users WHERE id = $1",
    comment["user_id"]
  )
  username = "deleted"
  if user_result.move_next
    username = user_result.read(String)
  end
  
  # Check if user has voted on this comment
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  user_vote = nil
  if valid && user_id
    user_vote = VoteDB.get_comment_vote(user_id, id)
  end
  
  env.response.status_code = 200
  {
    "status" => "success",
    "comment" => comment.merge({
      "username"   => username,
      "user_vote"  => user_vote
    })
  }.to_json
end

# Edit a comment (only author or admin)
put "/api/comments/:id" do |env|
  id = env.params.url["id"].to_i64?
  
  if id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid comment ID"
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
  
  # Check if comment exists and belongs to user
  result = POOL.query(
    "SELECT user_id FROM comments WHERE id = $1",
    id
  )
  if !result.move_next
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "Comment not found"
    }.to_json
  end
  
  comment_user_id = result.read(Int64)
  
  is_admin = Auth.is_admin?(user_id)
  if comment_user_id != user_id && !is_admin
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "You don't have permission to edit this comment"
    }.to_json
  end
  
  begin
    content_value = env.params.json["content"]?
    content = if content_value.is_a?(Array(JSON::Any))
                content_value.first?.try &.as_s || ""
              else
                content_value.try &.as_s || ""
              end
    
    if content.empty?
      env.response.status_code = 400
      next {
        "status"  => "error",
        "message" => "Comment content is required"
      }.to_json
    end
    
    if content.size > 10000
      env.response.status_code = 400
      next {
        "status"  => "error",
        "message" => "Comment is too long (max 10000 characters)"
      }.to_json
    end
    
    POOL.exec(
      "UPDATE comments SET content = $1, updated_at = NOW() WHERE id = $2",
      content, id
    )
    
    env.response.status_code = 200
    {
      "status"  => "success",
      "message" => "Comment updated successfully"
    }.to_json
  rescue e : Exception
    env.response.status_code = 500
    {
      "status"  => "error",
      "message" => "Internal server error"
    }.to_json
  end
end

# Delete a comment (only author or admin)
delete "/api/comments/:id" do |env|
  id = env.params.url["id"].to_i64?
  
  if id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid comment ID"
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
  
  # Check if comment exists and belongs to user
  result = POOL.query(
    "SELECT user_id, post_id FROM comments WHERE id = $1",
    id
  )
  if !result.move_next
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "Comment not found"
    }.to_json
  end
  
  comment_user_id = result.read(Int64)
  post_id = result.read(Int64)
  
  is_admin = Auth.is_admin?(user_id)
  if comment_user_id != user_id && !is_admin
    env.response.status_code = 403
    next {
      "status"  => "error",
      "message" => "You don't have permission to delete this comment"
    }.to_json
  end
  
  POOL.exec("DELETE FROM comments WHERE id = $1", id)
  
  # Update comment count on post
  if post_id
    PostDB.update_comment_count(post_id)
  end
  
  env.response.status_code = 200
  {
    "status"  => "success",
    "message" => "Comment deleted successfully"
  }.to_json
end

# Upvote a comment
post "/api/comments/:id/upvote" do |env|
  id = env.params.url["id"].to_i64?
  
  if id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid comment ID"
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
  
  # Check if comment exists
  result = POOL.query("SELECT id FROM comments WHERE id = $1", id)
  if !result.move_next
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "Comment not found"
    }.to_json
  end
  
  success = VoteDB.cast_comment_vote(user_id, id, 1)
  
  if success
    env.response.status_code = 200
    {
      "status"  => "success",
      "message" => "Comment upvoted successfully"
    }.to_json
  else
    env.response.status_code = 500
    {
      "status"  => "error",
      "message" => "Failed to cast vote"
    }.to_json
  end
end

# Downvote a comment
post "/api/comments/:id/downvote" do |env|
  id = env.params.url["id"].to_i64?
  
  if id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid comment ID"
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
  
  # Check if comment exists
  result = POOL.query("SELECT id FROM comments WHERE id = $1", id)
  if !result.move_next
    env.response.status_code = 404
    next {
      "status"  => "error",
      "message" => "Comment not found"
    }.to_json
  end
  
  success = VoteDB.cast_comment_vote(user_id, id, -1)
  
  if success
    env.response.status_code = 200
    {
      "status"  => "success",
      "message" => "Comment downvoted successfully"
    }.to_json
  else
    env.response.status_code = 500
    {
      "status"  => "error",
      "message" => "Failed to cast vote"
    }.to_json
  end
end

# Get comment replies (nested comments)
get "/api/comments/:id/replies" do |env|
  id = env.params.url["id"].to_i64?
  
  if id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid comment ID"
    }.to_json
  end
  
  limit = env.params.query["limit"]?.try &.to_i || 20
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if limit > 100
    limit = 100
  end
  
  result = POOL.query(
    "SELECT c.id, c.user_id, c.content, c.score, c.created_at,
            u.username
     FROM comments c
     LEFT JOIN users u ON c.user_id = u.id
     WHERE c.parent_id = $1
     ORDER BY c.score DESC, c.created_at ASC
     LIMIT $2 OFFSET $3",
    id, limit, offset
  )
  
  replies = [] of Hash(String, JSON::Any)
  result.each do
    reply = Hash(String, JSON::Any).new
    reply["id"] = JSON::Any.new(result.read(Int64))
    user_id = result.read(Int64?)
    if user_id
      reply["user_id"] = JSON::Any.new(user_id)
    else
      reply["user_id"] = JSON::Any.new(0_i64)
    end
    reply["content"] = JSON::Any.new(result.read(String))
    reply["score"] = JSON::Any.new(result.read(Int32))
    reply["created_at"] = JSON::Any.new(result.read(Time).to_s)
    username = result.read(String?)
    if username
      reply["username"] = JSON::Any.new(username)
    else
      reply["username"] = JSON::Any.new("deleted")
    end
    replies << reply
  end
  
  env.response.status_code = 200
  {
    "status" => "success",
    "comment_id" => id,
    "results" => replies,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => replies.size
    }
  }.to_json
end

# Get comments by user
get "/api/comments/user/:user_id" do |env|
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
    "status" => "success",
    "user_id" => user_id,
    "results" => comments,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => comments.size
    }
  }.to_json
end

# Get comment count for a post
get "/api/posts/:id/comment-count" do |env|
  id = env.params.url["id"].to_i64?
  
  if id.nil?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid post ID"
    }.to_json
  end
  
  result = POOL.query(
    "SELECT COUNT(*) FROM comments WHERE post_id = $1",
    id
  )
  result.move_next
  count = result.read(Int64)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "post_id" => id,
    "comment_count" => count
  }.to_json
end
