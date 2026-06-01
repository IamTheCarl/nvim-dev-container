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
      local ok, err = pcall(subject.ensure_available)
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
