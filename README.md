# nvim-dev-container

[![License](https://img.shields.io/badge/license-MIT-brightgreen)](/LICENSE)

A thin Neovim front-end for the official [`@devcontainers/cli`][cli]. The plugin
delegates all container orchestration (image build, container up, lifecycle
hooks, feature resolution, mount/env handling, etc.) to the CLI and focuses on
two things:

1. Finding the nearest `devcontainer.json` for the current workspace.
2. Streaming a locally-built Neovim into the container and attaching to it as a
   remote UI client (`:connect`).

This is a fork rewritten on top of the CLI; see git history for the previous
custom Docker/Podman/compose orchestration.

[cli]: https://github.com/devcontainers/cli

## Requirements

- Neovim 0.12.0+ (uses the built-in `:connect` remote UI client).
- The [`@devcontainers/cli`][cli] binary on `PATH` (or pass `cli_path`).
- A container runtime the CLI can drive (Docker or Podman).
- `nix` on `PATH` on the host — used by the installer to produce an AppImage of
  the configured Neovim that gets streamed into the container.
- For projects with local-path features that live outside the workspace's
  `.devcontainer/` folder, a CLI build that resolves feature parent paths from
  the config file's directory rather than `<workspace>/.devcontainer`.

## Installation

Install with your plugin manager of choice. The plugin has no Lua dependencies
beyond Neovim itself.

```lua
{ 'IamTheCarl/nvim-dev-container' }
```

## Usage

```lua
require("devcontainer").setup({
  -- Optional. Flake reference passed to `nix bundle` to produce the Neovim
  -- that gets installed into the container. Defaults to `nixpkgs#neovim`.
  -- nvim_nix_attribute = "github:me/dotfiles#neovim",
})
```

Then, from inside a project that contains a `devcontainer.json`:

```
:DevcontainerAttach
```

The plugin will:

1. Walk up from `config_search_start()` looking for
   `.devcontainer/devcontainer.json` or `.devcontainer.json`.
2. Ask the CLI to read the merged configuration.
3. Find or create the container via `devcontainer up`.
4. Run `onCreateCommand`, `updateContentCommand`, `postCreateCommand` inside
   the container.
5. Probe for a previously-installed Neovim under `nvim_install_dir`; if absent,
   build the configured `nvim_nix_attribute` into an AppImage on the host,
   stream it into the container in 1 MiB chunks over `docker exec`, and
   extract it.
6. Launch headless Neovim inside the container on a random port bound to
   `0.0.0.0`, resolve the container's bridge IP, and `:connect` to it.
7. Run `postAttachCommand` on the host (per the devcontainer spec).

Use `:detach` to disconnect from the remote UI without stopping the container.

## Commands

When `generate_commands` is not `false`:

| Command | Description |
|---------|-------------|
| `DevcontainerAttach [cmd]` | Find/start the container and attach Neovim (default) or run a custom command. |
| `DevcontainerStop` | Recreate the container (`up --remove-existing-container`). |
| `DevcontainerExec <cmd>` | Run a command inside the existing container. |
| `DevcontainerLogs` | Open the plugin's log file. |
| `DevcontainerEditNearestConfig` | Open or scaffold `devcontainer.json`. |
| `DevcontainerAddNeovim` | Install (or re-install) Neovim into the container. |
| `DevcontainerClearCache` | Drop the on-host Nix AppImage cache. |
| `DevcontainerCopyIn[!] [src…] [dest]` | Copy file(s)/director(ies) from host into the container. |
| `DevcontainerCopyOut[!] [src…] [dest]` | Copy file(s)/director(ies) from container to host. |

### Copying files

Both copy commands follow **scp semantics**: supply one or more sources and a
destination as positional arguments. The last argument is always the
destination. If only one argument (or no arguments) is given, the missing
side(s) are prompted interactively.

```vim
:DevcontainerCopyIn  /host/my-script.sh  ~/bin/my-script.sh
:DevcontainerCopyOut ~/logs              /tmp/container-logs

" Multiple sources — destination must be an existing directory
:DevcontainerCopyIn  file1.txt file2.txt  /workspace/

" Bang form skips the overwrite confirmation prompt
:DevcontainerCopyIn! /host/config.toml  ~/config.toml
```

**Container-side paths** are shell-expanded inside the container, so `~`,
`$HOME`, `$USER`, `/home/$USER/…`, and any other environment variable are all
supported. Tab-completion is available on container-side arguments (see note
below).

**Tab-completion on container paths** shells out to the container to `ls`, so
it causes a brief synchronous pause (typically < 500 ms on a local Docker
daemon) on the first `<Tab>` press. Host-side paths use normal file completion.

**Directory semantics** follow `docker cp`:
- Destination does not exist → created as a copy of the source.
- Destination is a regular file → overwritten (with confirmation, unless `!`).
- Destination is a directory → source is placed inside it as `dest/basename(src)`.

**`-L` / `--follow-link`** is not a user-visible flag in v1; the default
`docker cp` behaviour (follow source symlinks) applies.

## Setup options

Every key is optional. Defaults shown.

```lua
require("devcontainer").setup({
  config_search_start = function() return vim.loop.cwd() end,
  workspace_folder_provider = function()
    return (vim.lsp.buf.list_workspace_folders() or {})[1] or vim.loop.cwd()
  end,
  devcontainer_json_template = function() --[[ returns a list of lines ]] end,

  -- Neovim installer
  nvim_nix_attribute = "nixpkgs#neovim", -- flake ref consumed by `nix bundle`
  nvim_install_dir = "$HOME/.nvim-devcontainer", -- inside the container
  nvim_cache_versions = 3, -- on-host AppImage cache retention

  -- Container runtime
  docker_command = "docker", -- override to "podman" etc.
  cli_path = nil,            -- absolute path to devcontainer CLI; nil = PATH lookup
  remote_env = {},           -- forwarded to `devcontainer exec` as --remote-env
  nvim_shell = nil,          -- shell for &shell in the container-side nvim;
                             -- nil = auto-detect from container's /etc/passwd
                             -- (mirrors VSCode: SHELL env > login shell > /bin/sh)
                             -- set to "/bin/bash" to skip detection round-trip

  -- Misc
  generate_commands = true,
  autocommands = {
    init = false,   -- true|"ask" to auto-attach when a devcontainer.json is found
    clean = false,  -- auto-stop on VimLeavePre
    update = false, -- auto-restart when devcontainer.json changes
  },
  log_level = "info",
  disable_recursive_config_search = false,
})
```

## Architecture

```
lua/devcontainer/
  cli.lua        -- thin wrapper around @devcontainers/cli (up/exec/recreate/read-config/find-container)
  commands.lua   -- user-facing operations; find_nearest_config, attach flow, lifecycle hooks
  config.lua     -- plugin config singleton
  health.lua     -- :checkhealth
  init.lua       -- setup() + DevcontainerXxx user commands + optional autocommands
  status.lua     -- in-process container/build status tracking
  internal/
    cmdline.lua, executor.lua, log.lua, utils.lua, validation.lua
    installer.lua -- nix-bundle host-side cache + chunked stream into container
    nvim.lua      -- is_installed probe; add_neovim delegates to installer
```

## Testing

```sh
./scripts/test
```

This bootstraps a local `.testenv/` with plenary and nvim-treesitter and runs
the plenary harness against `tests/`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
