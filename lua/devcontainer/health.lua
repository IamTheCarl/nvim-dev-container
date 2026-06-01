local function vim_version_string()
  local v = vim.version()
  return v.major .. "." .. v.minor .. "." .. v.patch
end

local executor = require("devcontainer.internal.executor")
local cli = require("devcontainer.cli")

return {
  check = function()
    local cli_path = require("devcontainer.config").cli_path or "devcontainer (on PATH)"

    vim.health.start("Neovim version")

    if vim.fn.has("nvim-0.12") == 0 then
      vim.health.warn(
        "Neovim 0.12+ is recommended for the :connect-based attach command!\n"
          .. "You can still use the plugin but will get a TTY terminal instead of full Neovim embedding."
      )
    else
      vim.health.ok("Neovim version: " .. vim_version_string())
    end

    vim.health.start("devcontainer CLI")

    if cli.is_available() then
      local handle = io.popen((cli_path ~= "devcontainer (on PATH)" and cli_path or "devcontainer") .. " --version 2>&1")
      if handle then
        local version = handle:read("*a")
        handle:close()
        vim.health.ok("devcontainer CLI available (" .. cli_path .. "): " .. version:gsub("%s+", " "))
      else
        vim.health.warn("devcontainer CLI found at " .. cli_path .. " but --version failed")
      end
    else
      vim.health.error(
        "devcontainer CLI not found at " .. cli_path .. "!\n"
          .. "Install it with: npm install -g @devcontainers/cli\n"
          .. "Or set cli_path in setup: require('devcontainer').setup{ cli_path = '/path/to/devcontainer' }\n"
          .. "See: https://github.com/devcontainers/cli"
      )
    end

    vim.health.start("Container runtime (Docker/Podman)")

    local config = require("devcontainer.config")
    local docker_cmd = config.docker_command or "docker"
    local has_docker = executor.is_executable(docker_cmd)
    local has_podman = executor.is_executable("podman")

    if has_docker then
      local handle = io.popen(docker_cmd .. " --version 2>&1")
      if handle then
        local version = handle:read("*a")
        handle:close()
        vim.health.ok(docker_cmd .. " available: " .. version:gsub("%s+", " "))
      end
    else
      vim.health.error(
        docker_cmd .. " not found on PATH.\n"
          .. "The installer streams the Neovim bundle via `" .. docker_cmd .. " exec -i`."
      )
    end

    if has_podman then
      local handle = io.popen("podman --version 2>&1")
      if handle then
        local version = handle:read("*a")
        handle:close()
        vim.health.ok("Podman available: " .. version:gsub("%s+", " "))
      end
    end

    vim.health.start("Nix (for Neovim bundle install)")
    if executor.is_executable("nix") then
      local handle = io.popen("nix --version 2>&1")
      if handle then
        local version = handle:read("*a")
        handle:close()
        vim.health.ok("nix available: " .. version:gsub("%s+", " "))
      end
    else
      vim.health.error(
        "nix not found on PATH.\n"
          .. "Required to build the Neovim bundle that is streamed into the container.\n"
          .. "Install Nix: https://nixos.org/download"
      )
    end
  end,
}
