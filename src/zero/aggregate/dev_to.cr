# dev_to.cr - Dev.to content fetcher for Crystal Aggregator
# Official API docs: https://developers.forem.com/api/v1#tag/articles/operation/getArticles

require "http/client"
require "json"

module DevToFetcher
  BASE_URL = "https://dev.to/api"
  DEFAULT_LIMIT = 30
  FETCH_LIMIT = 100

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
      puts "Dev.to API key found"
    else
      puts "DEV_TO not set. Only public articles will be fetched."
    end

    response = HTTP::Client.get(url, headers: headers)
    puts "Dev.to response status: #{response.status_code}"

    case response.status_code
    when 200
      articles = parse_articles_response(response.body)
      puts "Dev.to parsed #{articles.size} articles"
      articles
    when 401
      puts "Dev.to API authentication failed. Check your DEV_TO environment variable."
      [] of Hash(String, JSON::Any)
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

      puts "Dev.to response type: #{data.class_name}"

      if data.is_a?(Array(JSON::Any))
        puts "Dev.to has #{data.as_a.size} items in array"

        data.as_a.each_with_index do |article, index|
          begin
            title = article["title"]?.to_s || "Untitled"
            url = article["url"]?.to_s || ""
            description = article["description"]?.to_s || ""
            cover_image = article["cover_image"]?.to_s || ""
            published_at = article["published_at"]?.to_s || ""
            tag_list = article["tag_list"]?.to_s || ""

            positive_reactions_count = 0
            if article["positive_reactions_count"]?
              positive_reactions_count = article["positive_reactions_count"].as_i
            elsif article["public_reactions_count"]?
              positive_reactions_count = article["public_reactions_count"].as_i
            end

            comments_count = article["comments_count"]?.try &.as_i || 0
            external_id = article["id"]?.try &.as_i64.to_s
            reading_time_minutes = article["reading_time_minutes"]?.try &.as_i || 0

            user = article["user"]?
            user_name = user ? user["name"]?.to_s : ""
            user_username = user ? user["username"]?.to_s : ""

            organisation = article["organization"]?
            org_name = organisation ? organisation["name"]?.to_s : ""

            content = description
            tags = tag_list.is_a?(Array) ? tag_list.as_a.join(", ") : tag_list.to_s

            article_data = Hash(String, JSON::Any).new
            article_data["title"] = JSON::Any.new(title)
            article_data["url"] = JSON::Any.new(url)
            article_data["content"] = JSON::Any.new(content)
            article_data["cover_image"] = JSON::Any.new(cover_image)
            article_data["source"] = JSON::Any.new("devto")
            article_data["external_id"] = JSON::Any.new(external_id)
            article_data["score"] = JSON::Any.new(positive_reactions_count)
            article_data["comment_count"] = JSON::Any.new(comments_count)
            article_data["is_user_post"] = JSON::Any.new(false)
            article_data["published_at"] = JSON::Any.new(published_at)
            article_data["tags"] = JSON::Any.new(tags)
            article_data["author_name"] = JSON::Any.new(user_name)
            article_data["author_username"] = JSON::Any.new(user_username)
            article_data["reading_time"] = JSON::Any.new(reading_time_minutes)
            article_data["org_name"] = JSON::Any.new(org_name)
            article_data["external_id_debug"] = JSON::Any.new(external_id || "MISSING")

            articles << article_data

            if index < 3
              puts "  Article #{index+1}: #{title[0..30]}... (ID: #{external_id || 'NONE'})"
            end
          rescue e : Exception
            puts "Error parsing article #{index}: #{e.message}"
          end
        end
      else
        puts "Response is not an array: #{data.class_name}"
        puts "Response preview: #{body[0..200]}"
      end

      articles
    rescue e : JSON::ParseException
      puts "Failed to parse JSON: #{e.message}"
      puts "Response preview: #{body[0..200]}"
      [] of Hash(String, JSON::Any)
    end
  end

  def self.save_articles_to_db(articles : Array(Hash(String, JSON::Any))) : Int32
    saved_count = 0

    if articles.empty?
      puts "No articles to save to database"
      return 0
    end

    puts "Attempting to save #{articles.size} articles to database..."

    articles.each_with_index do |article, index|
      external_id = article["external_id"]?.to_s

      if external_id.empty?
        puts "Article #{index} has no external_id, skipping"
        next
      end

      result = POOL.query(
        "SELECT id FROM posts WHERE external_id = $1 AND source = 'devto'",
        external_id
      )

      if result.move_next
        puts "  Article #{external_id} already exists in DB"
        next
      end

      begin
        title = article["title"]?.to_s || "Untitled"
        url = article["url"]?.to_s || ""
        content = article["content"]?.to_s || ""
        source = "devto"
        score = article["score"]?.try &.as_i || 0
        comment_count = article["comment_count"]?.try &.as_i || 0

        POOL.exec(
          "INSERT INTO posts (title, url, content, source, external_id, score, comment_count, is_user_post) 
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
          title,
          url,
          content,
          source,
          external_id,
          score,
          comment_count,
          false
        )
        saved_count += 1

        if saved_count <= 5
          puts "  Saved article: #{title[0..40]}..."
        end
      rescue e : PG::Error
        puts "Database error for article #{external_id}: #{e.message}"
      end
    end

    puts "Successfully saved #{saved_count} new articles to database"
    saved_count
  rescue e : Exception
    puts "Unexpected error saving articles: #{e.message}"
    0
  end

  def self.fetch_latest_articles(limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching latest articles from Dev.to..."
    params = {
      "per_page" => limit,
      "state"    => "fresh"
    }
    articles = fetch_articles(params)
    puts "Got #{articles.size} latest articles"
    saved = save_articles_to_db(articles)
    puts "Saved #{saved} latest articles"
    sleep 2
    saved
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
    puts "Got #{articles.size} top articles for #{time_range}"
    saved = save_articles_to_db(articles)
    puts "Saved #{saved} top articles for #{time_range}"
    sleep 2
    saved
  end

  def self.fetch_articles_by_tag(tag : String, limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching articles tagged with '#{tag}' from Dev.to..."
    params = {
      "per_page" => limit,
      "tag"      => tag
    }
    articles = fetch_articles(params)
    puts "Got #{articles.size} articles tagged with '#{tag}'"
    saved = save_articles_to_db(articles)
    puts "Saved #{saved} articles tagged with '#{tag}'"
    sleep 1
    saved
  end

  def self.fetch_articles_by_tags(tags : Array(String), limit_per_tag : Int32 = DEFAULT_LIMIT) : Int32
    total_saved = 0

    tags.each do |tag|
      saved = fetch_articles_by_tag(tag, limit_per_tag)
      total_saved += saved
      puts "Fetched #{saved} articles for tag #{tag}"
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

    # Fetch from more tags for better coverage
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
