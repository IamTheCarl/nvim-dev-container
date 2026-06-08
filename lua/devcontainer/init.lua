---@mod devcontainer Main devcontainer module - used to setup the plugin
---@brief [[
---Provides setup function
---@brief ]]
local M = {}

local config = require("devcontainer.config")
local commands = require("devcontainer.commands")
local log = require("devcontainer.internal.log")
local v = require("devcontainer.internal.validation")

local configured = false

---@class DevcontainerAutocommandOpts
---@field init? boolean|string set to true (or "ask" to prompt before starting) to enable automatic devcontainer start
---@field clean? boolean set to true to enable automatic devcontainer stop and clean on VimLeavePre
---@field update? boolean set to true to enable automatic devcontainer update when config file is changed

---@class DevcontainerSetupOpts
---@field config_search_start? function provides starting point for .devcontainer.json search
---@field workspace_folder_provider? function provides current workspace folder
---@field devcontainer_json_template? function provides template for new .devcontainer.json files - returns table
---@field nvim_nix_attribute? string Nix flake attribute used to bundle Neovim for the container (default `nixpkgs#neovim`)
---@field nvim_install_dir? string Install directory inside the container (default `$HOME/.nvim-devcontainer`)
---@field nvim_cache_versions? integer Number of cached Nix bundles to retain on host (default 3)
---@field docker_command? string Name of the docker binary on PATH (default `docker`)
---@field generate_commands? boolean can be set to false to prevent plugin from creating commands (true by default)
---@field autocommands? DevcontainerAutocommandOpts can be set to enable autocommands, disabled by default
---@field log_level? LogLevel can be used to override library logging level
---@field remote_env? table can be used to override remoteEnv when attaching to containers
---@field disable_recursive_config_search? boolean can be used to disable recursive .devcontainer search
---@field cli_path? string path to devcontainer CLI executable (useful for Nix installations)
---@field nvim_shell? string shell to use inside the container for &shell (nil = auto-detect from /etc/passwd)

