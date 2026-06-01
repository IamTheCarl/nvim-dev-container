---@mod devcontainer.internal.installer Nix-based Neovim installer
---@brief [[
---Bundles the user's Neovim (or a user-specified flake attribute) using
---`nix bundle` with the toArx bundler, caches the resulting self-extracting
---archive on the host, and streams it into the target container via
---`docker exec -i`. No root or sudo required inside the container.
---@brief ]]

local M = {}

local log = require("devcontainer.internal.log")
local config = require("devcontainer.config")
local status = require("devcontainer.status")

---Wrap a callback to run on the main event loop.
---@param fn function
---@return function
local function sched(fn)
  return vim.schedule_wrap(fn)
end

---Return the host cache directory for bundles.
---@return string
local function cache_dir()
  local dir = vim.fn.stdpath("cache") .. "/nvim-dev-container/nix"
  vim.fn.mkdir(dir, "p")
  return dir
end

---Resolve the Nix flake attribute to bundle for Neovim.
---User override via `config.nvim_nix_attribute`, otherwise default to
---`nixpkgs#neovim`. Raw Nix store paths are not accepted by `nix bundle`
---because they aren't Nix language values.
---@return string attribute
function M.resolve_nix_source()
  if type(config.nvim_nix_attribute) == "string" and config.nvim_nix_attribute ~= "" then
    return config.nvim_nix_attribute
  end
  return "nixpkgs#neovim"
end

---Compute a stable cache key for a Nix source attribute.
---Uses sha256 of the attribute string truncated to 16 chars. Resolution to
---the actual store path happens lazily inside `nix bundle`; the cache key
---will not auto-invalidate when nixpkgs updates. Use :DevcontainerClearCache.
---@param attr string
---@return string
local function cache_key(attr)
  return string.sub(vim.fn.sha256(attr), 1, 16)
end

---Resolve a Nix attribute to a concrete store outPath. Synchronous because
---it must complete before the bundle command can run; the call is fast for
---cached evaluations.
---@param attr string
---@return string? outPath, string? err
local function eval_out_path(attr)
  local res = vim.system({ "nix", "eval", "--raw", attr .. ".outPath" }, { text = true }):wait()
  if res.code ~= 0 then
    return nil, res.stderr or "nix eval failed"
  end
  local out = res.stdout and vim.trim(res.stdout) or ""
  if out == "" then return nil, "empty outPath" end
  return out, nil
end

---Ensure a bundled arx archive exists on disk for the given attribute.
---@param attr string nix flake attribute (e.g. "nixpkgs#neovim")
---@param cb fun(bundle_path: string?, err: string?)
function M.ensure_nix_bundle(attr, cb)
  local key = cache_key(attr)
  local bundle_path = cache_dir() .. "/" .. key

  if vim.fn.filereadable(bundle_path) == 1 then
    return cb(bundle_path, nil)
  end

  vim.notify("Building Nix bundle for " .. attr .. " — this may take a few minutes...", vim.log.levels.INFO)

  local cmd = {
    "nix", "bundle",
    "--bundler", "github:NixOS/bundlers#toArx",
    "--out-link", bundle_path,
    attr,
  }
  vim.system(cmd, { text = true }, sched(function(res)
    if res.code ~= 0 then
      return cb(nil, "nix bundle failed: " .. (res.stderr or "unknown"))
    end
    -- `nix bundle --out-link` creates a symlink; the arx blob is what we want to stream.
    local real = vim.fn.resolve(bundle_path)
    if vim.fn.filereadable(real) ~= 1 then
      return cb(nil, "bundle artifact missing at " .. real)
    end
    cb(real, nil)
  end))
end

---Read a file fully into a Lua string via libuv.
---@param path string
---@return string? data, string? err
local function read_file_bytes(path)
  local uv = vim.uv or vim.loop
  local fd, oerr = uv.fs_open(path, "r", 438)
  if not fd then return nil, oerr end
  local stat, serr = uv.fs_fstat(fd)
  if not stat then uv.fs_close(fd); return nil, serr end
  local data, rerr = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not data then return nil, rerr end
  return data, nil
end

