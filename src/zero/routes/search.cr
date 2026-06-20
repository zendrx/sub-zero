# routes/search.cr - Search routes for Crystal Aggregator

require "json"
require "kemal"

# Search posts by title or content
get "/api/search/posts" do |env|
  query = env.params.query["q"]?
  limit = env.params.query["limit"]?.try &.to_i || 20
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if query.nil? || query.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Search query is required"
    }.to_json
  end
  
  if limit > 100
    limit = 100
  end
  
  posts = PostDB.search(query, limit, offset)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "query"  => query,
    "results" => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => posts.size
    }
  }.to_json
end

# Search users by username or email (admin only for email)
get "/api/search/users" do |env|
  query = env.params.query["q"]?
  limit = env.params.query["limit"]?.try &.to_i || 20
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if query.nil? || query.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Search query is required"
    }.to_json
  end
  
  if limit > 100
    limit = 100
  end
  
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  is_admin = user_id ? Auth.is_admin?(user_id) : false
  
  users = search_users(query, limit, offset, is_admin)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "query"  => query,
    "results" => users,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => users.size
    }
  }.to_json
end

# Search comments
get "/api/search/comments" do |env|
  query = env.params.query["q"]?
  post_id = env.params.query["post_id"]?.try &.to_i64
  limit = env.params.query["limit"]?.try &.to_i || 20
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if query.nil? || query.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Search query is required"
    }.to_json
  end
  
  if limit > 100
    limit = 100
  end
  
  comments = search_comments(query, post_id, limit, offset)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "query"  => query,
    "post_id" => post_id,
    "results" => comments,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => comments.size
    }
  }.to_json
end

# Global search across all content types
get "/api/search/all" do |env|
  query = env.params.query["q"]?
  limit = env.params.query["limit"]?.try &.to_i || 10
  
  if query.nil? || query.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Search query is required"
    }.to_json
  end
  
  if limit > 50
    limit = 50
  end
  
  posts = PostDB.search(query, limit, 0)
  comments = search_comments(query, nil, limit, 0)
  
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  users = [] of Hash(String, JSON::Any)
  if valid && user_id
    is_admin = Auth.is_admin?(user_id)
    users = search_users(query, limit, 0, is_admin)
  end
  
  env.response.status_code = 200
  {
    "status" => "success",
    "query"  => query,
    "results" => {
      "posts"    => posts,
      "comments" => comments,
      "users"    => users
    },
    "total" => {
      "posts"    => posts.size,
      "comments" => comments.size,
      "users"    => users.size
    }
  }.to_json
end

# Search by source (reddit, hackernews, devto, user)
get "/api/search/source/:source" do |env|
  source = env.params.url["source"]
  query = env.params.query["q"]?
  limit = env.params.query["limit"]?.try &.to_i || 20
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if query.nil? || query.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Search query is required"
    }.to_json
  end
  
  if limit > 100
    limit = 100
  end
  
  posts = search_by_source(source, query, limit, offset)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "source" => source,
    "query"  => query,
    "results" => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => posts.size
    }
  }.to_json
end

# Search by tag
get "/api/search/tag/:tag" do |env|
  tag = env.params.url["tag"]
  limit = env.params.query["limit"]?.try &.to_i || 20
  offset = env.params.query["offset"]?.try &.to_i || 0
  
  if tag.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Tag is required"
    }.to_json
  end
  
  if limit > 100
    limit = 100
  end
  
  posts = search_by_tag(tag, limit, offset)
  
  env.response.status_code = 200
  {
    "status" => "success",
    "tag"    => tag,
    "results" => posts,
    "pagination" => {
      "limit"  => limit,
      "offset" => offset,
      "count"  => posts.size
    }
  }.to_json
end

# Advanced search with filters
post "/api/search/advanced" do |env|
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
    
    query = json_params["query"]?.try &.as_s || ""
    sources = json_params["sources"]?.try &.as_a?.try &.map(&.as_s) || [] of String
    tags = json_params["tags"]?.try &.as_a?.try &.map(&.as_s) || [] of String
    from_date = json_params["from_date"]?.try &.as_s
    to_date = json_params["to_date"]?.try &.as_s
    min_score = json_params["min_score"]?.try &.as_i || 0
    limit = json_params["limit"]?.try &.as_i || 20
    offset = json_params["offset"]?.try &.as_i || 0
    
    if query.empty?
      env.response.status_code = 400
      next {
        "status"  => "error",
        "message" => "Search query is required"
      }.to_json
    end
    
    if limit > 100
      limit = 100
    end
    
    posts = advanced_search(query, sources, tags, from_date, to_date, min_score, limit, offset)
    
    env.response.status_code = 200
    {
      "status" => "success",
      "query"  => query,
      "filters" => {
        "sources"   => sources,
        "tags"      => tags,
        "from_date" => from_date,
        "to_date"   => to_date,
        "min_score" => min_score
      },
      "results" => posts,
      "pagination" => {
        "limit"  => limit,
        "offset" => offset,
        "count"  => posts.size
      }
    }.to_json
  rescue e : Exception
    env.response.status_code = 500
    {
      "status"  => "error",
      "message" => "Internal server error: #{e.message}"
    }.to_json
  end
end

# Helper functions for searching

