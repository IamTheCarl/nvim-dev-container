---@mod devcontainer.internal.output_buffer Output buffer management
---@brief [[
---Manages output buffers for devcontainer operations (build, attach, etc.)
---Creates split windows to display real-time output with ANSI color support
---@brief ]]

local log = require("devcontainer.internal.log")

local M = {}

---@class OutputBuffer
---@field bufnr integer buffer number
---@field winid integer window id (if still open)
---@field title string buffer title
---@field closed boolean whether buffer has been closed
local OutputBuffer = {}
OutputBuffer.__index = OutputBuffer

---Create a new output buffer with a split window
---@param title string buffer title (e.g., "Build devcontainer")
---@param opts? table options
---@field height? integer split window height (default: 15)
---@return OutputBuffer
function M.new(title, opts)
  opts = opts or {}
  local height = opts.height or 15

  -- Create new buffer
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, string.format("[devcontainer] %s %s", title, os.date("%H:%M:%S")))

  -- Set buffer options
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })

  -- Create split window
  vim.cmd(string.format("split | resize %d", height))
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)

  -- Set window-local options
  vim.api.nvim_set_option_value("number", true, { win = winid })

  local self = setmetatable({
    bufnr = bufnr,
    winid = winid,
    title = title,
    closed = false,
  }, OutputBuffer)

  -- Set up keymapping for Enter to close
  self:_setup_keymaps()

  return self
end

---Setup keymaps for the buffer
function OutputBuffer:_setup_keymaps()
  vim.api.nvim_buf_set_keymap(
    self.bufnr,
    "n",
    "<CR>",
    "",
    {
      noremap = true,
      silent = true,
      callback = function()
        self:close()
      end,
    }
  )
end

---Decode JSON log line from devcontainer CLI
---@param line string JSON line to decode
---@return string decoded human-readable line
local function decode_json_log(line)
  -- Try to parse as JSON
  local ok, data = pcall(vim.json.decode, line)
  if not ok then
    -- Decoding failed, return as-is
    return line
  end
  
  if type(data) ~= "table" then
    -- Not a JSON object, return as-is
    return line
  end

  -- Extract log level and message
  local level = data.level
  local message = data.text or data.message or ""

  -- If no level, return original line
  if not level then
    return line
  end

  -- Simplify level names for readability
  local level_map = {
    debug = "DEBUG",
    info = "INFO",
    warning = "WARN",
    error = "ERROR",
    [0] = "DEBUG",
    [1] = "INFO",
    [2] = "WARN",
    [3] = "ERROR",
  }

  local display_level = level_map[level] or tostring(level):upper()

  -- Format: [LEVEL] message
  if message and message ~= "" then
    return string.format("[%s] %s", display_level, message)
  else
    return line
  end
end

---Append text to the buffer, preserving ANSI codes
---@param text string text to append
---@param type? "stdout" | "stderr" | "info" message type (for logging)
function OutputBuffer:append(text, type)
  if self.closed then
    return
  end

  type = type or "stdout"
  local captured_type = type  -- Capture for closure

  -- Schedule the append to avoid fast event context issues
  -- (stdout/stderr callbacks run in fast event context)
  vim.schedule(function()
    -- Check if buffer still exists
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
      self.closed = true
      return
    end

    -- Split text by newlines and append each line
    local lines = vim.split(text, "\n", { plain = true })

    -- Remove empty trailing line if text ended with newline
    if lines[#lines] == "" then
      table.remove(lines)
    end

    if #lines > 0 then
      -- Decode JSON log lines if this is stdout from devcontainer CLI
      if captured_type == "stdout" then
        local decoded_lines = {}
        for i, line in ipairs(lines) do
          decoded_lines[i] = decode_json_log(line)
        end
        lines = decoded_lines
      end

      vim.api.nvim_buf_set_option(self.bufnr, "modifiable", true)
      vim.api.nvim_buf_set_lines(self.bufnr, -1, -1, false, lines)
      vim.api.nvim_buf_set_option(self.bufnr, "modifiable", false)

      -- Auto-scroll to bottom
      if vim.api.nvim_win_is_valid(self.winid) then
        vim.api.nvim_win_set_cursor(self.winid, { vim.api.nvim_buf_line_count(self.bufnr), 0 })
      end
    end
  end)
end

---Append a progress line with timestamp
---@param label string progress label
function OutputBuffer:append_progress(label)
  local timestamp = os.date("%H:%M:%S")
  self:append(string.format("[%s] %s", timestamp, label), "info")
end

---Finalize the buffer with status information
---@param status "success" | "error" completion status
function OutputBuffer:finalize(status)
  if self.closed then
    return
  end

  -- Schedule to avoid fast event context issues
  vim.schedule(function()
    if self.closed then
      return
    end

    local timestamp = os.date("%H:%M:%S")
    local status_line

    if status == "success" then
      status_line = string.format("[%s] ✓ Operation completed successfully. Press <CR> to close.", timestamp)
    else
      status_line = string.format("[%s] ✗ Operation failed. Press <CR> to close.", timestamp)
    end

    self:append(status_line, "info")

    -- Make buffer non-modifiable
    if vim.api.nvim_buf_is_valid(self.bufnr) then
      vim.api.nvim_buf_set_option(self.bufnr, "modifiable", false)
    end
  end)
end

---Close the buffer and window
function OutputBuffer:close()
  if self.closed then
    return
  end

  self.closed = true

  -- Close window if still valid
  if vim.api.nvim_win_is_valid(self.winid) then
    vim.api.nvim_win_close(self.winid, true)
  end

  -- Delete buffer if still valid
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_delete(self.bufnr, { force = true })
  end
end

---Get the buffer number
---@return integer
function OutputBuffer:get_buffer_number()
  return self.bufnr
end

---Check if buffer is still valid
---@return boolean
function OutputBuffer:is_valid()
  return not self.closed
end

log.wrap(M)

return setmetatable(M, {
  __call = function(_, ...)
    return M.new(...)
  end,
})