---Stream the bundle file into the container and place it at the install path.
---Bypasses devcontainer CLI; uses `docker exec -i` directly. Requires the
---container's shell to accept `cat` writing a binary stream from stdin.
---@param container_id string
---@param bundle_path string host filesystem path to the arx bundle
---@param binary_name string filename to install under `$install_dir/bin/`
---@param cb fun(ok: boolean, err: string?)
function M.stream_install(container_id, bundle_path, binary_name, cb)
  local data, rerr = read_file_bytes(bundle_path)
  if not data then
    return cb(false, "failed to read bundle: " .. (rerr or "unknown"))
  end

  local install_dir = config.nvim_install_dir or "$HOME/.nvim-devcontainer"
  local docker = config.docker_command or "docker"
  local script = 'set -e; '
    .. 'mkdir -p "' .. install_dir .. '/bin"; '
    .. 'cat > "' .. install_dir .. '/bin/' .. binary_name .. '"; '
    .. 'chmod +x "' .. install_dir .. '/bin/' .. binary_name .. '"'

  vim.system(
    { docker, "exec", "-i", container_id, "sh", "-c", script },
    { stdin = data, text = false },
    sched(function(res)
      if res.code ~= 0 then
        return cb(false, "docker exec failed: " .. (res.stderr or "unknown"))
      end
      cb(true, nil)
    end)
  )
end

---@class InstallOpts
---@field on_success? fun()
---@field on_fail? fun(err: string?)
---@field nvim_attr? string override the Nix attribute for the nvim install

---Orchestrate the full installer pipeline.
---Bundles Neovim and streams it into the container as `bin/nvim`. Emits
---`User DevcontainerBuildProgress` autocmds for progress UI.
---@param container_id string
---@param opts? InstallOpts
function M.install(container_id, opts)
  opts = opts or {}
  local on_success = opts.on_success or function() end
  local on_fail = opts.on_fail or function(err)
    vim.notify("Container install failed: " .. (err or "unknown"), vim.log.levels.ERROR)
  end

  local nvim_attr = opts.nvim_attr or M.resolve_nix_source()

  local build_status = {
    build_title = "Installing Neovim into " .. container_id,
    progress = 0,
    step_count = 2,
    current_step = 1,
    image_id = nil,
    source_dockerfile = nil,
    build_command = "installer.install",
    commands_run = {
      "nix bundle " .. nvim_attr,
      "docker exec stream nvim",
    },
    running = true,
  }
  status.add_build(build_status)
  local function emit_progress()
    vim.api.nvim_exec_autocmds("User", { pattern = "DevcontainerBuildProgress", modeline = false })
  end
  emit_progress()

  local function finish(ok, err)
    build_status.running = false
    if ok then build_status.progress = 100 end
    emit_progress()
    M.prune_cache()
    if ok then return on_success() end
    return on_fail(err)
  end

  -- Step 1: bundle nvim
  M.ensure_nix_bundle(nvim_attr, function(nvim_bundle, nerr)
    if not nvim_bundle then return finish(false, nerr) end
    build_status.current_step = 2
    build_status.progress = 50
    emit_progress()

    -- Step 2: stream nvim into container
    M.stream_install(container_id, nvim_bundle, "nvim", function(ok_n, sn_err)
      if not ok_n then return finish(false, sn_err) end
      finish(true, nil)
    end)
  end)
end

---Trim the bundle cache to the newest `config.nvim_cache_versions` entries
---by mtime. Safe to call anytime; no-op when the cache fits.
function M.prune_cache()
  local keep = config.nvim_cache_versions or 3
  local uv = vim.uv or vim.loop
  local dir = cache_dir()
  local entries = {}
  local handle = uv.fs_scandir(dir)
  if not handle then return end
  while true do
    local name, _ = uv.fs_scandir_next(handle)
    if not name then break end
    local path = dir .. "/" .. name
    -- Resolve symlinks so we compare/keep the underlying store result.
    local real = vim.fn.resolve(path)
    local stat = uv.fs_stat(real)
    if stat then
      table.insert(entries, { path = path, mtime = stat.mtime.sec })
    end
  end
  table.sort(entries, function(a, b) return a.mtime > b.mtime end)
  for i = keep + 1, #entries do
    pcall(uv.fs_unlink, entries[i].path)
  end
end

---Remove the entire bundle cache directory.
function M.clear_cache()
  local dir = cache_dir()
  vim.fn.delete(dir, "rf")
  vim.fn.mkdir(dir, "p")
end

log.wrap(M)
return M
