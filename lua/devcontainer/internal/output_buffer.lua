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
---@field json_buffer string accumulated partial JSON for fragmented lines
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
    json_buffer = "",  -- Buffer for accumulating partial JSON across callback invocations
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

  -- Extract message based on type
  local message = nil
  local level_str = ""

  -- Get level display string
  if data.level then
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
    level_str = level_map[data.level] or tostring(data.level):upper()
  end

  -- For "raw" type messages, just extract and return the text
  -- These contain actual build/output text embedded as JSON
  if data.type == "raw" then
    -- Raw messages contain the actual build output in the "text" field
    if data.text then
      return data.text
    end
    return line
  end

  -- For "text" type, just show the text field (most common)
  if data.type == "text" then
    if data.text then
      return data.text
    end
    return line
  end

  -- For other types, try to extract message or text field
  message = data.text or data.message or ""

  -- If we have level and message, format with level
  if level_str ~= "" and message and message ~= "" then
    return string.format("[%s] %s", level_str, message)
  elseif message and message ~= "" then
    return message
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
  local captured_self = self  -- Capture self for closure

  -- Schedule the append to avoid fast event context issues
  -- (stdout/stderr callbacks run in fast event context)
  vim.schedule(function()
    -- Check if buffer still exists
    if not vim.api.nvim_buf_is_valid(captured_self.bufnr) then
      captured_self.closed = true
      return
    end

    -- DEBUG: Always add a marker to see if append is called
    local lines_to_add = {string.format("[append called: type=%s]", captured_type)}

    -- Decode JSON log lines if this is stdout/stderr from devcontainer CLI
    if captured_type == "stdout" or captured_type == "stderr" then
      -- Prepend any buffered partial JSON from previous calls
      text = captured_self.json_buffer .. text
      captured_self.json_buffer = ""
      
      -- DEBUG: Add marker so we know this is stdout/stderr
      if captured_type == "stdout" then
        table.insert(lines_to_add, "[STDOUT MARKER]")
      else
        table.insert(lines_to_add, "[STDERR MARKER]")
      end

      -- Try to parse each logical line as JSON
      -- For JSON log lines, we need to be careful about embedded newlines in the "text" field
      local remaining = text
      while remaining and remaining ~= "" do
        -- Try to find the start of a JSON object
        local first_brace = remaining:find("{")
        if not first_brace then
          -- No JSON object found, add remaining as plain text
          if remaining ~= "" then
            -- Check if this might be the start of a JSON object being fragmented
            if remaining:match("^%s*{") then
              -- Looks like the start of JSON, buffer it
              captured_self.json_buffer = remaining
            else
              for _, line in ipairs(vim.split(remaining, "\n", { plain = true })) do
                if line ~= "" then
                  table.insert(lines_to_add, line)
                end
              end
            end
          end
          break
        end

        -- Text before the brace
        if first_brace > 1 then
          local prefix = remaining:sub(1, first_brace - 1)
          for _, line in ipairs(vim.split(prefix, "\n", { plain = true })) do
            if line ~= "" then
              table.insert(lines_to_add, line)
            end
          end
        end

        -- Try to find the matching closing brace
        local json_start = first_brace
        local brace_count = 0
        local in_string = false
        local escape_next = false
        local json_end = nil

        for i = json_start, #remaining do
          local char = remaining:sub(i, i)

          if escape_next then
            escape_next = false
          elseif char == "\\" then
            escape_next = true
          elseif char == '"' and not escape_next then
            in_string = not in_string
          elseif not in_string then
            if char == "{" then
              brace_count = brace_count + 1
            elseif char == "}" then
              brace_count = brace_count - 1
              if brace_count == 0 then
                json_end = i
                break
              end
            end
          end
        end

        if json_end then
          -- Found a complete JSON object
          local json_str = remaining:sub(json_start, json_end)
          local decoded = decode_json_log(json_str)
          
          -- Split decoded output by newlines to handle embedded \n in "raw" messages
          local decoded_lines = vim.split(decoded, "\n", { plain = true })
          for _, decoded_line in ipairs(decoded_lines) do
            if decoded_line ~= "" then
              table.insert(lines_to_add, string.format("[DECODED] %s", decoded_line))
            end
          end

          -- Move past this JSON object
          remaining = remaining:sub(json_end + 1)
          -- Skip leading whitespace/newlines
          remaining = remaining:match("^%s*(.*)$")
        else
          -- Incomplete JSON, buffer it for next callback
          local partial = remaining:sub(json_start)
          if partial ~= "" then
            captured_self.json_buffer = partial
          end
          break
        end
      end
    else
      -- For non-stdout, just split by newlines normally
      table.insert(lines_to_add, string.format("[TYPE:%s]", captured_type))
      local lines = vim.split(text, "\n", { plain = true })
      for _, line in ipairs(lines) do
        if line ~= "" then
          table.insert(lines_to_add, line)
        end
      end
    end

    if #lines_to_add > 0 then
      -- CRITICAL: Ensure all lines are free of embedded newlines before adding to buffer
      -- nvim_buf_set_lines will fail if any line contains newlines
      local safe_lines = {}
      for _, line in ipairs(lines_to_add) do
        if line ~= "" then
          -- Split each line by newlines just to be safe
          local split_lines = vim.split(line, "\n", { plain = true })
          for _, split_line in ipairs(split_lines) do
            if split_line ~= "" then
              table.insert(safe_lines, split_line)
            end
          end
        end
      end
      
      if #safe_lines > 0 then
        vim.api.nvim_buf_set_option(captured_self.bufnr, "modifiable", true)
        vim.api.nvim_buf_set_lines(captured_self.bufnr, -1, -1, false, safe_lines)
        vim.api.nvim_buf_set_option(captured_self.bufnr, "modifiable", false)

        -- Auto-scroll to bottom
        if vim.api.nvim_win_is_valid(captured_self.winid) then
          vim.api.nvim_win_set_cursor(captured_self.winid, { vim.api.nvim_buf_line_count(captured_self.bufnr), 0 })
        end
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

  local captured_self = self

  -- Schedule to avoid fast event context issues
  vim.schedule(function()
    if captured_self.closed then
      return
    end

    -- Flush any remaining JSON buffer content
    if captured_self.json_buffer and captured_self.json_buffer ~= "" then
      captured_self:append(captured_self.json_buffer, "stdout")
      captured_self.json_buffer = ""
    end

    local timestamp = os.date("%H:%M:%S")
    local status_line

    if status == "success" then
      status_line = string.format("[%s] ✓ Operation completed successfully. Press <CR> to close.", timestamp)
    else
      status_line = string.format("[%s] ✗ Operation failed. Press <CR> to close.", timestamp)
    end

    captured_self:append(status_line, "info")

    -- Make buffer non-modifiable
    if vim.api.nvim_buf_is_valid(captured_self.bufnr) then
      vim.api.nvim_buf_set_option(captured_self.bufnr, "modifiable", false)
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
