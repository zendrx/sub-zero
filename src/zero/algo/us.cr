# us.cr - User algorithms for Crystal Aggregator
# Handles user-specific algorithmic operations

require "json"
require "time"

module UserAlgorithms
  # User engagement scoring
  # Higher score = more active, engaged user
  def self.calculate_user_engagement_score(user_id : Int64) : Float64
    stats = AlgoDB.get_user_stats(user_id)
    
    # Weight different activities
    upvote_weight = 2.0
    comment_weight = 3.0
    save_weight = 1.5
    share_weight = 4.0
    view_weight = 0.5
    
    score = 0.0
    score += stats["upvotes"].to_f * upvote_weight
    score += stats["comments"].to_f * comment_weight
    score += stats["saves"].to_f * save_weight
    # score += stats["shares"].to_f * share_weight
    # score += stats["views"].to_f * view_weight
    
    # Sources diversity bonus
    sources = stats["sources_used"].to_f
    score += Math.log([sources, 1].max) * 2.0
    
    score
  end
  
  # Predict user interest in a post
  def self.predict_user_interest(user_id : Int64, post_id : Int64) : Float64
    # Get post details
    result = POOL.exec(
      "SELECT source, title, score FROM posts WHERE id = $1",
      post_id
    )
    row = result.rows.first?
    return 0.0 unless row
    
    source = row[0].to_s
    title = row[1].to_s
    
    # Get user preferences
    source_scores = AlgoDB.get_user_source_preferences(user_id)
    tag_scores = AlgoDB.get_user_tag_preferences(user_id)
    
    # Calculate interest score
    interest = 0.0
    
    # Source match
    source_score = source_scores[source]? || 0.0
    interest += Math.tanh(source_score / 10.0) * 0.4
    
    # Tag match
    tags = AlgoDB.extract_tags_from_text(title)
    tag_score = 0.0
    tags.each do |tag|
      tag_score += tag_scores[tag]? || 0.0
    end
    tag_score = tag_score / [tags.size, 1].max
    interest += Math.tanh(tag_score / 10.0) * 0.3
    
    # Recency boost for new posts
    created_at = Time.parse(row[2].to_s, "%Y-%m-%d %H:%M:%S", Time::Location::UTC) rescue Time.utc
    hours = (Time.utc - created_at).total_hours
    recency = 1.0 / (1.0 + hours / 24.0)
    interest += recency * 0.15
    
    # Source diversity (if user only likes one source, give small negative)
    sources_used = AlgoDB.get_user_source_preferences(user_id).size
    if sources_used > 0
      diversity_penalty = 0.05 * (1.0 - Math.exp(-sources_used / 5.0))
      interest += diversity_penalty
    end
    
    interest.clamp(0.0, 1.0)
  end

  # Get user's activity pattern
  def self.get_user_activity_pattern(user_id : Int64) : Hash(String, JSON::Type)
    result = POOL.exec(
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
    result.rows.each do |row|
      hour_str = row[0].to_s
      hour = Time.parse(hour_str, "%Y-%m-%d %H:%M:%S", Time::Location::UTC).hour
      count = row[1].to_i
      hours[hour] += count
    end
    
    # Find peak activity hour
    peak_hour = hours.index(hours.max) || 0
    avg_hourly = hours.sum.to_f / hours.size
    
    {
      "hourly_activity" => hours,
      "peak_hour"       => peak_hour,
      "avg_hourly"      => avg_hourly,
      "total_activity"  => hours.sum
    }
  end

  # Get user's favorite sources
  def self.get_favorite_sources(user_id : Int64, limit : Int32 = 5) : Array(Hash(String, JSON::Type))
    result = POOL.exec(
      "SELECT source, score
       FROM user_source_preferences
       WHERE user_id = $1
       ORDER BY score DESC
       LIMIT $2",
      user_id, limit
    )
    
    result.rows.map do |row|
      {
        "source" => row[0].to_s,
        "score"  => row[1].to_f
      }
    end
  end

  # Get user's favorite tags
  def self.get_favorite_tags(user_id : Int64, limit : Int32 = 5) : Array(Hash(String, JSON::Type))
    result = POOL.exec(
      "SELECT tag, score
       FROM user_tag_preferences
       WHERE user_id = $1
       ORDER BY score DESC
       LIMIT $2",
      user_id, limit
    )
    
    result.rows.map do |row|
      {
        "tag"   => row[0].to_s,
        "score" => row[1].to_f
      }
    end
  end

  # Get personalized recommendations for a user
  def self.get_recommendations(user_id : Int64, limit : Int32 = 20) : Array(Hash(String, JSON::Type))
    # Try collaborative first
    collab = AlgoDB.get_collaborative_recommendations(user_id, limit // 2)
    
    # Fill remaining with personalized
    remaining = limit - collab.size
    personal = [] of Hash(String, JSON::Type)
    if remaining > 0
      personal = AlgoDB.get_personalized_feed(user_id, remaining, 0)
    end
    
    (collab + personal).map do |post|
      # Add prediction score
      post.merge({
        "predicted_interest" => predict_user_interest(user_id, post["id"].to_i64),
        "recommendation_type" => "personalized"
      })
    end
  end

  # Get "because you liked X" recommendations
  def self.get_related_recommendations(user_id : Int64, post_id : Int64, limit : Int32 = 10) : Array(Hash(String, JSON::Type))
    # Find users who liked this post
    similar_users = POOL.exec(
      "SELECT DISTINCT user_id
       FROM user_interactions
       WHERE post_id = $1 AND interaction_type = 'upvote'
       LIMIT 50",
      post_id
    ).rows.map { |row| row[0].to_i64 }
    
    return [] of Hash(String, JSON::Type) if similar_users.empty?
    
    # Find posts those users liked that this user hasn't seen
    result = POOL.exec(
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
    
    result.rows.map do |row|
      {
        "id"            => row[0].to_i64,
        "title"         => row[1].to_s,
        "url"           => row[2]?.try &.to_s || "",
        "source"        => row[3].to_s,
        "score"         => row[4].to_i,
        "comment_count" => row[5].to_i,
        "created_at"    => row[6].to_s,
        "similar_votes" => row[7].to_i64,
        "recommendation_type" => "because_you_liked"
      }
    end
  end

  # Calculate user similarity score between two users
  def self.calculate_user_similarity(user_a : Int64, user_b : Int64) : Float64
    result = POOL.exec(
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
    
    row = result.rows.first?
    return 0.0 unless row
    
    common = row[0].to_f
    total_a = row[1].to_f
    total_b = row[2].to_f
    
    return 0.0 if total_a == 0 || total_b == 0
    
    # Jaccard similarity
    common / (total_a + total_b - common)
  end

  # Get user's engagement history (for timeline visualization)
  def self.get_engagement_history(user_id : Int64, days : Int32 = 7) : Array(Hash(String, JSON::Type))
    result = POOL.exec(
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
    
    result.rows.map do |row|
      {
        "day"       => row[0].to_s,
        "views"     => row[1].to_i64,
        "upvotes"   => row[2].to_i64,
        "downvotes" => row[3].to_i64,
        "comments"  => row[4].to_i64,
        "saves"     => row[5].to_i64
      }
    end
  end
end
