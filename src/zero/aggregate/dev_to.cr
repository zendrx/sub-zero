# dev_to.cr - Dev.to content fetcher for Crystal Aggregator
# Official API docs: https://developers.forem.com/api/v1#tag/articles/operation/getArticles

require "http/client"
require "json"

module DevToFetcher
  BASE_URL = "https://dev.to/api"
  DEFAULT_LIMIT = 30
  FETCH_LIMIT = 700

  POPULAR_TAGS = ["ruby", "javascript", "python", "react", "rails", "go", "rust", "devops", "cloud", "ai", "machinelearning", "webdev"]

  def self.fetch_articles(params : Hash(String, String | Int32 | Nil) = {} of String => String | Int32 | Nil) : Array(Hash(String, JSON::Any))
    query = [] of String
    params.each do |key, value|
      if value
        query << "#{key}=#{URI.encode_path(value.to_s)}"
      end
    end

    url = query.empty? ? "#{BASE_URL}/articles" : "#{BASE_URL}/articles?#{query.join("&")}"

    headers = HTTP::Headers{
      "User-Agent" => "CrystalAggregator/1.0",
      "Accept"     => "application/json"
    }

    if api_key = ENV["DEV_TO"]?
      headers["api-key"] = api_key
    else
      puts "DEV_TO not set. Only public articles will be fetched."
    end

    response = HTTP::Client.get(url, headers: headers)

    case response.status_code
    when 200
      parse_articles_response(response.body)
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

      if data.is_a?(Array(JSON::Any))
        data.as_a.each do |article|
          title = article["title"]?.to_s || "Untitled"
          url = article["url"]?.to_s || ""
          description = article["description"]?.to_s || ""
          cover_image = article["cover_image"]?.to_s || ""
          published_at = article["published_at"]?.to_s || ""
          tag_list = article["tag_list"]?.to_s || ""
          positive_reactions_count = article["positive_reactions_count"]?.try &.as_i || 0
          comments_count = article["comments_count"]?.try &.as_i || 0
          external_id = article["id"]?.try &.as_i64.to_s
          reading_time_minutes = article["reading_time_minutes"]?.try &.as_i || 0

          user = article["user"]?
          user_name = user ? user["name"]?.to_s : ""
          user_username = user ? user["username"]?.to_s : ""

          organisation = article["organization"]?
          org_name = organisation ? organisation["name"]?.to_s : ""

          content = description
          tags = tag_list.split(",").map(&.strip).join(", ")

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

          articles << article_data
        end
      end

      articles
    rescue e : JSON::ParseException
      puts "Failed to parse JSON: #{e.message}"
      [] of Hash(String, JSON::Any)
    end
  end

  def self.save_articles_to_db(articles : Array(Hash(String, JSON::Any))) : Int32
    saved_count = 0

    articles.each do |article|
      external_id = article["external_id"]?.to_s
      next if external_id.empty?

      result = POOL.query(
        "SELECT id FROM posts WHERE external_id = $1 AND source = 'devto'",
        external_id
      )

      if !result.move_next
        POOL.exec(
          "INSERT INTO posts (title, url, content, source, external_id, score, comment_count, is_user_post) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
          article["title"]?.to_s || "Untitled",
          article["url"]?.to_s || "",
          article["content"]?.to_s || "",
          article["source"]?.to_s || "devto",
          article["external_id"]?.to_s || "",
          article["score"]?.try &.as_i || 0,
          article["comment_count"]?.try &.as_i || 0,
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

  def self.fetch_latest_articles(limit : Int32 = FETCH_LIMIT) : Int32
    puts "Fetching latest articles from Dev.to..."
    params = {
      "per_page" => limit,
      "sort"     => "published_at"
    }
    articles = fetch_articles(params)
    saved = save_articles_to_db(articles)
    puts "Saved #{saved} latest articles"
    sleep 2
    saved
  end

  def self.fetch_top_articles(limit : Int32 = FETCH_LIMIT, time_range : String = "week") : Int32
    puts "Fetching top articles from Dev.to for #{time_range}..."
    params = {
      "per_page"   => limit,
      "sort"       => "top",
      "top_period" => time_range
    }
    articles = fetch_articles(params)
    saved = save_articles_to_db(articles)
    puts "Saved #{saved} top articles for #{time_range}"
    sleep 2
    saved
  end

  def self.fetch_articles_by_tag(tag : String, limit : Int32 = FETCH_LIMIT) : Int32
    puts "Fetching articles tagged with '#{tag}' from Dev.to..."
    params = {
      "per_page" => limit,
      "tag"      => tag
    }
    articles = fetch_articles(params)
    saved = save_articles_to_db(articles)
    puts "Saved #{saved} articles tagged with '#{tag}'"
    sleep 2
    saved
  end

  def self.fetch_articles_by_tags(tags : Array(String), limit_per_tag : Int32 = FETCH_LIMIT) : Int32
    total_saved = 0

    begin
      tags.each do |tag|
        saved = fetch_articles_by_tag(tag, limit_per_tag)
        total_saved += saved
        puts "Fetched #{saved} articles for tag ##{tag}"
      end
    rescue e : Exception
      puts "Error fetching articles by tags: #{e.message}"
    end

    total_saved
  end

  def self.full_fetch
    puts "Starting full Dev.to fetch..."

    saved_latest = fetch_latest_articles(700)
    saved_top_week = fetch_top_articles(700, "week")
    saved_top_month = fetch_top_articles(700, "month")
    saved_tags = fetch_articles_by_tags(["ruby", "python", "javascript", "go", "rust"], 700)

    total = saved_latest + saved_top_week + saved_top_month + saved_tags
    puts "Dev.to fetch complete. Total saved: #{total} articles"
    total
  rescue e : Exception
    puts "Full fetch failed: #{e.message}"
    0
  end
end
