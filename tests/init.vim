set rtp+=.

set noswapfile

lua << EOF
require("nvim-treesitter").install({'json'}):wait(6000)

-- Changing path_sep for tests - for Windows tests compatibility
require("devcontainer.internal.utils").path_sep = "/"

vim.api.nvim_create_user_command("RunTests", function(opts)
  local path = opts.fargs[1] or "tests"
  require("plenary.test_harness").test_directory(path, { init = "./tests/init.vim" })
end, { nargs = "?" })
EOF

function! StatusLine()
  lua << EOF
local build_status_last = require("devcontainer.status").find_build({ running = true })
if build_status_last then
  local status
  status =
  (build_status_last.build_title or "")
  .. "["
  .. (build_status_last.current_step or "")
  .. "/"
  .. (build_status_last.step_count or "")
  .. "]"
  .. (build_status_last.progress and "(" .. build_status_last.progress .. "%%)" or "")
  vim.g.mystatus = status
else
  vim.g.mystatus = "NONE"
end
EOF
  return g:mystatus
endfunction

function! SetupStatusLineAutocommand()
  set statusline=%!StatusLine()
  autocmd User DevcontainerBuildProgress redrawstatus
endfunction
