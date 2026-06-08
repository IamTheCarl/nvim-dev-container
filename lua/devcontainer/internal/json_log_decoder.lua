---@mod devcontainer.internal.json_log_decoder JSON log decoder
---@brief [[
---Decodes devcontainer CLI's JSON log stream to human-readable format
---Converts {"type":"...","level":N,"text":"..."} to [LEVEL] text format
---@brief ]]

local M = {}

-- Log level mappings
local LEVELS = {
  [0] = "DEBUG",
  [1] = "INFO",
  [2] = "WARN",
  [3] = "ERROR",
}

---Decode a single JSON log line
---@param json_line string a line in devcontainer's JSON log format
---@return string decoded message or original line if not JSON
function M.decode_line(json_line)
  if not json_line or json_line == "" then
    return json_line
  end

  -- Try to parse as JSON
  local ok, parsed = pcall(vim.json.decode, json_line)
  if not ok or not parsed then
    -- Not JSON, return as-is
    return json_line
  end

  -- For "raw" type messages, just extract and return the text
  -- These contain actual build/output text embedded as JSON
  if parsed.type == "raw" then
    if parsed.text then
      return parsed.text
    end
    return json_line
  end

  -- Check if it has standard log format
  if not parsed.level or not parsed.text then
    -- Not a standard log line, return original
    return json_line
  end

  -- Get the log level name
  local level_name = LEVELS[parsed.level] or "UNKNOWN"

  -- Format as [LEVEL] text
  return string.format("[%s] %s", level_name, parsed.text)
end

---Decode a stream of text that may contain multiple JSON log lines
---@param text string text stream (may contain multiple lines)
---@return string[] array of decoded lines
function M.decode_stream(text)
  local lines = vim.split(text, "\n", { plain = true })
  local decoded_lines = {}

  for _, line in ipairs(lines) do
    if line ~= "" then
      table.insert(decoded_lines, M.decode_line(line))
    end
  end

  return decoded_lines
end

return M
