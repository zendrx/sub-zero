# hn.cr - Hacker News content fetcher for Crystal Aggregator
# Fetches top stories, new stories, and comments from Hacker News API

require "http/client"
require "json"

module HNFetcher
  # Hacker News API endpoints
  BASE_URL = "https://hacker-news.firebaseio.com/v0"
  
  # Number of stories to fetch
  DEFAULT_LIMIT = 30
  
  # Story types available
  STORY_TYPES = ["topstories", "newstories", "beststories", "askstories", "showstories", "jobstories"]
  
  # Fetches story IDs from a specific endpoint
  def self.fetch_story_ids(endpoint : String, limit : Int32 = DEFAULT_LIMIT) : Array(Int64)
    url = "#{BASE_URL}/#{endpoint}.json"
    
    response = HTTP::Client.get(url)
    
    if response.status_code == 200
      begin
        ids = JSON.parse(response.body).as_a.map(&.as_i64)
        ids.first(limit)
      rescue e : Exception
        puts "Failed to parse story IDs: #{e.message}"
        [] of Int64
      end
    else
      puts "Failed to fetch story IDs from #{endpoint}: #{response.status_code}"
      [] of Int64
    end
  rescue e : Exception
    puts "Error fetching story IDs: #{e.message}"
    [] of Int64
  end
  
  # Fetches a single story by ID
  def self.fetch_story(id : Int64) : Hash(String, JSON::Any)?
    url = "#{BASE_URL}/item/#{id}.json"
    
    response = HTTP::Client.get(url)
    
    if response.status_code == 200
      begin
        data = JSON.parse(response.body)
        
        # Skip if it's not a story (could be comment, poll, etc.)
        return nil if data["type"]?.to_s != "story"
        
        # Extract story information
        title = data["title"]?.to_s || "Untitled"
        url = data["url"]?.to_s || ""
        score = data["score"]?.try &.as_i || 0
        comment_count = data["descendants"]?.try &.as_i || 0
        external_id = data["id"]?.try &.as_i64.to_s
        by = data["by"]?.to_s || ""
        time = data["time"]?.try &.as_i || 0
        text = data["text"]?.to_s || ""
        story_type = data["type"]?.to_s || "story"
        
        # Determine if it's a text post or link post
        is_self = text.empty? ? false : true
        content = is_self ? text : ""
        
        # Build story hash using JSON::Any
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
        story["story_type"] = JSON::Any.new(story_type)
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
  rescue e : Exception
    puts "Error fetching story #{id}: #{e.message}"
    nil
  end
  
  # Fetches multiple stories by IDs
  def self.fetch_stories(ids : Array(Int64)) : Array(Hash(String, JSON::Any))
    stories = [] of Hash(String, JSON::Any)
    
    begin
      # Use fibers for concurrent fetching
      channels = ids.map { Channel(Hash(String, JSON::Any)?).new }
      
      ids.each_with_index do |id, index|
        spawn do
          story = fetch_story(id)
          channels[index].send(story)
        end
      end
      
      # Collect results
      ids.each_with_index do |id, index|
        story = channels[index].receive
        if story
          stories << story
        end
      end
    rescue e : Exception
      puts "Error fetching multiple stories: #{e.message}"
    end
    
    stories
  end
  
  # Saves fetched stories to the database, skipping duplicates
  def self.save_stories_to_db(stories : Array(Hash(String, JSON::Any))) : Int32
    saved_count = 0
    
    stories.each do |story|
      external_id = story["external_id"]?.to_s
      next if external_id.empty?
      
      # Check if story already exists
      result = POOL.query(
        "SELECT id FROM posts WHERE external_id = $1 AND source = 'hackernews'",
        external_id
      )
      
      if !result.move_next
        # Insert new story
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
  
  # Fetches top stories
  def self.fetch_top_stories(limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching top stories from Hacker News..."
    ids = fetch_story_ids("topstories", limit)
    stories = fetch_stories(ids)
    saved = save_stories_to_db(stories)
    puts "Saved #{saved} top stories"
    saved
  rescue e : Exception
    puts "Error fetching top stories: #{e.message}"
    0
  end
  
  # Fetches new stories
  def self.fetch_new_stories(limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching new stories from Hacker News..."
    ids = fetch_story_ids("newstories", limit)
    stories = fetch_stories(ids)
    saved = save_stories_to_db(stories)
    puts "Saved #{saved} new stories"
    saved
  rescue e : Exception
    puts "Error fetching new stories: #{e.message}"
    0
  end
  
  # Fetches best stories (highest ranking)
  def self.fetch_best_stories(limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching best stories from Hacker News..."
    ids = fetch_story_ids("beststories", limit)
    stories = fetch_stories(ids)
    saved = save_stories_to_db(stories)
    puts "Saved #{saved} best stories"
    saved
  rescue e : Exception
    puts "Error fetching best stories: #{e.message}"
    0
  end
  
  # Fetches Ask HN stories
  def self.fetch_ask_stories(limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching Ask HN stories..."
    ids = fetch_story_ids("askstories", limit)
    stories = fetch_stories(ids)
    saved = save_stories_to_db(stories)
    puts "Saved #{saved} Ask HN stories"
    saved
  rescue e : Exception
    puts "Error fetching Ask HN stories: #{e.message}"
    0
  end
  
  # Fetches Show HN stories
  def self.fetch_show_stories(limit : Int32 = DEFAULT_LIMIT) : Int32
    puts "Fetching Show HN stories..."
    ids = fetch_story_ids("showstories", limit)
    stories = fetch_stories(ids)
    saved = save_stories_to_db(stories)
    puts "Saved #{saved} Show HN stories"
    saved
  rescue e : Exception
    puts "Error fetching Show HN stories: #{e.message}"
    0
  end
  
  # Full fetch routine that combines multiple story types
  def self.full_fetch
    puts "Starting full Hacker News fetch..."
    
    # Fetch top stories
    saved_top = fetch_top_stories(30)
    
    # Fetch new stories
    saved_new = fetch_new_stories(20)
    
    # Fetch best stories
    saved_best = fetch_best_stories(20)
    
    # Fetch Ask HN
    saved_ask = fetch_ask_stories(15)
    
    # Fetch Show HN
    saved_show = fetch_show_stories(15)
    
    total = saved_top + saved_new + saved_best + saved_ask + saved_show
    puts "Hacker News fetch complete. Total saved: #{total} stories"
    total
  rescue e : Exception
    puts "Full fetch failed: #{e.message}"
    0
  end
  
  # Fetches comments for a specific story
  def self.fetch_story_comments(story_id : Int64, limit : Int32 = 20) : Array(Hash(String, JSON::Any))
    url = "#{BASE_URL}/item/#{story_id}.json"
    
    response = HTTP::Client.get(url)
    
    if response.status_code == 200
      begin
        data = JSON.parse(response.body)
        comments = [] of Hash(String, JSON::Any)
        
        if kids = data["kids"]?
          kids.as_a.first(limit).each do |kid|
            comment = fetch_comment(kid.as_i64)
            comments << comment if comment
          end
        end
        
        comments
      rescue e : Exception
        puts "Failed to fetch story comments: #{e.message}"
        [] of Hash(String, JSON::Any)
      end
    else
      puts "Failed to fetch story comments: #{response.status_code}"
      [] of Hash(String, JSON::Any)
    end
  rescue e : Exception
    puts "Error fetching story comments: #{e.message}"
    [] of Hash(String, JSON::Any)
  end
  
  # Fetches a single comment by ID
  def self.fetch_comment(id : Int64) : Hash(String, JSON::Any)?
    url = "#{BASE_URL}/item/#{id}.json"
    
    response = HTTP::Client.get(url)
    
    if response.status_code == 200
      begin
        data = JSON.parse(response.body)
        
        return nil if data["type"]?.to_s != "comment"
        
        comment = Hash(String, JSON::Any).new
        comment["id"] = JSON::Any.new(data["id"]?.try &.as_i64 || 0)
        comment["by"] = JSON::Any.new(data["by"]?.to_s || "")
        comment["text"] = JSON::Any.new(data["text"]?.to_s || "")
        comment["time"] = JSON::Any.new(data["time"]?.try &.as_i || 0)
        comment["parent"] = JSON::Any.new(data["parent"]?.try &.as_i64 || 0)
        
        comment
      rescue e : Exception
        puts "Failed to parse comment #{id}: #{e.message}"
        nil
      end
    else
      puts "Failed to fetch comment #{id}: #{response.status_code}"
      nil
    end
  rescue e : Exception
    puts "Error fetching comment #{id}: #{e.message}"
    nil
  end
end
