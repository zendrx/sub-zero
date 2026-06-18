# db_algo.cr - Algorithm database layer for Crystal Aggregator
# Handles all database operations needed for the recommendation algorithm

require "pg"
require "json"
require "time"

# Extends the main database module with algorithm-specific functions
module AlgoDB
  # User preference weights for different content types
  # Higher weight = more important to this user
  
  # Record a user interaction with a post
  def self.record_interaction(user_id : Int64, post_id : Int64, interaction_type : String, weight : Float64 = 1.0)
    # interaction_type: view, upvote, downvote, comment, save, share, click
    POOL.exec(
      "INSERT INTO user_interactions (user_id, post_id, interaction_type, weight, created_at)
       VALUES ($1, $2, $3, $4, NOW())",
      user_id, post_id, interaction_type, weight
    )
    
    # Update user preferences based on this interaction
    update_user_preferences(user_id, post_id, interaction_type, weight)
  rescue e : PG::Error
    puts "Failed to record interaction: #{e.message}"
  end
  
  # Update user preferences based on an interaction
  def self.update_user_preferences(user_id : Int64, post_id : Int64, interaction_type : String, weight : Float64 = 1.0)
    # Get post details to extract source and tags
    result = POOL.exec(
      "SELECT source, title FROM posts WHERE id = $1",
      post_id
    )
    row = result.rows.first?
    return unless row
    
    source = row[0].to_s
    title = row[1].to_s
    
    # Weight different interactions differently
    interaction_weights = {
      "upvote"   => 2.0,
      "comment"  => 1.5,
      "save"     => 1.5,
      "share"    => 2.5,
      "view"     => 0.5,
      "click"    => 0.8,
      "downvote" => -1.0
    }
    
    effective_weight = weight * (interaction_weights[interaction_type]? || 0.5)
    
    # Update source preference
    POOL.exec(
      "INSERT INTO user_source_preferences (user_id, source, score, updated_at)
       VALUES ($1, $2, $3, NOW())
       ON CONFLICT (user_id, source) DO UPDATE
       SET score = user_source_preferences.score + $3,
           updated_at = NOW()",
      user_id, source, effective_weight
    )
    
    # Extract and update tag preferences from title
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
  
  # Extract simple tags from text (very basic implementation)
  def self.extract_tags_from_text(text : String) : Array(String)
    # Simple tag extraction - look for common tech topics
    # In production, you'd use NLP or a proper tag system
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
  
  # Calculate hot score for a post using Reddit-style algorithm
  def self.calculate_hot_score(upvotes : Int32, downvotes : Int32, created_at : Time) : Float64
    score = upvotes - downvotes
    hours = (Time.utc - created_at).total_hours
    # Reddit's algorithm: log(score) + (hours / 45000)
    # Add small constant to avoid log(0)
    Math.log([score, 1].max) + (hours / 45000.0)
  end
  
  # Get personalized feed for a user
  def self.get_personalized_feed(user_id : Int64, limit : Int32 = 50, offset : Int32 = 0) : Array(Hash(String, JSON::Type))
    # Get user's source preferences
    source_scores = get_user_source_preferences(user_id)
    
    # Get user's tag preferences
    tag_scores = get_user_tag_preferences(user_id)
    
    # Get posts with personalized scoring
    # We need to fetch posts and calculate score
    result = POOL.exec(
      "SELECT p.id, p.title, p.url, p.source, p.score, p.comment_count, p.created_at, p.external_id,
              p.upvotes, p.downvotes
       FROM posts p
       WHERE p.is_user_post = false
       ORDER BY p.created_at DESC
       LIMIT $1 OFFSET $2",
      limit * 3, offset  # Fetch extra to allow for ranking
    )
    
    # Score each post based on user preferences
    scored_posts = [] of Tuple(Float64, Hash(String, JSON::Type))
    result.rows.each do |row|
      post = {
        "id"            => row[0].to_i64,
        "title"         => row[1].to_s,
        "url"           => row[2]?.try &.to_s || "",
        "source"        => row[3].to_s,
        "score"         => row[4].to_i,
        "comment_count" => row[5].to_i,
        "created_at"    => row[6].to_s,
        "external_id"   => row[7].to_s,
        "upvotes"       => row[8]?.try &.to_i || 0,
        "downvotes"     => row[9]?.try &.to_i || 0
      }
      
      # Calculate final score
      final_score = calculate_post_score_for_user(post, source_scores, tag_scores)
      scored_posts << {final_score, post}
    end
    
    # Sort by final score descending and take top N
    scored_posts.sort! { |a, b| b[0] <=> a[0] }
    scored_posts.first(limit).map { |_, post| post }
  end
  
  # Calculate post score for a specific user
  def self.calculate_post_score_for_user(post : Hash(String, JSON::Type), 
                                         source_scores : Hash(String, Float64),
                                         tag_scores : Hash(String, Float64)) : Float64
    # Base score from community engagement
    base_score = post["score"].to_f / 100.0  # Normalize
    
    # Source preference boost
    source = post["source"].to_s
    source_boost = source_scores[source]? || 0.0
    
    # Tag preference boost (extract from title)
    tags = extract_tags_from_text(post["title"].to_s)
    tag_boost = 0.0
    tags.each do |tag|
      tag_boost += tag_scores[tag]? || 0.0
    end
    tag_boost = tag_boost / [tags.size, 1].max  # Average
    
    # Time decay (freshness)
    created_at = Time.parse(post["created_at"].to_s, "%Y-%m-%d %H:%M:%S", Time::Location::UTC)
    hours = (Time.utc - created_at).total_hours
    time_decay = 1.0 / (1.0 + hours / 48.0)  # Half-life of 48 hours
    
    # Combine scores
    final_score = (base_score * 0.3) + (source_boost * 0.3) + (tag_boost * 0.2) + (time_decay * 0.2)
    final_score
  end
  
  # Get user's source preferences
  def self.get_user_source_preferences(user_id : Int64) : Hash(String, Float64)
    preferences = {} of String => Float64
    result = POOL.exec(
      "SELECT source, score FROM user_source_preferences WHERE user_id = $1",
      user_id
    )
    result.rows.each do |row|
      preferences[row[0].to_s] = row[1].to_f
    end
    preferences
  end
  
  # Get user's tag preferences
  def self.get_user_tag_preferences(user_id : Int64) : Hash(String, Float64)
    preferences = {} of String => Float64
    result = POOL.exec(
      "SELECT tag, score FROM user_tag_preferences WHERE user_id = $1",
      user_id
    )
    result.rows.each do |row|
      preferences[row[0].to_s] = row[1].to_f
    end
    preferences
  end
  
  # Get trending posts based on recent engagement spikes
  def self.get_trending_posts(limit : Int32 = 20) : Array(Hash(String, JSON::Type))
    # Find posts with high engagement in the last hour vs baseline
    result = POOL.exec(
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
    
    result.rows.map do |row|
      {
        "id"            => row[0].to_i64,
        "title"         => row[1].to_s,
        "url"           => row[2]?.try &.to_s || "",
        "source"        => row[3].to_s,
        "score"         => row[4].to_i,
        "comment_count" => row[5].to_i,
        "created_at"    => row[6].to_s,
        "recent_engagement" => row[7].to_i64
      }
    end
  end
  
  # Get posts from sources a user hasn't seen much of (for discovery)
  def self.get_discovery_posts(user_id : Int64, limit : Int32 = 20) : Array(Hash(String, JSON::Type))
    # Find posts from sources the user rarely interacts with
    result = POOL.exec(
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
  
  # Get collaborative recommendations (users who liked this, also liked...)
  def self.get_collaborative_recommendations(user_id : Int64, limit : Int32 = 20) : Array(Hash(String, JSON::Type))
    # Find similar users based on voting patterns
    similar_users = find_similar_users(user_id, 10)
    return [] of Hash(String, JSON::Type) if similar_users.empty?
    
    # Get posts they upvoted that this user hasn't seen
    result = POOL.exec(
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
    
    result.rows.map do |row|
      {
        "id"            => row[0].to_i64,
        "title"         => row[1].to_s,
        "url"           => row[2]?.try &.to_s || "",
        "source"        => row[3].to_s,
        "score"         => row[4].to_i,
        "comment_count" => row[5].to_i,
        "created_at"    => row[6].to_s,
        "similar_votes" => row[7].to_i64
      }
    end
  end
  
  # Find similar users based on voting overlap
  def self.find_similar_users(user_id : Int64, limit : Int32 = 10) : Array(Int64)
    result = POOL.exec(
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
    
    result.rows.map { |row| row[0].to_i64 }
  end
  
  # Get user engagement stats
  def self.get_user_stats(user_id : Int64) : Hash(String, JSON::Type)
    result = POOL.exec(
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
    
    row = result.rows.first?
    return {} of String => JSON::Type unless row
    
    {
      "posts_interacted" => row[0].to_i64,
      "upvotes"          => row[1].to_i64,
      "downvotes"        => row[2].to_i64,
      "comments"         => row[3].to_i64,
      "saves"            => row[4].to_i64,
      "sources_used"     => row[5].to_i64
    }
  end
end

# Database migration for algorithm tables
def setup_algo_tables
  # User interactions table
  POOL.exec <<-SQL
    CREATE TABLE IF NOT EXISTS user_interactions (
      id SERIAL PRIMARY KEY,
      user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
      post_id INTEGER REFERENCES posts(id) ON DELETE CASCADE,
      interaction_type TEXT NOT NULL,
      weight FLOAT DEFAULT 1.0,
      created_at TIMESTAMP DEFAULT NOW()
    )
  SQL

  # User source preferences table
  POOL.exec <<-SQL
    CREATE TABLE IF NOT EXISTS user_source_preferences (
      id SERIAL PRIMARY KEY,
      user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
      source TEXT NOT NULL,
      score FLOAT DEFAULT 0.0,
      updated_at TIMESTAMP DEFAULT NOW(),
      CONSTRAINT unique_user_source UNIQUE (user_id, source)
    )
  SQL

  # User tag preferences table
  POOL.exec <<-SQL
    CREATE TABLE IF NOT EXISTS user_tag_preferences (
      id SERIAL PRIMARY KEY,
      user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
      tag TEXT NOT NULL,
      score FLOAT DEFAULT 0.0,
      updated_at TIMESTAMP DEFAULT NOW(),
      CONSTRAINT unique_user_tag UNIQUE (user_id, tag)
    )
  SQL

  # Indexes for performance
  POOL.exec "CREATE INDEX IF NOT EXISTS idx_interactions_user_id ON user_interactions(user_id)"
  POOL.exec "CREATE INDEX IF NOT EXISTS idx_interactions_post_id ON user_interactions(post_id)"
  POOL.exec "CREATE INDEX IF NOT EXISTS idx_interactions_created_at ON user_interactions(created_at DESC)"
  POOL.exec "CREATE INDEX IF NOT EXISTS idx_source_prefs_user_id ON user_source_preferences(user_id)"
  POOL.exec "CREATE INDEX IF NOT EXISTS idx_tag_prefs_user_id ON user_tag_preferences(user_id)"
end
