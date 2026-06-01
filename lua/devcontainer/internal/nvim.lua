---@mod devcontainer.internal.nvim Neovim in container related commands
---@brief [[
---Provides high level commands related to using Neovim inside a container.
---Installation is delegated to `devcontainer.internal.installer`, which
---uses `nix bundle` + `docker exec -i` to stream a self-contained Neovim
---into the container at `$HOME/.nvim-devcontainer/bin/nvim`.
---@brief ]]

local M = {}

local log = require("devcontainer.internal.log")
local v = require("devcontainer.internal.validation")
local config = require("devcontainer.config")
local cli = require("devcontainer.cli")
local installer = require("devcontainer.internal.installer")

---Wrap callback to run in main event loop (avoids E5560 in fast callbacks)
---@param fn function
---@return function
local function sched(fn)
  return vim.schedule_wrap(fn)
end

---Shell snippet that ensures nvim is available, either at the installer-managed
---path or on PATH.
local function probe_cmd()
  local dir = config.nvim_install_dir or "$HOME/.nvim-devcontainer"
  return '("' .. dir .. '/bin/nvim" --version >/dev/null 2>&1 || nvim --version >/dev/null 2>&1)'
end

---Check if Neovim is available in the container (either at the installer path
---or on PATH).
---@param container_id string
---@param opts? table
---@field on_success? fun()
---@field on_fail? fun()
function M.is_installed(container_id, opts)
  opts = opts or {}
  v.validate_callbacks(opts)

  cli.exec(container_id, "/bin/sh", { "-c", probe_cmd() }, {
    on_exit = sched(function(result)
      if result.code == 0 then
        opts.on_success()
      else
        opts.on_fail()
      end
    end),
  })
end

---@class AddNeovimOpts
---@field on_success? fun()
---@field on_fail? fun(err: string?)
---@field nvim_attr? string override the Nix flake attribute for nvim

---Install Neovim into the container using the Nix bundle installer.
---Thin wrapper kept for API compatibility with the commands module.
---@param container_id string
---@param opts? AddNeovimOpts
function M.add_neovim(container_id, opts)
  vim.validate("container_id", container_id, "string")
  vim.validate("opts", opts, { "table", "nil" })
  opts = opts or {}
  installer.install(container_id, {
    nvim_attr = opts.nvim_attr,
    on_success = opts.on_success or function()
      vim.notify("Successfully installed Neovim into container (" .. container_id .. ")")
    end,
    on_fail = opts.on_fail or function(err)
      vim.notify(
        "Installing Neovim into container (" .. container_id .. ") failed: " .. (err or "unknown"),
        vim.log.levels.ERROR
      )
    end,
  })
end

log.wrap(M)
return M
