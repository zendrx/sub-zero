# auth.cr - Authentication module for Crystal Aggregator

require "json"
require "crypto/bcrypt/password"
require "jwt"
require "time"

module Auth
  # Configuration
  JWT_SECRET = ENV["JWT_SECRET"]? || "your-super-secret-key-change-in-production"
  JWT_EXPIRY_HOURS = 24
  SESSION_COOKIE_NAME = "aggregator_session"

  # Password hashing using Crypto::Bcrypt::Password
  def self.hash_password(password : String) : String
    Crypto::Bcrypt::Password.create(password, cost: 12).to_s
  end

  # Verify password against hash
  def self.verify_password(password : String, hash : String) : Bool
    Crypto::Bcrypt::Password.new(hash) == password
  rescue
    false
  end

  # Generate JWT token for a user
  def self.generate_token(user_id : Int64, username : String) : String
    payload = {
      "user_id"  => user_id,
      "username" => username,
      "exp"      => Time.utc + JWT_EXPIRY_HOURS.hours,
      "iat"      => Time.utc
    }
    JWT.encode(payload, JWT_SECRET, JWT::Algorithm::HS256)
  end

  # Decode and validate JWT token
  def self.decode_token(token : String) : Hash(String, JSON::Any)?
    begin
      decoded = JWT.decode(token, JWT_SECRET, JWT::Algorithm::HS256)
      payload = decoded[0]
      
      # Check expiration
      exp = payload["exp"]?.to_i64
      if exp && exp < Time.utc.to_unix
        return nil
      end
      
      payload
    rescue
      nil
    end
  end

  # Get user ID from token
  def self.user_id_from_token(token : String) : Int64?
    payload = decode_token(token)
    if payload
      payload["user_id"]?.to_i64
    else
      nil
    end
  end

  # Register a new user
  def self.register(username : String, email : String, password : String) : Tuple(Bool, String | Int64)
    if username.empty? || email.empty? || password.empty?
      return {false, "All fields are required"}
    end
    
    if username.size < 3 || username.size > 30
      return {false, "Username must be between 3 and 30 characters"}
    end
    
    if email.size < 5 || !email.includes?("@") || !email.includes?(".")
      return {false, "Invalid email address"}
    end
    
    if password.size < 6
      return {false, "Password must be at least 6 characters"}
    end
    
    if UserDB.exists?(username, email)
      if UserDB.username_exists?(username)
        return {false, "Username already taken"}
      end
      if UserDB.email_exists?(email)
        return {false, "Email already registered"}
      end
      return {false, "Username or email already exists"}
    end
    
    password_hash = hash_password(password)
    user_id = UserDB.create(username, email, password_hash)
    
    if user_id
      {true, user_id}
    else
      {false, "Failed to create user"}
    end
  end

  # Login a user
  def self.login(identifier : String, password : String) : Tuple(Bool, String | Hash(String, JSON::Any))
    user = UserDB.find_by_username(identifier)
    if !user
      user = UserDB.find_by_email(identifier)
    end
    
    if !user
      return {false, "Invalid username or password"}
    end
    
    password_hash = user["password_hash"].as_s
    if !verify_password(password, password_hash)
      return {false, "Invalid username or password"}
    end
    
    UserDB.update_last_login(user["id"].as_i64)
    
    token = generate_token(user["id"].as_i64, user["username"].as_s)
    
    user_data = {
      "id"         => user["id"],
      "username"   => user["username"],
      "email"      => user["email"],
      "created_at" => user["created_at"],
      "is_admin"   => user["is_admin"],
      "token"      => JSON::Any.new(token)
    }
    
    {true, user_data}
  end

  # Validate session from request headers or cookies
  def self.validate_session(headers : HTTP::Headers, cookies : HTTP::Cookies? = nil) : Tuple(Bool, Int64?, Hash(String, JSON::Any)?)
    auth_header = headers["Authorization"]?
    if auth_header && auth_header.starts_with?("Bearer ")
      token = auth_header[7..-1]
      return validate_token(token)
    end
    
    if cookies
      cookie = cookies[SESSION_COOKIE_NAME]?
      if cookie
        return validate_token(cookie.value)
      end
    end
    
    {false, nil, nil}
  end

  # Validate a token and return user data
  def self.validate_token(token : String) : Tuple(Bool, Int64?, Hash(String, JSON::Any)?)
    payload = decode_token(token)
    if !payload
      return {false, nil, nil}
    end
    
    user_id = payload["user_id"]?.to_i64
    if !user_id
      return {false, nil, nil}
    end
    
    user = UserDB.find(user_id)
    if !user
      return {false, nil, nil}
    end
    
    {true, user_id, user}
  end

  # Check if user is authenticated
  def self.authenticated?(headers : HTTP::Headers, cookies : HTTP::Cookies? = nil) : Bool
    valid, _, _ = validate_session(headers, cookies)
    valid
  end

  # Get current user from session
  def self.current_user(headers : HTTP::Headers, cookies : HTTP::Cookies? = nil) : Hash(String, JSON::Any)?
    _, _, user = validate_session(headers, cookies)
    user
  end

  # Get current user ID from session
  def self.current_user_id(headers : HTTP::Headers, cookies : HTTP::Cookies? = nil) : Int64?
    _, user_id, _ = validate_session(headers, cookies)
    user_id
  end

  # Logout - just clear the cookie
  def self.logout : HTTP::Cookie
    HTTP::Cookie.new(
      name: SESSION_COOKIE_NAME,
      value: "",
      expires: Time.utc - 1.hour,
      path: "/",
      http_only: true,
      secure: ENV["PRODUCTION"]? == "true"
    )
  end

  # Create session cookie
  def self.session_cookie(token : String) : HTTP::Cookie
    HTTP::Cookie.new(
      name: SESSION_COOKIE_NAME,
      value: token,
      expires: Time.utc + JWT_EXPIRY_HOURS.hours,
      path: "/",
      http_only: true,
      secure: ENV["PRODUCTION"]? == "true",
      same_site: "Lax"
    )
  end

  # Change password
  def self.change_password(user_id : Int64, old_password : String, new_password : String) : Tuple(Bool, String)
    user = UserDB.find(user_id)
    if !user
      return {false, "User not found"}
    end
    
    result = POOL.query(
      "SELECT password_hash FROM users WHERE id = $1",
      user_id
    )
    if result.move_next
      current_hash = result.read(String)
      if !verify_password(old_password, current_hash)
        return {false, "Current password is incorrect"}
      end
    else
      return {false, "User not found"}
    end
    
    if new_password.size < 6
      return {false, "New password must be at least 6 characters"}
    end
    
    new_hash = hash_password(new_password)
    POOL.exec(
      "UPDATE users SET password_hash = $1 WHERE id = $2",
      new_hash, user_id
    )
    
    {true, "Password changed successfully"}
  rescue e : PG::Error
    {false, "Database error: #{e.message}"}
  end

  # Change email
  def self.change_email(user_id : Int64, new_email : String, password : String) : Tuple(Bool, String)
    user = UserDB.find(user_id)
    if !user
      return {false, "User not found"}
    end
    
    result = POOL.query(
      "SELECT password_hash FROM users WHERE id = $1",
      user_id
    )
    if result.move_next
      current_hash = result.read(String)
      if !verify_password(password, current_hash)
        return {false, "Invalid password"}
      end
    else
      return {false, "User not found"}
    end
    
    if new_email.empty? || !new_email.includes?("@")
      return {false, "Invalid email address"}
    end
    
    if UserDB.email_exists?(new_email) && UserDB.find_by_email(new_email)["id"].as_i64 != user_id
      return {false, "Email already in use"}
    end
    
    POOL.exec(
      "UPDATE users SET email = $1 WHERE id = $2",
      new_email, user_id
    )
    
    {true, "Email changed successfully"}
  rescue e : PG::Error
    {false, "Database error: #{e.message}"}
  end

  # Delete user account
  def self.delete_account(user_id : Int64, password : String) : Tuple(Bool, String)
    result = POOL.query(
      "SELECT password_hash FROM users WHERE id = $1",
      user_id
    )
    if result.move_next
      current_hash = result.read(String)
      if !verify_password(password, current_hash)
        return {false, "Invalid password"}
      end
    else
      return {false, "User not found"}
    end
    
    POOL.exec("DELETE FROM users WHERE id = $1", user_id)
    
    {true, "Account deleted successfully"}
  rescue e : PG::Error
    {false, "Database error: #{e.message}"}
  end

  # Check if user is admin
  def self.is_admin?(user_id : Int64) : Bool
    user = UserDB.find(user_id)
    user ? user["is_admin"].as_bool : false
  end

  # Require authentication middleware
  def self.require_auth(context : HTTP::Server::Context)
    valid, user_id, user = validate_session(context.request.headers, context.request.cookies)
    
    if !valid || !user_id
      context.response.status_code = 401
      context.response.content_type = "application/json"
      context.response.print %({"error":"Authentication required"})
      return false
    end
    
    context.set("current_user", user)
    context.set("current_user_id", user_id)
    true
  end

  # Require admin middleware
  def self.require_admin(context : HTTP::Server::Context)
    valid, user_id, user = validate_session(context.request.headers, context.request.cookies)
    
    if !valid || !user_id
      context.response.status_code = 401
      context.response.content_type = "application/json"
      context.response.print %({"error":"Authentication required"})
      return false
    end
    
    if !is_admin?(user_id)
      context.response.status_code = 403
      context.response.content_type = "application/json"
      context.response.print %({"error":"Admin privileges required"})
      return false
    end
    
    context.set("current_user", user)
    context.set("current_user_id", user_id)
    true
  end
end

# Helper module for easy session management in handlers
module AuthHelpers
  # Get current user from context
  def self.current_user(context : HTTP::Server::Context) : Hash(String, JSON::Any)?
    value = context.get("current_user")
    value.is_a?(Hash(String, JSON::Any)) ? value : nil
  end

  # Get current user ID from context
  def self.current_user_id(context : HTTP::Server::Context) : Int64?
    value = context.get("current_user_id")
    value.is_a?(Int64) ? value : nil
  end

  # Check if user is logged in
  def self.logged_in?(context : HTTP::Server::Context) : Bool
    current_user_id(context) != nil
  end

  # Check if user is admin
  def self.admin?(context : HTTP::Server::Context) : Bool
    user = current_user(context)
    user ? user["is_admin"].as_bool : false
  end
end
