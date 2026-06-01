---@mod devcontainer.cli Devcontainer CLI wrapper
---@brief [[
---Thin wrapper around the @devcontainers/cli commands
---All CLI commands output JSON to stdout
---@brief ]]

local uv = vim.loop
local log = require("devcontainer.internal.log")
local executor = require("devcontainer.internal.executor")
local config = require("devcontainer.config")

local M = {}

local CLI_COMMAND = config.cli_path or "devcontainer"

---@class CliResult
---@field code integer exit code
---@field signal integer signal
---@field stdout string raw stdout
---@field stderr string raw stderr
---@field data table|nil parsed JSON from stdout (only if exit_code == 0)
---@field error string|nil error message (only if exit_code ~= 0)

---@class CliRunOpts
---@field on_exit? fun(result: CliResult) callback when command exits
---@field stdout? fun(data: string|nil) stdout pipe handler
---@field stderr? fun(data: string|nil) stderr pipe handler
---@field cwd? string working directory

local function handle_close(handle)
  if not uv.is_closing(handle) then
    uv.close(handle)
  end
end

local function parse_json_output(output)
  if not output or output == "" then
    return nil
  end
  -- The devcontainer CLI outputs structured JSON logs to stdout.
  -- Find the last top-level JSON object (the actual command result).
  local last_json, last_end = "", 0
  local i = 1
  local len = #output

  while i <= len do
    if output:sub(i, i) == "{" then
      local depth = 0
      local start = i
      local in_str = false
      local j = i

      while j <= len do
        local ch = output:sub(j, j)
        if in_str then
          if ch == "\\" then
            j = j + 1
          elseif ch == '"' then
            in_str = false
          end
        else
          if ch == '"' then
            in_str = true
          elseif ch == "{" then
            depth = depth + 1
          elseif ch == "}" then
            depth = depth - 1
            if depth == 0 then
              local candidate = output:sub(start, j)
              local ok, data = pcall(vim.json.decode, candidate, { luanil = { object = true, array = true } })
              if ok and (data.configuration or data.outcome or data.imageName or data.containerId) then
                last_json = candidate
                last_end = j
              end
              break
            end
          end
        end
        j = j + 1
      end
    end
    i = i + 1
  end

  if last_json ~= "" then
    local ok, data = pcall(vim.json.decode, last_json, { luanil = { object = true, array = true } })
    if ok then
      if type(data) == "table" then
        local keys = {}
        for k in pairs(data) do table.insert(keys, k) end
      end
      return data
    end
  end
  return nil
end

---@param args string[] CLI arguments
---@param opts CliRunOpts|nil options
---@return table? handle, integer? pid
local function run_cli(args, opts)
  opts = opts or {}

  -- Insert --log-format json after the subcommand (first non-flag arg)
  local command_args = {}
  local subcmd_idx = 0
  for i, arg in ipairs(args) do
    if not arg:match("^%-%-") then
      subcmd_idx = i
      break
    end
  end

  if subcmd_idx > 0 then
    -- Add args before subcommand
    for i = 1, subcmd_idx - 1 do
      table.insert(command_args, args[i])
    end
    -- Add subcommand
    table.insert(command_args, args[subcmd_idx])
    -- Add log-format after subcommand
    table.insert(command_args, "--log-format")
    table.insert(command_args, "json")
    -- Add args after subcommand
    for i = subcmd_idx + 1, #args do
      table.insert(command_args, args[i])
    end
  else
    command_args = vim.list_extend({}, args)
    table.insert(command_args, "--log-format")
    table.insert(command_args, "json")
  end

  local uv_opts = {}
  if opts.cwd then
    uv_opts.cwd = opts.cwd
  end

  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)

  local captured_stdout = {}
  local captured_stderr = {}

  local handle, pid
  handle, pid = uv.spawn(
    CLI_COMMAND,
    vim.tbl_extend("force", uv_opts, {
      stdio = { nil, stdout, stderr },
      args = command_args,
    }),
    function(exit_code, signal)
      handle_close(stdout)
      handle_close(stderr)
      handle_close(handle)

      local full_stdout = table.concat(captured_stdout)
      local full_stderr = table.concat(captured_stderr)

      local result = {
        code = exit_code,
        signal = signal,
        stdout = full_stdout,
        stderr = full_stderr,
      }

      if exit_code == 0 then
        result.data = parse_json_output(full_stdout)
      else
        result.error = full_stderr or full_stdout or "Command failed with exit code " .. exit_code
      end

      if type(opts.on_exit) == "function" then
        opts.on_exit(result)
      end
    end
  )

  if stdout then
    uv.read_start(stdout, function(err, data)
      if data then
        table.insert(captured_stdout, data)
        if type(opts.stdout) == "function" then
          opts.stdout(data)
        end
      end
    end)
  end

  if stderr then
    uv.read_start(stderr, function(err, data)
      if data then
        table.insert(captured_stderr, data)
        if type(opts.stderr) == "function" then
          opts.stderr(data)
        end
      end
    end)
  end

  return handle, pid
