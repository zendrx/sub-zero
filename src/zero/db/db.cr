# db.cr - Database layer for Crystal Aggregator

require "pg"
require "json"

def setup_database
  POOL.exec <<-SQL
    CREATE TABLE IF NOT EXISTS users (
      id SERIAL PRIMARY KEY,
      username TEXT UNIQUE NOT NULL,
      email TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      created_at TIMESTAMP DEFAULT NOW(),
      last_login TIMESTAMP,
      is_admin BOOLEAN DEFAULT FALSE
    )
  SQL

  POOL.exec <<-SQL
    CREATE TABLE IF NOT EXISTS posts (
      id SERIAL PRIMARY KEY,
      title TEXT NOT NULL,
      url TEXT,
      source TEXT NOT NULL,
      external_id TEXT,
      user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
      score INTEGER DEFAULT 0,
      comment_count INTEGER DEFAULT 0,
      created_at TIMESTAMP DEFAULT NOW(),
      updated_at TIMESTAMP DEFAULT NOW()
    )
  SQL

  POOL.exec <<-SQL
    CREATE TABLE IF NOT EXISTS comments (
      id SERIAL PRIMARY KEY,
      post_id INTEGER REFERENCES posts(id) ON DELETE CASCADE,
      user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
      parent_id INTEGER REFERENCES comments(id) ON DELETE CASCADE,
      content TEXT NOT NULL,
      score INTEGER DEFAULT 0,
      created_at TIMESTAMP DEFAULT NOW(),
      updated_at TIMESTAMP DEFAULT NOW()
    )
  SQL

  POOL.exec <<-SQL
    CREATE TABLE IF NOT EXISTS votes (
      id SERIAL PRIMARY KEY,
      user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
      post_id INTEGER REFERENCES posts(id) ON DELETE CASCADE,
      comment_id INTEGER REFERENCES comments(id) ON DELETE CASCADE,
      vote_type INTEGER NOT NULL,
      created_at TIMESTAMP DEFAULT NOW(),
      CONSTRAINT vote_target_check CHECK (
        (post_id IS NOT NULL AND comment_id IS NULL) OR
        (post_id IS NULL AND comment_id IS NOT NULL)
      ),
      CONSTRAINT unique_user_post_vote UNIQUE (user_id, post_id),
      CONSTRAINT unique_user_comment_vote UNIQUE (user_id, comment_id)
    )
  SQL

  POOL.exec <<-SQL
    CREATE TABLE IF NOT EXISTS saved_posts (
      id SERIAL PRIMARY KEY,
      user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
      post_id INTEGER REFERENCES posts(id) ON DELETE CASCADE,
      created_at TIMESTAMP DEFAULT NOW(),
      CONSTRAINT unique_user_post_save UNIQUE (user_id, post_id)
    )
  SQL

  POOL.exec "CREATE INDEX IF NOT EXISTS idx_posts_created_at ON posts(created_at DESC)"
  POOL.exec "CREATE INDEX IF NOT EXISTS idx_posts_score ON posts(score DESC)"
  POOL.exec "CREATE INDEX IF NOT EXISTS idx_comments_post_id ON comments(post_id)"
  POOL.exec "CREATE INDEX IF NOT EXISTS idx_votes_user_id ON votes(user_id)"
  POOL.exec "CREATE INDEX IF NOT EXISTS idx_users_username ON users(username)"
  POOL.exec "CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)"
end

