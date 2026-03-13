local Curl = require("plenary.curl")

local config = require("codecompanion.config")
local constants = require("codecompanion.adapters.http.gemini-code-assist.constants")
local log = require("codecompanion.utils.log")
local runtime = require("codecompanion.adapters.http.gemini-code-assist.runtime")
local ui_utils = require("codecompanion.utils.ui")

local M = {}

local PROGRESS_BAR_WIDTH = 20

---@param percent number
---@param width number
---@return string
local function make_progress_bar(percent, width)
  local filled = math.floor(width * percent / 100)
  return string.rep("█", filled) .. string.rep("░", width - filled)
end

---@param session { access_token:string, project_id:string }
---@return table|nil
function M.fetch_quota(session)
  local headers = vim.tbl_extend("force", constants.HEADERS, {
    ["Authorization"] = "Bearer " .. session.access_token,
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
    ["Accept-Encoding"] = "gzip,deflate",
    ["User-Agent"] = constants.USER_AGENT,
  })

  local ok, response = pcall(Curl.post, constants.QUOTA_URL, {
    insecure = config.adapters.http.opts.allow_insecure,
    proxy = config.adapters.http.opts.proxy,
    headers = headers,
    body = vim.json.encode({ project = session.project_id }),
    timeout = 10000,
  })

  if not ok then
    log:error("Gemini Code Assist: Network error during quota retrieval: %s", response)
    return nil
  end

  if response.status ~= 200 then
    log:error("Gemini Code Assist: Quota retrieval failed (Status %s): %s", response.status, response.body)
    return nil
  end

  local decode_ok, data = pcall(vim.json.decode, response.body)
  if not decode_ok or type(data) ~= "table" then
    log:error("Gemini Code Assist: Failed to decode quota response: %s", response.body)
    return nil
  end

  return data
end

---@param quota table
---@param project_id string
---@return string[] lines, table[] highlights
function M.format_quota_lines(quota, project_id)
  local lines = {
    "Gemini Code Assist Quota",
    "",
    "Project: " .. project_id,
    "",
  }
  local highlights = {}

  local buckets = quota.buckets or {}
  table.sort(buckets, function(a, b)
    return (a.remainingFraction or 0) < (b.remainingFraction or 0)
  end)

  if #buckets == 0 then
    table.insert(lines, "No quota buckets returned.")
    return lines, highlights
  end

  table.insert(lines, "Model | Type | Remaining | Reset")
  table.insert(lines, string.rep("─", 78))

  for _, bucket in ipairs(buckets) do
    local remaining_percent = math.max(0, math.min((bucket.remainingFraction or 0) * 100, 100))
    local model_id = bucket.modelId or "unknown-model"
    local token_type = bucket.tokenType or "unknown-token-type"
    local reset_time = bucket.resetTime or "unknown"

    local line = string.format("%-28s | %-8s | %6.1f%% | %s", model_id, token_type, remaining_percent, reset_time)
    table.insert(lines, line)
    table.insert(lines, "  " .. make_progress_bar(remaining_percent, PROGRESS_BAR_WIDTH))

    local hl
    if remaining_percent <= 10 then
      hl = "Error"
    elseif remaining_percent <= 20 then
      hl = "WarningMsg"
    elseif remaining_percent <= 40 then
      hl = "MoreMsg"
    end

    if hl then
      table.insert(highlights, { line = #lines - 2, group = hl })
      table.insert(highlights, { line = #lines - 1, group = hl })
    end
  end

  return lines, highlights
end

---@param lines string[]
---@param highlights table[]
function M.render(lines, highlights)
  local float_opts = {
    title = " Gemini Code Assist Stats ",
    lock = true,
    relative = "editor",
    row = "center",
    col = "center",
    window = {
      width = 84,
      height = math.min(#lines + 2, 30),
    },
    ignore_keymaps = false,
    style = "minimal",
  }

  local bufnr, _ = ui_utils.create_float(lines, float_opts)
  for _, item in ipairs(highlights) do
    pcall(vim.api.nvim_buf_add_highlight, bufnr, -1, item.group, item.line, 0, -1)
  end
end

---@param profile string|nil
---@param configured_project_id string|nil
function M.show(profile, configured_project_id)
  local session = runtime.resolve_session(profile, configured_project_id)
  if not session then
    vim.notify("Gemini: Could not resolve auth/session. Run :CodeCompanionGeminiAuth", vim.log.levels.ERROR)
    return
  end

  local quota = M.fetch_quota(session)
  if not quota then
    vim.notify("Gemini: Could not retrieve quota stats.", vim.log.levels.ERROR)
    return
  end

  local lines, highlights = M.format_quota_lines(quota, session.project_id)
  M.render(lines, highlights)
end

return M
