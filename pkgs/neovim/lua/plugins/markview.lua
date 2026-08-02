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

		-- Markview invents its own heading/code colors (blue-gray banners) and
		-- re-applies them on ColorScheme, clobbering the colorscheme's groups.
		-- Sync its groups from the theme's canonical markdown tokens (the
		-- RenderMarkdown* groups both custom themes define on the elevation
		-- ladder), deferred so we run after markview's own re-apply.
		local function sync_markview_hl()
			local function get(n)
				return vim.api.nvim_get_hl(0, { name = n, link = false })
			end
			local code, inline, hbg = get("RenderMarkdownCode"), get("RenderMarkdownCodeInline"), get("RenderMarkdownH2Bg")
			if not (code.bg or inline.bg) then return end -- non-custom theme: leave markview alone
			vim.api.nvim_set_hl(0, "MarkviewCode", { bg = code.bg })
			-- YAML frontmatter borders are half-block chars (▄▀) drawn with MarkviewCodeFg
			-- as FOREGROUND; unset it fell to markview's purple, bg-only left the fill white.
			-- Set fg AND bg to the heading-bar bg so the border reads as a solid heading bar.
			vim.api.nvim_set_hl(0, "MarkviewCodeFg", { fg = hbg.bg, bg = hbg.bg })
			vim.api.nvim_set_hl(0, "MarkviewCodeInfo", { fg = get("Comment").fg, bg = code.bg })
			vim.api.nvim_set_hl(0, "MarkviewInlineCode", { fg = inline.fg, bg = inline.bg })
			for i = 1, 6 do
				local h = get("@markup.heading." .. i .. ".markdown")
				vim.api.nvim_set_hl(0, "MarkviewHeading" .. i, { fg = h.fg, bg = hbg.bg })
				vim.api.nvim_set_hl(0, "MarkviewHeading" .. i .. "Sign", { fg = h.fg })
			end
		end
		sync_markview_hl()
		vim.api.nvim_create_autocmd("ColorScheme", {
			callback = function()
				vim.defer_fn(sync_markview_hl, 50)
			end,
		})

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