end

---Check if devcontainer CLI is available
---@return boolean
function M.is_available()
  return executor.is_executable(CLI_COMMAND)
end

---Ensure devcontainer CLI is available - errors if not
function M.ensure_available()
  if not M.is_available() then
    error(
      "devcontainer CLI is not installed or not on PATH.\n"
        .. "Install it with: npm install -g @devcontainers/cli\n"
        .. "See: https://github.com/devcontainers/cli"
    )
  end
end

---Run devcontainer up to create and run a dev container
---Returns containerId, remoteUser, remoteWorkspaceFolder in result.data
---@param workspace_folder string path to workspace folder
---@param opts? table options
---@field config? string devcontainer.json path
---@field mounts? string[] additional mount strings (e.g., {"type=bind,source=/tmp,target=/tmp"})
---@field remote_env? table[string,string] remote environment variables
---@field default_user_env_probe? string "none" | "loginInteractiveShell" | "interactiveShell" | "loginShell"
---@field id_labels? string[] id labels
---@field include_configuration? boolean include configuration in output
---@field on_exit? fun(result: CliResult) callback
---@return table? handle, integer? pid
function M.up(workspace_folder, opts)
  opts = opts or {}
  M.ensure_available()

  local args = { "up", "--workspace-folder", workspace_folder }

  if opts.config then
    vim.list_extend(args, { "--config", opts.config })
  end

  if opts.mounts then
    for _, mount in ipairs(opts.mounts) do
      vim.list_extend(args, { "--mount", mount })
    end
  end

  if opts.remote_env then
    for k, v in pairs(opts.remote_env) do
      vim.list_extend(args, { "--remote-env", k .. "=" .. v })
    end
  end

  if opts.default_user_env_probe then
    vim.list_extend(args, { "--default-user-env-probe", opts.default_user_env_probe })
  end

  if opts.id_labels then
    for _, label in ipairs(opts.id_labels) do
      vim.list_extend(args, { "--id-label", label })
    end
  end

  if opts.include_configuration then
    table.insert(args, "--include-configuration")
  end

  return run_cli(args, opts)
end

---Run devcontainer exec to execute a command in a running container
---Can be called with container_id OR workspace_folder for container resolution
---@param target string|nil container ID or workspace folder path
---@param cmd string command to execute
---@param cmd_args? string[] command arguments
---@param opts? table options
---@field workspace_folder? string workspace folder (alternative to container_id target)
---@field remote_env? table[string,string] remote environment variables
---@field default_user_env_probe? string env probe type
---@field on_exit? fun(result: CliResult) callback
---@return table? handle, integer? pid
function M.exec(target, cmd, cmd_args, opts)
  opts = opts or {}
  M.ensure_available()

  -- Handle overloading: M.exec(container_id, cmd, opts) or M.exec(container_id, cmd, cmd_args, opts)
  if type(cmd_args) == "table" and not vim.islist(cmd_args) then
    opts = cmd_args
    cmd_args = nil
  else
  end

  local cli_args = { "exec" }

  -- Determine target: container_id or workspace_folder
  if type(target) == "string" then
    -- Check if it looks like a container ID (short hex) or workspace path
    if target:match("^/") or target:match("^%w:\\") then
      -- Looks like a workspace folder path
      vim.list_extend(cli_args, { "--workspace-folder", target })
    else
      -- Looks like a container ID
      vim.list_extend(cli_args, { "--container-id", target })
    end
  end

  table.insert(cli_args, cmd)

  if cmd_args then
    vim.list_extend(cli_args, cmd_args)
  end


 

  if opts.workspace_folder and (not target or not target:match("^/")) then
    vim.list_extend(cli_args, { "--workspace-folder", opts.workspace_folder })
  end

  if opts.remote_env then
    for k, v in pairs(opts.remote_env) do
      vim.list_extend(cli_args, { "--remote-env", k .. "=" .. v })
    end
  end

  if opts.default_user_env_probe then
    vim.list_extend(cli_args, { "--default-user-env-probe", opts.default_user_env_probe })
  end

  return run_cli(cli_args, opts)
end

