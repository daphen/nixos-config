return {
	"markview.nvim",
	lazy = false,
	after = function()
		require("markview").setup({
			-- Your custom configuration here if needed
		})

		-- A language-less ``` block renders as "󰡯 Unknown", which reads like a warning.
		-- Mirror the plain-"text" style onto the fallback so such blocks (e.g. a plan's
		-- placement tree) read cleanly. Glyphs are copied from the text entry — no
		-- hardcoded private-use codepoints.
		local ok_ft, fts = pcall(require, "markview.filetypes")
		if ok_ft and fts.styles and fts.styles.nosyntax and fts.styles.text then
			local t, n = fts.styles.text, fts.styles.nosyntax
			n.name, n.sign, n.icon = "text", t.sign, t.icon
			n.sign_hl, n.icon_hl, n.border_hl = t.sign_hl, t.icon_hl, t.border_hl
		end

		-- Set conceallevel for markdown files specifically
		vim.api.nvim_create_autocmd("FileType", {
			pattern = "markdown",
			callback = function()
				vim.opt_local.conceallevel = 2
				vim.opt_local.concealcursor = ""
			end,
		})
	end,
}
