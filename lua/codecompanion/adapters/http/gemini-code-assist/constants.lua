local M = {}

M.CLIENT_ID = vim.env.GEMINI_CLIENT_ID or "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
M.CLIENT_SECRET = vim.env.GEMINI_CLIENT_SECRET or "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"
M.TOKEN_URL = "https://oauth2.googleapis.com/token"
M.AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
M.API_BASE_URL = "https://cloudcode-pa.googleapis.com/v1internal"
M.TOKEN_FILE_NAME = "gemini_code_assist_token.json"

---Get the path to the token file for a specific profile
---@param profile? string
---@return string
function M.get_token_path(profile)
  local filename = M.TOKEN_FILE_NAME
  if profile and profile ~= "" then
    filename = filename:gsub("%.json$", "_" .. profile .. ".json")
  end
  return vim.fs.joinpath(vim.fn.stdpath("data"), filename)
end

M.HEADERS = {
  ["X-Goog-Api-Client"] = "gl-node/22.17.0",
  ["Client-Metadata"] = "ideType=IDE_UNSPECIFIED,platform=PLATFORM_UNSPECIFIED,pluginType=GEMINI",
}

return M
