return {
	"nvim-lspconfig",
	event = "VimEnter",  -- Load after session restoration to avoid LSP flood
	after = function()
		-- Configure LSP floating window borders globally
		local border = "rounded"

		-- Override the default open_floating_preview function to always use borders
		local orig_util_open_floating_preview = vim.lsp.util.open_floating_preview
		function vim.lsp.util.open_floating_preview(contents, syntax, opts, ...)
			opts = opts or {}
			opts.border = opts.border or border
			return orig_util_open_floating_preview(contents, syntax, opts, ...)
		end

		-- Also set handlers explicitly
		vim.lsp.handlers["textDocument/hover"] = vim.lsp.with(vim.lsp.handlers.hover, {
			border = border,
		})
		vim.lsp.handlers["textDocument/signatureHelp"] = vim.lsp.with(vim.lsp.handlers.signature_help, {
			border = border,
		})

		-- Filter out CSS unknownAtRules and Next.js diagnostics globally
		local orig_handler = vim.lsp.handlers["textDocument/publishDiagnostics"]
		vim.lsp.handlers["textDocument/publishDiagnostics"] = function(err, result, ctx, config)
			if result and result.diagnostics then
				result.diagnostics = vim.tbl_filter(function(d)
					local code = d.code

					-- Convert string codes to numbers if needed
					if type(code) == "string" then
						code = tonumber(code)
					end

					-- Filter out Tailwind CSS at-rules warnings
					if d.code == "unknownAtRules" and d.source == "css" then
						return false
					end

					-- Filter all Next.js-specific warnings (71XXX codes) during TanStack Start migration
					if type(code) == "number" and code >= 71000 and code < 72000 then
						return false
					end

					return true
				end, result.diagnostics)
			end
			orig_handler(err, result, ctx, config)
		end

		-- Configure diagnostics globally
		vim.diagnostic.config({
			virtual_text = {
				source = true,
				severity = {
					min = vim.diagnostic.severity.HINT,
				},
			},
			float = {
				source = true,
				border = "rounded",
			},
			signs = true,
			underline = true,
			update_in_insert = false,
			severity_sort = true,
		})

		-- Diagnostic highlights are handled by the theme system in lua/theme/highlights.lua
		-- No need to set them here as they're already defined with proper theme colors

		-- Debug command to check diagnostic severity
		vim.api.nvim_create_user_command("DiagnosticInfo", function()
			local diagnostics = vim.diagnostic.get(0)
			for _, d in ipairs(diagnostics) do
				local severity_name = vim.diagnostic.severity[d.severity]
				print(string.format("[%s] %s (code: %s, source: %s)", severity_name, d.message:sub(1, 50), d.code or "none", d.source or "unknown"))
			end
		end, {})

		-- Disable concealing which can cause URL highlighting issues (except for markdown)
		vim.api.nvim_create_autocmd("FileType", {
			pattern = "*",
			callback = function()
				if vim.bo.filetype ~= "markdown" then
					vim.opt_local.conceallevel = 0
					vim.opt_local.concealcursor = ""
				end
			end,
		})

		-- KEYMAPS
		vim.keymap.set("n", "K", vim.lsp.buf.hover, { desc = "Show description" })
		vim.keymap.set("n", "gD", vim.lsp.buf.declaration, { desc = "Go to declaration" })
		vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, { desc = "Rename" })
		vim.keymap.set("n", "<leader>d", vim.diagnostic.open_float, { desc = "Open diagnostics" })
		vim.keymap.set("n", "gd", vim.lsp.buf.definition, { desc = "Go to definition" })
		vim.keymap.set("n", "gs", ":vsplit | lua vim.lsp.buf.definition()<CR>") -- open defining buffer in vertical split
		-- vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, { desc = "Code action" })
		vim.keymap.set("n", "]d", function() vim.diagnostic.jump({ count = 1, float = true }) end, { desc = "Go to next diagnostics" })
		vim.keymap.set("n", "[d", function() vim.diagnostic.jump({ count = -1, float = true }) end, { desc = "Go to prev diagnostics" })
	end,
}
