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

  if opts.generate_commands ~= false then
    vim.api.nvim_create_user_command("DevcontainerAttach", function(args)
      local cmd = "nvim"
      if #args.fargs > 0 then
        cmd = table.concat(args.fargs, " ")
      end
      commands.attach({ command = cmd })
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
          require("devcontainer.internal.installer").clear_cache()
          vim.notify("Nix bundle cache cleared.")
        end
      end)
    end, {
      nargs = 0,
      desc = "Clear the Nix bundle cache used by the Neovim installer",
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
