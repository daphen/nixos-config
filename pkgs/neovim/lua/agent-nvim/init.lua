-- agent-nvim — the rail: a left sidebar cockpit for orchestrating `agentd`
-- agents. Three stacked windows in one column:
--   • roster  (top, sticky)   — sessions with live state, focus-ring selection
--   • chat    (middle, scrolls)— the active session's transcript, markdown+TS
--   • composer(bottom, grows)  — a real editable buffer with attachment chips
--
-- Scope = one agentd instance = one socket. Set AGENT_SCOPE per niri workspace to
-- get independent rails (e.g. lovable vs personal).
--
-- Rail keys — roster:  j/k move · <CR> open · n new · . cwd · x stop · a abort
--                      z collapse · r refresh · ? help · q close
--          — chat:     ]m/[m next/prev message · <Tab> fold msg · Y yank code
--                      i compose · <Esc> back to roster · (y/n answer approvals)
--          — composer: <CR> send · <C-s> send-from-insert · <C-x> drop attachments
--                      q back to roster · /slash commands · @ path hints
-- Anywhere: <leader>as (visual) send selection · :AgentSend[File|Diff|Diagnostics]
local M = {}

local uv = vim.uv or vim.loop
local api = vim.api
local fn = vim.fn

local WIDTH = 80
local COMPOSER_MAX = 12

-- Fancy, tofu-safe glyphs (geometric unicode + braille spinner — no private-use
-- codepoints, so they render on any font).
local SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local GLYPH = {
  idle = "○",
  streaming = "●",
  error = "✗",
  needs_input = "◆",
  queued = "◔",
  offline = "◌",
}
local BAR = "▌"       -- focus-ring left bar
local CHIP_BAR = "▎"  -- attachment chip left bar
local CARET = "▋"     -- streaming caret
local FOLDED = "▸"
local OPEN = "▾"
local LCAP = ""      -- rounded pill left cap
local RCAP = ""      -- rounded pill right cap

-- Scope resolution: an explicit AGENT_SCOPE wins (the cockpit sets it); otherwise
-- derive from the focused niri workspace — the `lovable` workspace hosts lovable
-- work, everything else (and off-niri) is personal. So an nvim started anywhere on
-- the lovable workspace is a lovable rail, not just the cockpit's launch command.
local function detect_scope()
  local env = vim.env.AGENT_SCOPE
  if env and env ~= "" then return env end
  local ok, out = pcall(vim.fn.system, { "niri", "msg", "--json", "workspaces" })
  if ok and type(out) == "string" and out ~= "" then
    local dok, wss = pcall(vim.json.decode, out)
    if dok and type(wss) == "table" then
      for _, w in ipairs(wss) do
        if w.is_focused and w.name == "lovable" then return "lovable" end
      end
    end
  end
  return "personal"
end
local scope = detect_scope()
-- Scopes are isolated agent worlds: one agentd daemon + socket + session set each.
-- The rail only ever sees its own scope's sessions (it dials that scope's socket),
-- so a lovable nvim and a personal nvim show disjoint rosters.
local ROOTS = { lovable = "~/work/lovable", personal = "~/personal" }

local S = {
  pipe = nil,
  connected = false,
  buf = nil, win = nil,             -- roster
  chatbuf = nil, chatwin = nil,     -- chat (middle pane, view = "chat")
  changesbuf = nil,                 -- changes view (middle pane, view = "changes")
  view = "chat",                    -- which buffer the middle pane shows
  changes_open = {},                -- changes bufline(0-idx) -> { path, l1 }
  composerbuf = nil, composerwin = nil,
  ns = nil, composer_ns = nil, chip_ns = nil,
  roster = {},        -- running sessions from the daemon
  sources = {},       -- candidate dirs for the picker
  selected = nil,
  focus = 1,
  chat = {},          -- id -> { msgs = { {role,text}, ... } }
  drafts = {},        -- id -> unsent composer text
  attach = {},        -- pending composer attachments { {path,l1,l2,lang,text} }
  pending = {},       -- id -> extension_ui_request awaiting an answer
  stream = {},        -- id -> partial streaming assistant text (live)
  stream_since = {},  -- id -> os.time() when streaming began (elapsed counter)
  idle_since = {},    -- id -> os.time() when the session last went idle
  folds = {},         -- id -> { [msgIndex]=true }
  plan = {},          -- id -> { done, total, phase } | false  (cached, refreshed slowly)
  show_all = false,   -- roster: false = attention queue only, true = every session
  displayed = {},     -- the sessions actually shown in the roster (filtered), in order
  collapsed = false,  -- roster collapsed to a summary line
  chat_line_msg = {}, -- chat bufline(0-idx) -> msgIndex
  chat_blocks = {},   -- 1-indexed buflines that start a message block
  readbuf = "",
  spin = 0,
  timer = nil,
  saved_gcr = nil,
}

local render, render_roster, render_chat, render_changes, handle, on_read, try_connect, connect, send
local start_session, view_session, open_picker, ensure_buf, focus_composer, refresh_plans, sync_approval_keys
local composer_send, composer_resize, composer_placeholder, render_chips
local add_attachment, session_state

