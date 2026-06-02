local commands = require("devcontainer.commands")
local uv = vim.loop

describe("commands._internal.find_nearest_config", function()
  local find_nearest_config = commands._internal.find_nearest_config
  local tmproot

  local function mkdir_p(path)
    vim.fn.mkdir(path, "p")
  end

  local function touch(path)
    local fd = assert(uv.fs_open(path, "w", tonumber("0644", 8)))
    uv.fs_close(fd)
  end

  before_each(function()
    tmproot = vim.fn.tempname()
    mkdir_p(tmproot)
  end)

  after_each(function()
    vim.fn.delete(tmproot, "rf")
  end)

  local function call_sync(start)
    local result_path, result_dir
    local done = false
    find_nearest_config(start, function(path, dir)
      result_path = path
      result_dir = dir
      done = true
    end)
    -- find_nearest_config invokes its callback synchronously via uv.fs_stat
    assert.is_true(done, "callback should be invoked synchronously")
    -- Normalize duplicate slashes so assertions don't depend on the
    -- trailing-slash behaviour of vim.fn.fnamemodify(":p").
    if result_path then
      result_path = result_path:gsub("//+", "/")
    end
    if result_dir then
      result_dir = result_dir:gsub("//+", "/"):gsub("/$", "")
    end
    return result_path, result_dir
  end

  it("finds .devcontainer/devcontainer.json in the start directory", function()
    mkdir_p(tmproot .. "/.devcontainer")
    touch(tmproot .. "/.devcontainer/devcontainer.json")
    local path, dir = call_sync(tmproot)
    assert.are.equal(tmproot .. "/.devcontainer/devcontainer.json", path)
    assert.are.equal(tmproot .. "/.devcontainer", dir)
  end)

  it("finds .devcontainer.json at top level", function()
    touch(tmproot .. "/.devcontainer.json")
    local path, dir = call_sync(tmproot)
    assert.are.equal(tmproot .. "/.devcontainer.json", path)
    assert.are.equal(tmproot, dir)
  end)

  it("prefers .devcontainer/devcontainer.json over .devcontainer.json", function()
    mkdir_p(tmproot .. "/.devcontainer")
    touch(tmproot .. "/.devcontainer/devcontainer.json")
    touch(tmproot .. "/.devcontainer.json")
    local path = call_sync(tmproot)
    assert.are.equal(tmproot .. "/.devcontainer/devcontainer.json", path)
  end)

  it("walks up from nested directory until config is found", function()
    mkdir_p(tmproot .. "/.devcontainer")
    touch(tmproot .. "/.devcontainer/devcontainer.json")
    mkdir_p(tmproot .. "/a/b/c")
    local path = call_sync(tmproot .. "/a/b/c")
    assert.are.equal(tmproot .. "/.devcontainer/devcontainer.json", path)
  end)

  it("invokes callback with nil when no config exists", function()
    mkdir_p(tmproot .. "/sub")
    local path, dir = call_sync(tmproot .. "/sub")
    assert.is_nil(path)
    assert.is_nil(dir)
  end)
end)