# User operations
module UserDB
  # Create a new user with username, email, and hashed password
  # Returns the user ID if successful, nil otherwise
  def self.create(username : String, email : String, password_hash : String) : Int64?
    result = POOL.exec(
      "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id",
      username, email, password_hash
    )
    result.rows.first?[0]?.try &.to_i64
  rescue e : PG::Error
    puts "Failed to create user: #{e.message}"
    nil
  end

  # Find user by ID, returns hash with user data or nil
  def self.find(id : Int64) : Hash(String, JSON::Type)?
    result = POOL.exec(
      "SELECT id, username, email, created_at, last_login, is_admin FROM users WHERE id = $1",
      id
    )
    row = result.rows.first?
    return nil unless row

    {
      "id"         => row[0].to_i64,
      "username"   => row[1].to_s,
      "email"      => row[2].to_s,
      "created_at" => row[3].to_s,
      "last_login" => row[4]?.try &.to_s || "",
      "is_admin"   => row[5]?.try &.to_bool || false
    }
  end

  # Find user by username, returns hash with user data including password hash
  def self.find_by_username(username : String) : Hash(String, JSON::Type)?
    result = POOL.exec(
      "SELECT id, username, email, password_hash, created_at, is_admin FROM users WHERE username = $1",
      username
    )
    row = result.rows.first?
    return nil unless row

    {
      "id"            => row[0].to_i64,
      "username"      => row[1].to_s,
      "email"         => row[2].to_s,
      "password_hash" => row[3].to_s,
      "created_at"    => row[4].to_s,
      "is_admin"      => row[5]?.try &.to_bool || false
    }
  end

  # Find user by email, returns hash with user data including password hash
  def self.find_by_email(email : String) : Hash(String, JSON::Type)?
    result = POOL.exec(
      "SELECT id, username, email, password_hash, created_at, is_admin FROM users WHERE email = $1",
      email
    )
    row = result.rows.first?
    return nil unless row

    {
      "id"            => row[0].to_i64,
      "username"      => row[1].to_s,
      "email"         => row[2].to_s,
      "password_hash" => row[3].to_s,
      "created_at"    => row[4].to_s,
      "is_admin"      => row[5]?.try &.to_bool || false
    }
  end

  # Update user's last login timestamp
  def self.update_last_login(id : Int64) : Bool
    POOL.exec("UPDATE users SET last_login = NOW() WHERE id = $1", id)
    true
  rescue e : PG::Error
    puts "Failed to update last_login: #{e.message}"
    false
  end

  # Check if username or email already exists
  def self.exists?(username : String, email : String) : Bool
    result = POOL.exec(
      "SELECT COUNT(*) FROM users WHERE username = $1 OR email = $2",
      username, email
    )
    count = result.rows.first?[0].to_i
    count > 0
  end

  # Check if username exists
  def self.username_exists?(username : String) : Bool
    result = POOL.exec("SELECT COUNT(*) FROM users WHERE username = $1", username)
    result.rows.first?[0].to_i > 0
  end

  # Check if email exists
  def self.email_exists?(email : String) : Bool
    result = POOL.exec("SELECT COUNT(*) FROM users WHERE email = $1", email)
    result.rows.first?[0].to_i > 0
  end
end

