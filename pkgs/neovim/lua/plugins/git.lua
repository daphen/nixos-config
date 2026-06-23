return {
	{
		"diffview.nvim",
		cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewToggleFiles", "DiffviewFocusFiles", "DiffviewFileHistory" },
		keys = {
			{ "<leader>gv", "<cmd>DiffviewOpen<cr>", desc = "DiffView Open" },
			{ "<C-g>d", function()
				if require("diffview.lib").get_current_view() then
					vim.cmd("DiffviewClose")
					return
				end
				local ok, signs = pcall(require, "hunk-nvim.signs")
				local base = ok and signs.current_base and signs.current_base()
				vim.cmd("DiffviewOpen " .. (base or "HEAD"))
			end, desc = "DiffView vs branch base (toggle)" },
			{ "<leader>gV", "<cmd>DiffviewClose<cr>", desc = "DiffView Close" },
			{ "<leader>gh", "<cmd>DiffviewFileHistory %<cr>", desc = "File History" },
			{ "<leader>gH", "<cmd>DiffviewFileHistory<cr>", desc = "Branch History" },
		},
		opts = {
			enhanced_diff_hl = true,
			view = {
				default = {
					layout = "diff2_horizontal",
				},
				file_history = {
					layout = "diff2_horizontal",
				},
			},
		},
	},
}
