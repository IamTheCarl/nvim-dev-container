---@mod devcontainer.commands High level devcontainer commands
---@brief [[
---Provides functions representing high level devcontainer commands
---Uses devcontainer CLI for all container operations
---@brief ]]

local cli = require("devcontainer.cli")
local nvim = require("devcontainer.internal.nvim")
local log = require("devcontainer.internal.log")
local status = require("devcontainer.status")
local plugin_config = require("devcontainer.config")

local M = {}

---Wrap a callback so it runs in the main event loop (avoids E5560 in fast callbacks)
---@param fn function
---@return function
local function sched(fn)
  return vim.schedule_wrap(fn)
end

---Find the nearest .devcontainer.json or .devcontainer/devcontainer.json file
---@param start_path string path to start searching from
---@param callback fun(config_path: string|nil, config_dir: string|nil)
local function find_nearest_config(start_path, callback)
  local uv = vim.loop
  local current = vim.fn.fnamemodify(start_path or uv.cwd(), ":p")

  while current and current ~= "" do
    local possible_paths = {
      current .. "/.devcontainer/devcontainer.json",
      current .. "/.devcontainer.json",
    }

    for _, path in ipairs(possible_paths) do
      local handle = uv.fs_stat(path)
      if handle and handle.type == "file" then
        local config_dir = path:match("^(.+)/[^/]+$")
        callback(path, config_dir)
        return
      end
    end

    local parent = current:match("^(.+)/[^/]+/$") or current:match("^(.+)/[^/]+$")
    if not parent or parent == current then
      break
    end
    current = parent
  end

  callback(nil, nil)
end

---Run lifecycle commands in container
---@param config table parsed devcontainer.json data from CLI
---@param container_id string
local function run_lifecycle_commands(config, container_id)
  local function run_script(script)
    if not script then
      return
    end

    local cmd_args = {}
    if type(script) == "string" then
      cmd_args = { "/bin/sh", "-c", script }
    elseif vim.islist(script) then
      cmd_args = script
    end

    local exec_args = vim.list_extend({}, { unpack(cmd_args, 2) })
    cli.exec(container_id, cmd_args[1], exec_args, {
      on_exit = function(result)
        if result.code ~= 0 then
          log.fmt_warn("Lifecycle command failed: %s", script)
        end
      end,
    })
  end

  run_script(config.onCreateCommand)
  run_script(config.updateContentCommand)
  run_script(config.postCreateCommand)
end

---Run host-side lifecycle command (postAttachCommand runs on host)
---@param host_command string|table
local function run_host_lifecycle(host_command)
  if not host_command then
    return
  end

  local command
  local args = {}

  if vim.islist(host_command) then
    command = host_command[1]
    args = { unpack(host_command, 2) }
  elseif type(host_command) == "string" then
    command = "/bin/sh"
    args = { "-c", host_command }
  end

  if command then
    local executor = require("devcontainer.internal.executor")
    executor.run_command(command, {
      args = args,
      stderr = vim.schedule_wrap(function(_, output)
        if output then
          log.fmt_error("Host lifecycle command (%s): %s", command, output)
        end
      end),
    })
  end
end

