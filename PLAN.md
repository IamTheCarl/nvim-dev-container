# Refactor Plan: nvim-dev-container → devcontainer CLI Wrapper

## Summary

Replace ~2000 lines of custom Docker/Podman orchestration with the official `@devcontainers/cli` package. The plugin becomes a thin wrapper around `devcontainer up`, `devcontainer exec`, and related CLI commands.

## Architecture Changes

### What Stays
- `internal/executor.lua` — generic process runner for subprocesses
- `internal/log.lua` — logging system
- `status.lua` — in-memory state tracking
- `config.lua` — configuration store (simplified)
- `health.lua` — `:checkhealth` (updated checks)
- `commands.lua` — high-level commands (rewritten)
- `init.lua` — plugin entry point (rewritten)

### What Goes
- `container.lua` (448 lines) — replaced by CLI
- `compose.lua` (95 lines) — replaced by CLI
- `container_utils.lua` (68 lines) — replaced by CLI
- `config_file/parse.lua` (406 lines) — CLI handles JSONC parsing
- `config_file/jsonc.lua` (47 lines) — CLI uses npm jsonc-parser
- `internal/container_executor.lua` (75 lines) — CLI exec handles this
- `internal/runtimes/` (~900 lines) — entire runtime abstraction layer

### New Module
- `cli.lua` (~150 lines) — thin wrapper around devcontainer CLI

## Key Design Decisions

### Neovim Installation (Hybrid Approach)
Default: download pre-compiled binary from GitHub releases (architecture-aware). Users can override `nvim_installation_commands_provider` for custom distro-specific installs.

### Socket Approach
1. Plugin creates temp dir via `vim.fn.tempname()`
2. Pass as `--mount type=bind,source=<temp>,target=/tmp/nvim-dev-container` to `devcontainer up`
3. Headless Neovim inside listens on `/tmp/nvim-dev-container/<tag>.sock`
4. Host connects via `:connect <temp>/<tag>.sock`

### Socket Tag Format
`uuid:sub(1,8) + "-" + sha256(config_path):sub(1,8)` — e.g., `a3f1b2c4-8e7d6f5a.sock`

### Commands
Consolidate to single `DevcontainerAttach` command.

### Docker Compose
Full support via CLI — no special handling needed in plugin.

### Backwards Compatibility
None. Require devcontainer CLI. Give helpful error if missing.

## Implementation Steps

1. Create `cli.lua` — wrapper around devcontainer CLI
2. Rewrite `internal/nvim.lua` — pre-compiled binary installer
3. Rewrite `config.lua` — remove runtime/compose options
4. Rewrite `commands.lua` — call CLI instead of direct docker
5. Rewrite `init.lua` — simplified setup, single command
6. Update `health.lua` — check CLI availability
7. Delete old modules
8. Update tests
9. Run `:checkhealth devcontainer`

## Estimated Line Count
- Before: ~2,600 lines
- After: ~1,200 lines
- Reduction: ~55%
