---@mod devcontainer.config Devcontainer plugin config module
---@brief [[
---Provides current devcontainer plugin configuration
---Don't change directly, use `devcontainer.setup{}` instead
---Can be used for read-only access
---@brief ]]

local M = {}

local function workspace_folder_provider()
  local folders = vim.lsp.buf.list_workspace_folders()
  return folders[1] or vim.loop.cwd()
end

local function config_search_start()
  return vim.loop.cwd()
end

local function default_devcontainer_json_template()
  return {
    "{",
    [[  "name": "Your Definition Name Here (Community)",]],
    [[// Update the 'image' property with your Docker image name.]],
    [[// "image": "alpine",]],
    [[// Or define build if using Dockerfile.]],
    [[// "build": {]],
    [[//     "dockerfile": "Dockerfile",]],
    [[// [Optional] You can use build args to set options. e.g. 'VARIANT' below affects the image in the Dockerfile]],
    [[//     "args": { "VARIANT": "buster" },]],
    [[// }]],
    [[// Or use docker-compose]],
    [[// Update the 'dockerComposeFile' list if you have more compose files or use different names.]],
    [["dockerComposeFile": "docker-compose.yml",]],
    [[// Use 'forwardPorts' to make a list of ports inside the container available locally.]],
    [[// "forwardPorts": [],]],
    [[// Define mounts.]],
    [[// "mounts": [ "source=${localWorkspaceFolder},target=/workspaces/${localWorkspaceFolderBasename} ]]
      .. [[,type=bind,consistency=delegated" ],]],
    [[// Uncomment when using a ptrace-based debugger like C++, Go, and Rust]],
    [[// "runArgs": [ "--cap-add=SYS_PTRACE", "--security-opt", "seccomp=unconfined" ],]],
    [[}]],
  }
end

---Provides docker build path
---By default uses first LSP workplace folder or vim.loop.cwd()
---@type function
M.workspace_folder_provider = workspace_folder_provider

---Provides starting search path for .devcontainer.json
---After this search moves up until root
---By default it uses vim.loop.cwd()
---@type function
M.config_search_start = config_search_start

---Flag to disable recursive search for .devcontainer config files
---By default plugin will move up to root looking for .devcontainer files
---This flag can be used to prevent it and only look in M.config_search_start
---@type boolean
M.disable_recursive_config_search = false

---Provides template for creating new .devcontainer.json files
---This function should return a table listing lines of the file
---@type function
M.devcontainer_json_template = default_devcontainer_json_template

---Nix flake attribute used to build the Neovim bundle that is installed
---into the container. Defaults to `nixpkgs#neovim`. Override to bundle
---your own Neovim derivation (e.g. a flake containing your full config):
---  require("devcontainer").setup({ nvim_nix_attribute = "github:me/dotfiles#nvim" })
---Raw `/nix/store/...` paths are not accepted by `nix bundle`; use a
---flake reference.
---@type string|nil
M.nvim_nix_attribute = nil

---Directory inside the container where the streamed Neovim is installed.
---The extracted AppImage lands at `<nvim_install_dir>/app/`, with the
---launcher at `<nvim_install_dir>/app/AppRun`. The value is passed
---verbatim to the container shell, so `$HOME` expansion works.
---@type string
M.nvim_install_dir = "$HOME/.nvim-devcontainer"

---Maximum number of Nix bundles to retain in the host cache. Older
---bundles (by mtime) are pruned after a successful install.
---@type integer
M.nvim_cache_versions = 3

---Name of the docker executable on PATH. Override for podman, etc.
---@type string
M.docker_command = "docker"

---@alias LogLevel
---| '"trace"'
---| '"debug"'
---| '"info"'
---| '"warn"'
---| '"error"'
---| '"fatal"'

---Current log level
---@type LogLevel
M.log_level = "info"

---List of env variables to add to all containers when attaching
---Applicable only to `devcontainer.commands` functions!
---NOTE: This supports "${containerEnv:VAR_NAME}" syntax to use variables from container
---@type table[string, string]
M.remote_env = {}

---Path to the devcontainer CLI executable.
---If not set, the plugin will search for 'devcontainer' on PATH.
---Useful when the CLI is installed via Nix and not on PATH.
---@type string|nil
M.cli_path = nil

---Shell to use inside the container for Neovim's &shell option.
---When nil (default), the login shell is auto-detected from the container's
---/etc/passwd for the remoteUser (or the current uid if remoteUser is not set).
---Set to an explicit path (e.g. "/bin/bash") to skip the detection round-trip.
---@type string|nil
M.nvim_shell = nil

return M