---Attach to a running container with Neovim
---@param container_id string
---@param config_path string path to devcontainer.json
---@param config table parsed devcontainer.json data from CLI
---@param command string|table command to run (default: "nvim")
---@param on_success? function callback with config data
local function attach_to_container(container_id, config_path, config, command, on_success)
  command = command or "nvim"

  local function do_attach()
    if command == "nvim" and vim.fn.has("nvim-0.12") == 1 then
      local install_dir = plugin_config.nvim_install_dir or "$HOME/.nvim-devcontainer"
      local docker = plugin_config.docker_command or "docker"

      -- Pick a random ephemeral port for the container-side nvim listener.
      math.randomseed(os.time() + vim.fn.getpid())
      local port = math.random(40000, 49999)

      local remote_env = {}
      if plugin_config.remote_env then
        for k, v in pairs(plugin_config.remote_env) do
          remote_env[k] = v
        end
      end

      -- Launch headless nvim in the container, bound to 0.0.0.0:<port>.
      -- Reachable from the host via the container's docker-bridge IP.
      -- No authentication; acceptable for local-dev usage only.
      --
      -- AppRun sets VIMRUNTIME / LD_LIBRARY_PATH and execs nvim directly
      -- (no user-namespace chroot), so child processes spawned by :terminal,
      -- :!cmd, and LSP servers can reach the container's native /usr/bin,
      -- /bin, /lib, etc. — i.e. normal devcontainer semantics.
      local launch_script = "nohup " .. install_dir .. "/app/AppRun --headless"
        .. " --listen 0.0.0.0:" .. tostring(port)
        .. " >/dev/null 2>&1 &"
      cli.exec(container_id, "/bin/sh", { "-c", launch_script }, {
        remote_env = remote_env,
        on_exit = sched(function(result)
          if result.code ~= 0 then
            vim.notify("Failed to start Neovim in container: " .. (result.stderr or "unknown error"), vim.log.levels.ERROR)
            return
          end

          -- Resolve the container's IP on the docker bridge network.
          local inspect = vim.system({
            docker, "inspect",
            "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
            container_id,
          }, { text = true }):wait()
          if inspect.code ~= 0 then
            vim.notify("docker inspect failed: " .. (inspect.stderr or "unknown"), vim.log.levels.ERROR)
            return
          end
          local ip = vim.trim(inspect.stdout or "")
          if ip == "" then
            vim.notify("Could not resolve container IP for " .. container_id, vim.log.levels.ERROR)
            return
          end

          local target = ip .. ":" .. tostring(port)

          local function do_connect()
            -- Defer the :connect outside the scheduled cli.exec callback;
            -- invoking it from within a vim.schedule_wrap context causes the
            -- TUI to exit shortly after a successful connect.
            vim.defer_fn(function()
              local ok, cerr = pcall(vim.cmd, "connect " .. target)
              if not ok then
                vim.notify("connect failed: " .. tostring(cerr), vim.log.levels.ERROR)
                return
              end
              vim.notify("Connected to Neovim in container! Use :detach to disconnect.")
              if type(on_success) == "function" then
                on_success(config)
              end
            end, 500)
          end
          if #vim.api.nvim_list_uis() > 0 then
            do_connect()
          else
            vim.api.nvim_create_autocmd("UIEnter", {
              once = true,
              callback = do_connect,
            })
          end
        end),
      })
    else
      local remote_env = {}
      if plugin_config.remote_env then
        for k, v in pairs(plugin_config.remote_env) do
          remote_env[k] = v
        end
      end
      cli.exec(container_id, command, {
        remote_env = remote_env,
        on_exit = sched(function(result)
          if result.code == 0 then
            if type(on_success) == "function" then
              on_success(config)
            end
          else
            vim.notify("Failed to attach to container: " .. (result.stderr or "unknown error"), vim.log.levels.ERROR)
          end
        end),
      })
    end
  end

  if command == "nvim" then
    nvim.is_installed(container_id, {
      on_success = function()
        do_attach()
      end,
      on_fail = sched(function()
        vim.notify("Neovim not found in container; installing via Nix bundle...", vim.log.levels.INFO)
        nvim.add_neovim(container_id, {
          on_success = sched(function()
            do_attach()
          end),
          on_fail = sched(function(err)
            vim.notify(
              "Failed to install Neovim into container: " .. (err or "unknown"),
              vim.log.levels.ERROR
            )
          end),
        })
      end),
    })
  else
    do_attach()
  end
end

---Main attach function - the core of DevcontainerAttach command
---@param opts? table options
---@field config_path? string specific config file path
---@field command? string|table command to run in container
---@field callback? function success callback
function M.attach(opts)
  opts = opts or {}

  local config_path = opts.config_path
  local config_dir

  local function on_config_found(path, dir)
    config_path = path
    config_dir = dir

    -- Use CLI to parse the config (handles JSONC properly)
    cli.read_config(config_dir or vim.loop.cwd(), {
      config = config_path,
      include_merged = true,
      on_exit = sched(function(read_result)
        if read_result.code ~= 0 then
          vim.notify("Failed to read devcontainer config: " .. (read_result.error or "unknown error"), vim.log.levels.ERROR)
          return
        end

        local raw_data = read_result.data
        local config = raw_data and raw_data.mergedConfiguration or raw_data and raw_data.configuration
        if not config then
          vim.notify("No configuration found in devcontainer config", vim.log.levels.ERROR)
          return
        end

        local workspace_folder = vim.fn.fnamemodify(config_dir, ":h") or vim.loop.cwd()

        cli.find_container(nil, workspace_folder, config_path, function(container_id)
          -- Container already exists, attach to it directly
          local container_status = {
            container_id = container_id,
            autoremove = false,
          }
          status.add_container(container_status)

          attach_to_container(
            container_id,
            config_path,
            config,
            opts.command,
            function()
              run_host_lifecycle(config and config.postAttachCommand)
              if type(opts.callback) == "function" then
                opts.callback(config)
              end
            end
          )
        end, function(err)
          -- Container doesn't exist, create it
          cli.up(workspace_folder, {
            config = config_path,
            include_configuration = true,
            on_exit = sched(function(result)
              if result.code ~= 0 then
                vim.notify("Failed to start devcontainer: " .. (result.error or "unknown error"), vim.log.levels.ERROR)
                return
              end

              local container_id = result.data and result.data.containerId
              if not container_id then
                vim.notify("No container ID returned from devcontainer up", vim.log.levels.ERROR)
                return
              end

              local container_status = {
                container_id = container_id,
                image_id = result.data.configuration and result.data.configuration.image or nil,
                autoremove = false,
                workspace_dir = result.data and result.data.remoteWorkspaceFolder or nil,
              }
              status.add_container(container_status)

              run_lifecycle_commands(config, container_id)

              attach_to_container(
                container_id,
                config_path,
                config,
                opts.command,
                function()
                  run_host_lifecycle(config and config.postAttachCommand)
                  if type(opts.callback) == "function" then
                    opts.callback(config)
                  end
                end
              )
            end),
          })
        end)
      end),
    })
  end

  if config_path then
    config_dir = config_path:match("^(.+)/[^/]+$")
    on_config_found(config_path, config_dir)
  else
    find_nearest_config(
      plugin_config.config_search_start() or vim.loop.cwd(),
      function(path, dir)
        if path then
          on_config_found(path, dir)
        else
          vim.notify("No devcontainer.json found in workspace", vim.log.levels.ERROR)
        end
      end
    )
  end
