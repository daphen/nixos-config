-- Core setup (loaded before plugins)
require("core.keymaps")
require("core.options")
require("notes-sync")

-- Local lua modules (not lz.n plugins — they live on rtp, not packpath/opt).
-- ai-tracker registers its own commands and sets up autocmds on setup().
require("ai-tracker").setup({
  log_file = vim.fn.expand("~/.local/share/nvim/ai-changes.jsonl"),
  max_entries = 1000,
  auto_reload = true,
})

-- ai-tracker keymaps (moved here from a would-be lz.n spec since ai-tracker
-- is a local lua module rather than a pack/opt plugin).
local map = vim.keymap.set
map("n", "<C-g><C-g>", function() require("ai-tracker").show() end, { desc = "AI Changes (by file)" })
map("n", "<C-g>a",     function() require("ai-tracker").show_all_lines() end, { desc = "AI Changes (all lines)" })
map("n", "<C-g>p",     function() require("ai-tracker").show_grouped() end, { desc = "AI Changes (grouped by prompt)" })
map("n", "<C-g>P",     function() require("ai-tracker").show_prompt_files() end, { desc = "AI Prompts & Files" })
map("n", "<C-g>j",     function() require("ai-tracker").next() end, { desc = "Next AI change" })
map("n", "<C-g>k",     function() require("ai-tracker").prev() end, { desc = "Previous AI change" })
map("n", "<C-g>r",     function() require("ai-tracker").reset_tracking() end, { desc = "Reset AI tracking" })
map("n", "<leader>ap", function() require("ai-tracker").annotate_prompt() end, { desc = "Annotate AI prompt" })
map("n", "<leader>ac", function() require("ai-tracker").clear_clean_files() end, { desc = "Clear AI tracking for clean files" })
map("n", "<leader>aR", function() require("ai-tracker").reset_tracking() end, { desc = "Reset AI tracking (new)" })

-- Remaining plugins are loaded via lz.n from nvimWrapper's initLua spec:
--   require('lz.n').load('plugins')
--   require('lz.n').load('plugins.lsp')
-- No lazy.nvim bootstrap needed — plugins are pre-installed by nix.
