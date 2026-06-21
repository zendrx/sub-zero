require "pg"
require "json"
require "time"

module AlgoDB
  # Record a user interaction with a post
  def self.record_interaction(user_id : Int64, post_id : Int64, interaction_type : String, weight : Float64 = 1.0)
    POOL.exec(
      "INSERT INTO user_interactions (user_id, post_id, interaction_type, weight, created_at)
      VALUES ($1, $2, $3, $4, NOW())",
      user_id, post_id, interaction_type, weight
    )

    update_user_preferences(user_id, post_id, interaction_type, weight)
  rescue e : PG::Error
    puts "Failed to record interaction: #{e.message}"
  end

  # Update user preferences based on an interaction
  def self.update_user_preferences(user_id : Int64, post_id : Int64, interaction_type : String, weight : Float64 = 1.0)
    result = POOL.query(
      "SELECT source, title FROM posts WHERE id = $1",
      post_id
    )
    if !result.move_next
      return
    end

    source = result.read(String)
    title = result.read(String)

    interaction_weights = {
      "upvote" => 2.0,
      "comment" => 1.5,
      "save" => 1.5,
      "share" => 2.5,
      "view" => 0.5,
      "click" => 0.8,
      "downvote" => -1.0,
    }

    effective_weight = weight * (interaction_weights[interaction_type]? || 0.5)

    POOL.exec(
      "INSERT INTO user_source_preferences (user_id, source, score, updated_at)
      VALUES ($1, $2, $3, NOW())
      ON CONFLICT (user_id, source) DO UPDATE
      SET score = user_source_preferences.score + $3,
          updated_at = NOW()",
      user_id, source, effective_weight
    )

    tags = extract_tags_from_text(title)
    tags.each do |tag|
      POOL.exec(
        "INSERT INTO user_tag_preferences (user_id, tag, score, updated_at)
        VALUES ($1, $2, $3, NOW())
        ON CONFLICT (user_id, tag) DO UPDATE
        SET score = user_tag_preferences.score + $3,
            updated_at = NOW()",
        user_id, tag, effective_weight * 0.5
      )
    end
  end

  # Extract simple tags from text
  def self.extract_tags_from_text(text : String) : Array(String)
    tags = [] of String
    text = text.downcase

    common_tags = ["ruby", "python", "javascript", "react", "rails", "go", "rust",
                   "devops", "cloud", "ai", "machinelearning", "webdev", "security",
                   "database", "api", "microservices", "kubernetes", "docker", "linux",
                   "vim", "emacs", "vscode", "git", "github", "opensource", "startup"]

    common_tags.each do |tag|
      if text.includes?(tag)
        tags << tag
      end
    end

    tags
  end

  # Calculate hot score for a post
  def self.calculate_hot_score(upvotes : Int32, downvotes : Int32, created_at : Time) : Float64
    score = upvotes - downvotes
    hours = (Time.utc - created_at).total_hours
    Math.log([score, 1].max) + (hours / 45000.0)
  end

  # Get user's source preferences
  def self.get_user_source_preferences(user_id : Int64) : Hash(String, Float64)
    preferences = {} of String => Float64
    result = POOL.query(
      "SELECT source, score FROM user_source_preferences WHERE user_id = $1",
      user_id
    )
    result.each do
      preferences[result.read(String)] = result.read(Float64)
    end
    preferences
  end

  # Get user's tag preferences
  def self.get_user_tag_preferences(user_id : Int64) : Hash(String, Float64)
    preferences = {} of String => Float64
    result = POOL.query(
      "SELECT tag, score FROM user_tag_preferences WHERE user_id = $1",
      user_id
    )
    result.each do
      preferences[result.read(String)] = result.read(Float64)
    end
    preferences
  end

  # Get trending posts based on recent engagement spikes
  def self.get_trending_posts(limit : Int32 = 20) : Array(Hash(String, JSON::Any))
    result = POOL.query(
      "SELECT p.id, p.title, p.url, p.source, p.score, p.comment_count, p.created_at,
              COUNT(i.id) as recent_interactions
       FROM posts p
       LEFT JOIN user_interactions i ON p.id = i.post_id
         AND i.created_at > NOW() - INTERVAL '1 hour'
       WHERE p.created_at > NOW() - INTERVAL '7 days'
       GROUP BY p.id
       HAVING COUNT(i.id) > 3
       ORDER BY recent_interactions DESC, p.score DESC
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
      post["recent_engagement"] = JSON::Any.new(result.read(Int64))
      posts << post
    end
    posts
  end

  # Get posts from sources a user hasn't seen much of
  def self.get_discovery_posts(user_id : Int64, limit : Int32 = 20) : Array(Hash(String, JSON::Any))
    result = POOL.query(
      "SELECT p.id, p.title, p.url, p.source, p.score, p.comment_count, p.created_at
       FROM posts p
       WHERE p.source NOT IN (
         SELECT source FROM user_source_preferences
         WHERE user_id = $1 AND score > 0.5
       )
       AND p.id NOT IN (
         SELECT post_id FROM user_interactions WHERE user_id = $1
       )
       AND p.is_user_post = false
       ORDER BY p.score DESC
       LIMIT $2",
      user_id, limit
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

  # Get collaborative recommendations
  def self.get_collaborative_recommendations(user_id : Int64, limit : Int32 = 20) : Array(Hash(String, JSON::Any))
    similar_users = find_similar_users(user_id, 10)
    return [] of Hash(String, JSON::Any) if similar_users.empty?

    result = POOL.query(
      "SELECT DISTINCT p.id, p.title, p.url, p.source, p.score, p.comment_count, p.created_at,
              COUNT(DISTINCT i.user_id) as similar_user_votes
       FROM posts p
       JOIN user_interactions i ON p.id = i.post_id
       WHERE i.user_id IN (#{similar_users.join(",")})
         AND i.interaction_type = 'upvote'
         AND p.id NOT IN (
           SELECT post_id FROM user_interactions WHERE user_id = $1
         )
         AND p.is_user_post = false
       GROUP BY p.id
       ORDER BY similar_user_votes DESC, p.score DESC
       LIMIT $2",
      user_id, limit
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
      post["similar_votes"] = JSON::Any.new(result.read(Int64))
      posts << post
    end
    posts
  end

  # Find similar users based on voting overlap
  def self.find_similar_users(user_id : Int64, limit : Int32 = 10) : Array(Int64)
    result = POOL.query(
      "SELECT i2.user_id, COUNT(*) as overlap
       FROM user_interactions i1
       JOIN user_interactions i2 ON i1.post_id = i2.post_id
       WHERE i1.user_id = $1
         AND i1.interaction_type = 'upvote'
         AND i2.interaction_type = 'upvote'
         AND i2.user_id != $1
       GROUP BY i2.user_id
       ORDER BY overlap DESC
       LIMIT $2",
      user_id, limit
    )

    users = [] of Int64
    result.each do
      users << result.read(Int64)
    end
    users
  end

  # Get user engagement stats
  def self.get_user_stats(user_id : Int64) : Hash(String, JSON::Any)
    result = POOL.query(
      "SELECT
        COUNT(DISTINCT post_id) as posts_interacted,
        COUNT(DISTINCT post_id) FILTER (WHERE interaction_type = 'upvote') as upvotes,
        COUNT(DISTINCT post_id) FILTER (WHERE interaction_type = 'downvote') as downvotes,
        COUNT(DISTINCT post_id) FILTER (WHERE interaction_type = 'comment') as comments,
        COUNT(DISTINCT post_id) FILTER (WHERE interaction_type = 'save') as saves,
        COUNT(DISTINCT source) as sources_used
       FROM user_interactions
       WHERE user_id = $1",
      user_id
    )

    if result.move_next
      stats = Hash(String, JSON::Any).new
      stats["posts_interacted"] = JSON::Any.new(result.read(Int64))
      stats["upvotes"] = JSON::Any.new(result.read(Int64))
      stats["downvotes"] = JSON::Any.new(result.read(Int64))
      stats["comments"] = JSON::Any.new(result.read(Int64))
      stats["saves"] = JSON::Any.new(result.read(Int64))
      stats["sources_used"] = JSON::Any.new(result.read(Int64))
      stats
    else
      Hash(String, JSON::Any).new
    end
  end
end

# Database migration for algorithm tables
def setup_algo_tables
  POOL.exec <<-SQL
    CREATE TABLE IF NOT EXISTS user_interactions (
      id BIGSERIAL PRIMARY KEY,
      user_id BIGINT REFERENCES users(id) ON DELETE CASCADE,
      post_id BIGINT REFERENCES posts(id) ON DELETE CASCADE,
      interaction_type TEXT NOT NULL,
      weight FLOAT DEFAULT 1.0,
      created_at TIMESTAMP DEFAULT NOW()
    )
  SQL

  POOL.exec <<-SQL
    CREATE TABLE IF NOT EXISTS user_source_preferences (
      id BIGSERIAL PRIMARY KEY,
      user_id BIGINT REFERENCES users(id) ON DELETE CASCADE,
      source TEXT NOT NULL,
      score FLOAT DEFAULT 0.0,
      updated_at TIMESTAMP DEFAULT NOW(),
      CONSTRAINT unique_user_source UNIQUE (user_id, source)
    )
  SQL

  POOL.exec <<-SQL
    CREATE TABLE IF NOT EXISTS user_tag_preferences (
      id BIGSERIAL PRIMARY KEY,
      user_id BIGINT REFERENCES users(id) ON DELETE CASCADE,
      tag TEXT NOT NULL,
      score FLOAT DEFAULT 0.0,
      updated_at TIMESTAMP DEFAULT NOW(),
      CONSTRAINT unique_user_tag UNIQUE (user_id, tag)
    )
  SQL

  POOL.exec "CREATE INDEX IF NOT EXISTS idx_interactions_user_id ON user_interactions(user_id)"
  POOL.exec "CREATE INDEX IF NOT EXISTS idx_interactions_post_id ON user_interactions(post_id)"
  POOL.exec "CREATE INDEX IF NOT EXISTS idx_interactions_created_at ON user_interactions(created_at DESC)"
  POOL.exec "CREATE INDEX IF NOT EXISTS idx_source_prefs_user_id ON user_source_preferences(user_id)"
  POOL.exec "CREATE INDEX IF NOT EXISTS idx_tag_prefs_user_id ON user_tag_preferences(user_id)"
end
