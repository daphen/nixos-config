vim.g.mapleader = " "

local keymap = vim.keymap

-- center cursor after search
keymap.set("n", "n", "nzzzv")
keymap.set("n", "N", "Nzzzv")

-- x key does not copy deleted character to register
keymap.set("n", "x", '"_x')

-- split screen nav
keymap.set("n", "<C-h>", "<C-w>h")
keymap.set("n", "<C-j>", "<C-w>j")
keymap.set("n", "<C-k>", "<C-w>k")
-- In Cockpit, <C-l> crosses into the rail when there is no split to the
-- right (vim-tmux-navigator style); otherwise it's a plain window move. Bound in
-- EVERY mode: focus is leaving nvim entirely, so waiting for normal mode first is
-- friction — each mode just drops back to normal on the way out (otherwise you'd
-- return mid-insert / with a stale visual selection).
if vim.env.COCKPIT_COCKPIT == "1" or vim.env.HEIDR_COCKPIT == "1" then
  local cross_script = vim.fn.expand("~/.config/niri/scripts/cockpit-cross")
  local focus_packet = string.char(3, 0, 0, 0, 14)
    .. "\0c\0o\0c\0k\0p\0i\0t"
    .. string.char(0, 0, 0, 20)
    .. "\0f\0o\0c\0u\0s\0R\0i\0g\0h\0t"
    .. string.char(0, 0, 0, 0)
  local function focus_rail()
    local nvim_sock = vim.env.NVIM_LISTEN_ADDRESS or ""
    local runtime = vim.env.XDG_RUNTIME_DIR or ("/run/user/" .. vim.fn.getuid())
    local file = io.open(runtime .. "/cockpit-ipc." .. (nvim_sock:match("([^/]+)$") or "") .. ".id", "r")
    if not file then vim.system({ cross_script, "right" }); return end
    local instance = file:read("*l")
    file:close()
    if not instance or instance == "" then vim.system({ cross_script, "right" }); return end

    local pipe, done = vim.uv.new_pipe(false), false
    local function finish(ok)
      if done then return end
      done = true
      if not pipe:is_closing() then pipe:close() end
      if not ok then vim.schedule(function() vim.system({ cross_script, "right" }) end) end
    end
    vim.defer_fn(function() finish(false) end, 250)
    pipe:connect(runtime .. "/quickshell/by-id/" .. instance .. "/ipc.sock", function(err)
      if err then finish(false); return end
      pipe:read_start(function(read_err, data)
        finish(not read_err and data ~= nil and data:byte(1) == 5)
      end)
      pipe:write(focus_packet, function(write_err)
        if write_err then finish(false) end
      end)
    end)
  end
  local function cross_right()
    local prev = vim.fn.winnr()
    vim.cmd("wincmd l")
    if vim.fn.winnr() == prev then focus_rail() end
  end
  keymap.set("n", "<C-l>", cross_right)
  keymap.set({ "i", "v", "x", "s" }, "<C-l>", function()
    vim.cmd("stopinsert")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    vim.schedule(cross_right)
  end)
  -- Terminal buffers need an explicit hop out of terminal-insert first.
  keymap.set("t", "<C-l>", function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true), "n", false)
    vim.schedule(cross_right)
  end)
else
  keymap.set("n", "<C-l>", "<C-w>l")
end

-- split screen actions
keymap.set("n", "<leader>sv", "<C-w>v") -- split vertically
keymap.set("n", "<leader>sh", "<C-w>s") -- split horizontally
keymap.set("n", "<leader>se", "<C-w>=") -- make split windows equal width
keymap.set("n", "<C-x>", ":close<CR>") -- close current split window

-- resize splits — leader+h/l for width. Ctrl+Shift+hjkl misfires on the
-- Charybdis (home-row-mods drops the modifiers, nvim only sees bare hjkl), so
-- width lives on the leader; height stays on C-S-j/k where it still works.
keymap.set("n", "<leader>h", "<cmd>vertical resize -3<CR>", { desc = "Shrink width" })
keymap.set("n", "<leader>l", "<cmd>vertical resize +3<CR>", { desc = "Grow width" })
keymap.set("n", "<C-S-j>", "<cmd>resize -2<CR>", { desc = "Shrink height" })
keymap.set("n", "<C-S-k>", "<cmd>resize +2<CR>", { desc = "Grow height" })

-- move highlighted
keymap.set("v", "J", ":m '>+1<CR>gv=gv")
keymap.set("v", "K", ":m '<-2<CR>gv=gv")

-- we have telescope fuzzy find in current buffer on / so we're remapping normal search
-- keymap.set("n", "<leader>/", "/")