---Stop a dev container by stopping and removing it
---@param workspace_folder string path to workspace folder
---@param opts? table options
---@field config? string devcontainer.json path
---@field on_exit? fun(result: CliResult) callback
---@return table? handle, integer? pid
function M.down(workspace_folder, opts)
  opts = opts or {}
  M.ensure_available()

  local args = { "up", "--remove-existing-container", "--expect-existing-container=false", "--workspace-folder", workspace_folder }

  if opts.config then
    vim.list_extend(args, { "--config", opts.config })
  end

  return run_cli(args, opts)
end

---Read devcontainer configuration without creating a container
---@param workspace_folder string path to workspace folder
---@param opts? table options
---@field config? string devcontainer.json path
---@field include_features? boolean include features configuration
---@field include_merged? boolean include merged configuration
---@field on_exit? fun(result: CliResult) callback
---@return table? handle, integer? pid
function M.read_config(workspace_folder, opts)
  opts = opts or {}
  M.ensure_available()

  local args = { "read-configuration", "--workspace-folder", workspace_folder }

  if opts.config then
    vim.list_extend(args, { "--config", opts.config })
  end

  if opts.include_features then
    table.insert(args, "--include-features-configuration")
  end

  if opts.include_merged then
    table.insert(args, "--include-merged-configuration")
  end

  return run_cli(args, opts)
end

---Build a dev container image
---@param workspace_folder string path to workspace folder
---@param opts? table options
---@field config? string devcontainer.json path
---@field on_exit? fun(result: CliResult) callback
---@return table? handle, integer? pid
function M.build(workspace_folder, opts)
  opts = opts or {}
  M.ensure_available()

  local args = { "build", "--workspace-folder", workspace_folder }

  if opts.config then
    vim.list_extend(args, { "--config", opts.config })
  end

  return run_cli(args, opts)
end

---Find a running container by workspace folder or container ID
---@param container_id string|nil container ID (if nil, searches by workspace)
---@param workspace_folder string|nil workspace folder path
---@param config_path string|nil devcontainer.json config path
---@param on_success? fun(container_id: string) callback with resolved container ID
---@param on_fail? fun(error: string) callback on failure
function M.find_container(container_id, workspace_folder, config_path, on_success, on_fail)
  local sched_on_success = vim.schedule_wrap(on_success)
  local sched_on_fail = vim.schedule_wrap(on_fail)

  if container_id then
    -- Direct container ID - verify it exists
    M.exec(container_id, "echo", { "test" }, {
      on_exit = function(result)
        if result.code == 0 then
          sched_on_success(container_id)
        else
          sched_on_fail("Container " .. container_id .. " not found or not running")
        end
      end,
    })
    return
  end

  if not workspace_folder then
    sched_on_fail("Either container_id or workspace_folder must be provided")
    return
  end

  -- Use exec with workspace_folder to find container via labels
  -- The CLI automatically resolves container by devcontainer.local_folder label
  M.exec(workspace_folder, "echo", { "test" }, {
    on_exit = function(result)
if result.code == 0 then
        -- Container exists, now get its ID via docker inspect
        local uv = vim.loop
        local normalized_path = vim.fn.fnamemodify(workspace_folder, ":p"):gsub("/$", "")
        local label = "devcontainer.local_folder=" .. normalized_path
        local stdout = uv.new_pipe(false)
        local stderr = uv.new_pipe(false)
        local captured_stdout = {}
        local captured_stderr = {}

        local handle, pid = uv.spawn(
          "docker",
          {
            stdio = { nil, stdout, stderr },
            args = { "ps", "-q", "--filter", "label=" .. label },
          },
          function(code, signal)
            handle_close(stdout)
            handle_close(stderr)
            if handle then
              handle_close(handle)
            end

            local full_stdout = table.concat(captured_stdout)

            if code == 0 then
              local container_ids = vim.split(full_stdout, "\n")
              local trimmed_ids = {}
              for _, cid in ipairs(container_ids) do
                local trimmed = cid:gsub("^%s*(.-)%s*$", "%1")
                if trimmed ~= "" then
                  table.insert(trimmed_ids, trimmed)
                end
              end
              if #trimmed_ids > 0 then
                sched_on_success(trimmed_ids[1])
              else
                sched_on_fail("No running container found for " .. workspace_folder)
              end
            else
              sched_on_fail("Could not find running container for " .. workspace_folder)
            end
          end
        )
        uv.read_start(stdout, function(_, data)
          if data then
            table.insert(captured_stdout, data)
          end
        end)
        uv.read_start(stderr, function(_, data)
          if data then
            table.insert(captured_stderr, data)
          end
        end)
      else
        sched_on_fail("No running container found for " .. workspace_folder)
      end
    end,
  })
end

log.wrap(M)
return M
