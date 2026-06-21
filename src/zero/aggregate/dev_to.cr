# dev_to.cr - Dev.to content fetcher for Crystal Aggregator
# Fixed version focusing strictly on the 3 core elements.

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
    puts "[Dev.to] Fetching: #{url}"

    headers = HTTP::Headers{
      "User-Agent" => "CrystalAggregator/1.0",
      "Accept"     => "application/json"
    }

    api_key = ENV["DEV_TO"]?
    if api_key
      headers["api-key"] = api_key
      puts "[Dev.to] Using API key (length: #{api_key.size})"
    else
      puts "[Dev.to] WARNING: DEV_TO env var not set."
    end

    response = HTTP::Client.get(url, headers: headers)
    puts "[Dev.to] Response status: #{response.status_code}"

    case response.status_code
    when 200
      parse_articles_response(response.body)
    when 401
      puts "[Dev.to] ERROR: 401 Unauthorized – invalid API key."
      [] of Hash(String, JSON::Any)
    when 403
      puts "[Dev.to] ERROR: 403 Forbidden – API key may be invalid or expired."
      [] of Hash(String, JSON::Any)
    when 429
      puts "[Dev.to] Rate limited (429). Waiting 30 seconds..."
      sleep 30
      response = HTTP::Client.get(url, headers: headers)
      if response.status_code == 200
        parse_articles_response(response.body)
      else
        puts "[Dev.to] Retry failed with status #{response.status_code}."
        [] of Hash(String, JSON::Any)
      end
    else
      puts "[Dev.to] Unexpected status: #{response.status_code}"
      puts "[Dev.to] Response preview: #{response.body[0..200]}" if response.body
      [] of Hash(String, JSON::Any)
    end
  rescue e : Exception
    puts "[Dev.to] EXCEPTION in fetch_articles: #{e.message}"
    [] of Hash(String, JSON::Any)
  end

  def self.parse_articles_response(body : String) : Array(Hash(String, JSON::Any))
    articles = [] of Hash(String, JSON::Any)
    begin
      data = JSON.parse(body)
      array_data = data.as_a?
      unless array_data
        puts "[Dev.to] Response is not an array. Preview: #{body[0..200]}"
        return articles
      end

      puts "[Dev.to] Parsing #{array_data.size} articles..."

      array_data.each_with_index do |article, idx|
        begin
          # Core 1, 2, and 3 extracted properly without .to_s string formatting pollution
          title = article["title"]?.try(&.as_s) || ""
          url = article["url"]?.try(&.as_s) || ""
          description = article["description"]?.try(&.as_s) || ""
          published_at = article["published_at"]?.try(&.as_s) || ""
          
          # Using Dev.to's actual unique API ID for external_id to avoid matching collissions
          devto_id = article["id"]?.try(&.as_i64.to_s) || article["id"]?.try(&.as_i.to_s) || ""

          if title.empty? || url.empty?
            puts "[Dev.to] Article #{idx} skipped: missing title or URL."
            next
          end

          external_id = !devto_id.empty? ? devto_id : url
          if external_id.empty?
            external_id = Digest::SHA256.hexdigest(title + published_at)
          end

          article_data = Hash(String, JSON::Any).new
          article_data["title"] = JSON::Any.new(title)
          article_data["url"] = JSON::Any.new(url)
          article_data["content"] = JSON::Any.new(description)
          article_data["published_at"] = JSON::Any.new(published_at)
          article_data["external_id"] = JSON::Any.new(external_id)
          article_data["source"] = JSON::Any.new("devto")
          
          # Padded with zeroes as requested for your platform's native calculation metrics
          article_data["score"] = JSON::Any.new(0_i64)
          article_data["comment_count"] = JSON::Any.new(0_i64)
          article_data["is_user_post"] = JSON::Any.new(false)

          articles << article_data
          if idx < 3
            puts "[Dev.to]   #{idx+1}. #{title[0..40]}... (id: #{external_id})"
          end
        rescue e : Exception
          puts "[Dev.to] Error parsing article #{idx}: #{e.message}"
        end
      end

      puts "[Dev.to] Parsed #{articles.size} valid articles."
    rescue e : Exception
      puts "[Dev.to] FATAL parse error: #{e.message}"
      puts "[Dev.to] Body preview: #{body[0..500]}"
    end
    articles
  end

  def self.save_articles_to_db(articles : Array(Hash(String, JSON::Any))) : Int32
    saved_count = 0
    return 0 if articles.empty?

    puts "[Dev.to] Saving #{articles.size} articles to database..."
    articles.each_with_index do |article, idx|
      external_id = article["external_id"]?.try(&.as_s) || ""
      
      if external_id.empty?
        puts "[Dev.to] Article #{idx} missing external_id, skipping."
        next
      end

      # Fixed pool exhaustion leak by safely utilizing scalar? (closes result sets instantly)
      exists = POOL.scalar?("SELECT 1 FROM posts WHERE external_id = $1 AND source = 'devto'", external_id)
      if exists
        next
      end

      begin
        title = article["title"]?.try(&.as_s) || "Untitled"
        url = article["url"]?.try(&.as_s) || ""
        content = article["content"]?.try(&.as_s) || ""

        POOL.exec(
          "INSERT INTO posts (title, url, content, source, external_id, score, comment_count, is_user_post) 
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
          title,
          url,
          content,
          "devto",
          external_id,
          0,     # Native Score
          0,     # Native Comment Count
          false  # Native User Post Flag
        )
        saved_count += 1
        if saved_count <= 3
          puts "[Dev.to]   Saved: #{title[0..40]}..."
        end
      rescue e : PG::Error
        puts "[Dev.to] DB error for #{external_id}: #{e.message}"
      end
    end

    puts "[Dev.to] Successfully saved #{saved_count} new articles."
    saved_count
  rescue e : Exception
    puts "[Dev.to] save_articles_to_db error: #{e.message}"
    0
  end

  def self.fetch_latest_articles(limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "[Dev.to] Fetching latest (limit #{limit})..."
    params = { "per_page" => limit, "state" => "fresh" }
    articles = fetch_articles(params)
    save_articles_to_db(articles)
  end

  def self.fetch_top_articles(limit : Int32 = DEFAULT_LIMIT, time_range : String = "week") : Int32
    days = case time_range
           when "week" then 7
           when "month" then 30
           when "year" then 365
           else 7
           end
    puts "[Dev.to] Fetching top #{time_range} (top=#{days}, limit #{limit})..."
    params = { "per_page" => limit, "top" => days }
    articles = fetch_articles(params)
    save_articles_to_db(articles)
  end

  def self.fetch_articles_by_tag(tag : String, limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "[Dev.to] Fetching tag '#{tag}' (limit #{limit})..."
    params = { "per_page" => limit, "tag" => tag }
    articles = fetch_articles(params)
    save_articles_to_db(articles)
  end

  def self.fetch_articles_by_tags(tags : Array(String), limit_per_tag : Int32 = DEFAULT_LIMIT) : Int32
    total = 0
    begin
      tags.each do |tag|
        saved = fetch_articles_by_tag(tag, limit_per_tag)
        total += saved
        puts "[Dev.to] Tag '#{tag}' saved #{saved} articles."
      end
    rescue e : Exception
      puts "[Dev.to] fetch_articles_by_tags error: #{e.message}"
    end
    total
  end

  def self.full_fetch
    puts "=== Starting Dev.to full fetch ==="
    saved_latest = fetch_latest_articles(100)
    saved_top_week = fetch_top_articles(100, "week")
    saved_top_month = fetch_top_articles(100, "month")

    tags_to_fetch = ["ruby", "python", "javascript", "react", "rails", "go", "rust", "devops", "webdev", "ai"]
    saved_tags = fetch_articles_by_tags(tags_to_fetch, 30)

    total = saved_latest + saved_top_week + saved_top_month + saved_tags
    puts "=== Dev.to complete. Total saved: #{total} articles ==="
    total
  rescue e : Exception
    puts "Dev.to full_fetch failed: #{e.message}"
    0
  end
end
