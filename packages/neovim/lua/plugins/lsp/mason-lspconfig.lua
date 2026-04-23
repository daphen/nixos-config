return {
	"mason-lspconfig.nvim",
	lazy = true,  -- LSP config will trigger loading when needed
	after = function()
		local lspconfig = require("lspconfig")
		local cmp_nvim_lsp = require("cmp_nvim_lsp")
		local capabilities = cmp_nvim_lsp.default_capabilities()

		require("mason-lspconfig").setup({
			ensure_installed = {
				"ts_ls",
				"eslint",
				"html",
				-- "cssls",  -- Disabled: Tailwind v4 uses unknown at-rules
				"tailwindcss",
				"lua_ls",
				"emmet_ls",
				"svelte",
				"graphql",
				"pylsp",
			},
			automatic_installation = false,  -- Disabled to prevent cssls auto-install
			handlers = {
				-- Default handler for servers without custom config
				function(server_name)
					lspconfig[server_name].setup({
						capabilities = capabilities,
					})
				end,
				-- Custom handlers for servers with specific configs
				["html"] = function()
					lspconfig.html.setup({
						capabilities = capabilities,
						filetypes = { "hbs" },
					})
				end,
				["ts_ls"] = function()
					lspconfig.ts_ls.setup({
						capabilities = capabilities,
						handlers = {
							["textDocument/publishDiagnostics"] = function(_, result, ctx, config)
								-- Filter diagnostics
								if result.diagnostics then
									result.diagnostics = vim.tbl_filter(function(diagnostic)
										local code = diagnostic.code

										-- Convert string codes to numbers if needed
										if type(code) == "string" then
											code = tonumber(code)
										end

										-- Filter ESLint diagnostics from ts_ls to prevent duplicates
										if diagnostic.source == "eslint" then
											return false
										end

										-- Filter all Next.js-specific warnings (71XXX codes) during TanStack Start migration
										if type(code) == "number" and code >= 71000 and code < 72000 then
											return false
										end

										return true
									end, result.diagnostics)
								end

								vim.lsp.handlers["textDocument/publishDiagnostics"](_, result, ctx, config)
							end,
						},
					})
				end,
				["eslint"] = function()
					lspconfig.eslint.setup({
						capabilities = capabilities,
						on_attach = function(client, bufnr)
							-- Enable formatting via ESLint
							vim.api.nvim_create_autocmd("BufWritePre", {
								buffer = bufnr,
								command = "EslintFixAll",
							})
						end,
						settings = {
							workingDirectories = { mode = "auto" },
						},
					})
				end,
			-- cssls disabled - Tailwind v4 uses unknown at-rules that cause warnings
			-- ["cssls"] = function()
			-- 	lspconfig.cssls.setup({
			-- 		capabilities = capabilities,
			-- 		settings = {
			-- 			css = {
			-- 				validate = false,
			-- 			},
			-- 			scss = {
			-- 				validate = false,
			-- 			},
			-- 			less = {
			-- 				validate = false,
			-- 			},
			-- 		},
			-- 	})
			-- end,
				["tailwindcss"] = function()
					lspconfig.tailwindcss.setup({
						capabilities = capabilities,
						settings = {
							tailwindCSS = {
								experimental = {
									classRegex = {
										{ "cva\\(([^)]*)\\)", "[\"'`]([^\"'`]*).*?[\"'`]" },
										{ "cx\\(([^)]*)\\)", "(?:'|\"|`)([^']*)(?:'|\"|`)" },
									},
								},
							},
						},
					})
				end,
				["lua_ls"] = function()
					lspconfig.lua_ls.setup({
						capabilities = capabilities,
						settings = {
							Lua = {
								telemetry = { enable = false },
								diagnostics = { globals = { "vim" } },
								workspace = {
									checkThirdParty = false,
									library = {
										[vim.fn.expand("$VIMRUNTIME/lua")] = true,
										[vim.fn.stdpath("config") .. "/lua"] = true,
									},
								},
							},
						},
					})
				end,
				["emmet_ls"] = function()
					lspconfig.emmet_ls.setup({
						capabilities = capabilities,
						filetypes = {
							"html",
							"typescriptreact",
							"javascriptreact",
							"css",
							"sass",
							"scss",
							"less",
							"svelte",
						},
					})
				end,
			},
		})
	end,
}
