-- Runs at STARTUP, not from the heidr module: that module is only loaded on demand,
-- so the bind never happened for an nvim nobody had opened the rail in yet.
-- Make sure THIS nvim is reachable on the cockpit's RPC socket, however it was started.
-- heidr's launch command passes --listen, but an nvim started by hand in the pane (the
-- original exited, you typed `nvim`) only inherits NVIM_LISTEN_ADDRESS — and 0.12 does not
-- bind that on its own. The rail then fires every session-switch RPC at a path with no
-- listener and the editor silently never moves.
do
  local addr = vim.env.NVIM_LISTEN_ADDRESS
  if addr and addr ~= "" then
    local bound = false
    for _, s in ipairs(vim.fn.serverlist()) do
      if s == addr then bound = true break end
    end
    if not bound then
      -- A leftover file from a dead nvim blocks the bind; it is safe to clear because a
      -- live one would have answered above.
      if vim.uv.fs_stat(addr) then pcall(vim.uv.fs_unlink, addr) end
      pcall(vim.fn.serverstart, addr)
    end
  end
end

require("core.keymaps")
require("core.options")
require("notes-sync")

-- Own filetype for .mdx so render-markdown can target it (and the lz.n
-- ft trigger can fire) without fighting markview on plain markdown.
vim.filetype.add({ extension = { mdx = "mdx" } })

-- Skip in kitty-scrollback nvim — that's a pager, not an editor.
if vim.env.KITTY_SCROLLBACK_NVIM ~= "true" then
  require("hunk-nvim").setup()
  require("file-watcher").setup()
  require("plan-nvim").setup()
  require("heidr").setup()

  -- Eager: session restore must hook VimEnter before it fires.
  vim.opt.sessionoptions:remove("terminal")
  -- Drop buffers from sessions — restoring 10+ files in a TS monorepo
  -- triggers a serial LSP-attach storm (10s+ blank screen). Layout/cwd/
  -- folds still restore.
  vim.opt.sessionoptions:remove("buffers")
  local auto_session = require("auto-session")
  auto_session.setup({
    -- Off: the agent-rail owns the window layout and restores per-session editor
    -- state itself (S.editor), so auto-restore-on-boot was redundant AND raced the
    -- rail's boot — intermittently dumping the last file into the roster pane.
    -- Manual restore is still available via <leader>wr.
    auto_restore_enabled = false,
    auto_session_suppress_dirs = { "~/", "~/Dev/", "~/Downloads", "~/Documents", "~/Desktop/" },
    restore_error_handler = function(error_msg)
      if error_msg and error_msg:find("E216", 1, true) and error_msg:find("SessionLoadPre", 1, true) then
        return true
      end
      return auto_session.default_restore_error_handler(error_msg)
    end,
  })
  vim.keymap.set("n", "<leader>wr", "<cmd>SessionRestore<CR>", { desc = "Restore session for cwd" })

  local map = vim.keymap.set
  map("n", "<C-g>j", function() require("hunk-nvim.signs").next_hunk() end, { desc = "Next hunk" })
  map("n", "<C-g>k", function() require("hunk-nvim.signs").prev_hunk() end, { desc = "Prev hunk" })
end
