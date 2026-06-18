# routes/search.cr - Search routes for Crystal Aggregator
# Handles searching posts, users, comments, and other content

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
  
  # Check if user is authenticated and admin for email search
  valid, user_id, user = Auth.validate_session(env.request.headers, env.request.cookies)
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
  
  # Search across multiple content types
  posts = PostDB.search(query, limit, 0)
  comments = search_comments(query, nil, limit, 0)
  
  # Get users if authenticated
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)
  users = [] of Hash(String, JSON::Type)
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
    query = env.params.json["query"]?.try &.as(String) || ""
    sources = env.params.json["sources"]?.try &.as(Array(String)) || [] of String
    tags = env.params.json["tags"]?.try &.as(Array(String)) || [] of String
    from_date = env.params.json["from_date"]?.try &.as(String)
    to_date = env.params.json["to_date"]?.try &.as(String)
    min_score = env.params.json["min_score"]?.try &.to_i || 0
    limit = env.params.json["limit"]?.try &.to_i || 20
    offset = env.params.json["offset"]?.try &.to_i || 0
    
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
      "message" => "Internal server error"
    }.to_json
  end
end

# Helper functions for searching

# Search users by username
def search_users(query : String, limit : Int32, offset : Int32, is_admin : Bool = false) : Array(Hash(String, JSON::Type))
  if is_admin
    # Admins can search by username or email
    result = POOL.exec(
      "SELECT id, username, email, created_at, is_admin 
       FROM users 
       WHERE username ILIKE $1 OR email ILIKE $1
       ORDER BY created_at DESC
       LIMIT $2 OFFSET $3",
      "%#{query}%", limit, offset
    )
  else
    # Regular users can only search by username
    result = POOL.exec(
      "SELECT id, username, email, created_at, is_admin 
       FROM users 
       WHERE username ILIKE $1
       ORDER BY created_at DESC
       LIMIT $2 OFFSET $3",
      "%#{query}%", limit, offset
    )
  end
  
  result.rows.map do |row|
    {
      "id"         => row[0].to_i64,
      "username"   => row[1].to_s,
      "email"      => is_admin ? row[2].to_s : nil,
      "created_at" => row[3].to_s,
      "is_admin"   => row[4].to_bool
    }
  end
end

# Search comments
def search_comments(query : String, post_id : Int64? = nil, limit : Int32 = 20, offset : Int32 = 0) : Array(Hash(String, JSON::Type))
  if post_id
    result = POOL.exec(
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
    result = POOL.exec(
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
  
  result.rows.map do |row|
    {
      "id"          => row[0].to_i64,
      "post_id"     => row[1].to_i64,
      "user_id"     => row[2]?.try &.to_i64,
      "content"     => row[3].to_s,
      "score"       => row[4].to_i,
      "created_at"  => row[5].to_s,
      "username"    => row[6]?.try &.to_s || "deleted",
      "post_title"  => row[7]?.try &.to_s || "unknown"
    }
  end
end

# Search by source
def search_by_source(source : String, query : String, limit : Int32, offset : Int32) : Array(Hash(String, JSON::Type))
  result = POOL.exec(
    "SELECT id, title, url, source, score, comment_count, created_at
     FROM posts
     WHERE source = $1 AND title ILIKE $2
     ORDER BY score DESC
     LIMIT $3 OFFSET $4",
    source, "%#{query}%", limit, offset
  )
  
  result.rows.map do |row|
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
end

# Search by tag (simple tag matching from title)
def search_by_tag(tag : String, limit : Int32, offset : Int32) : Array(Hash(String, JSON::Type))
  result = POOL.exec(
    "SELECT id, title, url, source, score, comment_count, created_at
     FROM posts
     WHERE title ILIKE $1
     ORDER BY score DESC
     LIMIT $2 OFFSET $3",
    "%#{tag}%", limit, offset
  )
  
  result.rows.map do |row|
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
end

# Advanced search with multiple filters
def advanced_search(query : String, sources : Array(String), tags : Array(String), 
                   from_date : String?, to_date : String?, min_score : Int32,
                   limit : Int32, offset : Int32) : Array(Hash(String, JSON::Type))
  
  # Build the SQL query dynamically
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
  
  result = POOL.exec(sql, args: params)
  
  result.rows.map do |row|
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
end
