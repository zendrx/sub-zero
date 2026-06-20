# routes/auth.cr - Authentication routes for Crystal Aggregator using Kemal
# Handles registration, login, logout, and account management endpoints

# Registration endpoint
post "/api/auth/register" do |env|
  begin
    # Kemal automatically parses JSON bodies into env.params.json
    username = env.params.json["username"]?.try &.as(String) || ""
    email = env.params.json["email"]?.try &.as(String) || ""
    password = env.params.json["password"]?.try &.as(String) || ""

    result = Auth.register(username, email, password)

    if result[0] == true
      user_id = result[1].as(Int64)
      env.response.status_code = 201
      {
        "status"  => "success",
        "message" => "User created successfully",
        "user_id" => user_id,
      }.to_json
    else
      env.response.status_code = 400
      {
        "status"  => "error",
        "message" => result[1].as(String),
      }.to_json
    end
  rescue e : Exception
    env.response.status_code = 500
    {
      "status"  => "error",
      "message" => "Internal server error",
    }.to_json
  end
end

# Login endpoint
post "/api/auth/login" do |env|
  begin
    identifier = env.params.json["identifier"]?.try &.as(String) || ""
    password = env.params.json["password"]?.try &.as(String) || ""

    result = Auth.login(identifier, password)

    if result[0] == true
      user_data = result[1].as(Hash(String, JSON::Any))
      token = user_data["token"].to_s

      cookie = Auth.session_cookie(token)
      env.response.cookies << cookie

      env.response.status_code = 200
      {
        "status"  => "success",
        "message" => "Login successful",
        "user"    => user_data,
      }.to_json
    else
      env.response.status_code = 401
      {
        "status"  => "error",
        "message" => result[1].as(String),
      }.to_json
    end
  rescue e : Exception
    env.response.status_code = 500
    {
      "status"  => "error",
      "message" => "Internal server error",
    }.to_json
  end
end

# Logout endpoint
post "/api/auth/logout" do |env|
  if Auth.authenticated?(env.request.headers, env.request.cookies)
    cookie = Auth.logout
    env.response.cookies << cookie

    env.response.status_code = 200
    {
      "status"  => "success",
      "message" => "Logged out successfully",
    }.to_json
  else
    env.response.status_code = 401
    {
      "status"  => "error",
      "message" => "Not authenticated",
    }.to_json
  end
end

# Get current user endpoint
get "/api/auth/me" do |env|
  valid, user_id, user = Auth.validate_session(env.request.headers, env.request.cookies)

  if valid && user_id && user
    user.delete("password_hash") if user.has_key?("password_hash")

    env.response.status_code = 200
    {
      "status" => "success",
      "user"   => user,
    }.to_json
  else
    env.response.status_code = 401
    {
      "status"  => "error",
      "message" => "Not authenticated",
    }.to_json
  end
end

# Change password endpoint
put "/api/auth/change-password" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)

  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required",
    }.to_json
  end

  begin
    old_password = env.params.json["old_password"]?.try &.as(String) || ""
    new_password = env.params.json["new_password"]?.try &.as(String) || ""

    result = Auth.change_password(user_id, old_password, new_password)

    if result[0] == true
      env.response.status_code = 200
      {
        "status"  => "success",
        "message" => result[1].as(String),
      }.to_json
    else
      env.response.status_code = 400
      {
        "status"  => "error",
        "message" => result[1].as(String),
      }.to_json
    end
  rescue e : Exception
    env.response.status_code = 500
    {
      "status"  => "error",
      "message" => "Internal server error",
    }.to_json
  end
end

# Change email endpoint
put "/api/auth/change-email" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)

  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required",
    }.to_json
  end

  begin
    new_email = env.params.json["new_email"]?.try &.as(String) || ""
    password = env.params.json["password"]?.try &.as(String) || ""

    result = Auth.change_email(user_id, new_email, password)

    if result[0] == true
      env.response.status_code = 200
      {
        "status"  => "success",
        "message" => result[1].as(String),
      }.to_json
    else
      env.response.status_code = 400
      {
        "status"  => "error",
        "message" => result[1].as(String),
      }.to_json
    end
  rescue e : Exception
    env.response.status_code = 500
    {
      "status"  => "error",
      "message" => "Internal server error",
    }.to_json
  end
end

# Delete account endpoint
delete "/api/auth/delete-account" do |env|
  valid, user_id, _ = Auth.validate_session(env.request.headers, env.request.cookies)

  if !valid || !user_id
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Authentication required",
    }.to_json
  end

  begin
    password = env.params.json["password"]?.try &.as(String) || ""

    result = Auth.delete_account(user_id, password)

    if result[0] == true
      cookie = Auth.logout
      env.response.cookies << cookie

      env.response.status_code = 200
      {
        "status"  => "success",
        "message" => result[1].as(String),
      }.to_json
    else
      env.response.status_code = 400
      {
        "status"  => "error",
        "message" => result[1].as(String),
      }.to_json
    end
  rescue e : Exception
    env.response.status_code = 500
    {
      "status"  => "error",
      "message" => "Internal server error",
    }.to_json
  end
end

# Check if username is available
get "/api/auth/check-username/:username" do |env|
  username = env.params.url["username"]

  if username.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Username is required",
    }.to_json
  end

  exists = UserDB.username_exists?(username)

  env.response.status_code = 200
  {
    "status"    => "success",
    "username"  => username,
    "available" => !exists,
  }.to_json
end

# Check if email is available
get "/api/auth/check-email/:email" do |env|
  email = env.params.url["email"]

  if email.empty?
    env.response.status_code = 400
    next {
      "status"  => "error",
      "message" => "Email is required",
    }.to_json
  end

  exists = UserDB.email_exists?(email)

  env.response.status_code = 200
  {
    "status"    => "success",
    "email"     => email,
    "available" => !exists,
  }.to_json
end

# Refresh token endpoint
post "/api/auth/refresh" do |env|
  valid, user_id, user = Auth.validate_session(env.request.headers, env.request.cookies)

  if !valid || !user_id || !user
    env.response.status_code = 401
    next {
      "status"  => "error",
      "message" => "Not authenticated",
    }.to_json
  end

  token = Auth.generate_token(user_id, user["username"].to_s)

  cookie = Auth.session_cookie(token)
  env.response.cookies << cookie

  env.response.status_code = 200
  {
    "status"  => "success",
    "message" => "Token refreshed",
    "token"   => token,
  }.to_json
end
