return {
	"lualine.nvim",
	lazy = false,
	event = { "BufReadPost", "BufNewFile", "VimEnter" },
	after = function()
		-- lualine-so-fancy is an opt (lazy) plugin with no lz.n spec of its own, so
		-- nothing force-loads it — its fancy_branch/fancy_diff/fancy_diagnostics
		-- components would silently render nothing (the "missing git stuff"). Pull it
		-- onto the runtimepath before setup references those components.
		pcall(vim.cmd, "packadd lualine-so-fancy")

		-- Diff stat vs the SAME base as the hunk-nvim inline signs (current_base()),
		-- added/changed/removed counted from the diff hunk headers (gitsigns-style).
		-- Scope: the CURRENT FILE when you're focused in a worktree file; the WHOLE
		-- worktree when you're in the chat/plan (a rail buffer or a file outside the
		-- worktree repo). Cached; recomputed only on buffer/cwd/save/focus change.
		local git_cache = { diff = { added = 0, modified = 0, removed = 0 } }
		local refreshing = false
		local function refresh_git()
			if refreshing then return end
			refreshing = true
			vim.schedule(function()
				local added, changed, removed = 0, 0, 0
				local root = vim.fn.systemlist({ "git", "-C", vim.fn.getcwd(), "rev-parse", "--show-toplevel" })[1]
				if root and root ~= "" then
					local base = "HEAD"
					local ok, signs = pcall(require, "hunk-nvim.signs")
					if ok and signs.current_base then
						local b = signs.current_base()
						if b and b ~= "" then base = b end
					end
					local file = vim.fn.expand("%:p")
					local in_worktree = file ~= "" and vim.bo.buftype == "" and file:sub(1, #root + 1) == root .. "/"
					local args = { "git", "-C", root, "diff", "--unified=0", "--no-color", base }
					if in_worktree then args[#args + 1] = "--"; args[#args + 1] = file end
					local out = vim.fn.systemlist(args)
					if vim.v.shell_error == 0 then
						for _, l in ipairs(out) do
							local oc, nc = l:match("^@@ %-%d+,?(%d*) %+%d+,?(%d*)")
							if oc then
								local o = (oc == "" and 1) or tonumber(oc)
								local n = (nc == "" and 1) or tonumber(nc)
								changed = changed + math.min(o, n)
								added = added + math.max(0, n - o)
								removed = removed + math.max(0, o - n)
							end
						end
					end
				end
				git_cache.diff = { added = added, modified = changed, removed = removed }
				refreshing = false
				pcall(function() require("lualine").refresh() end)
			end)
		end
		-- scope depends on the focused buffer, so also refresh on BufEnter; guarded so
		-- overlapping triggers don't stack
		vim.api.nvim_create_autocmd({ "DirChanged", "BufEnter", "BufWritePost", "FocusGained", "VimEnter" }, {
			callback = refresh_git,
		})
		refresh_git()

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
				-- Lovable ticket worktrees (lovable.daphen-<ticket>-…) → show just the
				-- ticket id (every-2585) instead of the long branch-derived folder name.
				local ticket = folder_name:match("^lovable%.daphen%-(%a+%-%d+)")
				return " " .. (ticket or folder_name) .. " "
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
				},
				lualine_x = {
					{ "filetype", padding = { left = 1, right = 2 } },
					{ "fancy_diff", source = function() return git_cache.diff end },
				},
				lualine_y = {
					-- ticket id only; live agent state/spinner lives above the composer input
					{
						function() return get_project_root() end,
						padding = { left = 0, right = 0 },
					},
				},
				lualine_z = {
					{
						get_scrollbar,
						-- fg only (no custom bg): a distinct bg fills the rounded corner
						-- cell and leaks past the border. Orange marker reads on the bar.
						color = function()
							local pal = vim.g.theme_palette or {}
							return { fg = pal.orange or "#ff8a3d" }
						end,
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
								{ "fancy_diff", source = function() return git_cache.diff end },
							},
							lualine_y = {
								-- agent + plan status on the right
								{
									function() return get_project_root() end,
									padding = { left = 0, right = 0 },
								},
							},
							lualine_z = {
								{
									get_scrollbar,
									color = function()
										local pal = vim.g.theme_palette or {}
										return { fg = pal.orange or "#ff8a3d" }
									end,
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