# Post operations
module PostDB
  # Create a new post from external source
  def self.create(title : String, url : String, source : String, external_id : String? = nil) : Int64?
    result = POOL.exec(
      "INSERT INTO posts (title, url, source, external_id) VALUES ($1, $2, $3, $4) RETURNING id",
      title, url, source, external_id
    )
    result.rows.first?[0]?.try &.to_i64
  rescue e : PG::Error
    puts "Failed to create post: #{e.message}"
    nil
  end

  # Get posts with pagination, ordered by score
  def self.get_top(limit : Int32 = 50, offset : Int32 = 0) : Array(Hash(String, JSON::Type))
    result = POOL.exec(
      "SELECT id, title, url, source, score, comment_count, created_at FROM posts ORDER BY score DESC LIMIT $1 OFFSET $2",
      limit, offset
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

  # Get latest posts with pagination
  def self.get_latest(limit : Int32 = 50, offset : Int32 = 0) : Array(Hash(String, JSON::Type))
    result = POOL.exec(
      "SELECT id, title, url, source, score, comment_count, created_at FROM posts ORDER BY created_at DESC LIMIT $1 OFFSET $2",
      limit, offset
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

  # Get a single post by ID
  def self.find(id : Int64) : Hash(String, JSON::Type)?
    result = POOL.exec(
      "SELECT id, title, url, source, score, comment_count, created_at FROM posts WHERE id = $1",
      id
    )
    row = result.rows.first?
    return nil unless row

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

  # Search posts by title
  def self.search(query : String, limit : Int32 = 50) : Array(Hash(String, JSON::Type))
    result = POOL.exec(
      "SELECT id, title, url, source, score, comment_count, created_at FROM posts WHERE title ILIKE $1 ORDER BY score DESC LIMIT $2",
      "%#{query}%", limit
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

  # Increment post score
  def self.increment_score(id : Int64, amount : Int32 = 1) : Bool
    POOL.exec("UPDATE posts SET score = score + $1 WHERE id = $2", amount, id)
    true
  rescue e : PG::Error
    puts "Failed to update post score: #{e.message}"
    false
  end

  # Update comment count for a post
  def self.update_comment_count(id : Int64) : Bool
    POOL.exec(
      "UPDATE posts SET comment_count = (SELECT COUNT(*) FROM comments WHERE post_id = $1) WHERE id = $1",
      id
    )
    true
  rescue e : PG::Error
    puts "Failed to update comment count: #{e.message}"
    false
  end

  # Prune old posts with no engagement, keeps latest 10,000
  def self.prune_old_posts(keep_count : Int32 = 10000) : Int64
    result = POOL.exec(
      "DELETE FROM posts WHERE id NOT IN (SELECT id FROM posts ORDER BY created_at DESC LIMIT $1) RETURNING id",
      keep_count
    )
    result.rows.size.to_i64
  rescue e : PG::Error
    puts "Failed to prune posts: #{e.message}"
    0_i64
  end
end

# Comment operations
module CommentDB
  # Create a new comment on a post
  def self.create(post_id : Int64, user_id : Int64, content : String, parent_id : Int64? = nil) : Int64?
    result = POOL.exec(
      "INSERT INTO comments (post_id, user_id, content, parent_id) VALUES ($1, $2, $3, $4) RETURNING id",
      post_id, user_id, content, parent_id
    )
    comment_id = result.rows.first?[0]?.try &.to_i64
    PostDB.update_comment_count(post_id) if comment_id
    comment_id
  rescue e : PG::Error
    puts "Failed to create comment: #{e.message}"
    nil
  end

  # Get comments for a post with pagination
  def self.get_for_post(post_id : Int64, limit : Int32 = 50, offset : Int32 = 0) : Array(Hash(String, JSON::Type))
    result = POOL.exec(
      "SELECT id, user_id, content, score, parent_id, created_at FROM comments WHERE post_id = $1 ORDER BY created_at ASC LIMIT $2 OFFSET $3",
      post_id, limit, offset
    )
    result.rows.map do |row|
      {
        "id"         => row[0].to_i64,
        "user_id"    => row[1].to_i64,
        "content"    => row[2].to_s,
        "score"      => row[3].to_i,
        "parent_id"  => row[4]?.try &.to_i64,
        "created_at" => row[5].to_s
      }
    end
  end

  # Get a single comment by ID
  def self.find(id : Int64) : Hash(String, JSON::Type)?
    result = POOL.exec(
      "SELECT id, post_id, user_id, content, score, parent_id, created_at FROM comments WHERE id = $1",
      id
    )
    row = result.rows.first?
    return nil unless row

    {
      "id"         => row[0].to_i64,
      "post_id"    => row[1].to_i64,
      "user_id"    => row[2].to_i64,
      "content"    => row[3].to_s,
      "score"      => row[4].to_i,
      "parent_id"  => row[5]?.try &.to_i64,
      "created_at" => row[6].to_s
    }
  end

  # Increment comment score
  def self.increment_score(id : Int64, amount : Int32 = 1) : Bool
    POOL.exec("UPDATE comments SET score = score + $1 WHERE id = $2", amount, id)
    true
  rescue e : PG::Error
    puts "Failed to update comment score: #{e.message}"
    false
  end
end

# Vote operations
module VoteDB
  # Cast a vote on a post, vote_type: 1 for upvote, -1 for downvote
  def self.cast_post_vote(user_id : Int64, post_id : Int64, vote_type : Int32) : Bool
    # Check if user already voted on this post
    existing = POOL.exec(
      "SELECT vote_type FROM votes WHERE user_id = $1 AND post_id = $2",
      user_id, post_id
    )
    row = existing.rows.first?

    if row
      old_vote = row[0].to_i
      if old_vote == vote_type
        # Same vote, remove it (toggle off)
        POOL.exec(
          "DELETE FROM votes WHERE user_id = $1 AND post_id = $2",
          user_id, post_id
        )
        # Reverse the vote on the post
        PostDB.increment_score(post_id, -vote_type)
      else
        # Different vote, update it
        POOL.exec(
          "UPDATE votes SET vote_type = $1 WHERE user_id = $2 AND post_id = $3",
          vote_type, user_id, post_id
        )
        # Adjust post score: remove old vote, add new vote
        PostDB.increment_score(post_id, -old_vote)
        PostDB.increment_score(post_id, vote_type)
      end
    else
      # No existing vote, insert new one
      POOL.exec(
        "INSERT INTO votes (user_id, post_id, vote_type) VALUES ($1, $2, $3)",
        user_id, post_id, vote_type
      )
      PostDB.increment_score(post_id, vote_type)
    end
    true
  rescue e : PG::Error
    puts "Failed to cast post vote: #{e.message}"
    false
  end

  # Cast a vote on a comment
  def self.cast_comment_vote(user_id : Int64, comment_id : Int64, vote_type : Int32) : Bool
    existing = POOL.exec(
      "SELECT vote_type FROM votes WHERE user_id = $1 AND comment_id = $2",
      user_id, comment_id
    )
    row = existing.rows.first?

    if row
      old_vote = row[0].to_i
      if old_vote == vote_type
        POOL.exec(
          "DELETE FROM votes WHERE user_id = $1 AND comment_id = $2",
          user_id, comment_id
        )
        CommentDB.increment_score(comment_id, -vote_type)
      else
        POOL.exec(
          "UPDATE votes SET vote_type = $1 WHERE user_id = $2 AND comment_id = $3",
          vote_type, user_id, comment_id
        )
        CommentDB.increment_score(comment_id, -old_vote)
        CommentDB.increment_score(comment_id, vote_type)
      end
    else
      POOL.exec(
        "INSERT INTO votes (user_id, comment_id, vote_type) VALUES ($1, $2, $3)",
        user_id, comment_id, vote_type
      )
      CommentDB.increment_score(comment_id, vote_type)
    end
    true
  rescue e : PG::Error
    puts "Failed to cast comment vote: #{e.message}"
    false
  end

  # Get user's vote on a post, returns vote_type or nil
  def self.get_post_vote(user_id : Int64, post_id : Int64) : Int32?
    result = POOL.exec(
      "SELECT vote_type FROM votes WHERE user_id = $1 AND post_id = $2",
      user_id, post_id
    )
    row = result.rows.first?
    row[0]?.try &.to_i
  end

  # Get user's vote on a comment
  def self.get_comment_vote(user_id : Int64, comment_id : Int64) : Int32?
    result = POOL.exec(
      "SELECT vote_type FROM votes WHERE user_id = $1 AND comment_id = $2",
      user_id, comment_id
    )
    row = result.rows.first?
    row[0]?.try &.to_i
  end
end

# Saved posts operations
module SaveDB
  # Save a post for a user
  def self.save(user_id : Int64, post_id : Int64) : Bool
    POOL.exec(
      "INSERT INTO saved_posts (user_id, post_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
      user_id, post_id
    )
    true
  rescue e : PG::Error
    puts "Failed to save post: #{e.message}"
    false
  end

  # Unsave a post
  def self.unsave(user_id : Int64, post_id : Int64) : Bool
    POOL.exec(
      "DELETE FROM saved_posts WHERE user_id = $1 AND post_id = $2",
      user_id, post_id
    )
    true
  rescue e : PG::Error
    puts "Failed to unsave post: #{e.message}"
    false
  end

  # Check if a post is saved by a user
  def self.is_saved?(user_id : Int64, post_id : Int64) : Bool
    result = POOL.exec(
      "SELECT COUNT(*) FROM saved_posts WHERE user_id = $1 AND post_id = $2",
      user_id, post_id
    )
    result.rows.first?[0].to_i > 0
  end

  # Get all saved posts for a user
  def self.get_user_saves(user_id : Int64, limit : Int32 = 50, offset : Int32 = 0) : Array(Hash(String, JSON::Type))
    result = POOL.exec(
      "SELECT p.id, p.title, p.url, p.source, p.score, p.comment_count, p.created_at, s.created_at as saved_at
       FROM saved_posts s JOIN posts p ON s.post_id = p.id
       WHERE s.user_id = $1 ORDER BY s.created_at DESC LIMIT $2 OFFSET $3",
      user_id, limit, offset
    )
    result.rows.map do |row|
      {
        "id"            => row[0].to_i64,
        "title"         => row[1].to_s,
        "url"           => row[2]?.try &.to_s || "",
        "source"        => row[3].to_s,
        "score"         => row[4].to_i,
        "comment_count" => row[5].to_i,
        "created_at"    => row[6].to_s,
        "saved_at"      => row[7].to_s
      }
    end
  end
end

# Health check
def db_healthy? : Bool
  POOL.exec("SELECT 1")
  true
rescue e
  false
end
