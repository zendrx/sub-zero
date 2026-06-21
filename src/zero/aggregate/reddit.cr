require "http/client"
require "json"

module RedditFetcher
  BASE_URL = "https://www.reddit.com"

  SUBREDDITS = ["all", "popular", "AskReddit", "worldnews", "technology", "science", "programming", "funny", "pics", "videos"]

  LIMIT_PER_SUBREDDIT = 25

  def self.generate_browser_headers : HTTP::Headers
    user_agents = [
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36",
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:123.0) Gecko/20100101 Firefox/123.0",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.3 Safari/605.1.15"
    ]

    HTTP::Headers{
      "User-Agent" => user_agents.sample,
      "Accept" => "application/json, text/plain, */*",
      "Accept-Language" => "en-US,en;q=0.9",
      "Cache-Control" => "no-cache",
      "Pragma" => "no-cache"
    }
  end

  def self.fetch_subreddit(subreddit : String, sort : String = "hot", time : String = "day", limit : Int32 = LIMIT_PER_SUBREDDIT) : Array(Hash(String, JSON::Any))
    url = case sort
    when "hot" then "#{BASE_URL}/r/#{subreddit}/hot.json?limit=#{limit}"
    when "new" then "#{BASE_URL}/r/#{subreddit}/new.json?limit=#{limit}"
    when "top" then "#{BASE_URL}/r/#{subreddit}/top.json?limit=#{limit}&t=#{time}"
    when "rising" then "#{BASE_URL}/r/#{subreddit}/rising.json?limit=#{limit}"
    when "controversial" then "#{BASE_URL}/r/#{subreddit}/controversial.json?limit=#{limit}&t=#{time}"
    else "#{BASE_URL}/r/#{subreddit}/hot.json?limit=#{limit}"
    end

    headers = generate_browser_headers
    response = HTTP::Client.get(url, headers: headers)

    if response.status_code == 200
      parse_reddit_response(response.body)
    elsif response.status_code == 429
      puts "[Reddit] Rate limited by Reddit. Sleeping for 30 seconds..."
      sleep 30

      response = HTTP::Client.get(url, headers: generate_browser_headers)
      if response.status_code == 200
        parse_reddit_response(response.body)
      else
        puts "[Reddit] Failed to fetch after retry from r/#{subreddit}: #{response.status_code}"
        [] of Hash(String, JSON::Any)
      end
    else
      puts "[Reddit] Failed to fetch from r/#{subreddit}: #{response.status_code}"
      [] of Hash(String, JSON::Any)
    end
  rescue e : Exception
    puts "[Reddit] Error fetching r/#{subreddit}: #{e.message}"
    [] of Hash(String, JSON::Any)
  end

  def self.parse_reddit_response(body : String) : Array(Hash(String, JSON::Any))
    posts = [] of Hash(String, JSON::Any)
    begin
      data = JSON.parse(body)

      root_data = data["data"]? 
      return posts unless root_data

      children = root_data["children"]? 
      return posts unless children

      children.as_a.each do |child|
        post_data = child["data"]? 
        next unless post_data

        title = post_data["title"]?.try(&.as_s) || "Untitled"
        url = post_data["url"]?.try(&.as_s) || ""
        selftext = post_data["selftext"]?.try(&.as_s) || ""
        is_self = post_data["is_self"]?.try(&.as_bool) || false

        external_id = post_data["id"]?.try(&.as_s) || ""

        next if title.empty? || external_id.empty?

        content = is_self ? selftext : ""
        if url.empty? && post_data["permalink"]?
          url = "https://www.reddit.com" + post_data["permalink"].as_s
        end

        post = Hash(String, JSON::Any).new
        post["title"] = JSON::Any.new(title)
        post["url"] = JSON::Any.new(url)
        post["content"] = JSON::Any.new(content)
        post["source"] = JSON::Any.new("reddit")
        post["external_id"] = JSON::Any.new(external_id)

        post["score"] = JSON::Any.new(0_i64)
        post["comment_count"] = JSON::Any.new(0_i64)
        post["is_user_post"] = JSON::Any.new(false)

        posts << post
      end
    rescue e : Exception
      puts "[Reddit] Failed to parse JSON body context: #{e.message}"
    end
    posts
  end

  def self.save_posts_to_db(posts : Array(Hash(String, JSON::Any))) : Int32
    saved_count = 0
    return 0 if posts.empty?

    posts.each do |post|
      external_id = post["external_id"]?.try(&.as_s) || ""
      next if external_id.empty?

      begin
        count = POOL.scalar("SELECT COUNT(*) FROM posts WHERE external_id = $1 AND source = 'reddit'", external_id).as(Int64)
        next if count > 0

        title = post["title"]?.try(&.as_s) || "Untitled"
        url = post["url"]?.try(&.as_s) || ""
        content = post["content"]?.try(&.as_s) || ""

        POOL.exec(
          "INSERT INTO posts (title, url, content, source, external_id, score, comment_count, is_user_post)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
          title,
          url,
          content,
          "reddit",
          external_id,
          0,
          0,
          false
        )
        saved_count += 1
      rescue e : PG::Error
        puts "[Reddit] Database error while inserting story #{external_id}: #{e.message}"
      end
    end

    saved_count
  rescue e : Exception
    puts "[Reddit] Error inside save_posts_to_db context: #{e.message}"
    0
  end

  def self.fetch_multi_subreddits(subreddits : Array(String) = SUBREDDITS, sort : String = "hot", time : String = "day") : Int32
    total_saved = 0

    subreddits.each do |sub|
      puts "[Reddit] Requesting content listings from r/#{sub}..."
      posts = fetch_subreddit(sub, sort, time)
      saved = save_posts_to_db(posts)
      total_saved += saved
      puts "[Reddit] Processed and saved #{saved} stories from r/#{sub}"

      sleep 2.5
    end

    total_saved
  end

  def self.fetch_with_multiple_sorts(subreddit : String = "all", sorts : Array(String) = ["hot", "new", "top"]) : Int32
    total_saved = 0

    sorts.each do |sort|
      time = (sort == "top" || sort == "controversial") ? "day" : ""
      posts = fetch_subreddit(subreddit, sort, time)
      saved = save_posts_to_db(posts)
      total_saved += saved
      puts "[Reddit] Saved #{saved} posts from r/#{subreddit} with sort '#{sort}'"
      sleep 2.5
    end

    total_saved
  end

  def self.fetch_top_time_ranges(subreddit : String = "all", time_ranges : Array(String) = ["day", "week", "month"]) : Int32
    total_saved = 0

    time_ranges.each do |time|
      posts = fetch_subreddit(subreddit, "top", time)
      saved = save_posts_to_db(posts)
      total_saved += saved
      puts "[Reddit] Saved #{saved} posts from r/#{subreddit} for time range '#{time}'"
      sleep 2.5
    end

    total_saved
  end

  def self.search(query : String, limit : Int32 = 25) : Array(Hash(String, JSON::Any))
    url = "#{BASE_URL}/search.json?q=#{URI.encode_path(query)}&limit=#{limit}"
    response = HTTP::Client.get(url, headers: generate_browser_headers)

    if response.status_code == 200
      parse_reddit_response(response.body)
    else
      puts "[Reddit] Search failed: #{response.status_code}"
      [] of Hash(String, JSON::Any)
    end
  rescue e : Exception
    puts "[Reddit] Error searching Reddit: #{e.message}"
    [] of Hash(String, JSON::Any)
  end

  def self.fetch_user_posts(username : String, limit : Int32 = 25) : Array(Hash(String, JSON::Any))
    url = "#{BASE_URL}/user/#{username}/submitted.json?limit=#{limit}"
    response = HTTP::Client.get(url, headers: generate_browser_headers)

    if response.status_code == 200
      parse_reddit_response(response.body)
    else
      puts "[Reddit] Failed to fetch user posts: #{response.status_code}"
      [] of Hash(String, JSON::Any)
    end
  rescue e : Exception
    puts "[Reddit] Error fetching user posts: #{e.message}"
    [] of Hash(String, JSON::Any)
  end

  def self.full_fetch
    puts "=== Starting Full Reddit Sync Strategy ==="

    puts "[Reddit] Fetching Hot posts queue..."
    saved_hot = fetch_multi_subreddits(["all", "popular", "AskReddit", "worldnews", "technology"], "hot")
    sleep 3.0

    puts "[Reddit] Fetching Top posts queue..."
    saved_top = fetch_multi_subreddits(["programming", "webdev", "python", "rust", "golang"], "top")
    sleep 3.0

    puts "[Reddit] Fetching Rising posts queue..."
    saved_rising = fetch_multi_subreddits(["all", "popular"], "rising")

    total = saved_hot + saved_top + saved_rising
    puts "=== Reddit fetch execution complete. Total saved: #{total} items ==="
    total
  rescue e : Exception
    puts "[Reddit] Fatal full fetch iteration break: #{e.message}"
    0
  end
end
