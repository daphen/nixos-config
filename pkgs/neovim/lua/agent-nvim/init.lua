-- agent-nvim — the rail: a left sidebar of agent SESSIONS (statuses on top, the
-- selected session's chat below), streamed live from an `agentd` daemon over its
-- unix socket. A session is a pi running in any directory; git worktrees of the
-- scope's repo are just picker candidates ("sources").
--
-- Scope = one agentd instance = one socket. Set AGENT_SCOPE per niri workspace to
-- get independent rails (e.g. lovable vs personal). Read-only in M1; activate +
-- drive come in M2.
--
-- Keys (in the rail): j/k focus · <CR> view · n new session · x stop · r refresh · q close.
local M = {}

local uv = vim.uv or vim.loop
local api = vim.api

local WIDTH = 44
local GLYPH = { idle = "○", streaming = "●", error = "✗" }
local SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local PILL = { streaming = "AgentPillStream", error = "AgentPillErr", idle = "AgentPillIdle" }

-- Scope selects the daemon/socket. The lovable niri workspace launches nvim with
-- AGENT_SCOPE=lovable (worktree sources); everywhere else falls back to "default"
-- (generic — sources are the cwd's repo if any, plus "browse to a directory").
local scope = vim.env.AGENT_SCOPE or "default"
local ROOTS = { lovable = "~/work/lovable" }

local S = {
  pipe = nil,
  connected = false,
  buf = nil,
  win = nil,
  ns = nil,
  roster = {},   -- RUNNING sessions from the daemon
  sources = {},  -- candidate dirs (worktrees) for the picker
  selected = nil,
  focus = 1,
  chat = {},     -- id -> { lines = {...} }
  readbuf = "",
  spin = 0,
  timer = nil,
  saved_gcr = nil,
}

local render, handle, on_read, try_connect, connect, send, start_session, view_session, open_picker, ensure_buf

local function sock()
  return (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/agentd-" .. scope .. ".sock"
end

local function scope_root()
  return vim.fn.expand(ROOTS[scope] or vim.fn.getcwd())
end

local function agentd_bin()
  if vim.fn.executable("agentd") == 1 then
    return "agentd"
  end
  return (os.getenv("HOME") or "") .. "/personal/agentd/agentd"
end

local function set_hl()
  local p = vim.g.theme_palette or {}
  local nb = api.nvim_get_hl(0, { name = "Normal" })
  local dark = (nb and nb.bg) or 0x12161b
  local function hl(n, o) api.nvim_set_hl(0, n, o) end
  hl("AgentStream", { fg = p.green or "#5fca8b" })
  hl("AgentErr", { fg = p.red or "#e5675f" })
  hl("AgentIdle", { fg = p.fg_muted or "#5c6773" })
  hl("AgentAccent", { fg = p.orange or "#ff8a3d", bold = true })
  hl("AgentMuted", { fg = p.fg_muted or "#5c6773" })
  hl("AgentSel", { bg = p.bg_surface or "#1a222a" })
  hl("AgentPillStream", { fg = dark, bg = p.green or "#5fca8b", bold = true })
  hl("AgentPillErr", { fg = dark, bg = p.red or "#e5675f", bold = true })
  hl("AgentPillIdle", { fg = dark, bg = p.blue or "#5aa9e6" })
  hl("AgentHiddenCursor", { blend = 100 })
end

local function msg_text(msg)
  local t = {}
  for _, c in ipairs((msg and msg.content) or {}) do
    if c.type == "text" and c.text then
      t[#t + 1] = c.text
    end
  end
  return table.concat(t, "")
end

local function msg_lines(role, text)
  local pre = (role == "user") and "▌ you  " or ("▌ " .. (role or "?") .. "  ")
  local out = {}
  for _, para in ipairs(vim.split(text or "", "\n", { plain = true })) do
    out[#out + 1] = pre .. para
    pre = "       "
  end
  return out
end

-- Reply to an agent's interactive prompt (extension_ui_request).
local function ui_reply(sid, id, payload)
  local msg = { type = "extension_ui_response", session = sid, id = id }
  for k, v in pairs(payload) do
    msg[k] = v
  end
  send(msg)
end

-- Surface an agent's extension_ui_request as the matching nvim prompt.
local function handle_ui_request(o)
  local sid, id, method = o.session, o.id, o.method
  if method == "confirm" then
    vim.ui.select({ "yes", "no" }, {
      prompt = (o.title or "Confirm") .. (o.message and (" — " .. o.message) or ""),
    }, function(choice)
      ui_reply(sid, id, { confirmed = choice == "yes" })
    end)
  elseif method == "select" then
    vim.ui.select(o.options or {}, { prompt = o.title or "Select" }, function(choice)
      if choice then
        ui_reply(sid, id, { value = choice })
      else
        ui_reply(sid, id, { cancelled = true })
      end
    end)
  elseif method == "input" or method == "editor" then
    vim.ui.input({ prompt = (o.title or "Input") .. ": ", default = o.prefill or "" }, function(val)
      if val then
        ui_reply(sid, id, { value = val })
      else
        ui_reply(sid, id, { cancelled = true })
      end
    end)
  elseif method == "notify" then
    vim.notify("[" .. (sid or "agent") .. "] " .. (o.message or ""), vim.log.levels.INFO)
  end
  -- setStatus/setWidget/setTitle/set_editor_text: not surfaced in M2
end

render = function()
  if not (S.buf and api.nvim_buf_is_valid(S.buf)) then
    return
  end
  if S.focus < 1 then S.focus = 1 end
  if #S.roster > 0 and S.focus > #S.roster then S.focus = #S.roster end

  local lines, decor, mainline = {}, {}, {}
  local function push(l)
    lines[#lines + 1] = l
    return #lines - 1
  end

  decor[#decor + 1] = { line = push("  sessions · " .. scope), fg = "AgentMuted" }
  if #S.roster == 0 then
    decor[#decor + 1] = { line = push("  no running sessions"), fg = "AgentMuted" }
    decor[#decor + 1] = { line = push("  press n to start one"), fg = "AgentMuted" }
  end
  for i, a in ipairs(S.roster) do
    local streaming = a.status == "streaming"
    local icon = streaming and SPIN[(S.spin % #SPIN) + 1] or (GLYPH[a.status] or "○")
    local nameGrp = (a.id == S.selected and "AgentAccent")
      or (streaming and "AgentStream")
      or (a.status == "error" and "AgentErr")
      or "AgentIdle"
    local ml = push(" " .. icon .. " " .. a.name)
    mainline[i] = ml
    decor[#decor + 1] = { line = ml, fg = nameGrp }
    if (a.model and a.model ~= "") or (a.costUsd and a.costUsd > 0) then
      local meta = a.model or ""
      if a.costUsd and a.costUsd > 0 then
        meta = meta .. string.format("  $%.2f", a.costUsd)
      end
      decor[#decor + 1] = { line = ml, rvt = meta }
    end
    local label = " " .. a.status .. " "
    local sl = push("   " .. label)
    decor[#decor + 1] = { line = sl, pill = { 3, 3 + #label, PILL[a.status] or "AgentPillIdle" } }
  end

  decor[#decor + 1] = { line = push(string.rep("─", WIDTH - 2)), fg = "AgentMuted" }
  decor[#decor + 1] = { line = push("  chat · " .. (S.selected or "—")), fg = "AgentMuted" }
  local chat = S.selected and S.chat[S.selected]
  if chat and #chat.lines > 0 then
    for _, l in ipairs(chat.lines) do
      push(l)
    end
  else
    decor[#decor + 1] = { line = push("  press <CR> to open a session"), fg = "AgentMuted" }
  end

  vim.bo[S.buf].modifiable = true
  api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.bo[S.buf].modifiable = false
  api.nvim_buf_clear_namespace(S.buf, S.ns, 0, -1)
  for _, d in ipairs(decor) do
    if d.fg then
      pcall(api.nvim_buf_add_highlight, S.buf, S.ns, d.fg, d.line, 0, -1)
    end
    if d.pill then
      pcall(api.nvim_buf_set_extmark, S.buf, S.ns, d.line, d.pill[1],
        { end_col = d.pill[2], hl_group = d.pill[3], priority = 200 })
    end
    if d.rvt then
      pcall(api.nvim_buf_set_extmark, S.buf, S.ns, d.line, 0,
        { virt_text = { { d.rvt, "AgentMuted" } }, virt_text_pos = "right_align" })
    end
  end

  if S.win and api.nvim_win_is_valid(S.win) and mainline[S.focus] then
    pcall(api.nvim_win_set_cursor, S.win, { mainline[S.focus] + 1, 0 })
  end
end

handle = function(obj)
  local t = obj.type
  if t == "roster" then
    S.roster = obj.sessions or {}
    table.sort(S.roster, function(a, b) return (a.name or "") < (b.name or "") end)
    render()
  elseif t == "sources" then
    S.sources = obj.sources or {}
  elseif t == "response" and obj.command == "get_messages" and obj.data and obj.data.messages then
    local ls = {}
    for _, msg in ipairs(obj.data.messages) do
      for _, l in ipairs(msg_lines(msg.role, msg_text(msg))) do
        ls[#ls + 1] = l
      end
    end
    S.chat[obj.session] = { lines = ls }
    if obj.session == S.selected then render() end
  elseif t == "message_end" and obj.session then
    local c = S.chat[obj.session] or { lines = {} }
    for _, l in ipairs(msg_lines((obj.message or {}).role, msg_text(obj.message))) do
      c.lines[#c.lines + 1] = l
    end
    S.chat[obj.session] = c
    if obj.session == S.selected then render() end
  elseif t == "extension_ui_request" then
    handle_ui_request(obj)
  end
end

on_read = function(err, chunk)
  if err or not chunk then return end
  S.readbuf = S.readbuf .. chunk
  while true do
    local nl = S.readbuf:find("\n", 1, true)
    if not nl then break end
    local line = S.readbuf:sub(1, nl - 1)
    S.readbuf = S.readbuf:sub(nl + 1)
    if #line > 0 then
      local ok, obj = pcall(vim.json.decode, line)
      if ok and type(obj) == "table" then handle(obj) end
    end
  end
end

try_connect = function(cb, tries)
  tries = tries or 0
  local p = uv.new_pipe(false)
  p:connect(sock(), function(cerr)
    if not cerr then
      S.pipe = p
      S.connected = true
      p:read_start(vim.schedule_wrap(on_read))
      if cb then vim.schedule(cb) end
      return
    end
    pcall(function() p:close() end)
    if tries == 0 then
      vim.schedule(function()
        vim.fn.jobstart({ agentd_bin(), "--scope", scope, "--repo", scope_root() }, { detach = true })
      end)
    end
    if tries < 30 then
      local t = uv.new_timer()
      t:start(200, 0, function()
        t:close()
        try_connect(cb, tries + 1)
      end)
    else
      vim.schedule(function()
        vim.notify("agent-nvim: could not reach agentd (" .. scope .. ")", vim.log.levels.ERROR)
      end)
    end
  end)
end

connect = function(cb)
  if S.connected then
    if cb then cb() end
    return
  end
  try_connect(cb, 0)
end

send = function(obj)
  if not (S.connected and S.pipe) then return end
  S.pipe:write(vim.json.encode(obj) .. "\n")
end

-- Re-root the current nvim tab to a session's worktree so diff, the file-watcher
-- and plan-nvim all scope to that agent. tab-local (:tcd) keeps other tabs intact.
local function reroot(cwd)
  if not cwd or cwd == "" then
    return
  end
  pcall(vim.cmd, "tcd " .. vim.fn.fnameescape(cwd))
  pcall(function() require("plan-nvim").bind() end)
  pcall(function() require("file-watcher").start() end)
  pcall(vim.api.nvim_exec_autocmds, "DirChanged", { modeline = false })
end

start_session = function(name, cwd)
  S.selected = name
  send({ type = "spawn", session = name, cwd = cwd })
  send({ type = "get_messages", session = name })
  reroot(cwd)
  render()
end

view_session = function(name, cwd)
  S.selected = name
  send({ type = "get_messages", session = name })
  reroot(cwd)
  render()
end

open_picker = function()
  if #S.sources == 0 then
    send({ type = "list_sources" })
    vim.notify("agent-nvim: loading sources… press n again", vim.log.levels.INFO)
    return
  end
  local items = {}
  for _, s in ipairs(S.sources) do
    items[#items + 1] = { label = s.name, name = s.name, cwd = s.cwd }
  end
  table.sort(items, function(a, b) return a.label < b.label end)
  items[#items + 1] = { label = "＋ browse to a directory…", browse = true }
  vim.ui.select(items, {
    prompt = "Start a session (" .. scope .. ")",
    format_item = function(it) return it.label end,
  }, function(it)
    if not it then return end
    if it.browse then
      vim.ui.input({ prompt = "Session directory: ", default = vim.fn.getcwd(), completion = "dir" }, function(path)
        if path and #path > 0 then
          local dir = vim.fn.expand(path)
          start_session(vim.fn.fnamemodify(dir, ":t"), dir)
        end
      end)
    else
      start_session(it.name, it.cwd)
    end
  end)
end

local function start_spin()
  if S.timer then return end
  S.timer = uv.new_timer()
  S.timer:start(100, 100, vim.schedule_wrap(function()
    if not (S.win and api.nvim_win_is_valid(S.win)) then return end
    for _, a in ipairs(S.roster) do
      if a.status == "streaming" then
        S.spin = S.spin + 1
        render()
        return
      end
    end
  end))
end

local function stop_spin()
  if S.timer then
    pcall(function() S.timer:stop(); S.timer:close() end)
    S.timer = nil
  end
end

ensure_buf = function()
  if S.buf and api.nvim_buf_is_valid(S.buf) then return end
  S.buf = api.nvim_create_buf(false, true)
  vim.bo[S.buf].buftype = "nofile"
  vim.bo[S.buf].bufhidden = "hide"
  vim.bo[S.buf].modifiable = false
  pcall(api.nvim_buf_set_name, S.buf, "agent-rail")

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = S.buf, nowait = true, silent = true })
  end
  local function move(delta)
    S.focus = S.focus + delta
    render()
  end
  map("j", function() move(1) end)
  map("k", function() move(-1) end)
  map("<Down>", function() move(1) end)
  map("<Up>", function() move(-1) end)
  map("<C-d>", function() move(5) end)
  map("<C-u>", function() move(-5) end)
  map("<CR>", function()
    local a = S.roster[S.focus]
    if a then view_session(a.id, a.cwd) end
  end)
  map("i", function()
    if not S.selected then
      vim.notify("agent-nvim: open a session first (<CR>)", vim.log.levels.INFO)
      return
    end
    vim.ui.input({ prompt = "prompt " .. S.selected .. " › " }, function(text)
      if not text or #text == 0 then return end
      local c = S.chat[S.selected] or { lines = {} }
      for _, l in ipairs(msg_lines("user", text)) do
        c.lines[#c.lines + 1] = l
      end
      S.chat[S.selected] = c
      render()
      send({ type = "prompt", session = S.selected, message = text })
    end)
  end)
  map("n", function() open_picker() end)
  map("x", function()
    local a = S.roster[S.focus]
    if a then
      send({ type = "stop", session = a.id })
      if S.selected == a.id then S.selected = nil end
    end
  end)
  map("r", function()
    if S.selected then send({ type = "get_messages", session = S.selected }) end
  end)
  map("q", function() M.close() end)

  local grp = api.nvim_create_augroup("AgentRailCursor", { clear = true })
  api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = grp,
    buffer = S.buf,
    callback = function()
      if not S.saved_gcr then S.saved_gcr = vim.o.guicursor end
      vim.o.guicursor = "a:AgentHiddenCursor"
    end,
  })
  api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = grp,
    buffer = S.buf,
    callback = function()
      if S.saved_gcr then vim.o.guicursor = S.saved_gcr end
    end,
  })
end

function M.open()
  ensure_buf()
  if S.win and api.nvim_win_is_valid(S.win) then
    api.nvim_set_current_win(S.win)
    return
  end
  vim.cmd("topleft vsplit")
  S.win = api.nvim_get_current_win()
  api.nvim_win_set_buf(S.win, S.buf)
  api.nvim_win_set_width(S.win, WIDTH)
  vim.wo[S.win].winfixwidth = true
  vim.wo[S.win].number = false
  vim.wo[S.win].relativenumber = false
  vim.wo[S.win].signcolumn = "no"
  vim.wo[S.win].wrap = true
  vim.wo[S.win].cursorline = true
  vim.wo[S.win].cursorlineopt = "line"
  vim.wo[S.win].winhighlight = "CursorLine:AgentSel"
  if not S.saved_gcr then S.saved_gcr = vim.o.guicursor end
  vim.o.guicursor = "a:AgentHiddenCursor"
  start_spin()
  connect(function()
    send({ type = "list_sources" })
    render()
  end)
  render()
end

function M.close()
  stop_spin()
  if S.saved_gcr then vim.o.guicursor = S.saved_gcr end
  if S.win and api.nvim_win_is_valid(S.win) then
    api.nvim_win_close(S.win, true)
  end
  S.win = nil
end

function M.toggle()
  if S.win and api.nvim_win_is_valid(S.win) then
    M.close()
  else
    M.open()
  end
end

function M.statusline()
  if not S.selected then return "" end
  local a
  for _, x in ipairs(S.roster) do
    if x.id == S.selected then a = x break end
  end
  if not a then return "▸ " .. S.selected end
  local s = "▸ " .. a.name .. " · " .. (a.model ~= "" and a.model or "?")
  if a.status == "streaming" then s = s .. " ●" end
  if a.costUsd and a.costUsd > 0 then s = s .. string.format(" · $%.2f", a.costUsd) end
  return s
end

function M.setup(opts)
  opts = opts or {}
  if opts.scope then scope = opts.scope end
  if opts.scopes then ROOTS = opts.scopes end
  S.ns = api.nvim_create_namespace("agent_nvim")
  set_hl()
  api.nvim_create_autocmd("ColorScheme", { callback = set_hl })
  api.nvim_create_user_command("AgentRail", function() M.toggle() end, {})
  vim.keymap.set("n", "<leader>a", function() M.toggle() end, { desc = "Toggle agent rail" })
end

return M
