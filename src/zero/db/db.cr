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
      content TEXT,
      source TEXT NOT NULL,
      external_id TEXT,
      user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
      score INTEGER DEFAULT 0,
      comment_count INTEGER DEFAULT 0,
      is_user_post BOOLEAN DEFAULT FALSE,
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

def db_healthy? : Bool
  POOL.exec("SELECT 1")
  true
rescue e
  false
end

module UserDB
  def self.create(username : String, email : String, password_hash : String) : Int64?
    result = POOL.exec(
      "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id",
      username, email, password_hash
    )
    result.each do |row|
      return row[0].to_i64
    end
    nil
  rescue e : PG::Error
    puts "Failed to create user: #{e.message}"
    nil
  end

  def self.find(id : Int64) : Hash(String, JSON::Type)?
    result = POOL.exec(
      "SELECT id, username, email, created_at, last_login, is_admin FROM users WHERE id = $1",
      id
    )
    result.each do |row|
      return {
        "id"         => row[0].to_i64,
        "username"   => row[1].to_s,
        "email"      => row[2].to_s,
        "created_at" => row[3].to_s,
        "last_login" => row[4]?.try &.to_s || "",
        "is_admin"   => row[5]?.try &.to_bool || false
      }
    end
    nil
  end

  def self.find_by_username(username : String) : Hash(String, JSON::Type)?
    result = POOL.exec(
      "SELECT id, username, email, password_hash, created_at, is_admin FROM users WHERE username = $1",
      username
    )
    result.each do |row|
      return {
        "id"            => row[0].to_i64,
        "username"      => row[1].to_s,
        "email"         => row[2].to_s,
        "password_hash" => row[3].to_s,
        "created_at"    => row[4].to_s,
        "is_admin"      => row[5]?.try &.to_bool || false
      }
    end
    nil
  end

  def self.find_by_email(email : String) : Hash(String, JSON::Type)?
    result = POOL.exec(
      "SELECT id, username, email, password_hash, created_at, is_admin FROM users WHERE email = $1",
      email
    )
    result.each do |row|
      return {
        "id"            => row[0].to_i64,
        "username"      => row[1].to_s,
        "email"         => row[2].to_s,
        "password_hash" => row[3].to_s,
        "created_at"    => row[4].to_s,
        "is_admin"      => row[5]?.try &.to_bool || false
      }
    end
    nil
  end

  def self.update_last_login(id : Int64) : Bool
    POOL.exec("UPDATE users SET last_login = NOW() WHERE id = $1", id)
    true
  rescue e : PG::Error
    puts "Failed to update last_login: #{e.message}"
    false
  end

  def self.exists?(username : String, email : String) : Bool
    result = POOL.exec(
      "SELECT COUNT(*) FROM users WHERE username = $1 OR email = $2",
      username, email
    )
    count = 0
    result.each do |row|
      count = row[0].to_i
    end
    count > 0
  end

  def self.username_exists?(username : String) : Bool
    result = POOL.exec("SELECT COUNT(*) FROM users WHERE username = $1", username)
    count = 0
    result.each do |row|
      count = row[0].to_i
    end
    count > 0
  end

  def self.email_exists?(email : String) : Bool
    result = POOL.exec("SELECT COUNT(*) FROM users WHERE email = $1", email)
    count = 0
    result.each do |row|
      count = row[0].to_i
    end
    count > 0
  end
end
