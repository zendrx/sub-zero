# dev_to.cr - Dev.to content fetcher for Crystal Aggregator
# Fetches articles from Dev.to API and stores them in the database

require "http/client"
require "json"

module DevToFetcher
  # Dev.to API endpoints
  BASE_URL = "https://dev.to/api"
  
  # Number of articles to fetch per request
  DEFAULT_LIMIT = 30
  
  # Article sorting options
  SORT_OPTIONS = ["hot", "top", "new", "feed"]
  
  # Time ranges for top articles
  TIME_RANGES = ["week", "month", "year", "infinity"]
  
  # Tag list for filtering
  POPULAR_TAGS = ["ruby", "javascript", "python", "react", "rails", "go", "rust", "devops", "cloud", "ai", "machinelearning", "webdev"]
  
  # Fetches articles with optional filters
  def self.fetch_articles(params : Hash(String, String | Int32 | Nil) = {} of String => String | Int32 | Nil) : Array(Hash(String, JSON::Type))
    # Build query string
    query = [] of String
    params.each do |key, value|
      if value
        query << "#{key}=#{URI.encode_path(value.to_s)}"
      end
    end
    
    url = query.empty? ? "#{BASE_URL}/articles" : "#{BASE_URL}/articles?#{query.join("&")}"
    
    # Add User-Agent header
    headers = HTTP::Headers{"User-Agent" => "CrystalAggregator/1.0"}
    
    response = HTTP::Client.get(url, headers: headers)
    
    if response.status_code == 200
      parse_articles_response(response.body)
    elsif response.status_code == 429
      puts "Rate limited by Dev.to, waiting 30 seconds..."
      sleep 30
      # Retry once
      response = HTTP::Client.get(url, headers: headers)
      if response.status_code == 200
        parse_articles_response(response.body)
      else
        puts "Failed to fetch articles: #{response.status_code}"
        [] of Hash(String, JSON::Type)
      end
    else
      puts "Failed to fetch articles: #{response.status_code}"
      [] of Hash(String, JSON::Type)
    end
  rescue e : Exception
    puts "Error fetching articles: #{e.message}"
    [] of Hash(String, JSON::Type)
  end
  
  # Parses the JSON response from Dev.to
  def self.parse_articles_response(body : String) : Array(Hash(String, JSON::Type))
    begin
      data = JSON.parse(body)
      articles = [] of Hash(String, JSON::Type)
      
      data.as_a.each do |article|
        # Extract article information
        title = article["title"]?.to_s || "Untitled"
        url = article["url"]?.to_s || ""
        description = article["description"]?.to_s || ""
        cover_image = article["cover_image"]?.to_s || ""
        published_at = article["published_at"]?.to_s || ""
        tag_list = article["tag_list"]?.to_s || ""
        positive_reactions_count = article["positive_reactions_count"]?.to_i || 0
        comments_count = article["comments_count"]?.to_i || 0
        external_id = article["id"]?.to_i64.to_s
        reading_time_minutes = article["reading_time_minutes"]?.to_i || 0
        user = article["user"]?
        user_name = user ? user["name"]?.to_s : ""
        user_username = user ? user["username"]?.to_s : ""
        user_profile_image = user ? user["profile_image"]?.to_s : ""
        user_github = user ? user["github_username"]?.to_s : ""
        user_twitter = user ? user["twitter_username"]?.to_s : ""
        organisation = article["organization"]?
        org_name = organisation ? organisation["name"]?.to_s : ""
        
        # Build content from description and tags
        content = description
        tags = tag_list.split(",").map(&.strip).join(", ")
        
        # Build the article hash
        article_data = {
          "title"                  => title,
          "url"                    => url,
          "content"                => content,
          "cover_image"            => cover_image,
          "source"                 => "devto",
          "external_id"            => external_id,
          "score"                  => positive_reactions_count,
          "comment_count"          => comments_count,
          "is_user_post"           => false,
          "published_at"           => published_at,
          "tags"                   => tags,
          "author_name"            => user_name,
          "author_username"        => user_username,
          "reading_time"           => reading_time_minutes,
          "org_name"               => org_name
        }
        
        articles << article_data
      end
      
      articles
    rescue e : JSON::ParseException
      puts "Failed to parse JSON: #{e.message}"
      [] of Hash(String, JSON::Type)
    end
  end
  
  # Saves fetched articles to the database, skipping duplicates
  def self.save_articles_to_db(articles : Array(Hash(String, JSON::Type))) : Int32
    saved_count = 0
    
    articles.each do |article|
      external_id = article["external_id"]?.to_s
      next if external_id.empty?
      
      # Check if article already exists
      result = POOL.exec(
        "SELECT id FROM posts WHERE external_id = $1 AND source = 'devto'",
        external_id
      )
      
      if result.rows.empty?
        # Insert new article
        POOL.exec(
          "INSERT INTO posts (title, url, content, source, external_id, score, comment_count, is_user_post) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
          article["title"]?.to_s || "Untitled",
          article["url"]?.to_s || "",
          article["content"]?.to_s || "",
          article["source"]?.to_s || "devto",
          article["external_id"]?.to_s || "",
          article["score"]?.to_i || 0,
          article["comment_count"]?.to_i || 0,
          false
        )
        saved_count += 1
      end
    end
    
    saved_count
  rescue e : PG::Error
    puts "Database error while saving articles: #{e.message}"
    0
  end
  
  # Fetches latest articles
  def self.fetch_latest_articles(limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching latest articles from Dev.to..."
    params = {
      "per_page" => limit,
      "sort"     => "new"
    }
    articles = fetch_articles(params)
    saved = save_articles_to_db(articles)
    puts "Saved #{saved} latest articles"
    saved
  rescue e : Exception
    puts "Error fetching latest articles: #{e.message}"
    0
  end
  
  # Fetches top articles
  def self.fetch_top_articles(limit : Int32 = DEFAULT_LIMIT, time_range : String = "week") : Int32
    puts "Fetching top articles from Dev.to for #{time_range}..."
    params = {
      "per_page"   => limit,
      "sort"       => "top",
      "top_period" => time_range
    }
    articles = fetch_articles(params)
    saved = save_articles_to_db(articles)
    puts "Saved #{saved} top articles for #{time_range}"
    saved
  rescue e : Exception
    puts "Error fetching top articles: #{e.message}"
    0
  end
  
  # Fetches hot articles
  def self.fetch_hot_articles(limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching hot articles from Dev.to..."
    params = {
      "per_page" => limit,
      "sort"     => "hot"
    }
    articles = fetch_articles(params)
    saved = save_articles_to_db(articles)
    puts "Saved #{saved} hot articles"
    saved
  rescue e : Exception
    puts "Error fetching hot articles: #{e.message}"
    0
  end
  
  # Fetches articles by tag
  def self.fetch_articles_by_tag(tag : String, limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching articles tagged with '#{tag}' from Dev.to..."
    params = {
      "per_page" => limit,
      "tag"      => tag
    }
    articles = fetch_articles(params)
    saved = save_articles_to_db(articles)
    puts "Saved #{saved} articles tagged with '#{tag}'"
    saved
  rescue e : Exception
    puts "Error fetching articles by tag: #{e.message}"
    0
  end
  
  # Fetches articles from multiple tags
  def self.fetch_articles_by_tags(tags : Array(String), limit_per_tag : Int32 = 10) : Int32
    total_saved = 0
    
    # Use fibers for concurrent fetching
    channels = tags.map { Channel(Int32).new }
    
    tags.each_with_index do |tag, index|
      spawn do
        saved = fetch_articles_by_tag(tag, limit_per_tag)
        channels[index].send(saved)
      end
    end
    
    # Collect results
    tags.each_with_index do |tag, index|
      saved = channels[index].receive
      total_saved += saved
      puts "Fetched #{saved} articles for tag ##{tag}"
      sleep 1
    end
    
    total_saved
  rescue e : Exception
    puts "Error fetching articles by tags: #{e.message}"
    total_saved
  end
  
  # Fetches articles by username
  def self.fetch_articles_by_username(username : String, limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching articles by '#{username}' from Dev.to..."
    params = {
      "per_page" => limit,
      "username" => username
    }
    articles = fetch_articles(params)
    saved = save_articles_to_db(articles)
    puts "Saved #{saved} articles by '#{username}'"
    saved
  rescue e : Exception
    puts "Error fetching articles by username: #{e.message}"
    0
  end
  
  # Fetches articles by organization
  def self.fetch_articles_by_organization(org_name : String, limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching articles by organization '#{org_name}' from Dev.to..."
    params = {
      "per_page" => limit,
      "org"      => org_name
    }
    articles = fetch_articles(params)
    saved = save_articles_to_db(articles)
    puts "Saved #{saved} articles by '#{org_name}'"
    saved
  rescue e : Exception
    puts "Error fetching articles by organization: #{e.message}"
    0
  end
  
  # Full fetch routine that combines multiple sources
  def self.full_fetch
    puts "Starting full Dev.to fetch..."
    
    # Fetch hot articles
    saved_hot = fetch_hot_articles(25)
    
    # Fetch top articles for different time ranges
    saved_top_week = fetch_top_articles(15, "week")
    saved_top_month = fetch_top_articles(10, "month")
    
    # Fetch latest articles
    saved_latest = fetch_latest_articles(20)
    
    # Fetch articles from popular tags
    saved_tags = fetch_articles_by_tags(["ruby", "python", "javascript", "go", "rust"], 8)
    
    total = saved_hot + saved_top_week + saved_top_month + saved_latest + saved_tags
    puts "Dev.to fetch complete. Total saved: #{total} articles"
    total
  rescue e : Exception
    puts "Full fetch failed: #{e.message}"
    0
  end
  
  # Fetches a single article by ID
  def self.fetch_article_by_id(id : Int64) : Hash(String, JSON::Type)?
    url = "#{BASE_URL}/articles/#{id}"
    headers = HTTP::Headers{"User-Agent" => "CrystalAggregator/1.0"}
    
    response = HTTP::Client.get(url, headers: headers)
    
    if response.status_code == 200
      begin
        data = JSON.parse(response.body)
        
        {
          "title"          => data["title"]?.to_s || "Untitled",
          "url"            => data["url"]?.to_s || "",
          "content"        => data["body_html"]?.to_s || data["description"]?.to_s || "",
          "source"         => "devto",
          "external_id"    => data["id"]?.to_i64.to_s,
          "score"          => data["positive_reactions_count"]?.to_i || 0,
          "comment_count"  => data["comments_count"]?.to_i || 0,
          "is_user_post"   => false
        }
      rescue e : Exception
        puts "Failed to parse article #{id}: #{e.message}"
        nil
      end
    else
      puts "Failed to fetch article #{id}: #{response.status_code}"
      nil
    end
  rescue e : Exception
    puts "Error fetching article #{id}: #{e.message}"
    nil
  end
  
  # Search articles by query
  def self.search_articles(query : String, limit : Int32 = DEFAULT_LIMIT) : Array(Hash(String, JSON::Type))
    url = "#{BASE_URL}/articles?search=#{URI.encode_path(query)}&per_page=#{limit}"
    headers = HTTP::Headers{"User-Agent" => "CrystalAggregator/1.0"}
    
    response = HTTP::Client.get(url, headers: headers)
    
    if response.status_code == 200
      parse_articles_response(response.body)
    else
      puts "Search failed: #{response.status_code}"
      [] of Hash(String, JSON::Type)
    end
  rescue e : Exception
    puts "Error searching articles: #{e.message}"
    [] of Hash(String, JSON::Type)
  end
end
