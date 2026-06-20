# reddit.cr - Reddit content fetcher for Crystal Aggregator
# Fetches posts from multiple subreddits and stores them in the database

require "http/client"
require "json"

module RedditFetcher
  # Configuration
  USER_AGENT = "CrystalAggregator/1.0 (by /zen/zendrx)"
  BASE_URL = "https://www.reddit.com"
  
  # List of subreddits to fetch from
  SUBREDDITS = ["all", "popular", "AskReddit", "worldnews", "technology", "science", "programming", "funny", "pics", "videos"]
  
  # Number of posts to fetch per subreddit
  LIMIT_PER_SUBREDDIT = 25
  
  # Different sorting methods
  SORT_TYPES = ["hot", "new", "top", "rising", "controversial"]
  
  # Time ranges for top/controversial sorting
  TIME_RANGES = ["hour", "day", "week", "month", "year", "all"]
  
  # Fetches posts from a specific subreddit with given sort type
  def self.fetch_subreddit(subreddit : String, sort : String = "hot", time : String = "day", limit : Int32 = LIMIT_PER_SUBREDDIT) : Array(Hash(String, JSON::Any))
    # Build the URL based on sort type
    url = case sort
          when "hot"
            "#{BASE_URL}/r/#{subreddit}/hot.json?limit=#{limit}"
          when "new"
            "#{BASE_URL}/r/#{subreddit}/new.json?limit=#{limit}"
          when "top"
            "#{BASE_URL}/r/#{subreddit}/top.json?limit=#{limit}&t=#{time}"
          when "rising"
            "#{BASE_URL}/r/#{subreddit}/rising.json?limit=#{limit}"
          when "controversial"
            "#{BASE_URL}/r/#{subreddit}/controversial.json?limit=#{limit}&t=#{time}"
          else
            "#{BASE_URL}/r/#{subreddit}/hot.json?limit=#{limit}"
          end
    
    # Make the request
    response = HTTP::Client.get(url, headers: HTTP::Headers{"User-Agent" => USER_AGENT})
    
    # Check if request was successful
    if response.status_code == 200
      parse_reddit_response(response.body)
    elsif response.status_code == 429
      puts "Rate limited by Reddit, waiting 60 seconds..."
      sleep 60
      # Retry once
      response = HTTP::Client.get(url, headers: HTTP::Headers{"User-Agent" => USER_AGENT})
      if response.status_code == 200
        parse_reddit_response(response.body)
      else
        puts "Failed to fetch from r/#{subreddit}: #{response.status_code}"
        [] of Hash(String, JSON::Any)
      end
    else
      puts "Failed to fetch from r/#{subreddit}: #{response.status_code}"
      [] of Hash(String, JSON::Any)
    end
  rescue e : Exception
    puts "Error fetching r/#{subreddit}: #{e.message}"
    [] of Hash(String, JSON::Any)
  end
  
  # Parses the JSON response from Reddit
  def self.parse_reddit_response(body : String) : Array(Hash(String, JSON::Any))
    begin
      data = JSON.parse(body)
      posts = [] of Hash(String, JSON::Any)
      
      # Navigate the Reddit JSON structure
      if children = data["data"]? && data["data"]["children"]?
        children.as_a.each do |child|
          if post_data = child["data"]?
            # Extract post information - use .as_i for integers
            title = post_data["title"]?.to_s
            url = post_data["url"]?.to_s
            permalink = post_data["permalink"]?.to_s
            score = post_data["score"]?.try &.as_i || 0
            comment_count = post_data["num_comments"]?.try &.as_i || 0
            external_id = post_data["id"]?.to_s
            subreddit = post_data["subreddit"]?.to_s
            created_utc = post_data["created_utc"]?.try &.as_i || 0
            author = post_data["author"]?.to_s
            is_self = post_data["is_self"]?.try &.as_bool || false
            selftext = post_data["selftext"]?.to_s || ""
            
            # For self-posts, use the selftext as content
            # For link posts, use the URL
            content = is_self ? selftext : ""
            
            # Build the post hash using JSON::Any
            post = Hash(String, JSON::Any).new
            post["title"] = JSON::Any.new(title)
            post["url"] = JSON::Any.new(url)
            post["content"] = JSON::Any.new(content)
            post["source"] = JSON::Any.new("reddit")
            post["external_id"] = JSON::Any.new(external_id)
            post["subreddit"] = JSON::Any.new(subreddit)
            post["author"] = JSON::Any.new(author)
            post["score"] = JSON::Any.new(score)
            post["comment_count"] = JSON::Any.new(comment_count)
            post["is_self"] = JSON::Any.new(is_self)
            post["created_utc"] = JSON::Any.new(created_utc)
            post["permalink"] = JSON::Any.new(permalink)
            post["is_user_post"] = JSON::Any.new(false)
            
            posts << post
          end
        end
      end
      
      posts
    rescue e : JSON::ParseException
      puts "Failed to parse JSON: #{e.message}"
      [] of Hash(String, JSON::Any)
    end
  end
  
  # Saves fetched posts to the database, skipping duplicates
  def self.save_posts_to_db(posts : Array(Hash(String, JSON::Any))) : Int32
    saved_count = 0
    
    posts.each do |post|
      external_id = post["external_id"]?.to_s
      next if external_id.empty?
      
      # Check if post already exists using query
      result = POOL.query(
        "SELECT id FROM posts WHERE external_id = $1 AND source = 'reddit'",
        external_id
      )
      
      if !result.move_next
        # Insert new post
        POOL.exec(
          "INSERT INTO posts (title, url, content, source, external_id, score, comment_count, is_user_post) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
          post["title"]?.to_s || "Untitled",
          post["url"]?.to_s || "",
          post["content"]?.to_s || "",
          post["source"]?.to_s || "reddit",
          post["external_id"]?.to_s || "",
          post["score"]?.to_i || 0,
          post["comment_count"]?.to_i || 0,
          false
        )
        saved_count += 1
      end
    end
    
    saved_count
  rescue e : PG::Error
    puts "Database error while saving posts: #{e.message}"
    0
  end
  
  # Fetches posts from multiple subreddits with different sorting methods
  def self.fetch_multi_subreddits(subreddits : Array(String) = SUBREDDITS, sort : String = "hot", time : String = "day") : Int32
    total_saved = 0
    
    # Use fibers for concurrent fetching
    channels = subreddits.map do |sub|
      Channel(Array(Hash(String, JSON::Any))).new
    end
    
    subreddits.each_with_index do |sub, index|
      spawn do
        posts = fetch_subreddit(sub, sort, time)
        channels[index].send(posts)
      end
    end
    
    # Collect and save results
    subreddits.each_with_index do |sub, index|
      posts = channels[index].receive
      saved = save_posts_to_db(posts)
      total_saved += saved
      puts "Saved #{saved} posts from r/#{sub}"
    end
    
    total_saved
  rescue e : Exception
    puts "Error in multi-subreddit fetch: #{e.message}"
    total_saved
  end
  
  # Fetches posts using multiple sorting methods
  def self.fetch_with_multiple_sorts(subreddit : String = "all", sorts : Array(String) = ["hot", "new", "top"]) : Int32
    total_saved = 0
    
    sorts.each do |sort|
      time = sort == "top" || sort == "controversial" ? "day" : ""
      posts = fetch_subreddit(subreddit, sort, time)
      saved = save_posts_to_db(posts)
      total_saved += saved
      puts "Saved #{saved} posts from r/#{subreddit} with sort '#{sort}'"
      sleep 1 # Be nice to Reddit's API
    end
    
    total_saved
  rescue e : Exception
    puts "Error fetching with multiple sorts: #{e.message}"
    total_saved
  end
  
  # Fetches popular posts from various time ranges
  def self.fetch_top_time_ranges(subreddit : String = "all", time_ranges : Array(String) = ["day", "week", "month"]) : Int32
    total_saved = 0
    
    time_ranges.each do |time|
      posts = fetch_subreddit(subreddit, "top", time)
      saved = save_posts_to_db(posts)
      total_saved += saved
      puts "Saved #{saved} posts from r/#{subreddit} for time range '#{time}'"
      sleep 1
    end
    
    total_saved
  rescue e : Exception
    puts "Error fetching top by time ranges: #{e.message}"
    total_saved
  end
  
  # Search Reddit for posts matching a query
  def self.search(query : String, limit : Int32 = 25) : Array(Hash(String, JSON::Any))
    url = "#{BASE_URL}/search.json?q=#{URI.encode_path(query)}&limit=#{limit}"
    
    response = HTTP::Client.get(url, headers: HTTP::Headers{"User-Agent" => USER_AGENT})
    
    if response.status_code == 200
      parse_reddit_response(response.body)
    else
      puts "Search failed: #{response.status_code}"
      [] of Hash(String, JSON::Any)
    end
  rescue e : Exception
    puts "Error searching Reddit: #{e.message}"
    [] of Hash(String, JSON::Any)
  end
  
  # Fetches posts from a specific user's submissions
  def self.fetch_user_posts(username : String, limit : Int32 = 25) : Array(Hash(String, JSON::Any))
    url = "#{BASE_URL}/user/#{username}/submitted.json?limit=#{limit}"
    
    response = HTTP::Client.get(url, headers: HTTP::Headers{"User-Agent" => USER_AGENT})
    
    if response.status_code == 200
      parse_reddit_response(response.body)
    else
      puts "Failed to fetch user posts: #{response.status_code}"
      [] of Hash(String, JSON::Any)
    end
  rescue e : Exception
    puts "Error fetching user posts: #{e.message}"
    [] of Hash(String, JSON::Any)
  end
  
  # Full fetch routine that combines different strategies
  def self.full_fetch
    puts "Starting full Reddit fetch..."
    
    # Fetch hot posts from major subreddits
    puts "Fetching hot posts..."
    saved_hot = fetch_multi_subreddits(["all", "popular", "AskReddit", "worldnews", "technology"], "hot")
    puts "Saved #{saved_hot} hot posts"
    
    # Fetch top posts from programming subreddits
    puts "Fetching top posts from programming subreddits..."
    saved_top = fetch_multi_subreddits(["programming", "webdev", "python", "rust", "golang"], "top")
    puts "Saved #{saved_top} top posts"
    
    # Fetch rising posts for fresh content
    puts "Fetching rising posts..."
    saved_rising = fetch_multi_subreddits(["all", "popular"], "rising")
    puts "Saved #{saved_rising} rising posts"
    
    total = saved_hot + saved_top + saved_rising
    puts "Reddit fetch complete. Total saved: #{total} posts"
    total
  rescue e : Exception
    puts "Full fetch failed: #{e.message}"
    0
  end
  
  # Rotate user agents to avoid rate limiting
  def self.rotate_user_agent
    user_agents = [
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
      "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
      "Mozilla/5.0 (iPhone; CPU iPhone OS 14_0 like Mac OS X) AppleWebKit/605.1.15",
      "CrystalAggregator/1.0 (by /zen/zendrx)"
    ]
    user_agents.sample
  end
end
