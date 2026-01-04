local curl = require("plenary.curl")
local config = require("codecompanion.config")
local constants = require("codecompanion.adapters.http.gemini-code-assist.constants")

local M = {}

-- flag to indicate if we're in the process of authenticating
local is_authenticating = false

---Save the token response to disk
---@param token_file string
---@param data table
---@return boolean
local function save_token(token_file, data)
  local existing = {}
  local rfile = io.open(token_file, "r")
  if rfile then
    local content = rfile:read("*a")
    rfile:close()
    local ok, json = pcall(vim.json.decode, content)
    if ok then
      existing = json
    end
  end

  local final_data = vim.tbl_extend("force", existing, data)
  local wfile = io.open(token_file, "w")
  if wfile then
    wfile:write(vim.json.encode(final_data))
    wfile:close()
    return true
  end
  return false
end

---Load credentials from disk
---@param token_file string
---@return string|nil refresh_token
---@return string|nil managed_project_id
function M.load_token(token_file)
  local file = io.open(token_file, "r")
  if file then
    local content = file:read("*a")
    file:close()
    local ok, data = pcall(vim.json.decode, content)
    if ok and data.refresh_token then
      return data.refresh_token, data.managed_project_id
    end
  end
  return nil, nil
end

---Save a project ID to the token file
---@param token_file string
---@param project_id string|nil
function M.save_project_id(token_file, project_id)
  save_token(token_file, { managed_project_id = project_id })
end

---Resolve or provision a managed project
---@param access_token string
---@return string|nil project_id
function M.resolve_managed_project(access_token)
  local headers = vim.tbl_extend("force", constants.HEADERS, {
    ["Authorization"] = "Bearer " .. access_token,
    ["Content-Type"] = "application/json",
  })

  -- check for existing project
  local res = curl.post(constants.API_BASE_URL .. ":loadCodeAssist", {
    insecure = config.adapters.http.opts.allow_insecure,
    proxy = config.adapters.http.opts.proxy,
    headers = headers,
    body = vim.json.encode({
      metadata = { ideType = "IDE_UNSPECIFIED", platform = "PLATFORM_UNSPECIFIED", pluginType = "GEMINI" },
    }),
  })

  if res.status ~= 200 then
    return nil
  end
  local data = vim.json.decode(res.body)

  if data.cloudaicompanionProject then
    return data.cloudaicompanionProject
  end

  -- provision FREE tier if allowed
  local can_onboard = false
  for _, tier in ipairs(data.allowedTiers or {}) do
    if tier.id == "FREE" then
      can_onboard = true
      break
    end
  end

  if can_onboard then
    local ob_res = curl.post(constants.API_BASE_URL .. ":onboardUser", {
      insecure = config.adapters.http.opts.allow_insecure,
      proxy = config.adapters.http.opts.proxy,
      headers = headers,
      body = vim.json.encode({
        tierId = "FREE",
        metadata = { ideType = "IDE_UNSPECIFIED", platform = "PLATFORM_UNSPECIFIED", pluginType = "GEMINI" },
      }),
    })
    if ob_res.status == 200 then
      local ob_data = vim.json.decode(ob_res.body)
      return ob_data.response
        and ob_data.response.cloudaicompanionProject
        and ob_data.response.cloudaicompanionProject.id
    end
  end

  return nil
end

---Exchange the authorization code for access/refresh tokens
---@param token_file string
---@param code string
---@param redirect_uri string
local function exchange_code(token_file, code, redirect_uri)
  local status, response = pcall(curl.post, constants.TOKEN_URL, {
    insecure = config.adapters.http.opts.allow_insecure,
    proxy = config.adapters.http.opts.proxy,
    body = {
      client_id = constants.CLIENT_ID,
      client_secret = constants.CLIENT_SECRET,
      code = code,
      grant_type = "authorization_code",
      redirect_uri = redirect_uri,
    },
    timeout = 10000,
  })

  if not status then
    vim.notify("Gemini: error in curl request: " .. tostring(response), vim.log.levels.ERROR)
    return nil
  end

  if response.status == 200 then
    local ok, data = pcall(vim.json.decode, response.body)

    if not ok then
      vim.notify("Gemini: error parsing token response: " .. tostring(data), vim.log.levels.ERROR)
      return nil
    end

    if save_token(token_file, data) then
      vim.notify("Gemini: token saved successfully!", vim.log.levels.INFO)
      return data
    end
  else
    vim.notify("Gemini: error exchanging code: " .. tostring(response.body), vim.log.levels.ERROR)
  end
end

---Start the OAuth2 PKCE-like flow with a local server
---@param token_file string
function M.authenticate(token_file)
  if is_authenticating then
    vim.notify("⚠️ Gemini: Authentication process already in progress.", vim.log.levels.WARN)
    return
  end
  is_authenticating = true

  -- timeout to reset the flag in case something goes wrong
  -- (e.g. 60s, user doesn't complete the auth in time)
  vim.defer_fn(function()
    is_authenticating = false
  end, 60000)

  local uv = vim.uv or vim.loop
  local server = uv.new_tcp()
  local host = "127.0.0.1"
  local port = 0 -- Let OS assign a free port

  server:bind(host, port)

  -- Retrieve assigned port
  local address = server:getsockname()
  port = address.port
  local redirect_uri = string.format("http://%s:%d", host, port)

  local state_code = math.random(100000, 999999) -- simple CSRF protection

  -- init the server
  server:listen(128, function(err)
    assert(not err, err)
    local client = uv.new_tcp()
    server:accept(client)

    client:read_start(function(read_err, chunk)
      if chunk then
        local code = chunk:match("code=([^& ]+)")
        local state = chunk:match("state=([^& ]+)")

        local response_body
        if code and tonumber(state) == state_code then
          response_body =
            "<h1>Authentication Successful</h1><p>You can close this window and return to Neovim.</p><script>window.close()</script>"
          -- schedule the token exchange out of the uv loop
          vim.schedule(function()
            exchange_code(token_file, code, redirect_uri)
            is_authenticating = false
          end)
        else
          response_body = "<h1>Error</h1><p>Could not obtain code or invalid state.</p>"
          is_authenticating = false
        end

        local response = "HTTP/1.1 200 OK\r\n"
          .. "Content-Type: text/html\r\n"
          .. "Content-Length: "
          .. #response_body
          .. "\r\n"
          .. "Connection: close\r\n\r\n"
          .. response_body

        client:write(response, function()
          client:shutdown()
          client:close()
          server:close() -- close the server after handling one request
        end)
      end
    end)
  end)

  -- build the auth URL
  local url = string.format(
    "%s?client_id=%s&redirect_uri=%s&response_type=code&scope=https://www.googleapis.com/auth/cloud-platform&access_type=offline&prompt=consent&state=%s",
    constants.AUTH_URL,
    constants.CLIENT_ID,
    vim.uri_encode(redirect_uri),
    state_code
  )

  vim.notify("Gemini: Opening browser for authentication...", vim.log.levels.INFO)
  vim.ui.open(url)
end

return M
