# us.cr - User algorithms for Crystal Aggregator

require "json"
require "time"

module UserAlgorithms
  # Calculate user engagement score
  def self.calculate_user_engagement_score(user_id : Int64) : Float64
    stats = AlgoDB.get_user_stats(user_id)
    
    upvote_weight = 2.0
    comment_weight = 3.0
    save_weight = 1.5
    
    score = 0.0
    
    upvotes = stats["upvotes"]?.try &.as_i64
    if upvotes
      score += upvotes.to_f * upvote_weight
    end
    
    comments = stats["comments"]?.try &.as_i64
    if comments
      score += comments.to_f * comment_weight
    end
    
    saves = stats["saves"]?.try &.as_i64
    if saves
      score += saves.to_f * save_weight
    end
    
    sources = stats["sources_used"]?.try &.as_i64
    if sources
      score += Math.log([sources.to_f, 1.0].max) * 2.0
    end
    
    score
  end
  
  # Predict user interest in a post
  def self.predict_user_interest(user_id : Int64, post_id : Int64) : Float64
    result = POOL.query(
      "SELECT source, title, score FROM posts WHERE id = $1",
      post_id
    )
    if !result.move_next
      return 0.0
    end
    
    source = result.read(String)
    title = result.read(String)
    
    source_scores = AlgoDB.get_user_source_preferences(user_id)
    tag_scores = AlgoDB.get_user_tag_preferences(user_id)
    
    interest = 0.0
    
    source_score = source_scores[source]? || 0.0
    interest += Math.tanh(source_score / 10.0) * 0.4
    
    tags = AlgoDB.extract_tags_from_text(title)
    tag_score = 0.0
    tags.each do |tag|
      tag_score += tag_scores[tag]? || 0.0
    end
    tag_score = tag_score / [tags.size, 1].max
    interest += Math.tanh(tag_score / 10.0) * 0.3
    
    sources_used = AlgoDB.get_user_source_preferences(user_id).size
    if sources_used > 0
      diversity_penalty = 0.05 * (1.0 - Math.exp(-sources_used / 5.0))
      interest += diversity_penalty
    end
    
    interest.clamp(0.0, 1.0)
  end

  # Get user's activity pattern
  def self.get_user_activity_pattern(user_id : Int64) : Hash(String, JSON::Any)
    result = POOL.query(
      "SELECT 
         DATE_TRUNC('hour', created_at) as hour,
         COUNT(*) as interactions
       FROM user_interactions
       WHERE user_id = $1
         AND created_at > NOW() - INTERVAL '7 days'
       GROUP BY DATE_TRUNC('hour', created_at)
       ORDER BY hour",
      user_id
    )
    
    hours = Array(Int32).new(24, 0)
    result.each do
      hour_str = result.read(Time).to_s
      hour = Time.parse(hour_str, "%Y-%m-%d %H:%M:%S", Time::Location::UTC).hour
      count = result.read(Int64)
      hours[hour] += count.to_i
    end
    
    peak_hour = hours.index(hours.max) || 0
    avg_hourly = hours.sum.to_f / hours.size
    
    hourly_activity = hours.map { |h| JSON::Any.new(h) }
    
    activity = Hash(String, JSON::Any).new
    activity["hourly_activity"] = JSON::Any.new(hourly_activity)
    activity["peak_hour"] = JSON::Any.new(peak_hour)
    activity["avg_hourly"] = JSON::Any.new(avg_hourly)
    activity["total_activity"] = JSON::Any.new(hours.sum)
    activity
  end

  # Get user's favorite sources
  def self.get_favorite_sources(user_id : Int64, limit : Int32 = 5) : Array(Hash(String, JSON::Any))
    result = POOL.query(
      "SELECT source, score
       FROM user_source_preferences
       WHERE user_id = $1
       ORDER BY score DESC
       LIMIT $2",
      user_id, limit
    )
    
    sources = [] of Hash(String, JSON::Any)
    result.each do
      source = Hash(String, JSON::Any).new
      source["source"] = JSON::Any.new(result.read(String))
      source["score"] = JSON::Any.new(result.read(Float64))
      sources << source
    end
    sources
  end

  # Get user's favorite tags
  def self.get_favorite_tags(user_id : Int64, limit : Int32 = 5) : Array(Hash(String, JSON::Any))
    result = POOL.query(
      "SELECT tag, score
       FROM user_tag_preferences
       WHERE user_id = $1
       ORDER BY score DESC
       LIMIT $2",
      user_id, limit
    )
    
    tags = [] of Hash(String, JSON::Any)
    result.each do
      tag = Hash(String, JSON::Any).new
      tag["tag"] = JSON::Any.new(result.read(String))
      tag["score"] = JSON::Any.new(result.read(Float64))
      tags << tag
    end
    tags
  end

  # Get personalized recommendations for a user
  def self.get_recommendations(user_id : Int64, limit : Int32 = 20) : Array(Hash(String, JSON::Any))
    collab = AlgoDB.get_collaborative_recommendations(user_id, limit // 2)
    
    remaining = limit - collab.size
    personal = [] of Hash(String, JSON::Any)
    if remaining > 0
      # Use RecommendationEngine instead of AlgoDB
      personal = RecommendationEngine.get_personalized_feed(user_id, remaining, 0)
    end
    
    (collab + personal).map do |post|
      post.merge({
        "predicted_interest" => JSON::Any.new(predict_user_interest(user_id, post["id"].as_i64)),
        "recommendation_type" => JSON::Any.new("personalized")
      })
    end
  end

  # Get "because you liked X" recommendations
  def self.get_related_recommendations(user_id : Int64, post_id : Int64, limit : Int32 = 10) : Array(Hash(String, JSON::Any))
    similar_users_result = POOL.query(
      "SELECT DISTINCT user_id
       FROM user_interactions
       WHERE post_id = $1 AND interaction_type = 'upvote'
       LIMIT 50",
      post_id
    )
    
    similar_users = [] of Int64
    similar_users_result.each do
      similar_users << similar_users_result.read(Int64)
    end
    
    return [] of Hash(String, JSON::Any) if similar_users.empty?
    
    result = POOL.query(
      "SELECT DISTINCT p.id, p.title, p.url, p.source, p.score, p.comment_count, p.created_at,
              COUNT(DISTINCT i.user_id) as similar_votes
       FROM posts p
       JOIN user_interactions i ON p.id = i.post_id
       WHERE i.user_id IN (#{similar_users.join(",")})
         AND i.interaction_type = 'upvote'
         AND p.id != $1
         AND p.id NOT IN (
           SELECT post_id FROM user_interactions WHERE user_id = $2
         )
         AND p.is_user_post = false
       GROUP BY p.id
       ORDER BY similar_votes DESC, p.score DESC
       LIMIT $3",
      post_id, user_id, limit
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
      post["recommendation_type"] = JSON::Any.new("because_you_liked")
      posts << post
    end
    posts
  end

  # Calculate user similarity score between two users
  def self.calculate_user_similarity(user_a : Int64, user_b : Int64) : Float64
    result = POOL.query(
      "SELECT 
         COUNT(*) as common,
         (SELECT COUNT(*) FROM user_interactions WHERE user_id = $1) as total_a,
         (SELECT COUNT(*) FROM user_interactions WHERE user_id = $2) as total_b
       FROM user_interactions a
       JOIN user_interactions b ON a.post_id = b.post_id
       WHERE a.user_id = $1 AND b.user_id = $2
         AND a.interaction_type = 'upvote'
         AND b.interaction_type = 'upvote'",
      user_a, user_b
    )
    
    if !result.move_next
      return 0.0
    end
    
    common = result.read(Int64).to_f
    total_a = result.read(Int64).to_f
    total_b = result.read(Int64).to_f
    
    return 0.0 if total_a == 0 || total_b == 0
    
    common / (total_a + total_b - common)
  end

  # Get user's engagement history (for timeline visualization)
  def self.get_engagement_history(user_id : Int64, days : Int32 = 7) : Array(Hash(String, JSON::Any))
    result = POOL.query(
      "SELECT 
         DATE_TRUNC('day', created_at) as day,
         COUNT(*) FILTER (WHERE interaction_type = 'view') as views,
         COUNT(*) FILTER (WHERE interaction_type = 'upvote') as upvotes,
         COUNT(*) FILTER (WHERE interaction_type = 'downvote') as downvotes,
         COUNT(*) FILTER (WHERE interaction_type = 'comment') as comments,
         COUNT(*) FILTER (WHERE interaction_type = 'save') as saves
       FROM user_interactions
       WHERE user_id = $1
         AND created_at > NOW() - INTERVAL '$2 days'
       GROUP BY DATE_TRUNC('day', created_at)
       ORDER BY day",
      user_id, days
    )
    
    history = [] of Hash(String, JSON::Any)
    result.each do
      day = Hash(String, JSON::Any).new
      day["day"] = JSON::Any.new(result.read(Time).to_s)
      day["views"] = JSON::Any.new(result.read(Int64))
      day["upvotes"] = JSON::Any.new(result.read(Int64))
      day["downvotes"] = JSON::Any.new(result.read(Int64))
      day["comments"] = JSON::Any.new(result.read(Int64))
      day["saves"] = JSON::Any.new(result.read(Int64))
      history << day
    end
    history
  end
end
