local curl = require("plenary.curl")

local auth = require("codecompanion.adapters.http.gemini-code-assist.auth")
local config = require("codecompanion.config")
local constants = require("codecompanion.adapters.http.gemini-code-assist.constants")
local log = require("codecompanion.utils.log")

local M = {}

local token_cache = {}

---Get a fresh access token
---@param token_file string
---@return string|nil
function M.get_fresh_token(token_file)
  local cache = token_cache[token_file] or { access_token = nil, expires_at = 0 }

  if cache.access_token and os.time() < (cache.expires_at - 120) then
    return cache.access_token
  end

  local refresh_token, _ = auth.load_token(token_file)
  if not refresh_token then
    vim.notify("Gemini: Authentication required. Please run :CodeCompanionGeminiAuth", vim.log.levels.WARN)
    return nil
  end

  log:trace("Gemini Code Assist: Refreshing access token...")
  local ok, response = pcall(curl.post, constants.TOKEN_URL, {
    insecure = config.adapters.http.opts.allow_insecure,
    proxy = config.adapters.http.opts.proxy,
    body = {
      client_id = constants.CLIENT_ID,
      client_secret = constants.CLIENT_SECRET,
      refresh_token = refresh_token,
      grant_type = "refresh_token",
    },
    timeout = 10000,
  })

  if not ok then
    log:error("Gemini Code Assist: Network error during token refresh: %s", response)
    return nil
  end

  if response.status == 200 then
    local decode_ok, data = pcall(vim.json.decode, response.body)
    if decode_ok and data and data.access_token then
      token_cache[token_file] = {
        access_token = data.access_token,
        expires_at = os.time() + (data.access_token_expires_in or data.expires_in or 3599),
      }
      log:trace("Gemini Code Assist: Token refreshed successfully")
      return data.access_token
    end
    log:error("Gemini Code Assist: Failed to decode token response: %s", response.body)
    return nil
  end

  log:error("Gemini Code Assist: Token refresh failed (Status %s): %s", response.status, response.body)
  return nil
end

---Resolve project_id precedence:
---Configured adapter value > environment variable > cached token file > managed project API
---@param opts { token_file:string, access_token:string, configured_project_id:string|nil }
---@return string|nil
function M.resolve_project_id(opts)
  if
    opts.configured_project_id
    and opts.configured_project_id ~= ""
    and opts.configured_project_id ~= "GEMINI_CODE_ASSIST_PROJECT_ID"
  then
    return opts.configured_project_id
  end

  local env_project_id = os.getenv("GEMINI_CODE_ASSIST_PROJECT_ID")
  if env_project_id and env_project_id ~= "" then
    return env_project_id
  end

  local _, cached_id = auth.load_token(opts.token_file)
  if cached_id and cached_id ~= "" then
    return cached_id
  end

  log:info("Gemini: Resolving managed project...")
  local managed_id = auth.resolve_managed_project(opts.access_token)
  if managed_id then
    auth.save_project_id(opts.token_file, managed_id)
    return managed_id
  end

  log:error(
    "Gemini: Could not resolve Project ID. Ensure 'Gemini for Google Cloud API' is enabled at https://console.cloud.google.com/apis/library/cloudaicompanion.googleapis.com"
  )
  return nil
end

---Resolve full runtime session
---@param profile string|nil
---@param configured_project_id string|nil
---@return { token_file:string, access_token:string, project_id:string }|nil
function M.resolve_session(profile, configured_project_id)
  local token_file = constants.get_token_path(profile)
  local access_token = M.get_fresh_token(token_file)
  if not access_token then
    return nil
  end

  local project_id = M.resolve_project_id({
    token_file = token_file,
    access_token = access_token,
    configured_project_id = configured_project_id,
  })
  if not project_id then
    return nil
  end

  return {
    token_file = token_file,
    access_token = access_token,
    project_id = project_id,
  }
end

return M