--------------------------------------------------------------------------------
-- small utils
--------------------------------------------------------------------------------
local function sock() return (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/agentd-" .. scope .. ".sock" end
local function scope_root() return fn.expand(ROOTS[scope] or fn.getcwd()) end
local function agentd_bin()
  if fn.executable("agentd") == 1 then return "agentd" end
  return (os.getenv("HOME") or "") .. "/personal/agentd/agentd"
end
local function base(dir) return fn.fnamemodify(dir, ":t") end
local function rule(w) return string.rep("─", math.max(1, w or WIDTH)) end
local function palette() return vim.g.theme_palette or {} end

--------------------------------------------------------------------------------
-- highlights
--------------------------------------------------------------------------------
-- lift an 0xRRGGBB integer toward white by `amt` per channel → a guaranteed
-- elevation over the Normal background, whatever the theme.

local function set_hl()
  local p = palette()
  local nb = api.nvim_get_hl(0, { name = "Normal" })
  local dark = (nb and nb.bg) or 0x12161b
  local surface = p.bg_surface or "#1a222a"
  local accent = p.orange or "#ff8a3d"
  local attn = p.yellow or "#e5c07b"
  -- Elevation from the theme's surface ladder (surface2 tracks both modes: lighter
  -- than bg in dark, darker than bg in light) — never a channel-lift, which washes
  -- out to white in light mode.
  local cardbg = p.bg_surface2 or p.bg_selection or surface -- focus-ring card fill
  local function hl(n, o) api.nvim_set_hl(0, n, o) end

  hl("AgentStream", { fg = p.green or "#5fca8b" })
  hl("AgentErr", { fg = p.red or "#e5675f" })
  -- idle = secondary-emphasis text: readable in both modes (fg_secondary sits between
  -- fg and fg_muted, so it darkens in light mode instead of washing out)
  hl("AgentIdle", { fg = p.fg_secondary or p.fg_muted or "#8a95a3" })
  hl("AgentAccent", { fg = accent, bold = true })
  hl("AgentFocusName", { fg = p.fg or "#c7ccd1", bold = true }) -- focused-but-not-open row
  hl("AgentMuted", { fg = p.fg_muted or "#5c6773" })
  hl("AgentAttn", { fg = attn, bold = true })
  hl("AgentDivider", { fg = p.bg_surface2 or p.bg_secondary or "#2a3038" }) -- subtle line

  -- focus-ring card (elevated fill + solid accent edge). The edge is a bg-filled
  -- cell, not a ▌ glyph, so it's continuous across rows (glyphs leave inter-row
  -- gaps in fonts that don't draw block chars full-height).
  hl("AgentCard", { bg = cardbg })
  hl("AgentBarSolid", { bg = accent })

  -- pills + rounded caps
  hl("AgentPillStream", { fg = dark, bg = p.green or "#5fca8b", bold = true })
  hl("AgentPillErr", { fg = dark, bg = p.red or "#e5675f", bold = true })
  hl("AgentPillIdle", { fg = dark, bg = p.blue or "#5aa9e6" })
  hl("AgentPillAttn", { fg = dark, bg = attn, bold = true })
  hl("AgentCapStream", { fg = p.green or "#5fca8b" })
  hl("AgentCapErr", { fg = p.red or "#e5675f" })
  hl("AgentCapIdle", { fg = p.blue or "#5aa9e6" })
  hl("AgentCapAttn", { fg = attn })

  -- composer chips + keycaps + caret
  hl("AgentChip", { fg = p.fg or "#c7ccd1", bg = surface })
  hl("AgentChipBar", { fg = accent })
  hl("AgentKey", { fg = dark, bg = accent, bold = true })
  hl("AgentKeyMuted", { fg = p.fg or "#c7ccd1", bg = surface })
  hl("AgentCaret", { fg = accent, bold = true })
  hl("AgentApproval", { fg = attn, bold = true })

  -- Cursor hiding by colour-match (blend=100 is unreliable in some terminals):
  -- in the roster the cursor parks on the accent bar → paint it accent; in
  -- floats it sits on Normal bg → paint it Normal. Chat/composer keep a real cursor.
  hl("AgentCursorRoster", { fg = accent, bg = accent, blend = 100 })
  hl("AgentCursorFloat", { fg = dark, bg = dark, blend = 100 })

  -- markview markdown groups from the theme so chat messages pop. Inline code gets
  -- a calm distinct hue (cyan) on the subtle surface bg — distinguishable from body
  -- text, but not the accent orange (which floods a code-dense chat, see #156/#157).
  local code = p.cyan or p.blue or "#7dcfff"
  hl("MarkviewInlineCode", { fg = code, bg = surface })
  hl("MarkviewCode", { bg = surface })
  hl("MarkviewCodeInfo", { fg = p.fg_muted or "#5c6773", bg = surface })
  hl("MarkviewCodeFg", { bg = surface })
  hl("@markup.raw.markdown_inline", { fg = code, bg = surface })
  hl("@markup.raw.block.markdown", { bg = surface })
  for i = 1, 6 do
    hl("MarkviewHeading" .. i, { fg = accent, bold = true })
    hl("MarkviewHeading" .. i .. "Sign", { fg = accent })
  end
  hl("MarkviewListItemMinus", { fg = p.blue or "#5aa9e6" })
  hl("MarkviewListItemStar", { fg = p.blue or "#5aa9e6" })
  hl("MarkviewListItemPlus", { fg = p.blue or "#5aa9e6" })
end

--------------------------------------------------------------------------------
-- message helpers
--------------------------------------------------------------------------------
local function msg_text(msg)
  local t = {}
  for _, c in ipairs((msg and msg.content) or {}) do
    if c.type == "text" and c.text then t[#t + 1] = c.text end
  end
  return table.concat(t, "")
end

-- compact elapsed: 12s · 5m · 3h
local function dur(since)
  if not since then return nil end
  local el = os.time() - since
  if el < 1 then return nil end
  if el < 60 then return el .. "s" end
  if el < 3600 then return math.floor(el / 60) .. "m" end
  return math.floor(el / 3600) .. "h"
end

-- Resolve a session's visual state: glyph, name-highlight, pill text/groups.
-- A pending approval overrides the daemon status with a "needs input" state.
session_state = function(a)
  if S.pending[a.id] then
    return { key = "needs_input", glyph = GLYPH.needs_input, name = "AgentAttn",
      pill = "AgentPillAttn", cap = "AgentCapAttn", label = "needs input" }
  end
  local st = a.status or "idle"
  if st == "streaming" then
    local d = dur(S.stream_since[a.id])
    return { key = "streaming", glyph = SPIN[(S.spin % #SPIN) + 1], name = "AgentStream",
      pill = "AgentPillStream", cap = "AgentCapStream", label = d and ("working " .. d) or "working" }
  elseif st == "error" then
    return { key = "error", glyph = GLYPH.error, name = "AgentErr",
      pill = "AgentPillErr", cap = "AgentCapErr", label = "error" }
  end
  local d = dur(S.idle_since[a.id])
  -- idle is the resting state: plain readable text, no pill (a filled pill's
  -- dark-on-blue is fragile against darker theme blues, and idle shouldn't shout)
  return { key = "idle", glyph = GLYPH.idle, name = "AgentIdle", plain = true,
    pill = "AgentIdle", cap = "AgentIdle", label = d and ("idle " .. d) or "idle" }
end

-- The active session isn't a roster row — it's the header of its own chat. Build
-- a rich winbar for it: name + live state (spinner when working) + plan + cost.
local function active_winbar()
  if not S.selected then return "%#AgentMuted#  no session" end
  local a
  for _, x in ipairs(S.roster) do if x.id == S.selected then a = x break end end
  if not a then return "%#AgentAccent#  ◆ " .. S.selected end
  local ss = session_state(a)
  local parts = { "%#AgentAccent#  ◆ " .. a.name,
    "%#AgentMuted# · %#" .. ss.name .. "#" .. ss.glyph .. " " .. ss.label }
  local pl = S.plan[a.id]
  if pl and pl.total and pl.total > 0 then
    parts[#parts + 1] = "%#AgentMuted#   ◆ " .. pl.done .. "/" .. pl.total
  end
  if a.costUsd and a.costUsd > 0 then
    parts[#parts + 1] = string.format("%%#AgentMuted#   $%.2f", a.costUsd)
  end
  return table.concat(parts)
end

local function refresh_active_header()
  if S.chatwin and api.nvim_win_is_valid(S.chatwin) then
    vim.wo[S.chatwin].winbar = active_winbar()
  end
end

--------------------------------------------------------------------------------
-- roster (sticky top) — focus-ring selection, no cursor, collapsible
--------------------------------------------------------------------------------
render_roster = function()
  if not (S.buf and api.nvim_buf_is_valid(S.buf)) then return end

  -- track streaming / idle start times so the pill can show elapsed
  for _, a in ipairs(S.roster) do
    if a.status == "streaming" then
      S.stream_since[a.id] = S.stream_since[a.id] or os.time()
      S.idle_since[a.id] = nil
    else
      S.stream_since[a.id] = nil
      if a.status ~= "error" then
        S.idle_since[a.id] = S.idle_since[a.id] or os.time()
      else
        S.idle_since[a.id] = nil
      end
    end
  end

  -- The roster is an ATTENTION QUEUE: sessions needing input / erroring / working,
  -- minus the active one (it lives in the chat header). show_all bypasses this so
  -- idle sessions can still be reopened — and with NO session open there's no chat
  -- header to hold the active one, so show everything to pick from.
  local all = S.show_all or not S.selected
  local displayed, hidden = {}, 0
  for _, a in ipairs(S.roster) do
    local needs = S.pending[a.id] or a.status == "error" or a.status == "streaming"
    if all or (needs and a.id ~= S.selected) then
      displayed[#displayed + 1] = a
    elseif a.id ~= S.selected then
      hidden = hidden + 1
    end
  end
  S.displayed = displayed
  if S.focus < 1 then S.focus = 1 end
  if #displayed > 0 and S.focus > #displayed then S.focus = #displayed end

  local lines, decor, mainline = {}, {}, {}
  local function push(l) lines[#lines + 1] = l; return #lines - 1 end

  local dot = S.connected and "" or (GLYPH.offline .. " ")
  local head = "  " .. dot .. (all and "sessions · " or "attention · ") .. scope
  decor[#decor + 1] = { line = push(head), fg = "AgentMuted" }

  if #displayed == 0 then
    local msg = (#S.roster == 0) and "  no sessions — n to start · . for cwd"
      or ("  ✓ nothing needs attention" .. (hidden > 0 and ("   " .. hidden .. " idle · z for all") or ""))
    decor[#decor + 1] = { line = push(msg), fg = "AgentMuted" }
  else
    for i, a in ipairs(displayed) do
      local sstate = session_state(a)
      local focused = (i == S.focus)
      local isSel = (a.id == S.selected)

      -- name line: [bar] glyph name [✎ if draft]
      local nm = a.name
      local dr = S.drafts[a.id]
      if dr and dr:gsub("%s", "") ~= "" then nm = nm .. "  ✎" end
      -- col 0 is reserved for the focus edge (bg cell when focused); glyph at col 2
      local ml = push("  " .. sstate.glyph .. " " .. nm)
      mainline[i] = ml
      decor[#decor + 1] = { line = ml, fg = isSel and "AgentAccent" or (focused and "AgentFocusName" or sstate.name) }
      if focused then
        decor[#decor + 1] = { line = ml, card = true }
        decor[#decor + 1] = { line = ml, range = { 0, 1, "AgentBarSolid" } }
      end

      -- substatus line as REAL text + range highlights, so fg-only segments
      -- (caps, model, cost) inherit the card bg instead of punching Normal-bg
      -- holes through it (the overlay-virt-text bug). Active states wear a filled
      -- pill; the resting idle state is plain fg-only text (see session_state).
      local segs = sstate.plain and {
        -- align label under the name (name sits at col 4: 2 pad + glyph + space)
        { t = "    " .. sstate.label, hl = sstate.name },
      } or {
        { t = "   ", hl = nil },
        { t = LCAP, hl = sstate.cap },
        { t = " " .. sstate.label .. " ", hl = sstate.pill },
        { t = RCAP, hl = sstate.cap },
      }
      -- plan progress chip (◆ done/total) for sessions whose worktree has a plan
      local pl = S.plan[a.id]
      if pl and pl.total and pl.total > 0 then
        local hl = (pl.phase == "reconciled") and "AgentStream" or "AgentMuted"
        segs[#segs + 1] = { t = "  ◆ " .. pl.done .. "/" .. pl.total, hl = hl }
      end
      local sline = ""
      for _, s in ipairs(segs) do sline = sline .. s.t end
      local sl = push(sline)
      if focused then
        decor[#decor + 1] = { line = sl, card = true }
        decor[#decor + 1] = { line = sl, range = { 0, 1, "AgentBarSolid" } }
      end
      local col = 0
      for _, s in ipairs(segs) do
        local e = col + #s.t
        if s.hl then decor[#decor + 1] = { line = sl, range = { col, e, s.hl } } end
        col = e
      end
    end
    if not S.show_all and hidden > 0 then
      decor[#decor + 1] = { line = push("   " .. hidden .. " idle · z for all"), fg = "AgentMuted" }
    end
  end

  vim.bo[S.buf].modifiable = true
  api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.bo[S.buf].modifiable = false
  api.nvim_buf_clear_namespace(S.buf, S.ns, 0, -1)
  for _, d in ipairs(decor) do
    if d.fg then pcall(api.nvim_buf_add_highlight, S.buf, S.ns, d.fg, d.line, 0, -1) end
    if d.card then
      pcall(api.nvim_buf_set_extmark, S.buf, S.ns, d.line, 0, { line_hl_group = "AgentCard", priority = 90 })
    end
    if d.range then
      pcall(api.nvim_buf_set_extmark, S.buf, S.ns, d.line, d.range[1],
        { end_col = d.range[2], hl_group = d.range[3], priority = 160 })
    end
  end

  if S.win and api.nvim_win_is_valid(S.win) then
    pcall(api.nvim_win_set_height, S.win, math.max(1, #lines))
    if mainline[S.focus] then pcall(api.nvim_win_set_cursor, S.win, { mainline[S.focus] + 1, 0 }) end
  end
end

--------------------------------------------------------------------------------
-- chat (scrollable middle) — message blocks, folds, streaming, approval card
--------------------------------------------------------------------------------
render_chat = function(scroll)
  if not (S.chatbuf and api.nvim_buf_is_valid(S.chatbuf)) then return end
  local lines, decor = {}, {}
  local line_msg, blocks = {}, {}
  local function push(l, mi)
    lines[#lines + 1] = l
    line_msg[#lines - 1] = mi
    return #lines - 1
  end

  local chat = S.selected and S.chat[S.selected]
  local folds = (S.selected and S.folds[S.selected]) or {}
  local has_any = chat and chat.msgs and #chat.msgs > 0

  if not has_any and not (S.selected and S.stream[S.selected]) then
    decor[#decor + 1] = { line = push(S.selected and "  …no messages yet — compose below" or "  ↑ press <CR> on a session above to open it"), fg = "AgentMuted" }
  else
    if chat and chat.msgs then
      for mi, m in ipairs(chat.msgs) do
        if mi > 1 then push(""); push("") end
        local isUser = m.role == "user"
        local folded = folds[mi]
        local caret = folded and FOLDED or OPEN
        local hdr = (isUser and (caret .. " " .. BAR .. " you") or (caret .. " " .. BAR .. " agent"))
        blocks[#blocks + 1] = #lines + 1 -- 1-indexed bufline of this header
        decor[#decor + 1] = { line = push(hdr, mi), fg = isUser and "AgentAccent" or "AgentStream" }
        if folded then
          local n = select(2, m.text:gsub("\n", "\n")) + 1
          decor[#decor + 1] = { line = push("  ⋯ " .. n .. " lines", mi), fg = "AgentMuted" }
        else
          for _, para in ipairs(vim.split(m.text or "", "\n", { plain = true })) do
            push(para, mi)
          end
        end
      end
    end
    -- live streaming block (superseded by message_end when the turn completes)
    local sv = S.selected and S.stream[S.selected]
    if sv and sv ~= "" then
      if has_any then push(""); push("") end
      decor[#decor + 1] = { line = push(OPEN .. " " .. BAR .. " agent"), fg = "AgentStream" }
      for _, para in ipairs(vim.split(sv, "\n", { plain = true })) do push(para) end
      lines[#lines] = lines[#lines] .. " " .. CARET
      decor[#decor + 1] = { line = #lines - 1, caret = true }
    end
  end

  -- inline approval card for the selected session
  local ap = S.selected and S.pending[S.selected]
  if ap then
    push(""); push("")
    decor[#decor + 1] = { line = push("╭─ approval · " .. (ap.method or "confirm")), fg = "AgentApproval" }
    if ap.title and ap.title ~= "" then decor[#decor + 1] = { line = push("│ " .. ap.title), fg = "AgentApproval" } end
    if ap.message and ap.message ~= "" then
      for _, l in ipairs(vim.split(ap.message, "\n", { plain = true })) do
        decor[#decor + 1] = { line = push("│ " .. l), fg = "AgentMuted" }
      end
    end
    if ap.method == "select" and ap.options then
      for oi, opt in ipairs(ap.options) do
        decor[#decor + 1] = { line = push("│  [" .. oi .. "] " .. tostring(opt)), fg = "AgentAccent" }
      end
      decor[#decor + 1] = { line = push("╰ press a number · <Esc> cancel"), fg = "AgentMuted" }
    elseif ap.method == "input" or ap.method == "editor" then
      decor[#decor + 1] = { line = push("╰ press i to type a reply · <Esc> cancel"), fg = "AgentMuted" }
    else
      decor[#decor + 1] = { line = push("╰  [y] yes    [n] no    <Esc> cancel"), fg = "AgentAccent" }
    end
  end

  vim.bo[S.chatbuf].modifiable = true
  api.nvim_buf_set_lines(S.chatbuf, 0, -1, false, lines)
  vim.bo[S.chatbuf].modifiable = false
  api.nvim_buf_clear_namespace(S.chatbuf, S.ns, 0, -1)
  for _, d in ipairs(decor) do
    if d.fg then pcall(api.nvim_buf_add_highlight, S.chatbuf, S.ns, d.fg, d.line, 0, -1) end
    if d.caret then
      pcall(api.nvim_buf_set_extmark, S.chatbuf, S.ns, d.line, 0, { line_hl_group = "AgentStream", priority = 80 })
    end
  end

  S.chat_line_msg = line_msg
  S.chat_blocks = blocks

  if S.chatwin and api.nvim_win_is_valid(S.chatwin) then
    if S.view == "chat" then refresh_active_header() end
    if scroll then pcall(api.nvim_win_set_cursor, S.chatwin, { #lines, 0 }) end
  end
  if sync_approval_keys then sync_approval_keys() end
end

render = function() render_roster(); render_chat(true) end

--------------------------------------------------------------------------------
-- daemon event handling
--------------------------------------------------------------------------------
-- Best-effort extraction of an incremental text chunk from a streaming event.
local function delta_text(m)
  if type(m.text) == "string" then return m.text end
  if type(m.delta) == "table" and type(m.delta.text) == "string" then return m.delta.text end
  if type(m.content) == "string" then return m.content end
  return nil
end

handle = function(obj)
  local t = obj.type
  if t == "roster" then
    S.roster = obj.sessions or {}
    table.sort(S.roster, function(a, b) return (a.name or "") < (b.name or "") end)
    render_roster()
  elseif t == "sources" then
    S.sources = obj.sources or {}
  elseif t == "response" and obj.command == "get_messages" and obj.data and obj.data.messages then
    local msgs = {}
    for _, msg in ipairs(obj.data.messages) do
      local text = msg_text(msg)
      if (msg.role == "user" or msg.role == "assistant") and text:gsub("%s", "") ~= "" then
        msgs[#msgs + 1] = { role = msg.role, text = text }
      end
    end
    S.chat[obj.session] = { msgs = msgs }
    if obj.session == S.selected then render_chat(true) end
  elseif t == "message_end" and obj.session then
    local m = obj.message or {}
    local text = msg_text(m)
    S.stream[obj.session] = nil -- finalize any live stream
    if m.role ~= "assistant" or text:gsub("%s", "") == "" then
      if obj.session == S.selected then render_chat(false) end
      return
    end
    local c = S.chat[obj.session] or { msgs = {} }
    c.msgs[#c.msgs + 1] = { role = "assistant", text = text }
    S.chat[obj.session] = c
    if obj.session == S.selected then render_chat(true) end
  elseif (t == "text_delta" or t == "content_block_delta" or t == "message_delta" or t == "text") and obj.session then
    local chunk = delta_text(obj)
    if chunk and chunk ~= "" then
      S.stream[obj.session] = (S.stream[obj.session] or "") .. chunk
      if obj.session == S.selected then render_chat(true) end
    end
  elseif (t == "turn_end" or t == "agent_end") and obj.session then
    S.stream[obj.session] = nil
    if obj.session == S.selected then render_chat(false) end
  elseif t == "extension_ui_request" then
    local m = obj.method
    if m == "notify" then
      vim.notify("[" .. (obj.session or "agent") .. "] " .. (obj.message or ""), vim.log.levels.INFO)
    elseif m == "confirm" or m == "select" or m == "input" or m == "editor" then
      -- only genuine questions become an inline approval card / "needs input"
      S.pending[obj.session] = obj
      render_roster()
      if obj.session == S.selected then render_chat(true) end
    end
    -- setStatus/setWidget/setTitle/set_editor_text: UI directives, not questions —
    -- ignored (surfacing them as approvals was the spurious "setStatus" card)
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
      vim.schedule(function() render_roster() end)
      if cb then vim.schedule(cb) end
      return
    end
    pcall(function() p:close() end)
    if tries == 0 then
      vim.schedule(function()
        fn.jobstart({ agentd_bin(), "--scope", scope, "--repo", scope_root() }, { detach = true })
      end)
    end
    if tries < 30 then
      local tm = uv.new_timer()
      tm:start(200, 0, function() tm:close(); try_connect(cb, tries + 1) end)
    else
      vim.schedule(function()
        vim.notify("agent-nvim: could not reach agentd (" .. scope .. ")", vim.log.levels.ERROR)
      end)
    end
  end)
end

connect = function(cb)
  if S.connected then if cb then cb() end return end
  try_connect(cb, 0)
end

send = function(obj)
  if not (S.connected and S.pipe) then return end
  S.pipe:write(vim.json.encode(obj) .. "\n")
end

--------------------------------------------------------------------------------
-- re-root + session lifecycle
--------------------------------------------------------------------------------
local function reroot(cwd)
  if not cwd or cwd == "" then return end
  pcall(vim.cmd, "tcd " .. fn.fnameescape(cwd))
  pcall(function() require("plan-nvim").bind() end)
  local in_repo = fn.system({ "git", "-C", cwd, "rev-parse", "--is-inside-work-tree" })
  if in_repo:match("true") then pcall(function() require("file-watcher").start() end) end
  pcall(api.nvim_exec_autocmds, "DirChanged", { modeline = false })
end

-- save the current composer text as the draft for the outgoing session
local function save_draft()
  if S.selected and S.composerbuf and api.nvim_buf_is_valid(S.composerbuf) then
    local txt = table.concat(api.nvim_buf_get_lines(S.composerbuf, 0, -1, false), "\n")
    S.drafts[S.selected] = txt
  end
end

-- load a session's draft into the composer
local function load_draft(id)
  if not (S.composerbuf and api.nvim_buf_is_valid(S.composerbuf)) then return end
  local txt = S.drafts[id] or ""
  api.nvim_buf_set_lines(S.composerbuf, 0, -1, false, vim.split(txt, "\n", { plain = true }))
  render_chips() -- re-assert top pad (+ chips) after set_lines cleared extmarks
  composer_placeholder()
end

-- render the roster + whichever view the middle pane is currently showing
local function render_active()
  render_roster()
  if S.view == "changes" then render_changes() else render_chat(true) end
end

start_session = function(name, cwd)
  -- if a session with this name already runs, OPEN it (don't re-spawn — that
  -- restarts pi and wipes its history); only spawn a genuinely new one
  for _, a in ipairs(S.roster) do
    if a.id == name or a.name == name then return view_session(a.id, a.cwd or cwd) end
  end
  save_draft()
  S.selected = name
  send({ type = "spawn", session = name, cwd = cwd })
  send({ type = "get_messages", session = name })
  reroot(cwd)
  load_draft(name)
  refresh_plans()
  render_active()
end

view_session = function(name, cwd)
  save_draft()
  S.selected = name
  send({ type = "get_messages", session = name })
  reroot(cwd)
  load_draft(name)
  refresh_plans()
  render_active()
end

open_picker = function()
  local items = {}
  local cwd = fn.getcwd()
  items[#items + 1] = { label = "· this dir — " .. fn.fnamemodify(cwd, ":~"), name = base(cwd), cwd = cwd }
  local srcs = {}
  for _, s in ipairs(S.sources) do srcs[#srcs + 1] = { label = "  " .. s.name, name = s.name, cwd = s.cwd } end
  table.sort(srcs, function(a, b) return a.label < b.label end)
  for _, s in ipairs(srcs) do items[#items + 1] = s end
  if fn.executable("zoxide") == 1 then
    for i, dir in ipairs(fn.systemlist("zoxide query -l")) do
      if i > 20 then break end
      items[#items + 1] = { label = "z " .. fn.fnamemodify(dir, ":~"), name = base(dir), cwd = dir }
    end
  end
  items[#items + 1] = { label = "＋ browse to a directory…", browse = true }
  vim.ui.select(items, { prompt = "Start a session (" .. scope .. ")", format_item = function(it) return it.label end }, function(it)
    if not it then return end
    if it.browse then
      vim.ui.input({ prompt = "Session directory: ", default = fn.getcwd(), completion = "dir" }, function(path)
        if path and #path > 0 then
          local dir = fn.expand(path)
          start_session(fn.fnamemodify(dir, ":t"), dir)
        end
      end)
    else
      start_session(it.name, it.cwd)
    end
  end)
end

--------------------------------------------------------------------------------
-- spinner (only ticks while something streams)
--------------------------------------------------------------------------------
local function start_spin()
  if S.timer then return end
  S.timer = uv.new_timer()
  S.timer:start(90, 90, vim.schedule_wrap(function()
    if not (S.win and api.nvim_win_is_valid(S.win)) then return end
    local streaming = false
    for _, a in ipairs(S.roster) do
      if a.status == "streaming" then streaming = true; break end
    end
    S.tick = (S.tick or 0) + 1
    if S.tick % 200 == 0 then refresh_plans() end -- ~18s: refresh plan progress
    if streaming then
      S.spin = S.spin + 1
      render_roster()
      if S.view == "chat" then refresh_active_header() end -- animate the active spinner
    elseif S.tick % 22 == 0 then
      render_roster() -- ~2s refresh so idle durations tick up
    end
  end))
end

local function stop_spin()
  if S.timer then
    pcall(function() S.timer:stop(); S.timer:close() end)
    S.timer = nil
  end
end

--------------------------------------------------------------------------------
-- composer: attachments, chips, autogrow, slash commands, send
--------------------------------------------------------------------------------
local function composer_empty()
  local ls = api.nvim_buf_get_lines(S.composerbuf, 0, -1, false)
  return #ls == 0 or (#ls == 1 and ls[1] == "")
end

composer_resize = function()
  if not (S.composerwin and api.nvim_win_is_valid(S.composerwin)) then return end
  vim.wo[S.composerwin].wrap = true -- long lines wrap+grow, never side-scroll
  -- Height = total display rows, which includes the single blank pad virtual line
  -- above the input (see render_chips) plus wrapped content.
  local ok, h = pcall(api.nvim_win_text_height, S.composerwin, {})
  local all = (ok and type(h) == "table" and h.all) or (api.nvim_buf_line_count(S.composerbuf) + #S.attach)
  all = math.max(1, math.min(all, COMPOSER_MAX + #S.attach))
  pcall(api.nvim_win_set_height, S.composerwin, all)
end

composer_placeholder = function()
  api.nvim_buf_clear_namespace(S.composerbuf, S.composer_ns, 0, -1)
  if composer_empty() then
    local hint = S.selected and ("message " .. S.selected .. "…  (/ for commands)") or "open a session first"
    pcall(api.nvim_buf_set_extmark, S.composerbuf, S.composer_ns, 0, 0, {
      virt_text = { { hint, "AgentMuted" } }, virt_text_pos = "overlay",
    })
  end
end

-- Composer top decoration: one blank pad line above the input (+ any attachment
-- chips), as virtual lines. NO bottom pad: the lualine bar sits immediately below
-- the composer and already supplies a row of visual weight there, so a bottom
-- blank would read heavier than the top. One top pad + the bar = balanced.
render_chips = function()
  if not (S.composerbuf and api.nvim_buf_is_valid(S.composerbuf)) then return end
  api.nvim_buf_clear_namespace(S.composerbuf, S.chip_ns, 0, -1)
  local vls = { { { "", "Normal" } } }
  for _, at in ipairs(S.attach) do
    local loc = at.path
    if at.l1 then loc = loc .. ":" .. at.l1 .. (at.l2 and at.l2 ~= at.l1 and ("-" .. at.l2) or "") end
    local tag = (at.lang and at.lang ~= "") and ("  " .. at.lang) or ""
    vls[#vls + 1] = { { CHIP_BAR .. " ", "AgentChipBar" }, { " " .. loc .. tag .. " ", "AgentChip" } }
  end
  pcall(api.nvim_buf_set_extmark, S.composerbuf, S.chip_ns, 0, 0, { virt_lines = vls, virt_lines_above = true })
  composer_resize()
end

add_attachment = function(at)
  S.attach[#S.attach + 1] = at
  render_chips()
end

local function clear_attachments()
  S.attach = {}
  render_chips()
end

-- Format the outgoing prompt: attachments as fenced code, then the message.
local function build_prompt(text)
  if #S.attach == 0 then return text end
  local parts = {}
  for _, at in ipairs(S.attach) do
    local loc = at.path
    if at.l1 then loc = loc .. ":" .. at.l1 .. (at.l2 and at.l2 ~= at.l1 and ("-" .. at.l2) or "") end
    parts[#parts + 1] = "```" .. (at.lang or "") .. " " .. loc .. "\n" .. (at.text or "") .. "\n```"
  end
  if text ~= "" then parts[#parts + 1] = text end
  return table.concat(parts, "\n\n")
end

-- Slash commands typed in the composer. Returns true if handled (not a prompt).
local function run_slash(text)
  local cmd, rest = text:match("^/(%S+)%s*(.*)$")
  if not cmd then return false end
  if cmd == "abort" then
    send({ type = "abort", session = S.selected })
    S.stream[S.selected] = nil; render_chat(false)
  elseif cmd == "steer" then
    send({ type = "steer", session = S.selected, message = rest })
  elseif cmd == "clear" then
    S.chat[S.selected] = { msgs = {} }; S.stream[S.selected] = nil; render_chat(true)
  elseif cmd == "diff" then
    pcall(vim.cmd, "tab Git diff")
  elseif cmd == "plan" then
    pcall(function() require("plan-nvim").open() end)
  elseif cmd == "retry" then
    send({ type = "follow_up", session = S.selected, message = "retry the previous step" })
  elseif cmd == "help" then
    M.help()
  else
    -- Not a rail command → let it through to pi as a prompt. pi owns its own
    -- slash commands / skills (e.g. /plan-ticket), so the rail must not swallow them.
    return false
  end
  return true
end

composer_send = function()
  if not S.selected then vim.notify("agent-nvim: open a session first (<CR>)", vim.log.levels.INFO); return end
  local text = table.concat(api.nvim_buf_get_lines(S.composerbuf, 0, -1, false), "\n"):gsub("%s+$", "")
  if text == "" and #S.attach == 0 then return end

  -- slash command (only when there are no attachments and it's a lone command)
  if #S.attach == 0 and text:match("^/%S") and run_slash(text) then
    api.nvim_buf_set_lines(S.composerbuf, 0, -1, false, { "" })
    render_chips(); composer_placeholder()
    return
  end

  local prompt = build_prompt(text)
  local c = S.chat[S.selected] or { msgs = {} }
  c.msgs[#c.msgs + 1] = { role = "user", text = prompt } -- optimistic echo
  S.chat[S.selected] = c
  render_chat(true)
  send({ type = "prompt", session = S.selected, message = prompt })
  S.drafts[S.selected] = nil
  clear_attachments()
  api.nvim_buf_set_lines(S.composerbuf, 0, -1, false, { "" })
  render_chips(); composer_placeholder()
  vim.cmd("startinsert!")
end

focus_composer = function()
  if not S.selected then vim.notify("agent-nvim: open a session first (<CR>)", vim.log.levels.INFO); return end
  if S.composerwin and api.nvim_win_is_valid(S.composerwin) then
    api.nvim_set_current_win(S.composerwin)
    vim.cmd("startinsert!")
  end
end

--------------------------------------------------------------------------------
-- code bridge: send editor context into the composer as attachments
--------------------------------------------------------------------------------
local function ensure_open_and_compose()
  if not (S.win and api.nvim_win_is_valid(S.win)) then M.open() end
  vim.schedule(function() focus_composer() end)
end

-- Quick-send: a small floating prompt at the cursor to message the active session
-- from anywhere in the editor, without opening/focusing the rail.
function M.send_message()
  if not S.selected then vim.notify("agent-nvim: no active session — open one first", vim.log.levels.WARN); return end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  local width = math.min(80, vim.o.columns - 6)
  local win = api.nvim_open_win(buf, true, {
    relative = "cursor", row = 1, col = 0, width = width, height = 1,
    style = "minimal", border = "rounded", title = " → " .. S.selected .. " ", title_pos = "left",
  })
  vim.wo[win].winhighlight = "Normal:Normal,FloatBorder:AgentAccent"
  vim.cmd("startinsert")
  local function submit()
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):gsub("%s+$", "")
    pcall(api.nvim_win_close, win, true)
    if #text == 0 or not S.selected then return end
    local c = S.chat[S.selected] or { msgs = {} }
    c.msgs[#c.msgs + 1] = { role = "user", text = text }
    S.chat[S.selected] = c
    send({ type = "prompt", session = S.selected, message = text })
    if S.view == "chat" then render_chat(true) end
    vim.notify("agent-nvim: → " .. S.selected)
  end
  vim.keymap.set({ "n", "i" }, "<CR>", submit, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<Esc>", function() pcall(api.nvim_win_close, win, true) end, { buffer = buf, nowait = true })
end

function M.send_range()
  local buf = api.nvim_get_current_buf()
  local l1 = fn.getpos("'<")[2]
  local l2 = fn.getpos("'>")[2]
  if l1 == 0 then l1 = fn.line(".") end
  if l2 == 0 then l2 = l1 end
  if l1 > l2 then l1, l2 = l2, l1 end
  local text = table.concat(api.nvim_buf_get_lines(buf, l1 - 1, l2, false), "\n")
  local path = fn.expand("%:.")
  add_attachment({ path = path ~= "" and path or "[scratch]", l1 = l1, l2 = l2, lang = vim.bo[buf].filetype, text = text })
  ensure_open_and_compose()
end

function M.send_file()
  local buf = api.nvim_get_current_buf()
  local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local path = fn.expand("%:.")
  add_attachment({ path = path ~= "" and path or "[scratch]", lang = vim.bo[buf].filetype, text = text })
  ensure_open_and_compose()
end

function M.send_diff()
  local path = fn.expand("%:.")
  local out = fn.systemlist({ "git", "diff", "--", (path ~= "" and path or ".") })
  if #out == 0 then vim.notify("agent-nvim: no diff", vim.log.levels.INFO); return end
  add_attachment({ path = "git diff " .. (path ~= "" and path or "."), lang = "diff", text = table.concat(out, "\n") })
  ensure_open_and_compose()
end

function M.attach_file()
  vim.ui.input({ prompt = "Attach file: ", default = "", completion = "file" }, function(path)
    if not path or path == "" then return end
    local p = fn.expand(path)
    if fn.filereadable(p) == 0 then vim.notify("agent-nvim: not readable — " .. path, vim.log.levels.WARN); return end
    local text = table.concat(fn.readfile(p), "\n")
    local ft = vim.filetype.match({ filename = p }) or ""
    add_attachment({ path = fn.fnamemodify(p, ":."), lang = ft, text = text })
    focus_composer()
  end)
end

function M.send_diagnostics()
  local buf = api.nvim_get_current_buf()
  local ds = vim.diagnostic.get(buf)
  if #ds == 0 then vim.notify("agent-nvim: no diagnostics", vim.log.levels.INFO); return end
  local sev = { "ERROR", "WARN", "INFO", "HINT" }
  local out = {}
  for _, d in ipairs(ds) do
    out[#out + 1] = string.format("%s:%d:%d: %s: %s", fn.expand("%:."), d.lnum + 1, d.col + 1,
      sev[d.severity] or "?", (d.message or ""):gsub("\n", " "))
  end
  add_attachment({ path = "diagnostics " .. fn.expand("%:."), lang = "text", text = table.concat(out, "\n") })
  ensure_open_and_compose()
end

--------------------------------------------------------------------------------
-- chat navigation: block jump, fold, yank code
--------------------------------------------------------------------------------
local function chat_block_jump(dir)
  if not (S.chatwin and api.nvim_win_is_valid(S.chatwin)) then return end
  local cur = api.nvim_win_get_cursor(S.chatwin)[1]
  local target
  if dir > 0 then
    for _, ln in ipairs(S.chat_blocks) do if ln > cur then target = ln; break end end
  else
    for i = #S.chat_blocks, 1, -1 do if S.chat_blocks[i] < cur then target = S.chat_blocks[i]; break end end
  end
  if target then pcall(api.nvim_win_set_cursor, S.chatwin, { target, 0 }) end
end

local function chat_fold_toggle()
  if not (S.chatwin and api.nvim_win_is_valid(S.chatwin) and S.selected) then return end
  local ln0 = api.nvim_win_get_cursor(S.chatwin)[1] - 1
  local mi = S.chat_line_msg[ln0]
  if not mi then return end
  S.folds[S.selected] = S.folds[S.selected] or {}
  S.folds[S.selected][mi] = not S.folds[S.selected][mi]
  render_chat(false)
end

-- cwd of a roster session by id
local function session_cwd(id)
  for _, a in ipairs(S.roster) do if a.id == id then return a.cwd end end
  return nil
end

-- open a file in the main editor window (not a rail pane), at an optional line.
-- Relative paths resolve against the session's worktree.
local function open_in_editor(cwd, path, line)
  local file = path:match("^/") and path or ((cwd or fn.getcwd()) .. "/" .. path)
  file = fn.expand(file)
  if fn.filereadable(file) == 0 then vim.notify("agent-nvim: not readable — " .. path, vim.log.levels.WARN); return end
  local target
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if not api.nvim_buf_get_name(api.nvim_win_get_buf(w)):match("agent%-") then target = w; break end
  end
  if target then api.nvim_set_current_win(target) else vim.cmd("botright vsplit") end
  pcall(vim.cmd, "edit " .. fn.fnameescape(file))
  if line then pcall(api.nvim_win_set_cursor, 0, { tonumber(line), 0 }) end
end

-- reverse bridge: open the file referenced in the nearest fenced-code header
-- (```lang path:l1-l2). Opens in the main editor window, not the rail.
local function chat_open_ref()
  if not (S.chatwin and api.nvim_win_is_valid(S.chatwin)) then return end
  local cur = api.nvim_win_get_cursor(S.chatwin)[1]
  local all = api.nvim_buf_get_lines(S.chatbuf, 0, -1, false)
  local s = cur
  while s >= 1 and not (all[s] and all[s]:match("^```")) do s = s - 1 end
  local loc = all[s] and all[s]:match("^```%S*%s+(%S+)")
  if not loc then vim.notify("agent-nvim: no file reference at cursor", vim.log.levels.INFO); return end
  local path, l1 = loc:match("^([^:]+):(%d+)")
  open_in_editor(nil, path or loc, l1)
end

-- yank the fenced code block the cursor sits in (``` … ```), else the line
local function chat_yank_code()
  if not (S.chatwin and api.nvim_win_is_valid(S.chatwin)) then return end
  local cur = api.nvim_win_get_cursor(S.chatwin)[1]
  local all = api.nvim_buf_get_lines(S.chatbuf, 0, -1, false)
  local s = cur
  while s > 1 and not all[s]:match("^```") do s = s - 1 end
  if not all[s] or not all[s]:match("^```") then
    fn.setreg("+", all[cur] or ""); vim.notify("agent-nvim: yanked line", vim.log.levels.INFO); return
  end
  local e = cur + 1
  while e <= #all and not all[e]:match("^```") do e = e + 1 end
  local body = {}
  for i = s + 1, e - 1 do body[#body + 1] = all[i] end
  fn.setreg("+", table.concat(body, "\n"))
  vim.notify("agent-nvim: yanked code block (" .. #body .. " lines)", vim.log.levels.INFO)
end

--------------------------------------------------------------------------------
-- changes view: plan (progress.json) first, git diff as fallback/overlay
--------------------------------------------------------------------------------
-- the vault plans dir if present, else the worktree's local .plans
local function plandir(cwd)
  local vault = fn.expand("~/personal/notes/storage/plans")
  if fn.isdirectory(vault) == 1 then return vault end
  local local_ = (cwd or fn.getcwd()) .. "/.plans"
  return fn.isdirectory(local_) == 1 and local_ or nil
end

-- find the plan whose progress.json branch matches the session's branch
local function load_plan(cwd)
  local dir = plandir(cwd)
  if not dir then return nil end
  local branch = fn.system({ "git", "-C", cwd, "branch", "--show-current" }):gsub("%s+$", "")
  if branch == "" then return nil end
  for _, f in ipairs(fn.globpath(dir, "*.progress.json", false, true)) do
    local ok, data = pcall(function() return vim.json.decode(table.concat(fn.readfile(f), "\n")) end)
    if ok and type(data) == "table" and data.branch == branch then
      return { progress = data, key = fn.fnamemodify(f, ":t"):gsub("%.progress%.json$", "") }
    end
  end
  return nil
end

-- files changed on the branch (committed + uncommitted) vs where it forked
local function git_changes(cwd)
  if not cwd or fn.isdirectory(cwd) ~= 1 then return {} end
  if not fn.system({ "git", "-C", cwd, "rev-parse", "--is-inside-work-tree" }):match("true") then return {} end
  local base = fn.system({ "git", "-C", cwd, "merge-base", "HEAD", "origin/main" }):gsub("%s+$", "")
  if base == "" then base = fn.system({ "git", "-C", cwd, "merge-base", "HEAD", "main" }):gsub("%s+$", "") end
  local cmd = { "git", "-C", cwd, "diff", "--numstat" }
  if base ~= "" then cmd[#cmd + 1] = base end
  local files = {}
  for _, line in ipairs(fn.systemlist(cmd)) do
    local add, del, path = line:match("^(%S+)%s+(%S+)%s+(.+)$")
    if path then files[#files + 1] = { path = path, add = tonumber(add) or 0, del = tonumber(del) or 0 } end
  end
  return files
end

local function statmark(add, del)
  if not add then return "" end
  return string.format("  +%d -%d", add, del)
end

-- MCP servers available to a session: pi loads them from a --mcp-config file;
-- read the worktree's .mcp.json plus the global ~/.config/mcp/mcp.json.
local function session_mcp(cwd)
  local out, seen = {}, {}
  local files = {}
  if cwd and cwd ~= "" then files[#files + 1] = cwd .. "/.mcp.json" end
  files[#files + 1] = fn.expand("~/.config/mcp/mcp.json")
  for _, f in ipairs(files) do
    if fn.filereadable(f) == 1 then
      local ok, data = pcall(function() return vim.json.decode(table.concat(fn.readfile(f), "\n")) end)
      local servers = ok and type(data) == "table" and (data.mcpServers or data.servers)
      if type(servers) == "table" then
        for name in pairs(servers) do
          if not seen[name] then seen[name] = true; out[#out + 1] = name end
        end
      end
    end
  end
  table.sort(out)
  return out
end

-- refresh the cached plan progress for every rostered session (git + file reads,
-- so called sparingly: on select, on open, and on a slow timer — not per render)
refresh_plans = function()
  for _, a in ipairs(S.roster) do
    if a.cwd and a.cwd ~= "" then
      local plan = load_plan(a.cwd)
      if plan then
        local flow, done = plan.progress.flow or {}, 0
        for _, s in ipairs(flow) do if s.status == "done" then done = done + 1 end end
        S.plan[a.id] = { done = done, total = #flow, phase = plan.progress.phase }
      else
        S.plan[a.id] = false
      end
    end
  end
end

render_changes = function()
  if not (S.changesbuf and api.nvim_buf_is_valid(S.changesbuf)) then return end
  local lines, decor, openmap = {}, {}, {}
  local function push(l, path, l1)
    lines[#lines + 1] = l
    if path then openmap[#lines - 1] = { path = path, l1 = l1 } end
    return #lines - 1
  end

  local cwd = S.selected and session_cwd(S.selected)
  if not cwd then
    decor[#decor + 1] = { line = push("  press <CR> to open a session"), fg = "AgentMuted" }
  else
    local plan = load_plan(cwd)
    local changes = git_changes(cwd)
    local bypath = {}
    for _, c in ipairs(changes) do bypath[c.path] = c end

    if plan then
      local pg = plan.progress
      decor[#decor + 1] = { line = push("  plan · " .. plan.key .. " · " .. (pg.phase or "?")), fg = "AgentMuted" }
      push("")
      for _, step in ipairs(pg.flow or {}) do
        local g = step.status == "done" and "●" or (step.status == "active" and "◐" or "○")
        local grp = step.status == "done" and "AgentStream" or (step.status == "active" and "AgentAccent" or "AgentIdle")
        decor[#decor + 1] = { line = push("  " .. g .. " " .. (step.step or "")), fg = grp }
      end
      push("")
      decor[#decor + 1] = { line = push("  files"), fg = "AgentMuted" }
      for _, pf in ipairs(pg.planned or {}) do
        local c = bypath[pf.file]
        local mark = pf.status == "done" and "●" or (pf.status == "touched" and "◐" or "○")
        local grp = pf.status == "done" and "AgentStream" or (pf.status == "touched" and "AgentAccent" or "AgentIdle")
        decor[#decor + 1] = { line = push("  " .. mark .. " " .. pf.file .. statmark(c and c.add, c and c.del), pf.file), fg = grp }
        bypath[pf.file] = nil
      end
      local drift = {}
      for _, c in pairs(bypath) do drift[#drift + 1] = c end
      if #drift > 0 then
        push("")
        decor[#decor + 1] = { line = push("  unplanned"), fg = "AgentAttn" }
        table.sort(drift, function(a, b) return a.path < b.path end)
        for _, c in ipairs(drift) do
          decor[#decor + 1] = { line = push("  ⚠ " .. c.path .. statmark(c.add, c.del), c.path), fg = "AgentAttn" }
        end
      end
    else
      decor[#decor + 1] = { line = push("  changes · " .. base(cwd)), fg = "AgentMuted" }
      push("")
      if #changes == 0 then
        decor[#decor + 1] = { line = push("  no changes on this branch"), fg = "AgentMuted" }
      else
        for _, c in ipairs(changes) do
          decor[#decor + 1] = { line = push("  " .. c.path .. statmark(c.add, c.del), c.path), fg = "AgentIdle" }
        end
      end
    end

    -- MCP servers this session's worktree has configured
    local mcp = session_mcp(cwd)
    if #mcp > 0 then
      push("")
      decor[#decor + 1] = { line = push("  mcp"), fg = "AgentMuted" }
      for _, s in ipairs(mcp) do
        decor[#decor + 1] = { line = push("  ⚙ " .. s), fg = "AgentIdle" }
      end
    end
  end

  vim.bo[S.changesbuf].modifiable = true
  api.nvim_buf_set_lines(S.changesbuf, 0, -1, false, lines)
  vim.bo[S.changesbuf].modifiable = false
  api.nvim_buf_clear_namespace(S.changesbuf, S.ns, 0, -1)
  for _, d in ipairs(decor) do
    if d.fg then pcall(api.nvim_buf_add_highlight, S.changesbuf, S.ns, d.fg, d.line, 0, -1) end
  end
  S.changes_open = openmap
  if S.chatwin and api.nvim_win_is_valid(S.chatwin) and S.view == "changes" then
    vim.wo[S.chatwin].winbar = "%#AgentMuted#  changes · " .. (S.selected or "—")
  end
end

-- flip the middle pane between the chat transcript and the changes overview
local function toggle_view()
  S.view = (S.view == "chat") and "changes" or "chat"
  if not (S.chatwin and api.nvim_win_is_valid(S.chatwin)) then return end
  if S.view == "changes" then
    api.nvim_win_set_buf(S.chatwin, S.changesbuf)
    render_changes()
    pcall(api.nvim_win_set_cursor, S.chatwin, { 1, 0 })
  else
    api.nvim_win_set_buf(S.chatwin, S.chatbuf)
    render_chat(false)
  end
end

-- open the file on the current line of the changes view
local function changes_open()
  if not (S.chatwin and api.nvim_win_is_valid(S.chatwin)) then return end
  local ln0 = api.nvim_win_get_cursor(S.chatwin)[1] - 1
  local e = S.changes_open[ln0]
  if e then open_in_editor(S.selected and session_cwd(S.selected), e.path, e.l1) end
end

-- Resize the rail column. The rail lives on the RIGHT, so its movable edge is on
-- its left: h widens it (edge moves left), l narrows it — the intuitive direction,
-- opposite the global <leader>h/l which just shrink/grow the focused window.
local function rail_resize(delta)
  if S.win and api.nvim_win_is_valid(S.win) then
    pcall(api.nvim_win_set_width, S.win, math.max(24, api.nvim_win_get_width(S.win) + delta))
  end
end

--------------------------------------------------------------------------------
-- approvals answered inline from the chat
--------------------------------------------------------------------------------
local function answer(payload)
  local ap = S.selected and S.pending[S.selected]
  if not ap then return end
  local msg = { type = "extension_ui_response", session = ap.session, id = ap.id }
  for k, v in pairs(payload) do msg[k] = v end
  send(msg)
  S.pending[S.selected] = nil
  render_roster(); render_chat(false)
end

-- Bind the answer keys (y/n confirm, 1-9 select) on the chat buffer ONLY while
-- an approval card is showing for the selected session — otherwise they'd steal
-- count prefixes and yanks from normal chat navigation.
local approval_keys_on = false
sync_approval_keys = function()
  if not (S.chatbuf and api.nvim_buf_is_valid(S.chatbuf)) then return end
  local ap = S.selected and S.pending[S.selected]
  local want = ap ~= nil and ap.method ~= "notify"
  if want == approval_keys_on then return end
  approval_keys_on = want
  local o = { buffer = S.chatbuf, nowait = true, silent = true }
  local keys = { "y", "n", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
  if want then
    vim.keymap.set("n", "y", function() if S.selected and S.pending[S.selected] then answer({ confirmed = true }) end end, o)
    vim.keymap.set("n", "n", function() if S.selected and S.pending[S.selected] then answer({ confirmed = false }) end end, o)
    for d = 1, 9 do
      vim.keymap.set("n", tostring(d), function()
        local a = S.selected and S.pending[S.selected]
        if a and a.method == "select" and a.options and a.options[d] then answer({ value = a.options[d] }) end
      end, o)
    end
  else
    for _, k in ipairs(keys) do pcall(vim.keymap.del, "n", k, { buffer = S.chatbuf }) end
  end
end

--------------------------------------------------------------------------------
-- centred float (help, peek)
--------------------------------------------------------------------------------
local function float(lines, title)
  local b = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  vim.bo[b].filetype = "markdown"
  pcall(vim.treesitter.start, b, "markdown")
  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, api.nvim_strwidth(l)) end
  w = math.min(math.max(w + 4, 40), math.floor(vim.o.columns * 0.7))
  local h = math.min(#lines, math.floor(vim.o.lines * 0.7))
  local win = api.nvim_open_win(b, true, {
    relative = "editor", width = w, height = h,
    row = math.floor((vim.o.lines - h) / 2), col = math.floor((vim.o.columns - w) / 2),
    style = "minimal", border = "rounded", title = " " .. title .. " ", title_pos = "center",
  })
  vim.wo[win].winhighlight = "Normal:Normal,FloatBorder:AgentMuted"
  vim.wo[win].conceallevel = 2
  vim.wo[win].wrap = true
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = b, nowait = true })
  vim.keymap.set("n", "<Esc>", "<cmd>close<CR>", { buffer = b, nowait = true })
  -- floats are read-only navigation surfaces — hide the cursor here too
  local grp = api.nvim_create_augroup("AgentFloatCursor" .. b, { clear = true })
  api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = grp, buffer = b,
    callback = function()
      if not S.saved_gcr then S.saved_gcr = vim.o.guicursor end
      vim.o.guicursor = "a:AgentCursorFloat"
    end,
  })
  api.nvim_create_autocmd({ "BufLeave", "WinLeave", "BufWipeout" }, {
    group = grp, buffer = b,
    callback = function() if S.saved_gcr then vim.o.guicursor = S.saved_gcr end end,
  })
  if not S.saved_gcr then S.saved_gcr = vim.o.guicursor end
  vim.o.guicursor = "a:AgentCursorFloat"
  return win
end

function M.help()
  float({
    " roster   attention queue only · z show all (incl idle)",
    "          j/k move · <CR> open · n new · . cwd · x stop · a abort · p peek",
    " chat     <Tab> changes view · ]m/[m message · za fold · Y yank code",
    "          gf open ref · i compose · <Esc> roster · y/n approve",
    " changes  <CR> open file · <Tab> back to chat · r refresh (plan · git · mcp)",
    " composer <CR> send · <C-s> send(insert) · <C-f> attach file",
    "          <C-x> drop attachments · q roster · / commands",
    "",
    " anywhere <leader>a toggle · <leader>A quick-message active session",
    "          <leader>as (visual) send selection · :AgentSend / File / Diff / Diagnostics",
    "",
    " slash    /abort  /steer <m>  /clear  /diff  /plan  /retry  /help",
  }, "agent rail — keys")
end

-- peek the focused session's latest message without switching to it
function M.peek()
  local a = S.displayed[S.focus]
  if not a then return end
  local c = S.chat[a.id]
  local body = (c and c.msgs and #c.msgs > 0) and c.msgs[#c.msgs].text or "_no messages loaded — press <CR> to open_"
  local lines = { "**" .. a.name .. "** · " .. (a.status or "idle"), "" }
  for _, l in ipairs(vim.split(body, "\n", { plain = true })) do lines[#lines + 1] = l end
  float(lines, "peek")
end

--------------------------------------------------------------------------------
-- buffers + keymaps
--------------------------------------------------------------------------------
ensure_buf = function()
  if S.buf and api.nvim_buf_is_valid(S.buf) then return end

  -- roster buffer
  S.buf = api.nvim_create_buf(false, true)
  vim.bo[S.buf].buftype = "nofile"; vim.bo[S.buf].bufhidden = "hide"; vim.bo[S.buf].modifiable = false
  pcall(api.nvim_buf_set_name, S.buf, "agent-rail")

  -- chat buffer (markdown + treesitter for code fences)
  S.chatbuf = api.nvim_create_buf(false, true)
  vim.bo[S.chatbuf].buftype = "nofile"; vim.bo[S.chatbuf].bufhidden = "hide"; vim.bo[S.chatbuf].modifiable = false
  pcall(api.nvim_buf_set_name, S.chatbuf, "agent-chat")
  vim.bo[S.chatbuf].filetype = "markdown"
  pcall(vim.treesitter.start, S.chatbuf, "markdown")

  -- changes buffer (plan/git overview, shown in the middle pane on <Tab>)
  S.changesbuf = api.nvim_create_buf(false, true)
  vim.bo[S.changesbuf].buftype = "nofile"; vim.bo[S.changesbuf].bufhidden = "hide"; vim.bo[S.changesbuf].modifiable = false
  pcall(api.nvim_buf_set_name, S.changesbuf, "agent-changes")
  local function xmap(lhs, fn_) vim.keymap.set("n", lhs, fn_, { buffer = S.changesbuf, nowait = true, silent = true }) end
  xmap("<Tab>", function() toggle_view() end)
  xmap("<CR>", function() changes_open() end)
  xmap("r", function() render_changes() end)
  xmap("i", function() focus_composer() end)
  xmap("q", function() M.close() end)
  xmap("<Esc>", function() if S.win and api.nvim_win_is_valid(S.win) then api.nvim_set_current_win(S.win) end end)

  -- composer buffer (real editable)
  S.composerbuf = api.nvim_create_buf(false, true)
  vim.bo[S.composerbuf].buftype = "nofile"; vim.bo[S.composerbuf].bufhidden = "hide"; vim.bo[S.composerbuf].swapfile = false
  pcall(api.nvim_buf_set_name, S.composerbuf, "agent-composer")
  -- right margin for the input: typed text auto-wraps 2 cols short of the edge
  -- (inserts a real break at word boundaries — accepted tradeoff)
  vim.bo[S.composerbuf].textwidth = 0
  vim.bo[S.composerbuf].wrapmargin = 2

  -- chat keymaps
  local function cmap(lhs, fn_) vim.keymap.set("n", lhs, fn_, { buffer = S.chatbuf, nowait = true, silent = true }) end
  cmap("q", function() M.close() end)
  cmap("i", function() focus_composer() end)
  cmap("]m", function() chat_block_jump(1) end)
  cmap("[m", function() chat_block_jump(-1) end)
  cmap("<Tab>", function() toggle_view() end)   -- flip to the Changes view
  cmap("za", function() chat_fold_toggle() end) -- fold the message under cursor
  cmap("Y", function() chat_yank_code() end)
  cmap("gf", function() chat_open_ref() end)
  cmap("<Esc>", function() if S.win and api.nvim_win_is_valid(S.win) then api.nvim_set_current_win(S.win) end end)
  -- y/n/digit answer keys are bound only while an approval card is up (see
  -- sync_approval_keys) so they don't swallow count prefixes (22k) or yank (y)

  -- relative line numbers in the chat only while the cursor is there (for count
  -- motions like 12j); otherwise the 2-col alignment gutter
  local chatnum = api.nvim_create_augroup("AgentChatNum", { clear = true })
  api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
    group = chatnum, buffer = S.chatbuf,
    callback = function()
      if S.chatwin and api.nvim_win_is_valid(S.chatwin) then
        vim.wo[S.chatwin].statuscolumn = ""
        vim.wo[S.chatwin].number = true
        vim.wo[S.chatwin].relativenumber = true
        vim.wo[S.chatwin].numberwidth = 3
      end
    end,
  })
  api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    group = chatnum, buffer = S.chatbuf,
    callback = function()
      if S.chatwin and api.nvim_win_is_valid(S.chatwin) then
        vim.wo[S.chatwin].number = false
        vim.wo[S.chatwin].relativenumber = false
        vim.wo[S.chatwin].statuscolumn = "  "
      end
    end,
  })

  -- composer keymaps
  vim.keymap.set("n", "<CR>", composer_send, { buffer = S.composerbuf, nowait = true, silent = true })
  vim.keymap.set("i", "<C-s>", function() vim.cmd("stopinsert"); composer_send() end, { buffer = S.composerbuf, nowait = true, silent = true })
  vim.keymap.set("n", "<C-x>", function() clear_attachments() end, { buffer = S.composerbuf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-f>", function() vim.cmd("stopinsert"); M.attach_file() end, { buffer = S.composerbuf, nowait = true, silent = true })
  vim.keymap.set("n", "q", function()
    save_draft()
    if S.win and api.nvim_win_is_valid(S.win) then api.nvim_set_current_win(S.win) end
  end, { buffer = S.composerbuf, nowait = true })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = S.composerbuf,
    -- render_chips (not just composer_resize) so the top pad extmark is re-anchored
    -- at row 0 every edit — otherwise it drifts down with inserted lines and draws
    -- a phantom blank line mid-buffer.
    callback = function() render_chips(); composer_placeholder() end,
  })

  -- roster keymaps
  local function map(lhs, fn_) vim.keymap.set("n", lhs, fn_, { buffer = S.buf, nowait = true, silent = true }) end
  local function move(delta) S.focus = S.focus + delta; render_roster() end
  map("j", function() move(1) end)
  map("k", function() move(-1) end)
  map("<Down>", function() move(1) end)
  map("<Up>", function() move(-1) end)
  map("g", function() S.focus = 1; render_roster() end)
  map("G", function() S.focus = #S.displayed; render_roster() end)
  map("<CR>", function() local a = S.displayed[S.focus]; if a then view_session(a.id, a.cwd) end end)
  map("i", function() focus_composer() end)
  map("n", function() open_picker() end)
  map(".", function() local d = fn.getcwd(); start_session(fn.fnamemodify(d, ":t"), d) end)
  map("x", function()
    local a = S.displayed[S.focus]
    if a then send({ type = "stop", session = a.id }); if S.selected == a.id then S.selected = nil end end
  end)
  map("a", function() local a = S.displayed[S.focus]; if a then send({ type = "abort", session = a.id }); S.stream[a.id] = nil; render_chat(false) end end)
  map("z", function() S.show_all = not S.show_all; S.focus = 1; render_roster() end)
  map("p", function() M.peek() end)
  map("r", function() if S.selected then send({ type = "get_messages", session = S.selected }) end end)
  map("?", function() M.help() end)
  map("q", function() M.close() end)

  -- hide the cursor while in the roster (focus ring stands in for it)
  local grp = api.nvim_create_augroup("AgentRailCursor", { clear = true })
  api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = grp, buffer = S.buf,
    callback = function()
      if not S.saved_gcr then S.saved_gcr = vim.o.guicursor end
      vim.o.guicursor = "a:AgentCursorRoster"
    end,
  })
  api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = grp, buffer = S.buf,
    callback = function() if S.saved_gcr then vim.o.guicursor = S.saved_gcr end end,
  })

  -- rail-local resize: h widens, l narrows (the rail is on the right, so its
  -- edge is on the left — intuitive direction, unlike the global <leader>h/l)
  for _, b in ipairs({ S.buf, S.chatbuf, S.changesbuf, S.composerbuf }) do
    vim.keymap.set("n", "<leader>h", function() rail_resize(8) end, { buffer = b, nowait = true, silent = true, desc = "Widen rail" })
    vim.keymap.set("n", "<leader>l", function() rail_resize(-8) end, { buffer = b, nowait = true, silent = true, desc = "Narrow rail" })
  end
end

--------------------------------------------------------------------------------
-- responsive dividers
--------------------------------------------------------------------------------
-- Dividers between the stacked rail panes are neovim's own window separators
-- (WinSeparator, styled via winhighlight below) — no custom winbar rule, which
-- would double up with the separator.
local function refresh_rules() end

--------------------------------------------------------------------------------
-- open / close
--------------------------------------------------------------------------------
function M.open()
  ensure_buf()
  if S.win and api.nvim_win_is_valid(S.win) then api.nvim_set_current_win(S.win); return end

  vim.cmd("botright vsplit") -- rail on the right (more reading whitespace there)
  S.win = api.nvim_get_current_win()
  api.nvim_win_set_buf(S.win, S.buf)
  api.nvim_win_set_width(S.win, WIDTH)
  vim.wo[S.win].winfixwidth = true
  vim.wo[S.win].number = false; vim.wo[S.win].relativenumber = false; vim.wo[S.win].signcolumn = "no"
  vim.wo[S.win].wrap = true
  vim.wo[S.win].cursorline = false
  vim.wo[S.win].winhighlight = "WinSeparator:AgentDivider"
  -- pane separation via a blank gap, not a ─ rule: horizontal box glyphs render
  -- heavier than the vertical │ in this terminal/font and can't be matched, so
  -- separate with whitespace and keep only the thin vertical side border.
  vim.wo[S.win].fillchars = "eob: " -- default ─ divider below the roster

  vim.cmd("belowright split")
  S.chatwin = api.nvim_get_current_win()
  api.nvim_win_set_buf(S.chatwin, S.chatbuf)
  vim.wo[S.chatwin].number = false; vim.wo[S.chatwin].relativenumber = false; vim.wo[S.chatwin].signcolumn = "no"
  vim.wo[S.chatwin].wrap = true; vim.wo[S.chatwin].cursorline = false
  vim.wo[S.chatwin].conceallevel = 2; vim.wo[S.chatwin].concealcursor = "nvic"
  vim.wo[S.chatwin].linebreak = true
  -- wrapped rows keep the line's indent, and list items hang-indent so continuation
  -- text aligns under the item body, not back at the left margin
  vim.wo[S.chatwin].breakindent = true
  vim.wo[S.chatwin].breakindentopt = "list:-1"
  vim.bo[S.chatbuf].formatlistpat = [[^\s*\%(\d\+[.)]\|[-*+•]\)\s\+]]
  vim.wo[S.chatwin].statuscolumn = "  " -- 2-col left gutter, aligns body with roster + composer
  vim.wo[S.chatwin].winhighlight = "WinSeparator:AgentDivider"
  vim.wo[S.chatwin].fillchars = "eob: "

  vim.cmd("belowright split")
  S.composerwin = api.nvim_get_current_win()
  api.nvim_win_set_buf(S.composerwin, S.composerbuf)
  api.nvim_win_set_height(S.composerwin, 1)
  vim.wo[S.composerwin].winfixheight = true
  vim.wo[S.composerwin].number = false; vim.wo[S.composerwin].relativenumber = false; vim.wo[S.composerwin].signcolumn = "no"
  vim.wo[S.composerwin].foldcolumn = "0"; vim.wo[S.composerwin].wrap = true
  -- prompt marker only on the very first physical row (virtnum==0 keeps it off
  -- wrapped continuation rows of a long first line)
  vim.wo[S.composerwin].statuscolumn = "%#AgentAccent#%{v:lnum==1&&v:virtnum==0?'› ':'  '}"
  vim.wo[S.composerwin].fillchars = "eob: " -- blank bottom pad row (no hairline)
  vim.wo[S.composerwin].winhighlight = "Normal:Normal,WinSeparator:AgentDivider"
  render_chips(); composer_placeholder(); render_chips()

  vim.wo[S.win].winfixheight = true
  api.nvim_set_current_win(S.win)

  -- The editor↔rail vertical separator is drawn by the editor window to the
  -- rail's left; recolour just that window's WinSeparator (restored on close)
  -- so it matches the rail's internal dividers, without touching global state.
  -- All-box frame: the editor↔rail │ connects cleanly at junctions with the
  -- horizontal ─ dividers (box glyphs align by design). Just colour it.
  local edwin = fn.win_getid(fn.winnr("h"))
  if edwin ~= 0 and edwin ~= S.win and api.nvim_win_is_valid(edwin) then
    S.editorwin = edwin
    S.editor_wh = vim.wo[edwin].winhighlight
    vim.wo[edwin].winhighlight = (S.editor_wh ~= "" and (S.editor_wh .. ",") or "") .. "WinSeparator:AgentDivider"
  end

  if not S.saved_gcr then S.saved_gcr = vim.o.guicursor end
  vim.o.guicursor = "a:AgentCursorRoster"
  start_spin()

  -- responsive: redraw the divider when the rail is resized
  local grp = api.nvim_create_augroup("AgentRailResize", { clear = true })
  api.nvim_create_autocmd({ "WinResized", "VimResized" }, { group = grp, callback = refresh_rules })

  connect(function() send({ type = "list_sources" }); render() end)
  vim.defer_fn(function() if S.win and api.nvim_win_is_valid(S.win) then refresh_plans(); render_roster() end end, 300)
  render()
end

function M.close()
  save_draft()
  stop_spin()
  if S.editorwin and api.nvim_win_is_valid(S.editorwin) then
    vim.wo[S.editorwin].winhighlight = S.editor_wh or ""
  end
  S.editorwin = nil
  if S.saved_gcr then vim.o.guicursor = S.saved_gcr end
  for _, w in ipairs({ "composerwin", "chatwin", "win" }) do
    if S[w] and api.nvim_win_is_valid(S[w]) then api.nvim_win_close(S[w], true) end
    S[w] = nil
  end
end

function M.toggle()
  if S.win and api.nvim_win_is_valid(S.win) then M.close() else M.open() end
end

function M.statusline()
  if not S.selected then return "" end
  local a
  for _, x in ipairs(S.roster) do if x.id == S.selected then a = x break end end
  if not a then return "▸ " .. S.selected end
  local s = "▸ " .. a.name .. " · " .. ((a.model and a.model ~= "") and a.model or "?")
  if a.status == "streaming" then s = s .. " " .. GLYPH.streaming end
  if S.pending[a.id] then s = s .. " " .. GLYPH.needs_input end
  if a.costUsd and a.costUsd > 0 then s = s .. string.format(" · $%.2f", a.costUsd) end
  return s
end

--------------------------------------------------------------------------------
-- setup
--------------------------------------------------------------------------------
function M.setup(opts)
  opts = opts or {}
  if opts.scope then scope = opts.scope end
  if opts.scopes then ROOTS = opts.scopes end
  S.ns = api.nvim_create_namespace("agent_nvim")
  S.composer_ns = api.nvim_create_namespace("agent_nvim_composer")
  S.chip_ns = api.nvim_create_namespace("agent_nvim_chips")
  set_hl()
  vim.defer_fn(set_hl, 200) -- win over markview's own group setup on load
  api.nvim_create_autocmd("ColorScheme", {
    callback = function() set_hl(); vim.defer_fn(set_hl, 120) end,
  })

  api.nvim_create_user_command("AgentRail", function() M.toggle() end, {})
  api.nvim_create_user_command("AgentReroot", function(o) reroot(o.args) end, { nargs = 1 })
  api.nvim_create_user_command("AgentSend", function() M.send_range() end, { range = true })
  api.nvim_create_user_command("AgentSendFile", function() M.send_file() end, {})
  api.nvim_create_user_command("AgentSendDiff", function() M.send_diff() end, {})
  api.nvim_create_user_command("AgentSendDiagnostics", function() M.send_diagnostics() end, {})
  api.nvim_create_user_command("AgentMsg", function() M.send_message() end, {})

  vim.keymap.set("n", "<leader>a", function() M.toggle() end, { desc = "Toggle agent rail" })
  vim.keymap.set("n", "<leader>A", function() M.send_message() end, { desc = "Quick-message the active agent" })
  vim.keymap.set("x", "<leader>as", ":<C-u>lua require('agent-nvim').send_range()<CR>", { silent = true, desc = "Send selection to agent" })

  -- Autostart the rail when a scope is explicitly set: the cockpit/agent nvim sets
  -- AGENT_SCOPE per workspace (lovable / personal), so the rail becomes that scope's
  -- mission control on launch. A bare personal-machine nvim with no AGENT_SCOPE stays
  -- dormant (open on demand with <leader>a). Pass opts.autostart to force either way.
  -- Autostart when the scope resolved to a "work" world: an explicit AGENT_SCOPE
  -- (cockpit / opt-in personal) or the lovable workspace. A bare personal nvim
  -- elsewhere stays dormant (open on demand with <leader>a).
  local autostart = opts.autostart
  if autostart == nil then autostart = (vim.env.AGENT_SCOPE ~= nil) or (scope == "lovable") end
  if autostart then
    if vim.v.vim_did_enter == 1 then
      vim.schedule(function() M.open() end)
    else
      api.nvim_create_autocmd("VimEnter", { once = true, callback = function() M.open() end })
    end
  end
end

return M
