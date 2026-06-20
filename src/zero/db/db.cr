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
    result = POOL.query(
      "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id",
      username, email, password_hash
    )
    result.move_next
    result.read(Int64)
  rescue e : PG::Error
    puts "Failed to create user: #{e.message}"
    nil
  end

  def self.find(id : Int64) : Hash(String, JSON::Type)?
    result = POOL.query(
      "SELECT id, username, email, created_at, last_login, is_admin FROM users WHERE id = $1",
      id
    )
    if result.move_next
      user = Hash(String, JSON::Type).new
      user["id"] = result.read(Int64)
      user["username"] = result.read(String)
      user["email"] = result.read(String)
      user["created_at"] = result.read(Time).to_s
      last_login = result.read(Time?)
      if last_login
        user["last_login"] = last_login.to_s
      else
        user["last_login"] = ""
      end
      is_admin = result.read(Bool?)
      if is_admin
        user["is_admin"] = is_admin
      else
        user["is_admin"] = false
      end
      user
    else
      nil
    end
  end

  def self.find_by_username(username : String) : Hash(String, JSON::Type)?
    result = POOL.query(
      "SELECT id, username, email, password_hash, created_at, is_admin FROM users WHERE username = $1",
      username
    )
    if result.move_next
      user = Hash(String, JSON::Type).new
      user["id"] = result.read(Int64)
      user["username"] = result.read(String)
      user["email"] = result.read(String)
      user["password_hash"] = result.read(String)
      user["created_at"] = result.read(Time).to_s
      is_admin = result.read(Bool?)
      if is_admin
        user["is_admin"] = is_admin
      else
        user["is_admin"] = false
      end
      user
    else
      nil
    end
  end

  def self.find_by_email(email : String) : Hash(String, JSON::Type)?
    result = POOL.query(
      "SELECT id, username, email, password_hash, created_at, is_admin FROM users WHERE email = $1",
      email
    )
    if result.move_next
      user = Hash(String, JSON::Type).new
      user["id"] = result.read(Int64)
      user["username"] = result.read(String)
      user["email"] = result.read(String)
      user["password_hash"] = result.read(String)
      user["created_at"] = result.read(Time).to_s
      is_admin = result.read(Bool?)
      if is_admin
        user["is_admin"] = is_admin
      else
        user["is_admin"] = false
      end
      user
    else
      nil
    end
  end

  def self.update_last_login(id : Int64) : Bool
    POOL.exec("UPDATE users SET last_login = NOW() WHERE id = $1", id)
    true
  rescue e : PG::Error
    puts "Failed to update last_login: #{e.message}"
    false
  end

  def self.exists?(username : String, email : String) : Bool
    result = POOL.query(
      "SELECT COUNT(*) FROM users WHERE username = $1 OR email = $2",
      username, email
    )
    result.move_next
    result.read(Int64) > 0
  end

  def self.username_exists?(username : String) : Bool
    result = POOL.query("SELECT COUNT(*) FROM users WHERE username = $1", username)
    result.move_next
    result.read(Int64) > 0
  end

  def self.email_exists?(email : String) : Bool
    result = POOL.query("SELECT COUNT(*) FROM users WHERE email = $1", email)
    result.move_next
    result.read(Int64) > 0
  end
end

