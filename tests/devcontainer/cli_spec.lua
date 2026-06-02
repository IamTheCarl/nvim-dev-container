local subject = require("devcontainer.cli")

describe("cli.is_available", function()
  it("returns true if devcontainer CLI is on PATH", function()
    local available = subject.is_available()
    assert.is_boolean(available)
  end)
end)

describe("cli.ensure_available", function()
  it("does not error if CLI is available", function()
    if subject.is_available() then
      local ok = pcall(subject.ensure_available)
      assert.is_true(ok)
    end
  end)

  it("errors if CLI is not available", function()
    if not subject.is_available() then
      local ok, err = pcall(subject.ensure_available)
      assert.is_false(ok)
      assert.match("devcontainer CLI", err)
    end
  end)
end)

describe("cli._internal.parse_json_output", function()
  local parse = subject._internal.parse_json_output

  it("returns nil for empty input", function()
    assert.is_nil(parse(nil))
    assert.is_nil(parse(""))
  end)

  it("returns nil when no result object is present", function()
    -- Plain log lines without configuration/outcome/imageName/containerId
    assert.is_nil(parse([[{"type":"text","level":1,"timestamp":1,"text":"hello"}]]))
  end)

  it("extracts the trailing result object containing outcome", function()
    local stream = table.concat({
      [[{"type":"text","level":1,"timestamp":1,"text":"starting"}]],
      [[{"outcome":"success","containerId":"abc123","remoteUser":"root","remoteWorkspaceFolder":"/workspace"}]],
    }, "\n")
    local data = parse(stream)
    assert.are.equal("success", data.outcome)
    assert.are.equal("abc123", data.containerId)
  end)

  it("extracts the last matching object when multiple candidates exist", function()
    local stream = table.concat({
      [[{"configuration":{"image":"first"}}]],
      [[{"type":"text","level":1,"timestamp":1,"text":"middle"}]],
      [[{"configuration":{"image":"second"}}]],
    }, "\n")
    local data = parse(stream)
    assert.are.equal("second", data.configuration.image)
  end)

  it("ignores braces inside JSON string values", function()
    local stream = [[{"outcome":"success","text":"oops { not a real object }"}]]
    local data = parse(stream)
    assert.are.equal("success", data.outcome)
  end)

  it("returns nil for malformed objects", function()
    -- Unbalanced braces with no successfully-decoded matching object
    assert.is_nil(parse([[{"outcome":]]))
  end)
end)

describe("cli.up / cli.exec / cli.recreate arg construction", function()
  local captured

  before_each(function()
    captured = nil
    -- Stub uv.spawn so we capture the args without launching the CLI.
    -- The on_exit callback is invoked synchronously with a successful exit.
    package.loaded["devcontainer.cli"] = nil
    -- Replace vim.loop.spawn before re-loading the module so CLI_COMMAND
    -- resolution is unaffected.
    _G._real_spawn = vim.loop.spawn
    vim.loop.spawn = function(cmd, opts, cb)
      captured = { cmd = cmd, args = opts.args }
      -- Fire the exit callback right away on the next event-loop tick so
      -- cli internals can clean up pipes synchronously enough for tests.
      vim.schedule(function()
        cb(0, 0)
      end)
      -- Return a fake handle/pid pair compatible with uv.is_closing / uv.close
      return { _stub = true }, 1
    end
    -- Stub uv.is_closing / uv.close / uv.read_start / uv.new_pipe so the
    -- pipe machinery in run_cli is a no-op against our fake handle.
    _G._real_is_closing = vim.loop.is_closing
    _G._real_close = vim.loop.close
    _G._real_read_start = vim.loop.read_start
    _G._real_new_pipe = vim.loop.new_pipe
    vim.loop.is_closing = function() return true end
    vim.loop.close = function() end
    vim.loop.read_start = function() end
    vim.loop.new_pipe = function() return { _stub = true } end
    subject = require("devcontainer.cli")
    -- ensure_available checks PATH; bypass it.
    subject.ensure_available = function() end
  end)

  after_each(function()
    vim.loop.spawn = _G._real_spawn
    vim.loop.is_closing = _G._real_is_closing
    vim.loop.close = _G._real_close
    vim.loop.read_start = _G._real_read_start
    vim.loop.new_pipe = _G._real_new_pipe
    package.loaded["devcontainer.cli"] = nil
    subject = require("devcontainer.cli")
  end)

  local function index_of(t, v)
    for i, x in ipairs(t) do
      if x == v then return i end
    end
    return nil
  end

  it("cli.up emits up subcommand with workspace folder", function()
    subject.up("/workspace/proj", {})
    assert.is_table(captured)
    assert.are.equal("up", captured.args[1])
    local wf = index_of(captured.args, "--workspace-folder")
    assert.is_not_nil(wf)
    assert.are.equal("/workspace/proj", captured.args[wf + 1])
  end)

  it("cli.up forwards --config, mounts and remote env", function()
    subject.up("/workspace/proj", {
      config = "/etc/devcontainer.json",
      mounts = { "type=bind,source=/a,target=/b" },
      remote_env = { FOO = "bar" },
      include_configuration = true,
    })
    assert.is_not_nil(index_of(captured.args, "--config"))
    assert.is_not_nil(index_of(captured.args, "/etc/devcontainer.json"))
    assert.is_not_nil(index_of(captured.args, "--mount"))
    assert.is_not_nil(index_of(captured.args, "type=bind,source=/a,target=/b"))
    assert.is_not_nil(index_of(captured.args, "--remote-env"))
    assert.is_not_nil(index_of(captured.args, "FOO=bar"))
    assert.is_not_nil(index_of(captured.args, "--include-configuration"))
  end)

  it("cli.up injects --log-format json after the subcommand", function()
    subject.up("/workspace/proj", {})
    local lfi = index_of(captured.args, "--log-format")
    assert.are.equal(2, lfi)
    assert.are.equal("json", captured.args[lfi + 1])
  end)

  it("cli.exec treats absolute-path target as workspace folder", function()
    subject.exec("/workspace/proj", "ls", { "-la" }, {})
    assert.is_not_nil(index_of(captured.args, "--workspace-folder"))
    assert.is_nil(index_of(captured.args, "--container-id"))
    assert.is_not_nil(index_of(captured.args, "/workspace/proj"))
    assert.is_not_nil(index_of(captured.args, "ls"))
    assert.is_not_nil(index_of(captured.args, "-la"))
  end)

  it("cli.exec treats non-path target as container id", function()
    subject.exec("abc123def456", "echo", { "hi" }, {})
    assert.is_not_nil(index_of(captured.args, "--container-id"))
    assert.is_not_nil(index_of(captured.args, "abc123def456"))
    assert.is_nil(index_of(captured.args, "--workspace-folder"))
  end)

  it("cli.exec supports the (target, cmd, opts) overload", function()
    subject.exec("abc123def456", "echo", { remote_env = { K = "V" } })
    assert.is_not_nil(index_of(captured.args, "--container-id"))
    assert.is_not_nil(index_of(captured.args, "--remote-env"))
    assert.is_not_nil(index_of(captured.args, "K=V"))
  end)

  it("cli.recreate maps to `up --remove-existing-container`", function()
    subject.recreate("/workspace/proj", {})
    assert.are.equal("up", captured.args[1])
    assert.is_not_nil(index_of(captured.args, "--remove-existing-container"))
    assert.is_not_nil(index_of(captured.args, "--expect-existing-container=false"))
  end)
end)
