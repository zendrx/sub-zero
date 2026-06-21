# hn.cr - Hacker News content fetcher for Crystal Aggregator
# Fixed production version focusing strictly on the 3 core elements.

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
          # Limit the IDs early to avoid fetching hundreds of items unnecessarily
          ids.as_a.map(&.as_i64).take(limit)
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
        
        # Safe extraction of the item type
        item_type = data["type"]?.try(&.as_s) || ""
        return nil if item_type != "story"
        
        # Core 1, 2, and 3 extracted properly without string pollution
        title = data["title"]?.try(&.as_s) || "Untitled"
        story_url = data["url"]?.try(&.as_s) || ""
        text_content = data["text"]?.try(&.as_s) || ""
        
        # Get the real structural ID as a clean string string identifier
        external_id = data["id"]?.try(&.as_i64.to_s) || data["id"]?.try(&.as_i.to_s) || id.to_s
        
        # If the story doesn't have an external link, it's a self-post (like "Ask HN")
        # In that case, use the text body as content, otherwise fallback to standard link behavior
        content = story_url.empty? ? text_content : ""
        
        # If it's a text-only post and has no URL, link back to HN as a fallback
        if story_url.empty?
          story_url = "https://news.ycombinator.com/item?id=#{external_id}"
        end

        story = Hash(String, JSON::Any).new
        story["title"] = JSON::Any.new(title)
        story["url"] = JSON::Any.new(story_url)
        story["content"] = JSON::Any.new(content)
        story["source"] = JSON::Any.new("hackernews")
        story["external_id"] = JSON::Any.new(external_id)
        
        # Padded with zeroes as requested for your platform's native calculation metrics
        story["score"] = JSON::Any.new(0_i64)
        story["comment_count"] = JSON::Any.new(0_i64)
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
      sleep 0.1 # Be polite to the Firebase API
    end
    
    stories
  end

  def self.save_stories_to_db(stories : Array(Hash(String, JSON::Any))) : Int32
    saved_count = 0
    return 0 if stories.empty?
    
    stories.each do |story|
      # Safely extract external_id without literal JSON quote artifacts
      external_id = story["external_id"]?.try(&.as_s) || ""
      next if external_id.empty?
      
      # Fixed pool exhaustion leak by utilizing scalar? (closes result sets instantly)
      exists = POOL.scalar?("SELECT 1 FROM posts WHERE external_id = $1 AND source = 'hackernews'", external_id)
      if exists
        next # Already exists, keep moving loop along
      end
      
      begin
        title = story["title"]?.try(&.as_s) || "Untitled"
        url = story["url"]?.try(&.as_s) || ""
        content = story["content"]?.try(&.as_s) || ""

        POOL.exec(
          "INSERT INTO posts (title, url, content, source, external_id, score, comment_count, is_user_post) 
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
          title,
          url,
          content,
          "hackernews",
          external_id,
          0,     # Native Score padded to zero
          0,     # Native Comment Count padded to zero
          false  # Native User Post Flag
        )
        saved_count += 1
      rescue e : PG::Error
        puts "Database error while inserting story #{external_id}: #{e.message}"
      end
    end
    
    saved_count
  rescue e : Exception
    puts "Error in save_stories_to_db: #{e.message}"
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