module PostDB
  def self.create(title : String, url : String, source : String, external_id : String? = nil) : Int64?
    result = POOL.query(
      "INSERT INTO posts (title, url, source, external_id) VALUES ($1, $2, $3, $4) RETURNING id",
      title, url, source, external_id
    )
    result.move_next
    result.read(Int64)
  rescue e : PG::Error
    puts "Failed to create post: #{e.message}"
    nil
  end

  def self.create_user_post(title : String, url : String, content : String, user_id : Int64) : Int64?
    result = POOL.query(
      "INSERT INTO posts (title, url, content, source, user_id, is_user_post) VALUES ($1, $2, $3, 'user', $4, true) RETURNING id",
      title, url, content, user_id
    )
    result.move_next
    result.read(Int64)
  rescue e : PG::Error
    puts "Failed to create user post: #{e.message}"
    nil
  end

  def self.get_top(limit : Int32 = 50, offset : Int32 = 0) : Array(Hash(String, JSON::Type))
    result = POOL.query(
      "SELECT id, title, url, source, score, comment_count, created_at FROM posts ORDER BY score DESC LIMIT $1 OFFSET $2",
      limit, offset
    )
    rows = [] of Hash(String, JSON::Type)
    result.each do
      post = Hash(String, JSON::Type).new
      post["id"] = result.read(Int64)
      post["title"] = result.read(String)
      url = result.read(String?)
      if url
        post["url"] = url
      else
        post["url"] = ""
      end
      post["source"] = result.read(String)
      post["score"] = result.read(Int32)
      post["comment_count"] = result.read(Int32)
      post["created_at"] = result.read(Time).to_s
      rows << post
    end
    rows
  end

  def self.get_latest(limit : Int32 = 50, offset : Int32 = 0) : Array(Hash(String, JSON::Type))
    result = POOL.query(
      "SELECT id, title, url, source, score, comment_count, created_at FROM posts ORDER BY created_at DESC LIMIT $1 OFFSET $2",
      limit, offset
    )
    rows = [] of Hash(String, JSON::Type)
    result.each do
      post = Hash(String, JSON::Type).new
      post["id"] = result.read(Int64)
      post["title"] = result.read(String)
      url = result.read(String?)
      if url
        post["url"] = url
      else
        post["url"] = ""
      end
      post["source"] = result.read(String)
      post["score"] = result.read(Int32)
      post["comment_count"] = result.read(Int32)
      post["created_at"] = result.read(Time).to_s
      rows << post
    end
    rows
  end

  def self.find(id : Int64) : Hash(String, JSON::Type)?
    result = POOL.query(
      "SELECT id, title, url, source, score, comment_count, created_at FROM posts WHERE id = $1",
      id
    )
    if result.move_next
      post = Hash(String, JSON::Type).new
      post["id"] = result.read(Int64)
      post["title"] = result.read(String)
      url = result.read(String?)
      if url
        post["url"] = url
      else
        post["url"] = ""
      end
      post["source"] = result.read(String)
      post["score"] = result.read(Int32)
      post["comment_count"] = result.read(Int32)
      post["created_at"] = result.read(Time).to_s
      post
    else
      nil
    end
  end

  def self.search(query : String, limit : Int32 = 50, offset : Int32 = 0) : Array(Hash(String, JSON::Type))
    result = POOL.query(
      "SELECT id, title, url, source, score, comment_count, created_at FROM posts WHERE title ILIKE $1 ORDER BY score DESC LIMIT $2 OFFSET $3",
      "%#{query}%", limit, offset
    )
    rows = [] of Hash(String, JSON::Type)
    result.each do
      post = Hash(String, JSON::Type).new
      post["id"] = result.read(Int64)
      post["title"] = result.read(String)
      url = result.read(String?)
      if url
        post["url"] = url
      else
        post["url"] = ""
      end
      post["source"] = result.read(String)
      post["score"] = result.read(Int32)
      post["comment_count"] = result.read(Int32)
      post["created_at"] = result.read(Time).to_s
      rows << post
    end
    rows
  end

  def self.increment_score(id : Int64, amount : Int32 = 1) : Bool
    POOL.exec("UPDATE posts SET score = score + $1 WHERE id = $2", amount, id)
    true
  rescue e : PG::Error
    puts "Failed to update post score: #{e.message}"
    false
  end

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

  def self.prune_old_posts(keep_count : Int32 = 10000) : Int64
    result = POOL.query(
      "DELETE FROM posts WHERE id NOT IN (SELECT id FROM posts ORDER BY created_at DESC LIMIT $1) RETURNING id",
      keep_count
    )
    count = 0
    result.each do
      count += 1
    end
    count.to_i64
  rescue e : PG::Error
    puts "Failed to prune posts: #{e.message}"
    0_i64
  end
end

