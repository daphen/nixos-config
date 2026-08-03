return {
	"noice.nvim",
	event = "VimEnter",
	after = function()
		require("notify").setup({
			stages = "static",
			background_colour = "#000000",
		})

		require("noice").setup({
			presets = {
				command_palette = true,
				long_message_to_split = true,
			},
			lsp = {
				-- Disable all LSP overrides to use native Neovim borders
				override = {},
			},
			routes = {
				{
					filter = {
						event = "notify",
						find = "No information available",
					},
					opts = { skip = true },
				},
				{
					filter = {
						event = "msg_show",
						kind = "",
						find = "written",
					},
					opts = { skip = true },
				},
				{
					-- autoread buffer-reload chatter — constant noise in the cockpit
					-- (the agent rewrites open buffers via plan pulls / edits). Still
					-- lands in :messages; just no popup. Matches our echomsg + nvim's
					-- native "changed on disk" wording.
					filter = {
						event = "msg_show",
						find = "changed on disk",
					},
					opts = { skip = true },
				},
			},
		})

		vim.keymap.set("n", "<leader>ne", function() require("noice").cmd("errors") end)
	end,
}