keymap.set("n", "<m-j>", "<cmd>cnext<CR>", { desc = "Next quickfix item" })
keymap.set("n", "<m-k>", "<cmd>cprev<CR>", { desc = "Prev quickfix item" })

-- Leader p/P to force new line for paste
vim.keymap.set("n", "<leader>p", "o" .. "<ESC>" .. "p" .. "V" .. "=" .. "<ESC>" .. "$", { noremap = true })
vim.keymap.set("n", "<leader>P", "O" .. "<ESC>" .. "p" .. "V" .. "=" .. "<ESC>" .. "$", { noremap = true })

-- Copy entire file with <C-g><C-g>

-- too many typos
vim.cmd(":command W w")
vim.cmd(":command Wa wa")
vim.cmd(":command WQ wq")
vim.cmd(":command Wq wq")
vim.cmd(":command Wqa wqa")
vim.cmd(":command QA qa")
vim.cmd(":command Qa qa")

-- ShadCN HSL conversion command:
vim.api.nvim_create_user_command("HSL", function(opts)
	local range = opts.range
	if range == 0 then
		-- If no range specified, operate on current line
		vim.cmd([[.s/hsl(\s*\(\d\+\)deg,\s*\(\d\+\.\?\d*\)%,\s*\(\d\+\.\?\d*\)%)/\1 \2% \3%/g]])
	else
		-- If range specified (visual selection), operate on those lines
		vim.cmd([['<,'>s/hsl(\s*\(\d\+\)deg,\s*\(\d\+\.\?\d*\)%,\s*\(\d\+\.\?\d*\)%)/\1 \2% \3%/g]])
	end
end, { range = true })
vim.cmd([[cnoreabbrev hsl HSL]])

-- Reverse HSL conversion command:
vim.api.nvim_create_user_command("ToHSL", function(opts)
	local range = opts.range
	if range == 0 then
		-- If no range specified, operate on current line
		vim.cmd([[.s/\(\d\+\) \(\d\+\.\?\d*\)% \(\d\+\.\?\d*\)%/hsl(\1deg, \2%, \3%)/g]])
	else
		-- If range specified (visual selection), operate on those lines
		vim.cmd([['<,'>s/\(\d\+\) \(\d\+\.\?\d*\)% \(\d\+\.\?\d*\)%/hsl(\1deg, \2%, \3%)/g]])
	end

	-- Clear search highlights
	vim.cmd("nohlsearch")
end, { range = true })
vim.cmd([[cnoreabbrev tohsl ToHSL]])

keymap.set("n", "<leader>rc", ":ReloadColors<CR>", { noremap = true, silent = true, desc = "Reload colorscheme" })
vim.api.nvim_create_user_command("ReloadColors", function()
	-- Reload custom theme
	package.loaded["theme"] = nil
	package.loaded["theme.colors"] = nil
	package.loaded["theme.highlights"] = nil
	require("theme").reload()

	-- Reload lualine
	package.loaded["lualine"] = nil
	require("lualine").setup()

	-- Reload color highlighter
	require("nvim-highlight-colors").turnOff()
	require("nvim-highlight-colors").turnOn()
	vim.notify("Colorscheme reloaded", vim.log.levels.INFO)
end, {})

-- FORMAT WHEN PASTING
-- Function to indent the range of pasted text
local function indent_after_paste()
	-- Indent the lines between the marks `[` and `]`
	vim.cmd("normal! `[v`]=")
end

-- Override the default paste mappings to include indentation
vim.keymap.set("n", "p", function()
	if not vim.bo.modifiable then return end
	vim.cmd("normal! p")
	indent_after_paste()
end, { noremap = true, silent = true })

vim.keymap.set("n", "P", function()
	if not vim.bo.modifiable then return end
	vim.cmd("normal! P")
	indent_after_paste()
end, { noremap = true, silent = true })

-- Copy entire file with <C-g><C-g>



vim.keymap.set("v", "p", function()
	vim.cmd("normal! p")
	indent_after_paste()
end, { noremap = true, silent = true })

vim.keymap.set("v", "P", function()
	vim.cmd("normal! P")
	indent_after_paste()
end, { noremap = true, silent = true })

-- Search and replace word under cursor
vim.keymap.set("n", "SR", function()
	local word = vim.fn.expand("<cword>")
	-- Escape special characters in the word
	local escaped_word = vim.fn.escape(word, "/\\")
	-- Create the command string
	local cmd = ":%s/" .. escaped_word .. "//g"
	-- Feed the command to the command line without executing it
	vim.api.nvim_feedkeys(":" .. cmd, "n", false)
	-- Move cursor left twice (before the last slash)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Left><Left>", true, false, true), "n", false)
end, { noremap = true, desc = "Search and replace word under cursor" })
