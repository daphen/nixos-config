return {
	"lualine.nvim",
	lazy = false,
	event = { "BufReadPost", "BufNewFile", "VimEnter" },
	after = function()
		-- local icons = require("config.icons")
		local function get_scrollbar()
			local sbar_chars = {
				"▔",
				"🮂",
				"🬂",
				"🮃",
				"▀",
				"▄",
				"▃",
				"🬭",
				"▂",
				"▁",
			}

			local cur_line = vim.api.nvim_win_get_cursor(0)[1]
			local lines = vim.api.nvim_buf_line_count(0)

			local i = math.floor((cur_line - 1) / lines * #sbar_chars) + 1
			if i > #sbar_chars then i = #sbar_chars end
			local sbar = string.rep(sbar_chars[i], 2)

			-- Just return the raw characters
			return sbar
		end

		-- Function to find project root based on package.json
		local function get_project_root()
			local function find_package_json(path)
				local package_json = path .. "/package.json"
				local f = io.open(package_json, "r")
				if f then
					f:close()
					return path
				end

				-- Try parent directory if not at filesystem root
				local parent = path:match("(.+)/[^/]+$")
				if parent and parent ~= path then return find_package_json(parent) end

				return nil
			end

			local current_file = vim.fn.expand("%:p:h")
			local root_dir = find_package_json(current_file)

			if root_dir then
				-- Extract just the folder name from the full path
				local folder_name = root_dir:match("([^/]+)$")
				return " " .. folder_name .. " "
			else
				return ""
			end
		end

		-- Statusline shows the file being edited in the MAIN editor window, even
		-- when focus is in a rail pane (agent-*) — so it never reads "agent-chat".
		local function editor_filename()
			local cur = vim.api.nvim_get_current_buf()
			local ebuf, name = cur, vim.api.nvim_buf_get_name(cur)
			if name == "" or name:match("agent%-") then
				for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
					local b = vim.api.nvim_win_get_buf(w)
					local n = vim.api.nvim_buf_get_name(b)
					if vim.bo[b].buftype == "" and n ~= "" and not n:match("agent%-") then
						ebuf, name = b, n
						break
					end
				end
			end
			if name == "" then return "" end
			return vim.fn.fnamemodify(name, ":.") .. (vim.bo[ebuf].modified and " ●" or "")
		end

		-- Sections sit on a subtle surface bg (a lighter bar), read fresh from the
		-- theme palette so it tracks light/dark.
		local function get_theme()
			local pal = vim.g.theme_palette or {}
			local dark = vim.o.background == "dark"
			local surface = pal.bg_surface or (dark and "#24242b" or "#E8EAED")
			local fg = dark and "#EDEDED" or "#2D4A3D"
			local s = { fg = fg, bg = surface }
			return { normal = { a = s, b = s, c = s, x = s, y = s, z = { fg = "#ED333B", bg = surface } } }
		end

		require("lualine").setup({
			options = {
				theme = get_theme(),
				globalstatus = true,
				icons_enabled = true,
				component_separators = { left = "", right = "" },
				section_separators = { left = "", right = "" },
			},
			sections = {
				lualine_a = {},
				lualine_b = {
					{ "fancy_branch", padding = { left = 0, right = 2 } },
					{ editor_filename },
					{
						"fancy_diagnostics",
						sources = { "nvim_lsp" },
						symbols = { error = " ", warn = " ", info = " " },
						diagnostics_color = {
							error = "DiagnosticError",
							warn = "DiagnosticWarn",
							info = "DiagnosticInfo",
						},
					},
					{
						"diagnostics",
						sources = { "nvim_lsp" },
						symbols = { error = "E:", warn = "W:", info = "I:" },
						diagnostics_color = {
							error = "DiagnosticError",
							warn = "DiagnosticWarn",
							info = "DiagnosticInfo",
						},
					},
					{ "fancy_searchcount" },
				},
				lualine_c = {
					{
						"macro_recording",
						fmt = function(str) return string.upper(str) end,
						color = { fg = "#121214", bg = "#ED333B", gui = "bold" },
						padding = { left = 2, right = 2 },
					},
					{
						function() return require("agent-nvim").statusline() end,
						padding = { left = 1, right = 1 },
					},
				},
				lualine_x = {
					{ "filetype", padding = { left = 1, right = 2 } },
					"fancy_diff",
					{
						function() return get_project_root() end,
						padding = { left = 0, right = 0 },
					},
				},
				lualine_y = {},
				lualine_z = {
					{
						get_scrollbar,
						padding = { left = 1, right = 0 },
						separator = "",
					},
				},
			},
			extensions = { "lazy" },
		})

		vim.api.nvim_create_autocmd("OptionSet", {
			pattern = "background",
			callback = function()
				vim.defer_fn(function()
					require("lualine").setup({
						options = {
							theme = get_theme(),
							globalstatus = true,
							icons_enabled = true,
							component_separators = { left = "", right = "" },
							section_separators = { left = "", right = "" },
							disabled_filetypes = {
								statusline = {},
								winbar = {},
							},
						},
						sections = {
							lualine_a = {},
							lualine_b = {
								{ "fancy_branch", padding = { left = 0, right = 2 } },
								{ editor_filename },
								{
									"fancy_diagnostics",
									sources = { "nvim_lsp" },
									symbols = { error = "󰅚 ", warn = "󰀪 ", info = "󰋽 " },
									diagnostics_color = {
										error = "DiagnosticError",
										warn = "DiagnosticWarn",
										info = "DiagnosticInfo",
									},
								},
								{ "fancy_searchcount" },
							},
							lualine_c = {
								{
									"macro_recording",
									fmt = function(str) return string.upper(str) end,
									color = { fg = "#121214", bg = "#ED333B", gui = "bold" },
									padding = { left = 2, right = 2 },
								},
							},
							lualine_x = {
								{ "filetype", padding = { left = 1, right = 2 } },
								"fancy_diff",
								{
									function() return get_project_root() end,
									padding = { left = 0, right = 0 },
								},
							},
							lualine_y = {},
							lualine_z = {
								{
									get_scrollbar,
									padding = { left = 1, right = 0 },
									separator = "",
								},
							},
						},
						extensions = { "lazy" },
					})
				end, 50)
			end,
		})
	end,
}