---Starts the plugin and sets it up with provided options
---@param opts? DevcontainerSetupOpts
function M.setup(opts)
  if configured then
    log.info("Already configured, skipping!")
    return
  end

  vim.validate("opts", opts, "table")
  opts = opts or {}
  v.validate_opts(opts, {
    config_search_start = "function",
    workspace_folder_provider = "function",
    devcontainer_json_template = "function",
    nvim_nix_attribute = function(t)
      return t == nil or type(t) == "string"
    end,
    nvim_install_dir = function(t)
      return t == nil or type(t) == "string"
    end,
    nvim_cache_versions = function(t)
      return t == nil or type(t) == "number"
    end,
    docker_command = function(t)
      return t == nil or type(t) == "string"
    end,
    generate_commands = "boolean",
    autocommands = "table",
    log_level = "string",
    remote_env = "table",
    disable_recursive_config_search = "boolean",
    cli_path = function(t)
      return t == nil or type(t) == "string"
    end,
    nvim_shell = function(t)
      return t == nil or type(t) == "string"
    end,
  })

  if opts.autocommands then
    v.validate_deep(opts.autocommands, "opts.autocommands", {
      init = { "boolean", "string" },
      clean = "boolean",
      update = "boolean",
    })
  end

  configured = true

  config.devcontainer_json_template = opts.devcontainer_json_template or config.devcontainer_json_template
  config.nvim_nix_attribute = opts.nvim_nix_attribute or config.nvim_nix_attribute
  config.nvim_install_dir = opts.nvim_install_dir or config.nvim_install_dir
  config.nvim_cache_versions = opts.nvim_cache_versions or config.nvim_cache_versions
  config.docker_command = opts.docker_command or config.docker_command
  config.workspace_folder_provider = opts.workspace_folder_provider or config.workspace_folder_provider
  config.config_search_start = opts.config_search_start or config.config_search_start
  config.disable_recursive_config_search = opts.disable_recursive_config_search
    or config.disable_recursive_config_search
  if vim.env.NVIM_DEVCONTAINER_DEBUG then
    config.log_level = "trace"
  else
    config.log_level = opts.log_level or config.log_level
  end
  config.remote_env = opts.remote_env or config.remote_env

  if opts.cli_path then
    config.cli_path = opts.cli_path
    log.info("Using devcontainer CLI from: " .. opts.cli_path)
  end

  if opts.nvim_shell ~= nil then
    config.nvim_shell = opts.nvim_shell
  end

  if opts.generate_commands ~= false then
    vim.api.nvim_create_user_command("DevcontainerAttach", function(args)
      -- Parse arguments using -- as a delimiter
      -- Everything before -- is passed to devcontainer CLI
      -- Everything after -- is the command to run in the container
      local devcontainer_args = {}
      local container_cmd = nil
      local delimiter_index = nil

      for i, arg in ipairs(args.fargs) do
        if arg == "--" then
          delimiter_index = i
          break
        end
      end

      if delimiter_index then
        -- Found delimiter: split args
        for i = 1, delimiter_index - 1 do
          table.insert(devcontainer_args, args.fargs[i])
        end
        if delimiter_index < #args.fargs then
          container_cmd = table.concat(vim.list_slice(args.fargs, delimiter_index + 1), " ")
        end
      else
        -- No delimiter: all args are either devcontainer args or a container command
        -- Heuristic: if first arg starts with --, treat all as devcontainer args
        -- Otherwise, treat all as a container command
        if #args.fargs > 0 and args.fargs[1]:match("^%-%-") then
          devcontainer_args = args.fargs
        else
          container_cmd = #args.fargs > 0 and table.concat(args.fargs, " ") or nil
        end
      end

      commands.attach({
        command = container_cmd or "nvim",
        extra_cli_args = #devcontainer_args > 0 and devcontainer_args or nil,
      })
    end, {
      nargs = "*",
      desc = "Attach to devcontainer using devcontainer CLI",
    })

    vim.api.nvim_create_user_command("DevcontainerStop", function(_)
      commands.stop()
    end, {
      nargs = 0,
      desc = "Stop the devcontainer",
    })

    vim.api.nvim_create_user_command("DevcontainerExec", function(args)
      if #args.fargs == 0 then
        vim.notify("Usage: DevcontainerExec <command> [args...]", vim.log.levels.WARN)
        return
      end
      commands.exec(args.fargs)
    end, {
      nargs = "*",
      desc = "Execute a command in the running devcontainer",
    })

    vim.api.nvim_create_user_command("DevcontainerLogs", function(_)
      commands.open_logs()
    end, {
      nargs = 0,
      desc = "Open devcontainer plugin logs in a new buffer",
    })

    vim.api.nvim_create_user_command("DevcontainerEditNearestConfig", function(_)
      commands.edit_config()
    end, {
      nargs = 0,
      desc = "Open or create nearest devcontainer.json file",
    })

    vim.api.nvim_create_user_command("DevcontainerAddNeovim", function(_)
      commands.add_neovim()
    end, {
      nargs = 0,
      desc = "Add Neovim to the running devcontainer",
    })

    vim.api.nvim_create_user_command("DevcontainerClearCache", function(_)
      vim.ui.select({ "Yes", "No" }, { prompt = "Clear Nix bundle cache?" }, function(choice)
        if choice == "Yes" then
          commands.clear_cache()
        end
      end)
    end, {
      nargs = 0,
      desc = "Clear the host Nix bundle cache and the in-container nvim install",
    })

    -- Container-side tab completion helper.
    -- Runs synchronously via vim.fn.system (completion must return immediately).
    -- Finds the running container by workspace config, then shells `ls -1a`
    -- inside the container for the partial path's directory.
    -- NOTE: This involves two synchronous docker calls and will cause a brief
    -- hang (typically < 500ms on a local daemon) the first time Tab is pressed.
    local function complete_container_path(arglead, _cmdline, _cursorpos)
      local cli_mod = require("devcontainer.cli")

      -- Find config path synchronously
      local config_search_start = config.config_search_start and config.config_search_start() or vim.loop.cwd()
      local normalized = vim.fn.fnamemodify(config_search_start, ":p")
      local config_path = nil
      local current = normalized
      while current and current ~= "" do
        for _, p in ipairs({
          current .. ".devcontainer/devcontainer.json",
          current .. ".devcontainer.json",
        }) do
          if vim.fn.filereadable(p) == 1 then
            config_path = p
            break
          end
        end
        if config_path then break end
        local parent = current:match("^(.+)/[^/]+/$") or current:match("^(.+)/[^/]+$")
        if not parent or parent == current then break end
        current = parent .. "/"
      end

      if not config_path then
        return {}
      end

      -- Determine workspace folder and find container ID synchronously
      local config_dir = config_path:match("^(.+)/[^/]+$")
      local workspace_folder = vim.fn.fnamemodify(config_dir .. "/..", ":p"):gsub("/$", "")
      local label = "devcontainer.local_folder=" .. workspace_folder
      local container_id_raw = vim.fn.system({
        config.docker_command or "docker",
        "ps", "-q", "--filter", "label=" .. label,
      })
      local container_id = container_id_raw:match("^%s*(.-)%s*$")
      if not container_id or container_id == "" then
        return {}
      end

      -- Determine the directory to list and the prefix to filter by
      local dir, prefix
      if arglead == "" or arglead:sub(-1) == "/" then
        dir = arglead == "" and "$HOME" or arglead
        prefix = ""
      else
        local last_slash = arglead:match(".*/()")
        if last_slash then
          dir = arglead:sub(1, last_slash - 1)
          prefix = arglead:sub(last_slash)
        else
          dir = "$HOME"
          prefix = arglead
        end
      end

      -- Resolve dir through container shell (handles $HOME, ~, $VAR, etc.)
      local escaped_dir = dir:gsub("'", "'\\''")
      local resolve_script = "printf '%%s' '" .. escaped_dir .. "'"
      local resolved_dir_raw = vim.fn.system({
        config.docker_command or "docker",
        "exec", container_id, "/bin/sh", "-c", resolve_script,
      })
      local resolved_dir = resolved_dir_raw:gsub("%s+$", "")
      if resolved_dir == "" then
        resolved_dir = "/"
      end

      -- List the directory
      local escaped_resolved = resolved_dir:gsub("'", "'\\''")
      local ls_script = "ls -1a -- '" .. escaped_resolved .. "' 2>/dev/null"
      local ls_raw = vim.fn.system({
        config.docker_command or "docker",
        "exec", container_id, "/bin/sh", "-c", ls_script,
      })

      local results = {}
      local base = (dir == "$HOME" and arglead == "") and "" or (dir .. "/")
      for line in ls_raw:gmatch("[^\n]+") do
        if line ~= "." and line ~= ".." then
          if prefix == "" or line:sub(1, #prefix) == prefix then
            table.insert(results, base .. line)
          end
        end
      end
      return results
    end

    vim.api.nvim_create_user_command("DevcontainerCopyIn", function(args)
      local fargs = args.fargs
      if #fargs == 0 then
        -- Prompt for both sides
        vim.ui.input({ prompt = "Host source path: ", completion = "file" }, function(src)
          if not src or src == "" then return end
          vim.ui.input({ prompt = "Container destination path: " }, function(dest)
            if not dest or dest == "" then return end
            commands.copy_in({ src }, dest, { force = args.bang })
          end)
        end)
      elseif #fargs == 1 then
        vim.ui.input({ prompt = "Container destination path: " }, function(dest)
          if not dest or dest == "" then return end
          commands.copy_in(fargs, dest, { force = args.bang })
        end)
      else
        local sources = { unpack(fargs, 1, #fargs - 1) }
        local dest = fargs[#fargs]
        commands.copy_in(sources, dest, { force = args.bang })
      end
    end, {
      nargs = "*",
      bang = true,
      complete = "file",
      desc = "Copy file(s)/director(ies) from host into the running devcontainer (scp semantics; last arg is dest). Bang skips overwrite prompt.",
    })

    vim.api.nvim_create_user_command("DevcontainerCopyOut", function(args)
      local fargs = args.fargs
      if #fargs == 0 then
        vim.ui.input({ prompt = "Container source path: " }, function(src)
          if not src or src == "" then return end
          vim.ui.input({ prompt = "Host destination path: ", completion = "file" }, function(dest)
            if not dest or dest == "" then return end
            commands.copy_out({ src }, dest, { force = args.bang })
          end)
        end)
      elseif #fargs == 1 then
        vim.ui.input({ prompt = "Host destination path: ", completion = "file" }, function(dest)
          if not dest or dest == "" then return end
          commands.copy_out(fargs, dest, { force = args.bang })
        end)
      else
        local sources = { unpack(fargs, 1, #fargs - 1) }
        local dest = fargs[#fargs]
        commands.copy_out(sources, dest, { force = args.bang })
      end
    end, {
      nargs = "*",
      bang = true,
      complete = complete_container_path,
      desc = "Copy file(s)/director(ies) from the running devcontainer to the host (scp semantics; last arg is dest). Bang skips overwrite prompt.",
    })
  end

  if opts.autocommands then
    local au_id = vim.api.nvim_create_augroup("devcontainer_autostart", {})

    if opts.autocommands.init then
      local last_devcontainer_file = nil

      local function auto_start()
        local find_nearest = function(start_path, callback)
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
                callback(path)
                return
              end
            end

            local parent = current:match("^(.+)/[^/]+/$") or current:match("^(.+)/[^/]+$")
            if not parent or parent == current then
              break
            end
            current = parent
          end

          callback(nil)
        end

        find_nearest(config.config_search_start(), function(path)
          if path and path ~= last_devcontainer_file then
            last_devcontainer_file = path
            if opts.autocommands.init == "ask" then
              vim.ui.select(
                { "Yes", "No" },
                { prompt = "Devcontainer file found! Start container?" },
                function(choice)
                  if choice == "Yes" then
                    commands.attach()
                  end
                end
              )
            else
              commands.attach()
            end
          end
        end)
      end

      vim.api.nvim_create_autocmd("BufEnter", {
        pattern = "*",
        group = au_id,
        callback = function()
          auto_start()
        end,
        once = true,
      })

      vim.api.nvim_create_autocmd("DirChanged", {
        pattern = "*",
        group = au_id,
        callback = function()
          auto_start()
        end,
      })
    end

    if opts.autocommands.clean then
      vim.api.nvim_create_autocmd("VimLeavePre", {
        pattern = "*",
        group = au_id,
        callback = function()
          commands.stop()
        end,
      })
    end

    if opts.autocommands.update then
      vim.api.nvim_create_autocmd({ "BufWritePost", "FileWritePost" }, {
        pattern = "*devcontainer.json",
        group = au_id,
        callback = function(event)
          local find_nearest = function(start_path, callback)
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
                  callback(path)
                  return
                end
              end

              local parent = current:match("^(.+)/[^/]+/$") or current:match("^(.+)/[^/]+$")
              if not parent or parent == current then
                break
              end
              current = parent
            end

            callback(nil)
          end

          find_nearest(config.config_search_start(), function(path)
            if path and path == event.match then
              commands.stop(function()
                commands.attach()
              end)
            end
          end)
        end,
      })
    end
  end

  log.info("Setup complete!")
end

return M
