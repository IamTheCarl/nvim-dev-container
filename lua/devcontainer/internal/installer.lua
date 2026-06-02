---@mod devcontainer.internal.installer Nix-based Neovim installer
---@brief [[
---Bundles the user's Neovim (or a user-specified flake attribute) using
---`nix bundle` with the toAppImage bundler, caches the resulting AppImage on
---the host, streams it into the target container via `docker exec -i`, and
---extracts it in-place.
---
---After extraction the installer tries (as root) to symlink the container's
---`/nix/store` to the extracted bundle's nix directory.  When this succeeds
---the `<install_dir>/.direct_exec` marker is written and nvim is launched
---directly via the `entrypoint` symlink — bypassing AppRun's bwrap user
---namespace entirely.  This restores sudo (and other setuid helpers) inside
---:terminal sessions.  When root access is unavailable the marker is absent
---and AppRun is used as a fallback (sudo will not work in :terminal).
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
  -- Bundler-namespaced dir so older toArx artifacts can't be served by mistake.
  local dir = vim.fn.stdpath("cache") .. "/nvim-dev-container/appimage"
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

---Return the path to the SHA256 file for a given cache key.
---@param key string
---@return string
local function hash_file_path(key)
  return cache_dir() .. "/" .. key .. ".sha256"
end

---Compute the SHA256 of a file and store it next to the cache entry.
---The hash is written as a plain 64-char hex string with no trailing newline.
---Fails silently on error (leaves no hash file; treated as mismatch later).
---@param real_path string resolved (non-symlink) path to the AppImage
---@param key string cache key used to derive the hash file name
local function compute_and_store_hash(real_path, key)
  local res = vim.system({ "sha256sum", real_path }, { text = true }):wait()
  if res.code ~= 0 or not res.stdout then return end
  -- sha256sum output: "<hash>  <filename>\n"
  local hash = vim.trim(vim.split(res.stdout, "%s+")[1] or "")
  if #hash ~= 64 then return end
  local path = hash_file_path(key)
  local f = io.open(path, "w")
  if not f then return end
  f:write(hash)
  f:close()
end

---Validate that the stored SHA256 for a cache key still matches the AppImage.
---Returns false (mismatch) when:
---  • the .sha256 file does not exist (old/unvalidated cache entry)
---  • the stored hash and the computed hash differ
---@param real_path string resolved (non-symlink) path to the AppImage
---@param key string cache key
---@return boolean valid
local function validate_bundle_hash(real_path, key)
  local path = hash_file_path(key)
  local f = io.open(path, "r")
  if not f then return false end
  local stored = vim.trim(f:read("*a") or "")
  f:close()
  if #stored ~= 64 then return false end

  local res = vim.system({ "sha256sum", real_path }, { text = true }):wait()
  if res.code ~= 0 or not res.stdout then return false end
  local computed = vim.trim(vim.split(res.stdout, "%s+")[1] or "")
  return computed == stored
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

---Ensure a bundled AppImage exists on disk for the given attribute.
---On a cache hit the stored SHA256 is validated against the current file.
---A missing or mismatched hash is treated as a stale cache entry: the cache
---is cleared and the bundle is rebuilt so any closure change is picked up
---automatically.
---@param attr string nix flake attribute (e.g. "nixpkgs#neovim")
---@param cb fun(bundle_path: string?, err: string?)
function M.ensure_nix_bundle(attr, cb)
  local key = cache_key(attr)
  local bundle_path = cache_dir() .. "/" .. key

  if vim.fn.filereadable(bundle_path) == 1 then
    local real = vim.fn.resolve(bundle_path)
    if validate_bundle_hash(real, key) then
      return cb(bundle_path, nil)
    end
    -- Hash missing or mismatch — stale cache; clear and rebuild.
    vim.notify(
      "Cached Neovim bundle is out of date, rebuilding...",
      vim.log.levels.INFO
    )
    M.clear_cache()
  end

  vim.notify("Building Nix AppImage for " .. attr .. " — this may take a few minutes...", vim.log.levels.INFO)

  local cmd = {
    "nix", "bundle",
    "--bundler", "github:NixOS/bundlers#toAppImage",
    "--out-link", bundle_path,
    attr,
  }
  vim.system(cmd, { text = true }, sched(function(res)
    if res.code ~= 0 then
      return cb(nil, "nix bundle failed: " .. (res.stderr or "unknown"))
    end
    -- `nix bundle --out-link` creates a symlink; resolve to the underlying
    -- AppImage in the nix store.
    local real = vim.fn.resolve(bundle_path)
    if vim.fn.filereadable(real) ~= 1 then
      return cb(nil, "bundle artifact missing at " .. real)
    end
    compute_and_store_hash(real, key)
    cb(real, nil)
  end))
end

---Chunk size for streaming the AppImage into the container. 1 MiB keeps
---peak Lua heap bounded and yields ~80 schedule ticks for a typical bundle.
local STREAM_CHUNK = 1024 * 1024

---Attempt to symlink the container's /nix/store to the extracted bundle's nix
---directory, running the mkdir/ln as root via `docker exec --user root`.
---When successful, writes a `.direct_exec` marker so the launcher knows it
---can bypass AppRun's user-namespace chroot.
---
---Fails silently when root access is not available (marker absent → AppRun
---fallback is used; sudo will not work inside :terminal in that case).
---
---@param container_id string
---@param cb fun(ok: boolean)
function M.try_setup_direct_exec(container_id, cb)
  local docker = config.docker_command or "docker"
  local install_dir = config.nvim_install_dir or "$HOME/.nvim-devcontainer"

  -- Step 1: resolve $HOME in the container user context (root's $HOME differs).
  vim.system(
    { docker, "exec", container_id, "sh", "-c", "echo " .. install_dir },
    { text = true },
    sched(function(r1)
      if r1.code ~= 0 then return cb(false) end
      local actual = vim.trim(r1.stdout or "")
      if actual == "" then return cb(false) end

      -- Step 2: as root, create /nix and symlink /nix/store → <actual>/app/nix/store.
      -- Use -sfn so re-installs update a stale symlink.
      -- Skip if /nix/store is already a real (non-symlink) directory — the container
      -- has its own nix; we leave it alone and let AppRun handle isolation.
      local root_script = string.format(
        "if [ -d /nix/store ] && [ ! -L /nix/store ]; then exit 1; fi; "
          .. "mkdir -p /nix && ln -sfn %s/app/nix/store /nix/store",
        actual
      )
      vim.system(
        { docker, "exec", "--user", "root", container_id, "sh", "-c", root_script },
        { text = true },
        sched(function(r2)
          if r2.code ~= 0 then return cb(false) end

          -- Step 3: touch the marker as the container user.
          vim.system(
            { docker, "exec", container_id, "touch", actual .. "/.direct_exec" },
            { text = true },
            sched(function(r3) cb(r3.code == 0) end)
          )
        end)
      )
    end)
  )
end

---Stream the AppImage into the container and extract it in-place.
---Bypasses devcontainer CLI; uses `docker exec -i` directly. Wipes any
---existing install dir first so leftovers from prior bundler formats can't
---confuse the probe.
---
---Pumps the AppImage to `docker exec`'s stdin in fixed-size chunks so peak
---Lua heap stays at one chunk regardless of bundle size. Yields via
---`vim.schedule` between writes so the UI thread stays responsive.
---
---Resulting layout inside the container:
---   $install_dir/app/AppRun           ← launcher (sets VIMRUNTIME etc.)
---   $install_dir/app/usr/bin/nvim     ← the binary itself
---   $install_dir/app/usr/lib/...      ← bundled runtime libs
---
---@param container_id string
---@param bundle_path string host filesystem path to the AppImage
---@param cb fun(ok: boolean, err: string?)
---@param on_progress? fun(bytes_written: integer, total: integer)
function M.stream_and_extract(container_id, bundle_path, cb, on_progress)
  local uv = vim.uv or vim.loop
  local fd, oerr = uv.fs_open(bundle_path, "r", 438)
  if not fd then
    return cb(false, "failed to open bundle: " .. (oerr or "unknown"))
  end
  local stat, serr = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return cb(false, "failed to stat bundle: " .. (serr or "unknown"))
  end
  local total = stat.size

  local install_dir = config.nvim_install_dir or "$HOME/.nvim-devcontainer"
  local docker = config.docker_command or "docker"
  -- Stream the AppImage, extract its squashfs payload, then promote
  -- squashfs-root → app and remove the now-redundant AppImage file.
  local script = table.concat({
    "set -e",
    'rm -rf "' .. install_dir .. '"',
    'mkdir -p "' .. install_dir .. '"',
    'cat > "' .. install_dir .. '/nvim.AppImage"',
    'chmod +x "' .. install_dir .. '/nvim.AppImage"',
    'cd "' .. install_dir .. '"',
    './nvim.AppImage --appimage-extract >/dev/null',
    'mv squashfs-root app',
    'rm -f "' .. install_dir .. '/nvim.AppImage"',
  }, "; ")

  local handle = vim.system(
    { docker, "exec", "-i", container_id, "sh", "-c", script },
    { stdin = true, text = false },
    sched(function(res)
      if res.code ~= 0 then
        return cb(false, "docker exec failed: " .. (res.stderr or "unknown"))
      end
      cb(true, nil)
    end)
  )

  local offset = 0
  local done = false
  local function cleanup()
    if not done then
      done = true
      uv.fs_close(fd)
    end
  end

  local pump
  pump = function()
    if done then return end
    local data, rerr = uv.fs_read(fd, STREAM_CHUNK, offset)
    if not data then
      cleanup()
      pcall(handle.kill, handle, "sigterm")
      return cb(false, "failed to read bundle chunk: " .. (rerr or "unknown"))
    end
    if #data == 0 then
      cleanup()
      handle:write(nil) -- close stdin; on_exit will fire the user callback
      return
    end
    handle:write(data)
    offset = offset + #data
    if on_progress then on_progress(offset, total) end
    vim.schedule(pump)
  end

  pump()
end

---@class InstallOpts
---@field on_success? fun()
---@field on_fail? fun(err: string?)
---@field nvim_attr? string override the Nix attribute for the nvim install

---Orchestrate the full installer pipeline.
---Bundles Neovim as an AppImage and extracts it into the container under
---`<install_dir>/app/`. Emits `User DevcontainerBuildProgress` autocmds
---for progress UI.
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
      "docker exec stream + extract AppImage",
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

  -- Step 1: bundle nvim as AppImage
  M.ensure_nix_bundle(nvim_attr, function(nvim_bundle, nerr)
    if not nvim_bundle then return finish(false, nerr) end
    build_status.current_step = 2
    build_status.progress = 50
    emit_progress()

    -- Step 2: stream into container and extract. Per-chunk progress maps
    -- the byte-pump range onto 50..99 so the status UI animates during the
    -- network/disk-bound phase; 100 is reserved for post-extract success.
    M.stream_and_extract(container_id, nvim_bundle, function(ok_n, sn_err)
      if not ok_n then return finish(false, sn_err) end

      -- Step 3: optionally set up /nix/store symlink for direct execution.
      -- This removes AppRun's bwrap user-namespace so sudo works in :terminal.
      -- Silently skipped when root access is unavailable (AppRun used instead).
      M.try_setup_direct_exec(container_id, function(direct_ok)
        if not direct_ok then
          log.fmt_warn(
            "Could not set up /nix/store symlink in %s (no root access or real nix store present). "
              .. "AppRun will be used — sudo and other setuid helpers will not work inside :terminal.",
            container_id
          )
        end
        finish(true, nil)
      end)
    end, sched(function(bytes_written, total)
      if total > 0 then
        local pct = 50 + math.floor((bytes_written / total) * 49)
        if pct > build_status.progress then
          build_status.progress = pct
          emit_progress()
        end
      end
    end))
  end)
end

---Trim the bundle cache to the newest `config.nvim_cache_versions` entries
---by mtime. Safe to call anytime; no-op when the cache fits.
---Deletes the accompanying .sha256 file when a bundle is evicted.
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
    -- Skip hash sidecar files; they are managed alongside their bundle.
    if not name:match("%.sha256$") then
      local path = dir .. "/" .. name
      -- Resolve symlinks so we compare/keep the underlying store result.
      local real = vim.fn.resolve(path)
      local stat = uv.fs_stat(real)
      if stat then
        table.insert(entries, { path = path, mtime = stat.mtime.sec })
      end
    end
  end
  table.sort(entries, function(a, b) return a.mtime > b.mtime end)
  for i = keep + 1, #entries do
    pcall(uv.fs_unlink, entries[i].path)
    pcall(uv.fs_unlink, entries[i].path .. ".sha256")
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
