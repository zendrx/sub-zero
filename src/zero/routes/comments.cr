# routes/comments.cr - Comment routes for Crystal Aggregator

require "json"
require "kemal"

# Comment creation params
struct CommentParams
  include JSON::Serializable
  
  property post_id : Int64
  property content : String
  property parent_id : Int64?
end

# Helper to parse JSON body safely
def parse_json_body(env)
  body = env.request.body
  if body.nil?
    raise "Request body is empty"
  end
  CommentParams.from_json(body)
end

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
    # Parse JSON body into typed struct - handle nil body
    body = env.request.body
    if body.nil?
      env.response.status_code = 400
      next {
        "status"  => "error",
        "message" => "Request body is empty"
      }.to_json
    end
    
    params = CommentParams.from_json(body)
    
    if params.content.empty?
      env.response.status_code = 400
      next {
        "status"  => "error",
        "message" => "Comment content is required"
      }.to_json
    end
    
    if params.content.size > 10000
      env.response.status_code = 400
      next {
        "status"  => "error",
        "message" => "Comment is too long (max 10000 characters)"
      }.to_json
    end
    
    # Check if post exists
    post_result = POOL.query("SELECT id FROM posts WHERE id = $1", params.post_id)
    if !post_result.move_next
      env.response.status_code = 404
      next {
        "status"  => "error",
        "message" => "Post not found"
      }.to_json
    end
    
    comment_id = CommentDB.create(params.post_id, user_id, params.content, params.parent_id)
    
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
  rescue JSON::SerializableError
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid JSON payload"
    }.to_json
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
  
  user_result = POOL.query(
    "SELECT username FROM users WHERE id = $1",
    comment["user_id"]
  )
  username = "deleted"
  if user_result.move_next
    username = user_result.read(String)
  end
  
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
    body = env.request.body
    if body.nil?
      env.response.status_code = 400
      next {
        "status"  => "error",
        "message" => "Request body is empty"
      }.to_json
    end
    
    params = CommentParams.from_json(body)
    
    if params.content.empty?
      env.response.status_code = 400
      next {
        "status"  => "error",
        "message" => "Comment content is required"
      }.to_json
    end
    
    if params.content.size > 10000
      env.response.status_code = 400
      next {
        "status"  => "error",
        "message" => "Comment is too long (max 10000 characters)"
      }.to_json
    end
    
    POOL.exec(
      "UPDATE comments SET content = $1, updated_at = NOW() WHERE id = $2",
      params.content, id
    )
    
    env.response.status_code = 200
    {
      "status"  => "success",
      "message" => "Comment updated successfully"
    }.to_json
  rescue JSON::SerializableError
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Invalid JSON payload"
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
  
  result = POOL.query("