# Search users by username
def search_users(query : String, limit : Int32, offset : Int32, is_admin : Bool = false) : Array(Hash(String, JSON::Any))
  if is_admin
    result = POOL.query(
      "SELECT id, username, email, created_at, is_admin 
       FROM users 
       WHERE username ILIKE $1 OR email ILIKE $1
       ORDER BY created_at DESC
       LIMIT $2 OFFSET $3",
      "%#{query}%", limit, offset
    )
  else
    result = POOL.query(
      "SELECT id, username, email, created_at, is_admin 
       FROM users 
       WHERE username ILIKE $1
       ORDER BY created_at DESC
       LIMIT $2 OFFSET $3",
      "%#{query}%", limit, offset
    )
  end
  
  users = [] of Hash(String, JSON::Any)
  result.each do
    user = Hash(String, JSON::Any).new
    user["id"] = JSON::Any.new(result.read(Int64))
    user["username"] = JSON::Any.new(result.read(String))
    if is_admin
      user["email"] = JSON::Any.new(result.read(String))
    else
      email = result.read(String)
      user["email"] = JSON::Any.new(nil)
    end
    user["created_at"] = JSON::Any.new(result.read(Time).to_s)
    user["is_admin"] = JSON::Any.new(result.read(Bool))
    users << user
  end
  users
end

# Search comments
def search_comments(query : String, post_id : Int64? = nil, limit : Int32 = 20, offset : Int32 = 0) : Array(Hash(String, JSON::Any))
  if post_id
    result = POOL.query(
      "SELECT c.id, c.post_id, c.user_id, c.content, c.score, c.created_at,
              u.username, p.title as post_title
       FROM comments c
       LEFT JOIN users u ON c.user_id = u.id
       LEFT JOIN posts p ON c.post_id = p.id
       WHERE c.content ILIKE $1 AND c.post_id = $2
       ORDER BY c.created_at DESC
       LIMIT $3 OFFSET $4",
      "%#{query}%", post_id, limit, offset
    )
  else
    result = POOL.query(
      "SELECT c.id, c.post_id, c.user_id, c.content, c.score, c.created_at,
              u.username, p.title as post_title
       FROM comments c
       LEFT JOIN users u ON c.user_id = u.id
       LEFT JOIN posts p ON c.post_id = p.id
       WHERE c.content ILIKE $1
       ORDER BY c.created_at DESC
       LIMIT $2 OFFSET $3",
      "%#{query}%", limit, offset
    )
  end
  
  comments = [] of Hash(String, JSON::Any)
  result.each do
    comment = Hash(String, JSON::Any).new
    comment["id"] = JSON::Any.new(result.read(Int64))
    comment["post_id"] = JSON::Any.new(result.read(Int64))
    user_id = result.read(Int64?)
    if user_id
      comment["user_id"] = JSON::Any.new(user_id)
    else
      comment["user_id"] = JSON::Any.new(0_i64)
    end
    comment["content"] = JSON::Any.new(result.read(String))
    comment["score"] = JSON::Any.new(result.read(Int32))
    comment["created_at"] = JSON::Any.new(result.read(Time).to_s)
    username = result.read(String?)
    if username
      comment["username"] = JSON::Any.new(username)
    else
      comment["username"] = JSON::Any.new("deleted")
    end
    post_title = result.read(String?)
    if post_title
      comment["post_title"] = JSON::Any.new(post_title)
    else
      comment["post_title"] = JSON::Any.new("unknown")
    end
    comments << comment
  end
  comments
end

# Search by source
def search_by_source(source : String, query : String, limit : Int32, offset : Int32) : Array(Hash(String, JSON::Any))
  result = POOL.query(
    "SELECT id, title, url, source, score, comment_count, created_at
     FROM posts
     WHERE source = $1 AND title ILIKE $2
     ORDER BY score DESC
     LIMIT $3 OFFSET $4",
    source, "%#{query}%", limit, offset
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
  posts
end

# Search by tag (simple tag matching from title)
def search_by_tag(tag : String, limit : Int32, offset : Int32) : Array(Hash(String, JSON::Any))
  result = POOL.query(
    "SELECT id, title, url, source, score, comment_count, created_at
     FROM posts
     WHERE title ILIKE $1
     ORDER BY score DESC
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
  posts
end

# Advanced search with multiple filters
def advanced_search(query : String, sources : Array(String), tags : Array(String), 
                   from_date : String?, to_date : String?, min_score : Int32,
                   limit : Int32, offset : Int32) : Array(Hash(String, JSON::Any))
  
  sql = "SELECT id, title, url, source, score, comment_count, created_at FROM posts WHERE title ILIKE $1"
  params = ["%#{query}%"] of String | Int32 | String
  
  if !sources.empty?
    placeholders = sources.map_with_index { |_, i| "$#{params.size + i + 1}" }.join(",")
    sql += " AND source IN (#{placeholders})"
    sources.each { |s| params << s }
  end
  
  if !tags.empty?
    tag_conditions = tags.map { |tag| "title ILIKE $#{params.size + 1}" }.join(" OR ")
    sql += " AND (#{tag_conditions})"
    tags.each { |tag| params << "%#{tag}%" }
  end
  
  if from_date
    sql += " AND created_at >= $#{params.size + 1}"
    params << from_date
  end
  
  if to_date
    sql += " AND created_at <= $#{params.size + 1}"
    params << to_date
  end
  
  if min_score > 0
    sql += " AND score >= $#{params.size + 1}"
    params << min_score
  end
  
  sql += " ORDER BY score DESC LIMIT $#{params.size + 1} OFFSET $#{params.size + 2}"
  params << limit
  params << offset
  
  result = POOL.query(sql, args: params)
  
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
  posts
end
