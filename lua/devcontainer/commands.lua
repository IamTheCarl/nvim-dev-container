---@mod devcontainer.commands High level devcontainer commands
---@brief [[
---Provides functions representing high level devcontainer commands
---Uses devcontainer CLI for all container operations
---@brief ]]

local cli = require("devcontainer.cli")
local nvim = require("devcontainer.internal.nvim")
local installer = require("devcontainer.internal.installer")
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
---@param extra_cli_args? string[] additional devcontainer CLI arguments to pass through
---@param output_buf? table output buffer for displaying progress
---@param on_success? function callback with config data
local function attach_to_container(container_id, config_path, config, command, extra_cli_args, output_buf, on_success)
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

      -- Determine the shell to use for &shell in the container-side nvim.
      -- Option C: explicit override via nvim_shell config.
      -- Option B: auto-detect from container's /etc/passwd for remoteUser.
      local function launch_with_shell(shell)
        remote_env["SHELL"] = shell

        -- Change into the workspace directory before launching nvim so the
        -- server's cwd matches the project root. Falls back to the image's
        -- WORKDIR when workspaceFolder is not set in devcontainer.json.
        local workspace_dir = config and config.workspaceFolder
        local cd_prefix = workspace_dir and ("cd " .. vim.fn.shellescape(workspace_dir) .. " && ") or ""
        -- When .direct_exec is present the installer has symlinked /nix/store so
        -- nvim can be run directly from the entrypoint without AppRun's bwrap
        -- user-namespace.  This restores sudo (and other setuid helpers) inside
        -- :terminal sessions.  Falls back to AppRun when the marker is absent.
        local launch_script = cd_prefix
          .. string.format(
            "d=%s; if [ -e \"$d/.direct_exec\" ]; then NVIM_LAUNCHER=\"$d/app/entrypoint\"; else NVIM_LAUNCHER=\"$d/app/AppRun\"; fi; nohup \"$NVIM_LAUNCHER\" --headless --listen 0.0.0.0:%d >/dev/null 2>&1 &",
            install_dir, port
          )
        cli.exec(container_id, "/bin/sh", { "-c", launch_script }, {
        remote_env = remote_env,
        extra_cli_args = extra_cli_args,
        on_exit = sched(function(result)
          if result.code ~= 0 then
            if output_buf then
              output_buf:append("Failed to start Neovim in container: " .. (result.stderr or "unknown error"), "stderr")
              output_buf:finalize("error")
            end
            vim.notify("Failed to start Neovim in container: " .. (result.stderr or "unknown error"), vim.log.levels.ERROR)
            return
          end

          if output_buf then
            output_buf:append_progress("Neovim started, connecting...")
          end

          -- Resolve the container's IP on the docker bridge network.
          local inspect = vim.system({
            docker, "inspect",
            "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
            container_id,
          }, { text = true }):wait()
          if inspect.code ~= 0 then
            if output_buf then
              output_buf:append("docker inspect failed: " .. (inspect.stderr or "unknown"), "stderr")
              output_buf:finalize("error")
            end
            vim.notify("docker inspect failed: " .. (inspect.stderr or "unknown"), vim.log.levels.ERROR)
            return
          end
          local ip = vim.trim(inspect.stdout or "")
          if ip == "" then
            if output_buf then
              output_buf:append("Could not resolve container IP for " .. container_id, "stderr")
              output_buf:finalize("error")
            end
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
                if output_buf then
                  output_buf:append("connect failed: " .. tostring(cerr), "stderr")
                  output_buf:finalize("error")
                end
                vim.notify("connect failed: " .. tostring(cerr), vim.log.levels.ERROR)
                return
              end
              if output_buf then
                output_buf:append_progress("✓ Connected to Neovim in container!")
                output_buf:finalize("success")
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
        stdout = output_buf and function(data)
          if data then
            output_buf:append(data, "stdout")
          end
        end or nil,
        stderr = output_buf and function(data)
          if data then
            output_buf:append(data, "stderr")
          end
        end or nil,
      })
      end -- launch_with_shell

      -- Dispatch: use explicit override (Option C) or auto-detect (Option B).
      if plugin_config.nvim_shell then
        launch_with_shell(plugin_config.nvim_shell)
      else
        local remote_user = config and config.remoteUser
        cli.get_remote_shell(container_id, remote_user, launch_with_shell)
      end
    else
      local remote_env = {}
      if plugin_config.remote_env then
        for k, v in pairs(plugin_config.remote_env) do
          remote_env[k] = v
        end
      end
        cli.exec(container_id, command, {
         remote_env = remote_env,
         extra_cli_args = extra_cli_args,
         on_exit = sched(function(result)
           if output_buf then
             if result.code == 0 then
               output_buf:append_progress("✓ Command completed successfully")
               output_buf:finalize("success")
             else
               output_buf:append("Failed to attach to container: " .. (result.stderr or "unknown error"), "stderr")
               output_buf:finalize("error")
             end
           end
           if result.code == 0 then
             if type(on_success) == "function" then
               on_success(config)
             end
           else
             vim.notify("Failed to attach to container: " .. (result.stderr or "unknown error"), vim.log.levels.ERROR)
           end
         end),
         stdout = output_buf and function(data)
           if data then
             output_buf:append(data, "stdout")
           end
         end or nil,
         stderr = output_buf and function(data)
           if data then
             output_buf:append(data, "stderr")
           end
         end or nil,
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
---@field extra_cli_args? string[] additional devcontainer CLI arguments to pass through
---@field callback? function success callback
function M.attach(opts)
  opts = opts or {}
  local show_output = opts.show_output ~= false

  local output_buf
  if show_output then
    local output_buffer = require("devcontainer.internal.output_buffer")
    output_buf = output_buffer("Attach")
  end

  local config_path = opts.config_path
  local config_dir

  local function on_config_found(path, dir)
    config_path = path
    config_dir = dir

    if output_buf then
      output_buf:append_progress("Reading configuration...")
    end

    -- Use CLI to parse the config (handles JSONC properly)
    cli.read_config(config_dir or vim.loop.cwd(), {
      config = config_path,
      include_merged = true,
      extra_cli_args = opts.extra_cli_args,
      on_exit = sched(function(read_result)
        if read_result.code ~= 0 then
          if output_buf then
            output_buf:append("Failed to read devcontainer config: " .. (read_result.error or "unknown error"), "stderr")
            output_buf:finalize("error")
          end
          vim.notify("Failed to read devcontainer config: " .. (read_result.error or "unknown error"), vim.log.levels.ERROR)
          return
        end

        if output_buf then
          output_buf:append_progress("Configuration loaded")
        end

        local raw_data = read_result.data
        local config = raw_data and raw_data.mergedConfiguration or raw_data and raw_data.configuration
        if not config then
          if output_buf then
            output_buf:append("No configuration found in devcontainer config", "stderr")
            output_buf:finalize("error")
          end
          vim.notify("No configuration found in devcontainer config", vim.log.levels.ERROR)
          return
        end

        local workspace_folder = vim.fn.fnamemodify(config_dir, ":h") or vim.loop.cwd()

        if output_buf then
          output_buf:append_progress("Finding/starting container...")
        end

        cli.find_container(nil, workspace_folder, config_path, function(container_id)
          -- Container already exists, attach to it directly
          local container_status = {
            container_id = container_id,
            autoremove = false,
          }
          status.add_container(container_status)

          if output_buf then
            output_buf:append_progress("Container ready")
          end

          attach_to_container(
            container_id,
            config_path,
            config,
            opts.command,
            opts.extra_cli_args,
            output_buf,
            function()
              run_host_lifecycle(config and config.postAttachCommand)
              if type(opts.callback) == "function" then
                opts.callback(config)
              end
            end
          )
        end, function(err)
          -- Container doesn't exist, create it
          if output_buf then
            output_buf:append_progress("Starting new container...")
          end

          cli.up(workspace_folder, {
            config = config_path,
            include_configuration = true,
            extra_cli_args = opts.extra_cli_args,
            on_exit = sched(function(result)
              if result.code ~= 0 then
                if output_buf then
                  output_buf:append("Failed to start devcontainer: " .. (result.error or "unknown error"), "stderr")
                  output_buf:finalize("error")
                end
                vim.notify("Failed to start devcontainer: " .. (result.error or "unknown error"), vim.log.levels.ERROR)
                return
              end

              if output_buf then
                output_buf:append_progress("Container started")
              end

              local container_id = result.data and result.data.containerId
              if not container_id then
                if output_buf then
                  output_buf:append("No container ID returned from devcontainer up", "stderr")
                  output_buf:finalize("error")
                end
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
                 opts.extra_cli_args,
                 output_buf,
                 function()
                   run_host_lifecycle(config and config.postAttachCommand)
                   if type(opts.callback) == "function" then
                     opts.callback(config)
                   end
                 end
               )
            end),
            stdout = output_buf and function(data)
              if data then
                output_buf:append(data, "stdout")
              end
            end or nil,
            stderr = output_buf and function(data)
              if data then
                output_buf:append(data, "stderr")
              end
            end or nil,
          })
        end)
      end),
      stdout = output_buf and function(data)
        if data then
          output_buf:append(data, "stdout")
        end
      end or nil,
      stderr = output_buf and function(data)
        if data then
          output_buf:append(data, "stderr")
        end
      end or nil,
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
    local workspace_folder = dir and vim.fn.fnamemodify(dir, ":h") or vim.loop.cwd()
    cli.recreate(workspace_folder, {
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

---Build a devcontainer image
---@param opts? table options
---@field config_path? string specific config file path
---@field extra_cli_args? string[] additional devcontainer CLI arguments to pass through
---@field no_cache? boolean skip Docker cache (force full rebuild)
---@field show_output? boolean show output buffer (default: true)
---@field callback? function success callback
function M.build(opts)
  opts = opts or {}
  local show_output = opts.show_output ~= false

  local output_buf
  if show_output then
    local output_buffer = require("devcontainer.internal.output_buffer")
    output_buf = output_buffer("Build")
  end

  local function on_config_found(path, dir)
    local config_name = path:match("([^/]+)/devcontainer%.json$") or "devcontainer"
    local workspace_folder = dir and vim.fn.fnamemodify(dir, ":h") or vim.loop.cwd()

    local function do_build()
      local build_args = {}
      if opts.no_cache then
        table.insert(build_args, "--no-cache")
      end

      if opts.extra_cli_args then
        vim.list_extend(build_args, opts.extra_cli_args)
      end

      if output_buf then
        output_buf:append_progress("Building container image...")
      end

       cli.build(workspace_folder, {
         config = path,
         extra_cli_args = #build_args > 0 and build_args or nil,
         on_exit = sched(function(result)
           if output_buf then
             if result.code == 0 then
               output_buf:finalize("success")
               vim.notify("Devcontainer build completed successfully", vim.log.levels.INFO)
             else
               local error_msg = result.error or "unknown error"
               -- Decode JSON error messages if present
               local output_buffer = require("devcontainer.internal.output_buffer")
               error_msg = output_buffer.decode_json_log(error_msg)
               output_buf:append("Error: " .. error_msg, "stderr")
               output_buf:finalize("error")
               vim.notify("Failed to build devcontainer: " .. error_msg, vim.log.levels.ERROR)
             end
           else
             if result.code == 0 then
               vim.notify("Devcontainer build completed successfully", vim.log.levels.INFO)
             else
               vim.notify("Failed to build devcontainer: " .. (result.error or "unknown error"), vim.log.levels.ERROR)
             end
           end

           if type(opts.callback) == "function" then
             opts.callback()
           end
         end),
        stdout = output_buf and function(data)
          if data then
            output_buf:append(data, "stdout")
          end
        end or nil,
        stderr = output_buf and function(data)
          if data then
            output_buf:append(data, "stderr")
          end
        end or nil,
      })
    end

    if output_buf then
      output_buf:append_progress("Reading configuration...")
    end

    cli.read_config(dir or vim.loop.cwd(), {
      config = path,
      include_merged = true,
      extra_cli_args = opts.extra_cli_args,
       on_exit = sched(function(read_result)
         if read_result.code ~= 0 then
           if output_buf then
             local error_msg = read_result.error or "unknown error"
             -- Decode JSON error messages if present
             local output_buffer = require("devcontainer.internal.output_buffer")
             error_msg = output_buffer.decode_json_log(error_msg)
             output_buf:append("Error: " .. error_msg, "stderr")
             output_buf:finalize("error")
           end
           vim.notify("Failed to read devcontainer config: " .. (read_result.error or "unknown error"), vim.log.levels.ERROR)
           return
         end

         if output_buf then
           output_buf:append_progress("Configuration loaded")
         end
         do_build()
       end),
      stdout = output_buf and function(data)
        if data then
          output_buf:append(data, "stdout")
        end
      end or nil,
      stderr = output_buf and function(data)
        if data then
          output_buf:append(data, "stderr")
        end
      end or nil,
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
          if output_buf then
            output_buf:append("No devcontainer.json found in workspace", "stderr")
            output_buf:finalize("error")
          end
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

---Clear the host-side Nix bundle cache, and (if a container can be
---located for the current workspace) also wipe the extracted nvim
---install directory inside that container. Without the second step
---the in-container `is_installed` probe keeps returning true and the
---next attach silently keeps using the stale install.
function M.clear_cache()
  installer.clear_cache()
  vim.notify("Host Nix bundle cache cleared.")

  find_nearest_config(
    plugin_config.config_search_start() or vim.loop.cwd(),
    function(config_path, config_dir)
      if not config_path then
        -- No workspace context; host-side clear is all we can do.
        return
      end

      local workspace_folder = vim.fn.fnamemodify(config_dir, ":h") or vim.loop.cwd()

      cli.find_container(nil, workspace_folder, config_path, function(container_id)
        local install_dir = plugin_config.nvim_install_dir or "$HOME/.nvim-devcontainer"
        cli.exec(container_id, "/bin/sh", { "-c", 'rm -rf "' .. install_dir .. '"' }, {
          on_exit = sched(function(result)
            if result.code == 0 then
              vim.notify(
                "Cleared nvim install in container " .. container_id .. " (" .. install_dir .. ")"
              )
            else
              vim.notify(
                "Failed to clear in-container nvim install (exit "
                  .. tostring(result.code)
                  .. "); remove "
                  .. install_dir
                  .. " manually inside the container.",
                vim.log.levels.WARN
              )
            end
          end),
        })
      end, function(_err)
        -- No running container; nothing in-container to clear.
      end)
    end
  )
end

---Perform an overwrite check and optional confirmation, then run a docker cp.
---@param container_id string
---@param src_basename string basename of the source (for dir-inside-dir check)
---@param resolved_dest string already-resolved container-side or host-side destination path
---@param dest_is_container boolean true if dest is container-side
---@param force boolean skip confirmation when true
---@param do_copy fun() called if copy should proceed
---@param callback fun(proceed: boolean)
local function check_overwrite(container_id, src_basename, resolved_dest, dest_is_container, force, callback)
  local function confirm(path)
    if force then
      callback(true)
      return
    end
    vim.schedule(function()
      vim.ui.select({ "Yes", "No" }, { prompt = "Overwrite " .. path .. "?" }, function(choice)
        callback(choice == "Yes")
      end)
    end)
  end

  if dest_is_container then
    cli.stat_in_container(container_id, resolved_dest, function(stat, _err)
      if not stat or not stat.exists then
        callback(true)
        return
      end
      if stat.is_dir then
        local combined = resolved_dest:gsub("/$", "") .. "/" .. src_basename
        cli.stat_in_container(container_id, combined, function(inner_stat, _)
          if inner_stat and inner_stat.exists then
            confirm(combined)
          else
            callback(true)
          end
        end)
      else
        confirm(resolved_dest)
      end
    end)
  else
    -- Host-side stat
    local stat = vim.loop.fs_stat(resolved_dest)
    if not stat then
      callback(true)
      return
    end
    if stat.type == "directory" then
      local combined = resolved_dest:gsub("/$", "") .. "/" .. src_basename
      local inner = vim.loop.fs_stat(combined)
      if inner then
        confirm(combined)
      else
        callback(true)
      end
    else
      confirm(resolved_dest)
    end
  end
end

---Copy one or more host files/directories into the running devcontainer.
---Follows scp semantics: last positional arg is the destination; multiple
---sources are allowed but require the destination to be a directory.
---Container-side paths are shell-expanded (supports `~`, `$HOME`, etc.).
---@param host_sources string[] source paths on the host (expanded via vim.fn.expand)
---@param container_dest string destination path inside the container
---@param opts? table
---@field force? boolean skip overwrite confirmation (bang form)
---@field follow_link? boolean follow symlinks on source (-L)
function M.copy_in(host_sources, container_dest, opts)
  opts = opts or {}
  local force = opts.force or false
  local follow_link = opts.follow_link or false

  -- Expand host-side paths
  local expanded_sources = {}
  for _, src in ipairs(host_sources) do
    table.insert(expanded_sources, vim.fn.expand(src))
  end

  find_nearest_config(
    plugin_config.config_search_start() or vim.loop.cwd(),
    function(config_path, config_dir)
      if not config_path then
        vim.notify("No devcontainer.json found in workspace", vim.log.levels.ERROR)
        return
      end

      local workspace_folder = vim.fn.fnamemodify(config_dir, ":h") or vim.loop.cwd()

      cli.find_container(nil, workspace_folder, config_path, function(container_id)
        -- Validate all sources exist on host
        for _, src in ipairs(expanded_sources) do
          if not vim.loop.fs_stat(src) then
            vim.notify("Source does not exist: " .. src, vim.log.levels.ERROR)
            return
          end
        end

        -- Resolve container destination through in-container shell
        cli.resolve_container_path(container_id, container_dest, function(resolved_dest, err)
          if not resolved_dest then
            vim.notify("Failed to resolve container path: " .. (err or "unknown error"), vim.log.levels.ERROR)
            return
          end

          -- For multiple sources the destination must be a directory
          if #expanded_sources > 1 then
            cli.stat_in_container(container_id, resolved_dest, function(stat, _)
              if not (stat and stat.is_dir) then
                vim.notify(
                  "Destination must be an existing directory when copying multiple sources",
                  vim.log.levels.ERROR
                )
                return
              end
              -- Copy each source sequentially
              local i = 0
              local results = {}
              local function copy_next()
                i = i + 1
                if i > #expanded_sources then
                  local failed = 0
                  for _, r in ipairs(results) do
                    if r ~= 0 then
                      failed = failed + 1
                    end
                  end
                  if failed == 0 then
                    vim.notify(
                      "Copied " .. #expanded_sources .. " item(s) into container " .. container_id
                    )
                  else
                    vim.notify(
                      tostring(failed) .. " of " .. #expanded_sources .. " copy operation(s) failed",
                      vim.log.levels.WARN
                    )
                  end
                  return
                end
                local src = expanded_sources[i]
                local basename = src:match("[^/]+$") or src
                check_overwrite(container_id, basename, resolved_dest, true, force, function(proceed)
                  if not proceed then
                    vim.notify("Skipped: " .. src)
                    table.insert(results, 0)
                    copy_next()
                    return
                  end
                  cli.copy_to_container(container_id, src, resolved_dest, {
                    follow_link = follow_link,
                    on_exit = function(result)
                      table.insert(results, result.code)
                      if result.code ~= 0 then
                        vim.notify("Failed to copy " .. src .. ": " .. result.stderr, vim.log.levels.ERROR)
                      end
                      copy_next()
                    end,
                  })
                end)
              end
              copy_next()
            end)
          else
            -- Single source
            local src = expanded_sources[1]
            local basename = src:match("[^/]+$") or src
            check_overwrite(container_id, basename, resolved_dest, true, force, function(proceed)
              if not proceed then
                vim.notify("Copy cancelled.")
                return
              end
              cli.copy_to_container(container_id, src, resolved_dest, {
                follow_link = follow_link,
                on_exit = function(result)
                  if result.code == 0 then
                    vim.notify("Copied " .. src .. " into container " .. container_id)
                  else
                    vim.notify("Copy failed: " .. result.stderr, vim.log.levels.ERROR)
                  end
                end,
              })
            end)
          end
        end)
      end, function(err)
        vim.notify("No running devcontainer found: " .. err, vim.log.levels.ERROR)
      end)
    end
  )
end

---Copy one or more files/directories out of the running devcontainer to the host.
---Follows scp semantics: last positional arg is the destination; multiple
---sources are allowed but require the destination to be an existing directory.
---Container-side paths are shell-expanded (supports `~`, `$HOME`, etc.).
---@param container_sources string[] source paths inside the container
---@param host_dest string destination path on the host (expanded via vim.fn.expand)
---@param opts? table
---@field force? boolean skip overwrite confirmation (bang form)
---@field follow_link? boolean follow symlinks on source (-L)
function M.copy_out(container_sources, host_dest, opts)
  opts = opts or {}
  local force = opts.force or false
  local follow_link = opts.follow_link or false
  local expanded_host_dest = vim.fn.expand(host_dest)

  find_nearest_config(
    plugin_config.config_search_start() or vim.loop.cwd(),
    function(config_path, config_dir)
      if not config_path then
        vim.notify("No devcontainer.json found in workspace", vim.log.levels.ERROR)
        return
      end

      local workspace_folder = vim.fn.fnamemodify(config_dir, ":h") or vim.loop.cwd()

      cli.find_container(nil, workspace_folder, config_path, function(container_id)
        -- Resolve all container sources
        local resolved_sources = {}
        local pending = #container_sources

        local function on_all_resolved()
          -- For multiple sources the host destination must be a directory
          if #resolved_sources > 1 then
            local dest_stat = vim.loop.fs_stat(expanded_host_dest)
            if not (dest_stat and dest_stat.type == "directory") then
              vim.notify(
                "Destination must be an existing directory when copying multiple sources",
                vim.log.levels.ERROR
              )
              return
            end
          end

          local i = 0
          local results = {}
          local function copy_next()
            i = i + 1
            if i > #resolved_sources then
              local failed = 0
              for _, r in ipairs(results) do
                if r ~= 0 then
                  failed = failed + 1
                end
              end
              if failed == 0 then
                vim.notify(
                  "Copied " .. #resolved_sources .. " item(s) from container " .. container_id
                )
              else
                vim.notify(
                  tostring(failed) .. " of " .. #resolved_sources .. " copy operation(s) failed",
                  vim.log.levels.WARN
                )
              end
              return
            end

            local rsrc = resolved_sources[i]
            local basename = rsrc:match("[^/]+$") or rsrc
            check_overwrite(container_id, basename, expanded_host_dest, false, force, function(proceed)
              if not proceed then
                vim.notify("Skipped: " .. rsrc)
                table.insert(results, 0)
                copy_next()
                return
              end
              cli.copy_from_container(container_id, rsrc, expanded_host_dest, {
                follow_link = follow_link,
                on_exit = function(result)
                  table.insert(results, result.code)
                  if result.code ~= 0 then
                    vim.notify("Failed to copy " .. rsrc .. ": " .. result.stderr, vim.log.levels.ERROR)
                  end
                  copy_next()
                end,
              })
            end)
          end
          copy_next()
        end

        -- Resolve each source path sequentially, collecting results
        local resolve_idx = 0
        local function resolve_next()
          resolve_idx = resolve_idx + 1
          if resolve_idx > #container_sources then
            on_all_resolved()
            return
          end
          cli.resolve_container_path(container_id, container_sources[resolve_idx], function(resolved, err)
            if not resolved then
              vim.notify(
                "Failed to resolve container path '" .. container_sources[resolve_idx] .. "': " .. (err or ""),
                vim.log.levels.ERROR
              )
              return
            end
            table.insert(resolved_sources, resolved)
            resolve_next()
          end)
        end
        resolve_next()
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
