def flash(env)
  value = env.get("flash")
  if value.is_a?(Hash(String, String))
    value
  else
    {} of String => String
  end
end