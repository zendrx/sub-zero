# hn.cr - Hacker News content fetcher for Crystal Aggregator

require "http/client"
require "json"

module HNFetcher
  BASE_URL = "https://hacker-news.firebaseio.com/v0"
  DEFAULT_LIMIT = 30

  def self.fetch_story_ids(endpoint : String, limit : Int32 = DEFAULT_LIMIT) : Array(Int64)
    url = "#{BASE_URL}/#{endpoint}.json"
    
    response = HTTP::Client.get(url)
    
    if response.status_code == 200
      begin
        body = response.body
        return [] of Int64 if body.empty?
        
        ids = JSON.parse(body)
        if ids.is_a?(Array)
          ids.as_a.map(&.as_i64)
        else
          [] of Int64
        end
      rescue e : Exception
        puts "Failed to parse story IDs from #{endpoint}: #{e.message}"
        [] of Int64
      end
    else
      puts "Failed to fetch story IDs from #{endpoint}: #{response.status_code}"
      [] of Int64
    end
  end

  def self.fetch_story(id : Int64) : Hash(String, JSON::Any)?
    url = "#{BASE_URL}/item/#{id}.json"
    
    response = HTTP::Client.get(url)
    
    if response.status_code == 200
      begin
        data = JSON.parse(response.body)
        
        return nil if data["type"]?.to_s != "story"
        
        title = data["title"]?.to_s || "Untitled"
        url = data["url"]?.to_s || ""
        score = data["score"]?.try &.as_i || 0
        comment_count = data["descendants"]?.try &.as_i || 0
        external_id = data["id"]?.try &.as_i64.to_s
        by = data["by"]?.to_s || ""
        time = data["time"]?.try &.as_i || 0
        text = data["text"]?.to_s || ""
        
        is_self = text.empty? ? false : true
        content = is_self ? text : ""
        
        story = Hash(String, JSON::Any).new
        story["title"] = JSON::Any.new(title)
        story["url"] = JSON::Any.new(url)
        story["content"] = JSON::Any.new(content)
        story["source"] = JSON::Any.new("hackernews")
        story["external_id"] = JSON::Any.new(external_id)
        story["score"] = JSON::Any.new(score)
        story["comment_count"] = JSON::Any.new(comment_count)
        story["is_self"] = JSON::Any.new(is_self)
        story["author"] = JSON::Any.new(by)
        story["created_utc"] = JSON::Any.new(time)
        story["is_user_post"] = JSON::Any.new(false)
        
        story
      rescue e : Exception
        puts "Failed to parse story #{id}: #{e.message}"
        nil
      end
    else
      puts "Failed to fetch story #{id}: #{response.status_code}"
      nil
    end
  end

  def self.fetch_stories(ids : Array(Int64)) : Array(Hash(String, JSON::Any))
    stories = [] of Hash(String, JSON::Any)
    
    ids.each do |id|
      story = fetch_story(id)
      stories << story if story
      sleep 0.1
    end
    
    stories
  end

  def self.save_stories_to_db(stories : Array(Hash(String, JSON::Any))) : Int32
    saved_count = 0
    
    stories.each do |story|
      external_id = story["external_id"]?.to_s
      next if external_id.empty?
      
      result = POOL.query(
        "SELECT id FROM posts WHERE external_id = $1 AND source = 'hackernews'",
        external_id
      )
      
      if !result.move_next
        POOL.exec(
          "INSERT INTO posts (title, url, content, source, external_id, score, comment_count, is_user_post) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
          story["title"]?.to_s || "Untitled",
          story["url"]?.to_s || "",
          story["content"]?.to_s || "",
          story["source"]?.to_s || "hackernews",
          story["external_id"]?.to_s || "",
          story["score"]?.try &.as_i || 0,
          story["comment_count"]?.try &.as_i || 0,
          false
        )
        saved_count += 1
      end
    end
    
    saved_count
  rescue e : PG::Error
    puts "Database error while saving stories: #{e.message}"
    0
  end

  def self.fetch_top_stories(limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching top stories from Hacker News..."
    ids = fetch_story_ids("topstories", limit)
    stories = fetch_stories(ids)
    saved = save_stories_to_db(stories)
    puts "Saved #{saved} top stories"
    saved
  end

  def self.fetch_new_stories(limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching new stories from Hacker News..."
    ids = fetch_story_ids("newstories", limit)
    stories = fetch_stories(ids)
    saved = save_stories_to_db(stories)
    puts "Saved #{saved} new stories"
    saved
  end

  def self.fetch_best_stories(limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching best stories from Hacker News..."
    ids = fetch_story_ids("beststories", limit)
    stories = fetch_stories(ids)
    saved = save_stories_to_db(stories)
    puts "Saved #{saved} best stories"
    saved
  end

  def self.fetch_ask_stories(limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching Ask HN stories..."
    ids = fetch_story_ids("askstories", limit)
    stories = fetch_stories(ids)
    saved = save_stories_to_db(stories)
    puts "Saved #{saved} Ask HN stories"
    saved
  end

  def self.fetch_show_stories(limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching Show HN stories..."
    ids = fetch_story_ids("showstories", limit)
    
    if ids.empty?
      puts "No Show HN stories available at this time"
      return 0
    end
    
    stories = fetch_stories(ids)
    saved = save_stories_to_db(stories)
    puts "Saved #{saved} Show HN stories"
    saved
  rescue e : Exception
    # The exception might have no message, so we handle it gracefully
    puts "Show HN endpoint temporarily unavailable or returned malformed data"
    0
  end

  def self.full_fetch
    puts "Starting full Hacker News fetch..."
    
    saved_top = fetch_top_stories(30)
    saved_new = fetch_new_stories(20)
    saved_best = fetch_best_stories(20)
    saved_ask = fetch_ask_stories(15)
    saved_show = fetch_show_stories(15)
    
    total = saved_top + saved_new + saved_best + saved_ask + saved_show
    puts "Hacker News fetch complete. Total saved: #{total} stories"
    total
  rescue e : Exception
    puts "Full fetch failed: #{e.message}"
    0
  end
end
