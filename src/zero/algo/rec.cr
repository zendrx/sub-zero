# rec.cr - Recommendation engine for Crystal Aggregator

require "json"

module RecommendationEngine
  # Feed types
  enum FeedType
    Hot
    New
    Top
    Personalized
    Trending
    Discovery
    Collaborative
    Mixed
  end

  # Get feed based on type
  def self.get_feed(user_id : Int64? = nil, feed_type : FeedType = FeedType::Hot, 
                    limit : Int32 = 50, offset : Int32 = 0) : Array(Hash(String, JSON::Any))
    case feed_type
    when FeedType::Hot
      get_hot_feed(limit, offset)
    when FeedType::New
      get_new_feed(limit, offset)
    when FeedType::Top
      get_top_feed(limit, offset)
    when FeedType::Personalized
      if user_id
        get_personalized_feed(user_id, limit, offset)
      else
        get_hot_feed(limit, offset)
      end
    when FeedType::Trending
      get_trending_feed(limit)
    when FeedType::Discovery
      if user_id
        get_discovery_feed(user_id, limit)
      else
        get_hot_feed(limit, offset)
      end
    when FeedType::Collaborative
      if user_id
        get_collaborative_feed(user_id, limit)
      else
        get_hot_feed(limit, offset)
      end
    when FeedType::Mixed
      if user_id
        get_mixed_feed(user_id, limit)
      else
        get_hot_feed(limit, offset)
      end
    end
  end

  # Hot feed - Reddit-style time decay
  def self.get_hot_feed(limit : Int32 = 50, offset : Int32 = 0) : Array(Hash(String, JSON::Any))
    result = POOL.query(
      "SELECT id, title, url, source, score, comment_count, created_at, upvotes, downvotes
       FROM posts
       WHERE is_user_post = false
       ORDER BY (LOG(GREATEST(score, 1)) + (EXTRACT(EPOCH FROM created_at) / 45000)) DESC
       LIMIT $1 OFFSET $2",
      limit, offset
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
      post["upvotes"] = JSON::Any.new(result.read(Int32))
      post["downvotes"] = JSON::Any.new(result.read(Int32))
      post["feed_type"] = JSON::Any.new("hot")
      posts << post
    end
    posts
  end

  # New feed - most recent first
  def self.get_new_feed(limit : Int32 = 50, offset : Int32 = 0) : Array(Hash(String, JSON::Any))
    result = POOL.query(
      "SELECT id, title, url, source, score, comment_count, created_at, upvotes, downvotes
       FROM posts
       WHERE is_user_post = false
       ORDER BY created_at DESC
       LIMIT $1 OFFSET $2",
      limit, offset
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
      post["upvotes"] = JSON::Any.new(result.read(Int32))
      post["downvotes"] = JSON::Any.new(result.read(Int32))
      post["feed_type"] = JSON::Any.new("new")
      posts << post
    end
    posts
  end

  # Top feed - highest scoring posts
  def self.get_top_feed(limit : Int32 = 50, offset : Int32 = 0) : Array(Hash(String, JSON::Any))
    result = POOL.query(
      "SELECT id, title, url, source, score, comment_count, created_at, upvotes, downvotes
       FROM posts
       WHERE is_user_post = false
       ORDER BY score DESC
       LIMIT $1 OFFSET $2",
      limit, offset
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
      post["upvotes"] = JSON::Any.new(result.read(Int32))
      post["downvotes"] = JSON::Any.new(result.read(Int32))
      post["feed_type"] = JSON::Any.new("top")
      posts << post
    end
    posts
  end

  # Personalized feed - based on user preferences
  def self.get_personalized_feed(user_id : Int64, limit : Int32 = 50, offset : Int32 = 0) : Array(Hash(String, JSON::Any))
    # Get user preferences from AlgoDB
    source_scores = AlgoDB.get_user_source_preferences(user_id)
    tag_scores = AlgoDB.get_user_tag_preferences(user_id)
    
    # Fetch candidate posts
    result = POOL.query(
      "SELECT id, title, url, source, score, comment_count, created_at, upvotes, downvotes
       FROM posts
       WHERE is_user_post = false
         AND id NOT IN (
           SELECT post_id FROM user_interactions WHERE user_id = $1
         )
       ORDER BY created_at DESC
       LIMIT $2 OFFSET $3",
      user_id, limit * 2, offset
    )
    
    # Score each post based on user preferences
    scored_posts = [] of Tuple(Float64, Hash(String, JSON::Any))
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
      post["upvotes"] = JSON::Any.new(result.read(Int32))
      post["downvotes"] = JSON::Any.new(result.read(Int32))
      
      # Calculate score
      score = calculate_personalized_score(post, source_scores, tag_scores)
      scored_posts << {score, post}
    end
    
    scored_posts.sort! { |a, b| b[0] <=> a[0] }
    scored_posts.first(limit).map do |_, post|
      post.merge({"feed_type" => JSON::Any.new("personalized")})
    end
  end

  # Calculate personalized score for a post
  def self.calculate_personalized_score(post : Hash(String, JSON::Any),
                                        source_scores : Hash(String, Float64),
                                        tag_scores : Hash(String, Float64)) : Float64
    # Base score from community engagement
    base_score = Math.log([post["score"].as_i64.to_f, 1].max) / 10.0
    
    # Source preference
    source = post["source"].as_s
    source_boost = source_scores[source]? || 0.0
    normalized_source = Math.tanh(source_boost / 10.0)
    
    # Tag preference
    tags = AlgoDB.extract_tags_from_text(post["title"].as_s)
    tag_boost = 0.0
    tags.each do |tag|
      tag_boost += tag_scores[tag]? || 0.0
    end
    normalized_tag = Math.tanh((tag_boost / [tags.size, 1].max) / 10.0)
    
    # Time decay
    created_at = Time.parse(post["created_at"].as_s, "%Y-%m-%d %H:%M:%S", Time::Location::UTC)
    hours = (Time.utc - created_at).total_hours
    time_boost = 1.0 / (1.0 + hours / 72.0)
    
    # Combine scores
    final_score = (base_score * 0.3) + (normalized_source * 0.35) + (normalized_tag * 0.25) + (time_boost * 0.1)
    final_score.clamp(0.0, 1.0)
  end

  # Trending feed - posts with recent engagement spikes
  def self.get_trending_feed(limit : Int32 = 20) : Array(Hash(String, JSON::Any))
    AlgoDB.get_trending_posts(limit).map do |post|
      post.merge({"feed_type" => JSON::Any.new("trending")})
    end
  end

  # Discovery feed - new sources the user hasn't explored
  def self.get_discovery_feed(user_id : Int64, limit : Int32 = 20) : Array(Hash(String, JSON::Any))
    AlgoDB.get_discovery_posts(user_id, limit).map do |post|
      post.merge({"feed_type" => JSON::Any.new("discovery")})
    end
  end

  # Collaborative feed - what similar users like
  def self.get_collaborative_feed(user_id : Int64, limit : Int32 = 20) : Array(Hash(String, JSON::Any))
    AlgoDB.get_collaborative_recommendations(user_id, limit).map do |post|
      post.merge({"feed_type" => JSON::Any.new("collaborative")})
    end
  end

  # Mixed feed - combines multiple feed types
  def self.get_mixed_feed(user_id : Int64, limit : Int32 = 50) : Array(Hash(String, JSON::Any))
    feeds = [] of Array(Hash(String, JSON::Any))
    
    # Get posts from different feed types
    feeds << get_hot_feed(limit // 4, 0)
    feeds << get_personalized_feed(user_id, limit // 4, 0)
    feeds << get_trending_feed(limit // 4)
    feeds << get_collaborative_feed(user_id, limit // 4)
    
    # Combine and shuffle slightly
    combined = feeds.flatten
    combined.shuffle(random: Random.new(Time.utc.to_unix))
    combined.first(limit).map do |post|
      post.merge({"feed_type" => JSON::Any.new("mixed")})
    end
  end
end