module CommentDB
  def self.create(post_id : Int64, user_id : Int64, content : String, parent_id : Int64? = nil) : Int64?
    result = POOL.query(
      "INSERT INTO comments (post_id, user_id, content, parent_id) VALUES ($1, $2, $3, $4) RETURNING id",
      post_id, user_id, content, parent_id
    )
    result.move_next
    comment_id = result.read(Int64)
    PostDB.update_comment_count(post_id)
    comment_id
  rescue e : PG::Error
    puts "Failed to create comment: #{e.message}"
    nil
  end

  def self.get_for_post(post_id : Int64, limit : Int32 = 50, offset : Int32 = 0) : Array(Hash(String, JSON::Type))
    result = POOL.query(
      "SELECT id, user_id, content, score, parent_id, created_at FROM comments WHERE post_id = $1 ORDER BY created_at ASC LIMIT $2 OFFSET $3",
      post_id, limit, offset
    )
    rows = [] of Hash(String, JSON::Type)
    result.each do
      comment = Hash(String, JSON::Type).new
      comment["id"] = result.read(Int64)
      user_id = result.read(Int64?)
      if user_id
        comment["user_id"] = user_id
      else
        comment["user_id"] = 0_i64
      end
      comment["content"] = result.read(String)
      comment["score"] = result.read(Int32)
      parent_id = result.read(Int64?)
      if parent_id
        comment["parent_id"] = parent_id
      else
        comment["parent_id"] = nil
      end
      comment["created_at"] = result.read(Time).to_s
      rows << comment
    end
    rows
  end

  def self.find(id : Int64) : Hash(String, JSON::Type)?
    result = POOL.query(
      "SELECT id, post_id, user_id, content, score, parent_id, created_at FROM comments WHERE id = $1",
      id
    )
    if result.move_next
      comment = Hash(String, JSON::Type).new
      comment["id"] = result.read(Int64)
      comment["post_id"] = result.read(Int64)
      user_id = result.read(Int64?)
      if user_id
        comment["user_id"] = user_id
      else
        comment["user_id"] = 0_i64
      end
      comment["content"] = result.read(String)
      comment["score"] = result.read(Int32)
      parent_id = result.read(Int64?)
      if parent_id
        comment["parent_id"] = parent_id
      else
        comment["parent_id"] = nil
      end
      comment["created_at"] = result.read(Time).to_s
      comment
    else
      nil
    end
  end

  def self.increment_score(id : Int64, amount : Int32 = 1) : Bool
    POOL.exec("UPDATE comments SET score = score + $1 WHERE id = $2", amount, id)
    true
  rescue e : PG::Error
    puts "Failed to update comment score: #{e.message}"
    false
  end
end

module VoteDB
  def self.cast_post_vote(user_id : Int64, post_id : Int64, vote_type : Int32) : Bool
    existing = POOL.query(
      "SELECT vote_type FROM votes WHERE user_id = $1 AND post_id = $2",
      user_id, post_id
    )
    if existing.move_next
      old_vote = existing.read(Int32)
      if old_vote == vote_type
        POOL.exec(
          "DELETE FROM votes WHERE user_id = $1 AND post_id = $2",
          user_id, post_id
        )
        PostDB.increment_score(post_id, -vote_type)
      else
        POOL.exec(
          "UPDATE votes SET vote_type = $1 WHERE user_id = $2 AND post_id = $3",
          vote_type, user_id, post_id
        )
        PostDB.increment_score(post_id, -old_vote)
        PostDB.increment_score(post_id, vote_type)
      end
    else
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

  def self.cast_comment_vote(user_id : Int64, comment_id : Int64, vote_type : Int32) : Bool
    existing = POOL.query(
      "SELECT vote_type FROM votes WHERE user_id = $1 AND comment_id = $2",
      user_id, comment_id
    )
    if existing.move_next
      old_vote = existing.read(Int32)
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

  def self.get_post_vote(user_id : Int64, post_id : Int64) : Int32?
    result = POOL.query(
      "SELECT vote_type FROM votes WHERE user_id = $1 AND post_id = $2",
      user_id, post_id
    )
    if result.move_next
      result.read(Int32)
    else
      nil
    end
  end

  def self.get_comment_vote(user_id : Int64, comment_id : Int64) : Int32?
    result = POOL.query(
      "SELECT vote_type FROM votes WHERE user_id = $1 AND comment_id = $2",
      user_id, comment_id
    )
    if result.move_next
      result.read(Int32)
    else
      nil
    end
  end
end

module SaveDB
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

  def self.is_saved?(user_id : Int64, post_id : Int64) : Bool
    result = POOL.query(
      "SELECT COUNT(*) FROM saved_posts WHERE user_id = $1 AND post_id = $2",
      user_id, post_id
    )
    result.move_next
    result.read(Int64) > 0
  end

  def self.get_user_saves(user_id : Int64, limit : Int32 = 50, offset : Int32 = 0) : Array(Hash(String, JSON::Type))
    result = POOL.query(
      "SELECT p.id, p.title, p.url, p.source, p.score, p.comment_count, p.created_at, s.created_at as saved_at
       FROM saved_posts s JOIN posts p ON s.post_id = p.id
       WHERE s.user_id = $1 ORDER BY s.created_at DESC LIMIT $2 OFFSET $3",
      user_id, limit, offset
    )
    rows = [] of Hash(String, JSON::Type)
    result.each do
      save = Hash(String, JSON::Type).new
      save["id"] = result.read(Int64)
      save["title"] = result.read(String)
      url = result.read(String?)
      if url
        save["url"] = url
      else
        save["url"] = ""
      end
      save["source"] = result.read(String)
      save["score"] = result.read(Int32)
      save["comment_count"] = result.read(Int32)
      save["created_at"] = result.read(Time).to_s
      save["saved_at"] = result.read(Time).to_s
      rows << save
    end
    rows
  end
end
