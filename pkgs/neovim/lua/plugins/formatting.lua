return {
	"conform.nvim",
	event = { "BufReadPre", "BufNewFile", "VimEnter" },
	after = function()
		local conform = require("conform")
		local utils = require("utils")

		-- Cache expensive lookups to avoid repeated filesystem checks
		local project_cache = {}

		local function find_project_root(path)
			if project_cache[path] then
				return project_cache[path]
			end
			-- Try monorepo/project root markers first
			local root = utils.find_root_with_markers(path, { ".prettierrc", ".prettierrc.json", "pnpm-workspace.yaml", ".git" })
			if root then
				project_cache[path] = root
				return root
			end
			-- Fallback to package.json for simple projects
			local fallback = utils.find_root_with_markers(path, { "package.json" })
			project_cache[path] = fallback
			return fallback
		end

		-- Check if we're in the Lovable project
		local lovable_cache = {}
		local function is_lovable_project(path)
			if lovable_cache[path] ~= nil then
				return lovable_cache[path]
			end
			local root = utils.find_root_with_markers(path, { ".treefmt.toml", ".oxfmtrc.json" })
			lovable_cache[path] = root ~= nil
			return lovable_cache[path]
		end

		local prettier_configs = {
			".prettierrc",
			".prettierrc.json",
			".prettierrc.js",
			"prettier.config.js",
			"prettier.config.mjs",
		}

		conform.setup({
			formatters_by_ft = {
				-- Use lovable_format for these filetypes if in Lovable project, otherwise prettier
				javascript = { "lovable_format", "prettier" },
				typescript = { "lovable_format", "prettier" },
				javascriptreact = { "lovable_format", "prettier" },
				typescriptreact = { "lovable_format", "prettier" },
				css = { "lovable_format", "prettier" },
				html = { "lovable_format", "prettier" },
				less = { "lovable_format", "prettier" },
				scss = { "lovable_format", "prettier" },
				markdown = { "mdformat" },
				json = { "lovable_format", "prettier" },
				yaml = { "lovable_format", "prettier" },
				-- Prettier-only for these
				svelte = { "prettier" },
				vue = { "prettier" },
				svg = { "prettier" },
				-- Other formatters
				lua = { "stylua" },
				python = { "black" },
			},
			formatters = {
				-- Lovable project formatter (uses treefmt + oxfmt)
				lovable_format = {
					condition = function()
						local current_path = utils.current_path()
						return is_lovable_project(current_path)
					end,
					command = function()
						local current_path = utils.current_path()
						local root = utils.find_root_with_markers(current_path, { ".treefmt.toml" })
						if root then
							local sep = package.config:sub(1, 1)
							local format_bin = root .. sep .. "bin" .. sep .. "format"
							if vim.fn.executable(format_bin) == 1 then
								return format_bin
							end
						end
						return "format" -- Fallback to PATH
					end,
					args = { "$FILENAME" },
					stdin = false,
					cwd = function()
						local current_path = utils.current_path()
						return utils.find_root_with_markers(current_path, { ".treefmt.toml" }) or vim.fn.getcwd()
					end,
				},
				mdformat = {
					prepend_args = { "--wrap", "80" },
				},
				black = {
					cwd = require("conform.util").root_file({ "pyproject.toml" }),
				},
				prettier = {
					-- Cache prettier availability per project to avoid repeated checks
					_cache = {},
					condition = function(self)
						local current_path = utils.current_path()

						-- Check cache first
						if self._cache[current_path] ~= nil then
							return self._cache[current_path]
						end

						-- Don't use prettier in Lovable project (lovable_format handles it)
						if is_lovable_project(current_path) then
							self._cache[current_path] = false
							return false
						end

						local root_path = find_project_root(current_path)

						-- Check global prettier first
						if vim.fn.executable("prettier") == 1 then
							self._cache[current_path] = true
							return true
						end

						if not root_path then
							self._cache[current_path] = false
							return false
						end

						local sep = package.config:sub(1, 1)
						local paths = {
							root_path .. sep .. "node_modules" .. sep .. ".bin" .. sep .. "prettier",
						}

						-- Check for pnpm prettier
						local pnpm_prettier = vim.fn.glob(
							root_path
								.. sep
								.. ".pnpm"
								.. sep
								.. "prettier@*"
								.. sep
								.. "node_modules"
								.. sep
								.. "prettier"
								.. sep
								.. "bin"
								.. sep
								.. "prettier.cjs"
						)
						if pnpm_prettier ~= "" then
							table.insert(paths, pnpm_prettier)
						end

						for _, path in ipairs(paths) do
							if path ~= "" and vim.fn.executable(path) == 1 then
								self._cache[current_path] = true
								return true
							end
						end

						self._cache[current_path] = false
						return false
					end,
					command = function()
						local current_path = utils.current_path()
						local root_path = find_project_root(current_path)
						if not root_path then
							return "prettier"
						end

						local sep = package.config:sub(1, 1)
						local paths = {
							root_path .. sep .. "node_modules" .. sep .. ".bin" .. sep .. "prettier",
						}

						-- Check for pnpm prettier
						local pnpm_prettier = vim.fn.glob(
							root_path
								.. sep
								.. ".pnpm"
								.. sep
								.. "prettier@*"
								.. sep
								.. "node_modules"
								.. sep
								.. "prettier"
								.. sep
								.. "bin"
								.. sep
								.. "prettier.cjs"
						)
						if pnpm_prettier ~= "" then
							table.insert(paths, pnpm_prettier)
						end

						for _, path in ipairs(paths) do
							if path ~= "" and vim.fn.executable(path) == 1 then
								return path
							end
						end

						return "prettier"
					end,
					args = function(_, ctx)
						local current_path = utils.current_path()
						local root_path = find_project_root(current_path)
						local args = { "--stdin-filepath", ctx.filename }

						if vim.fn.fnamemodify(ctx.filename, ":e") == "svg" then
							table.insert(args, "--parser")
							table.insert(args, "html")
						end

						if root_path then
							local sep = package.config:sub(1, 1)
							for _, config in ipairs(prettier_configs) do
								local config_path = root_path .. sep .. config
								if vim.fn.filereadable(config_path) ~= 0 then
									-- Use vim.list_extend to combine the tables
									vim.list_extend(args, { "--config", config_path })
									break
								end
							end
						end

						return args
					end,
					cwd = function()
						local current_path = utils.current_path()
						return find_project_root(current_path) or vim.fn.getcwd()
					end,
				},
			},
			format_after_save = {
				timeout_ms = 2000,
				lsp_fallback = true,
			},
		})

		local function format_read(buf)
			if not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].modified or vim.bo[buf].readonly
				or not vim.bo[buf].modifiable or vim.bo[buf].buftype ~= "" then return end
			local path = vim.api.nvim_buf_get_name(buf)
			if not path:match("%.md$") and not path:match("%.markdown$") then return end
			if vim.fn.executable("mdformat") ~= 1 then return end
			local input = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. (vim.bo[buf].endofline and "\n" or "")
			local tick = vim.api.nvim_buf_get_changedtick(buf)
			vim.system({ "mdformat", "--wrap", "80", "-" }, { stdin = input, text = true }, function(result)
				vim.schedule(function()
					if result.code ~= 0 then
						vim.notify("Markdown formatting failed: " .. path, vim.log.levels.ERROR)
						return
					end
					if result.stdout == input or not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].modified
						or vim.bo[buf].readonly or vim.api.nvim_buf_get_changedtick(buf) ~= tick
						or vim.api.nvim_buf_get_name(buf) ~= path then return end
					local ok, disk = pcall(vim.fn.readfile, path, "b")
					if not ok or table.concat(disk, "\n") ~= input then return end
					vim.fn.writefile(vim.split(result.stdout, "\n", { plain = true }), path, "b")
					vim.cmd("checktime " .. buf)
				end)
			end)
		end
		vim.api.nvim_create_autocmd({ "BufReadPost", "FileChangedShellPost" }, {
			group = vim.api.nvim_create_augroup("MarkdownReadFormatting", { clear = true }),
			pattern = { "*.md", "*.markdown" },
			callback = function(ev) vim.schedule(function() format_read(ev.buf) end) end,
		})
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			vim.schedule(function() format_read(buf) end)
		end

		vim.keymap.set({ "n", "v" }, "<leader>cf", function()
			conform.format({
				lsp_fallback = true,
				async = false,
				timeout = 500,
			})
		end, { desc = "Format file or range" })
	end,
}
