# dev_to.cr - Dev.to content fetcher for Crystal Aggregator

require "http/client"
require "json"
require "digest/sha256"

module DevToFetcher
  BASE_URL = "https://dev.to/api"
  DEFAULT_LIMIT = 30

  POPULAR_TAGS = [
    "ruby", "python", "javascript", "react", "rails", "go", "rust",
    "devops", "cloud", "ai", "machinelearning", "webdev", "css",
    "html", "vue", "angular", "node", "typescript", "docker",
    "kubernetes", "aws", "azure", "gcp", "linux", "git", "github",
    "opensource", "startup", "productivity", "career", "beginners",
    "codenewbie", "programming", "database", "api", "security"
  ]

  def self.fetch_articles(params : Hash(String, String | Int32 | Nil) = {} of String => String | Int32 | Nil) : Array(Hash(String, JSON::Any))
    query = [] of String
    params.each do |key, value|
      if value
        query << "#{key}=#{URI.encode_path(value.to_s)}"
      end
    end

    url = query.empty? ? "#{BASE_URL}/articles" : "#{BASE_URL}/articles?#{query.join("&")}"
    puts "Dev.to URL: #{url}"

    headers = HTTP::Headers{
      "User-Agent" => "CrystalAggregator/1.0",
      "Accept"     => "application/json"
    }

    if api_key = ENV["DEV_TO"]?
      headers["api-key"] = api_key
    end

    response = HTTP::Client.get(url, headers: headers)

    case response.status_code
    when 200
      parse_articles_response(response.body)
    when 429
      puts "Rate limited by Dev.to, waiting 30 seconds..."
      sleep 30
      response = HTTP::Client.get(url, headers: headers)
      if response.status_code == 200
        parse_articles_response(response.body)
      else
        puts "Failed to fetch articles after retry: #{response.status_code}"
        [] of Hash(String, JSON::Any)
      end
    else
      puts "Failed to fetch articles: #{response.status_code}"
      [] of Hash(String, JSON::Any)
    end
  rescue e : Exception
    puts "Error fetching articles: #{e.message}"
    [] of Hash(String, JSON::Any)
  end

  def self.parse_articles_response(body : String) : Array(Hash(String, JSON::Any))
    begin
      data = JSON.parse(body)
      articles = [] of Hash(String, JSON::Any)

      array_data = data.as_a?
      return articles unless array_data

      array_data.each do |article|
        title = article["title"]?.try &.as_s || "Untitled"
        url = article["url"]?.try &.as_s || ""
        description = article["description"]?.try &.as_s || ""
        published_at = article["published_at"]?.try &.as_s || ""

        # Generate unique external_id from URL
        external_id = url
        if external_id.empty?
          external_id = Digest::SHA256.hexdigest(title + published_at)
        end

        # Build minimal article data
        article_data = Hash(String, JSON::Any).new
        article_data["title"] = JSON::Any.new(title)
        article_data["url"] = JSON::Any.new(url)
        article_data["content"] = JSON::Any.new(description)
        article_data["published_at"] = JSON::Any.new(published_at)
        article_data["external_id"] = JSON::Any.new(external_id)
        article_data["source"] = JSON::Any.new("devto")
        article_data["score"] = JSON::Any.new(0)
        article_data["comment_count"] = JSON::Any.new(0)
        article_data["is_user_post"] = JSON::Any.new(false)

        articles << article_data
      end

      articles
    rescue e : Exception
      puts "Error parsing Dev.to response: #{e.message}"
      [] of Hash(String, JSON::Any)
    end
  end

  def self.save_articles_to_db(articles : Array(Hash(String, JSON::Any))) : Int32
    saved_count = 0
    return 0 if articles.empty?

    articles.each do |article|
      external_id = article["external_id"]?.to_s
      next if external_id.empty?

      result = POOL.query(
        "SELECT id FROM posts WHERE external_id = $1 AND source = 'devto'",
        external_id
      )

      if result.move_next
        next
      end

      begin
        title = article["title"]?.to_s || "Untitled"
        url = article["url"]?.to_s || ""
        content = article["content"]?.to_s || ""
        source = "devto"

        POOL.exec(
          "INSERT INTO posts (title, url, content, source, external_id, score, comment_count, is_user_post) 
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
          title,
          url,
          content,
          source,
          external_id,
          0,
          0,
          false
        )
        saved_count += 1
      rescue e : PG::Error
        puts "Database error for article #{external_id}: #{e.message}"
      end
    end

    puts "Saved #{saved_count} new Dev.to articles"
    saved_count
  end

  def self.fetch_latest_articles(limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching latest articles from Dev.to..."
    params = {
      "per_page" => limit,
      "state"    => "fresh"
    }
    articles = fetch_articles(params)
    save_articles_to_db(articles)
  end

  def self.fetch_top_articles(limit : Int32 = DEFAULT_LIMIT, time_range : String = "week") : Int32
    puts "Fetching top articles from Dev.to for #{time_range}..."
    days = case time_range
           when "week" then 7
           when "month" then 30
           when "year" then 365
           else 7
           end
    params = {
      "per_page" => limit,
      "top"      => days
    }
    articles = fetch_articles(params)
    save_articles_to_db(articles)
  end

  def self.fetch_articles_by_tag(tag : String, limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching articles tagged with '#{tag}'..."
    params = {
      "per_page" => limit,
      "tag"      => tag
    }
    articles = fetch_articles(params)
    save_articles_to_db(articles)
  end

  def self.fetch_articles_by_tags(tags : Array(String), limit_per_tag : Int32 = DEFAULT_LIMIT) : Int32
    total_saved = 0
    tags.each do |tag|
      saved = fetch_articles_by_tag(tag, limit_per_tag)
      total_saved += saved
    end
    total_saved
  rescue e : Exception
    puts "Error fetching articles by tags: #{e.message}"
    total_saved
  end

  def self.full_fetch
    puts "Starting full Dev.to fetch..."

    saved_latest = fetch_latest_articles(100)
    saved_top_week = fetch_top_articles(100, "week")
    saved_top_month = fetch_top_articles(100, "month")

    tags_to_fetch = ["ruby", "python", "javascript", "react", "rails", "go", "rust", "devops", "webdev", "ai"]
    saved_tags = fetch_articles_by_tags(tags_to_fetch, 30)

    total = saved_latest + saved_top_week + saved_top_month + saved_tags
    puts "Dev.to fetch complete. Total saved: #{total} articles"
    total
  rescue e : Exception
    puts "Full fetch failed: #{e.message}"
    0
  end
end
