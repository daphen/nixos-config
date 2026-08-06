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
			-- root + base are resolved SYNCHRONOUSLY here: refresh_git runs from autocmds
			-- (a normal context), and base_for → git_exec uses vim.fn.systemlist, which
			-- is illegal in the fast context of a vim.system callback (E5560). These
			-- calls are cheap (base_for caches per-root). Only the potentially-huge diff
			-- goes async so it never blocks the main loop ~800ms on BufEnter. On
			-- main/master we diff HEAD (uncommitted changes), not the branch base.
			local cwd = vim.fn.getcwd()
			local file = vim.fn.expand("%:p")
			local editable = vim.bo.buftype == ""
			local root = vim.trim((vim.fn.systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })[1]) or "")
			if root == "" then refreshing = false; return end
			local branch = vim.trim((vim.fn.systemlist({ "git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD" })[1]) or "")
			-- Base for THIS worktree (root), NOT the focused buffer's repo — base_for
			-- caches per-root + is trunk-move-aware, so the diff always matches getcwd
			-- even when the focused buffer is a rail pane (agent-composer).
			local base = "HEAD"
			if branch ~= "main" and branch ~= "master" then
				local ok, signs = pcall(require, "hunk-nvim.signs")
				if ok and signs.base_for then
					local b = signs.base_for(root)
					if b and b ~= "" then base = b end
				end
			end
			local in_worktree = editable and file ~= "" and file:sub(1, #root + 1) == root .. "/"
			local args = { "git", "-C", root, "diff", "--numstat", "--no-color", base }
			if in_worktree then args[#args + 1] = "--"; args[#args + 1] = file end
			vim.system(args, { text = true }, function(r2)
				local added, removed = 0, 0
				if r2.code == 0 then
					for _, l in ipairs(vim.split(r2.stdout or "", "\n", { plain = true })) do
						local a, d = l:match("^(%d+)%s+(%d+)")
						if a then added = added + tonumber(a); removed = removed + tonumber(d) end
					end
				end
				git_cache.diff = { added = added, modified = 0, removed = removed }
				refreshing = false
				vim.schedule(function() pcall(function() require("lualine").refresh() end) end)
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
				-- Lovable worktrees → short id instead of the long branch-derived folder:
				--   work:   lovable.daphen-every-2585-…      → every-2585
				--   review: lovable.review-76010-feat-…      → review-76010
				local ticket = folder_name:match("^lovable%.daphen%-(%a+%-%d+)")
					or folder_name:match("^lovable%.(review%-%d+)")
				return " " .. (ticket or folder_name) .. " "
			else
				return ""
			end
		end

		local function editor_filename()
			local ok, rail = pcall(require, "heidr")
			local win = ok and rail.editor_win and rail.editor_win()
			if not win or not vim.api.nvim_win_is_valid(win) then return "" end
			local ebuf = vim.api.nvim_win_get_buf(win)
			local name = vim.api.nvim_buf_get_name(ebuf)
			if name == "" or vim.bo[ebuf].buftype ~= "" then return "" end
			return vim.fn.fnamemodify(name, ":.") .. (vim.bo[ebuf].modified and " ●" or "")
		end

		-- Sections sit on a subtle surface bg (a lighter bar), read fresh from the
		-- theme palette so it tracks light/dark.
		local function get_theme()
			local pal = vim.g.theme_palette or {}
			local dark = vim.o.background == "dark"
			-- statusline background = the theme's surface2 elevation.
			local surface = pal.bg_surface2 or pal.bg_surface or (dark and "#2E2E2E" or "#E8EAED")
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
					-- work items (plan progress ◆ N/N) for the active rail session; the
					-- live working state/spinner stays above the composer input.
					{
						function()
							local ok, m = pcall(require, "heidr")
							return (ok and m.plan_chip) and m.plan_chip() or ""
						end,
						padding = { left = 1, right = 1 },
					},
					-- ticket id
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
								-- work items (plan progress ◆ N/N) for the active rail session
								{
									function()
										local ok, m = pcall(require, "heidr")
										return (ok and m.plan_chip) and m.plan_chip() or ""
									end,
									padding = { left = 1, right = 1 },
								},
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