end

---Stop the devcontainer for the given config
---@param opts? table options
---@field config_path? string specific config file path
---@field callback? function success callback
function M.stop(opts)
  opts = opts or {}

  local function on_config_found(path, dir)
    cli.recreate(dir or vim.loop.cwd(), {
      config = path,
      on_exit = sched(function(result)
        if result.code == 0 then
          vim.notify("Devcontainer stopped successfully")
          if type(opts.callback) == "function" then
            opts.callback()
          end
        else
          vim.notify("Failed to stop devcontainer: " .. (result.error or "unknown error"), vim.log.levels.ERROR)
        end
      end),
    })
  end

  if opts.config_path then
    local dir = opts.config_path:match("^(.+)/[^/]+$")
    on_config_found(opts.config_path, dir)
  else
    find_nearest_config(
      plugin_config.config_search_start() or vim.loop.cwd(),
      function(path, dir)
        if path then
          on_config_found(path, dir)
        else
          vim.notify("No devcontainer.json found in workspace", vim.log.levels.ERROR)
        end
      end
    )
  end
end

---Execute a command in the running devcontainer
---@param command string|table command to execute
---@param opts? table options
---@field config_path? string specific config file path
---@field callback? function success callback with output
function M.exec(command, opts)
  opts = opts or {}

  local target_container = nil

  if opts.container_id then
    target_container = opts.container_id
  else
    find_nearest_config(
      plugin_config.config_search_start() or vim.loop.cwd(),
      function(path, dir)
        if path then
          cli.exec(dir, "echo", { "test" }, {
            on_exit = sched(function(result)
              if result.code == 0 then
                if type(opts.callback) == "function" then
                  opts.callback(result.stdout)
                end
              else
                vim.notify("No running devcontainer found", vim.log.levels.ERROR)
              end
            end),
          })
        else
          vim.notify("No devcontainer.json found in workspace", vim.log.levels.ERROR)
        end
      end
    )
    return
  end

  local cmd_args = {}
  local cmd_str

  if type(command) == "string" then
    cmd_str = command
  else
    cmd_str = command[1]
    cmd_args = { unpack(command, 2) }
  end

  cli.exec(target_container, cmd_str, cmd_args, {
    on_exit = sched(function(result)
      if result.code == 0 then
        if type(opts.callback) == "function" then
          opts.callback(result.stdout)
        else
          vim.notify("Command executed successfully: " .. cmd_str)
        end
      else
        vim.notify(
          "Command failed: "
            .. cmd_str
            .. "\nError: "
            .. (result.stderr or result.stdout or "unknown error"),
          vim.log.levels.ERROR
        )
      end
    end),
  })
end

---Open the log file
function M.open_logs()
  local log_module = require("devcontainer.internal.log")
  vim.cmd("edit " .. log_module.logfile)
end

---Add Neovim to the running devcontainer
---@param opts? table options
---@field callback? function success callback
function M.add_neovim(opts)
  opts = opts or {}

  find_nearest_config(
    plugin_config.config_search_start() or vim.loop.cwd(),
    function(config_path, config_dir)
      if not config_path then
        vim.notify("No devcontainer.json found in workspace", vim.log.levels.ERROR)
        return
      end

      local workspace_folder = vim.fn.fnamemodify(config_dir, ":h") or vim.loop.cwd()

      cli.find_container(nil, workspace_folder, config_path, function(container_id)
        nvim.add_neovim(container_id, {
          on_success = sched(function()
            vim.notify("Neovim added successfully to container " .. container_id, vim.log.levels.INFO)
            if type(opts.callback) == "function" then
              opts.callback()
            end
          end),
          on_fail = sched(function()
            vim.notify("Failed to add Neovim to container", vim.log.levels.ERROR)
          end),
        })
      end, function(err)
        vim.notify("No running devcontainer found: " .. err, vim.log.levels.ERROR)
      end)
    end
  )
end

---Open or create nearest devcontainer.json config
function M.edit_config()
  find_nearest_config(
    plugin_config.config_search_start() or vim.loop.cwd(),
    function(path, dir)
      local edit_path = path
      if not path then
        local project_root = plugin_config.workspace_folder_provider()
        vim.fn.mkdir(project_root .. "/.devcontainer", "p")
        edit_path = project_root .. "/.devcontainer/devcontainer.json"
      end
      vim.cmd("edit " .. edit_path)
      vim.cmd("setlocal filetype=jsonc")
      if not path then
        local template = plugin_config.devcontainer_json_template()
        if template then
          vim.api.nvim_buf_set_lines(0, 0, -1, false, template)
        end
      end
    end
  )
end

log.wrap(M)

-- Internal exports for testing only. Not part of the public API.
M._internal = {
  find_nearest_config = find_nearest_config,
}

return M
