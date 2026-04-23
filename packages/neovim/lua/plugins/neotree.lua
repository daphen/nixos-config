return {
	"neo-tree.nvim",
	keys = {
		{ "<leader>o", "<cmd>Neotree toggle position=float<cr>", desc = "Toggle NeoTree" },
	},
	after = function()
		require("neo-tree").setup({
			popup_border_style = "rounded",
			default_component_configs = {
				filesystem = {
					follow_current_file = {
						enabled = true,
						leave_dirs_open = true,
					},
					filtered_items = {
						visible = true,
						hide_dotfiles = false,
						hide_gitignored = true,
						never_show = {
							".DS_Store",
							"thumbs.db",
						},
					},
				},
				buffers = {
					follow_current_file = {
						enabled = true,
						leave_dirs_open = false,
					},
				},
			},
		})
	end,
}
