-- agent-nvim — the rail: a left sidebar cockpit for orchestrating `agentd`
-- agents. Three stacked windows in one column:
--   • roster  (top, sticky)   — sessions with live state, focus-ring selection
--   • chat    (middle, scrolls)— the active session's transcript, markdown+TS
--   • composer(bottom, grows)  — a real editable buffer with attachment chips
--
-- Scope = one agentd instance = one socket. Set AGENT_SCOPE per niri workspace to
-- get independent rails (e.g. lovable vs personal).
--
-- Rail keys — roster:  j/k move · <CR> open · ]a/[a next needing you · n new
--                      . cwd · x stop · a abort · <C-r> restart pi · z all · / filter · s search · r refresh · ? help · q close
--          — chat:     ]m/[m next/prev message · <Tab> changes view · Y yank code
--                      za fold msg · zM/zR fold/unfold all · yr reply · yc convo
--                      i compose · <Esc> back to roster · (y/n answer approvals)
--          — composer: <CR> send · <C-s> send-from-insert · <C-↑/↓> scroll chat · <C-x> drop attachments
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
-- QsLib "Diagswipe" braille loader (frames from vyfor/rattles) — same animation as
-- the dsqrd AI-summary button, at ~60ms/frame.
local SPIN = {
  "⠁⠀", "⠋⠀", "⠟⠁", "⡿⠋", "⣿⠟", "⣿⡿", "⣿⣿", "⣿⣿",
  "⣾⣿", "⣴⣿", "⣠⣾", "⢀⣴", "⠀⣠", "⠀⢀", "⠀⠀", "⠀⠀",
}
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

local ICON_FALLBACK = {
  plan = fn.nr2char(0xf0756),
  files = fn.nr2char(0xf09ee),
  changes = fn.nr2char(0xf062c),
  mcp = fn.nr2char(0xf0493),
  warn = fn.nr2char(0xf002a),
  session = fn.nr2char(0xf140b),
  cycle = fn.nr2char(0xf0b67),
  ticket = fn.nr2char(0xf04fc),
  swatch = fn.nr2char(0xf14fb),
  dev_up = fn.nr2char(0xf06a5),
  dev_down = fn.nr2char(0xf06a6),
  dev_broken = fn.nr2char(0xf0026),
  image = "🖼",
  check = "✓",
  xmark = "✗",
  file_change = "○",
}
local ICON_NAMES = {
  plan = "tasks-2",
  files = "file-content",
  changes = "nodes",
  mcp = "puzzle-piece", -- gear-2 is a two-tone glyph whose color-2 slash overlaps the gear and flattens to garbage; puzzle-piece is single-tone
  warn = "triangle-warning",
  session = "bolt-lightning",
  cycle = "refresh-2",
  ticket = "ticket-4",
  dev_up = "plug-2",
  dev_down = "plug-2-outline",
  dev_broken = "triangle-warning",
  swatch = "chip",
  image = "image",
  check = "check",
  xmark = "xmark",
  file_change = "pen-3",
}
local ICON = vim.deepcopy(ICON_FALLBACK)
local qsicons = {}

local function icon(name, fallback)
  local codepoint = qsicons[name]
  return codepoint and fn.nr2char(codepoint) or fallback or ""
end

local function load_qsicons()
  local map_path = vim.env.QSICONS_MAP
  if not map_path or map_path == "" then
    local match = fn.system({ "fc-match", "-f", "%{family}\n%{file}\n", "QsIcons" })
    local lines = vim.split(match, "\n", { plain = true, trimempty = true })
    if lines[1] == "QsIcons" and lines[2] then
      map_path = fn.fnamemodify(lines[2], ":h") .. "/qsicons-map.json"
    end
  end
  if not map_path or fn.filereadable(map_path) ~= 1 then return end
  local ok, decoded = pcall(vim.json.decode, table.concat(fn.readfile(map_path), "\n"))
  if not ok or type(decoded) ~= "table" then return end
  qsicons = decoded
  for key, name in pairs(ICON_NAMES) do
    ICON[key] = icon(name, ICON_FALLBACK[key])
  end
end

M.icon = icon

-- A volt-style progress bar: `width` vertical bars, the first `done/total` share in
-- `fillhl`, the rest in `emptyhl`. Returns (text, segs) where segs are byte columns
-- (each │ is 3 bytes) so callers drop it straight into a box row or a decor line.
local function progress_bar(done, total, width, fillhl, emptyhl)
  width = width or 16
  total = math.max(1, total or 1)
  local filled = math.max(0, math.min(width, math.floor((done / total) * width + 0.5)))
  local s = string.rep("│", width)
  return s, { { 0, filled * 3, fillhl or "AgentStream" }, { filled * 3, width * 3, emptyhl or "AgentMuted" } }
end

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
  gitdiff = {},                     -- cwd -> { files, bypath }
  diff_jobs = {},                   -- cwd -> active job id
  diff_timers = {},                 -- cwd -> debounce timer
  editor_win = nil,                 -- stable non-rail editor window
  composerbuf = nil, composerwin = nil,
  ns = nil, composer_ns = nil, chip_ns = nil,
  roster = {},        -- running sessions from the daemon
  sources = {},       -- candidate dirs for the picker
  selected = nil,
  focus = 1,
  chat = {},          -- id -> { msgs = { {role,text}, ... } }
  drafts = {},        -- id -> unsent composer text
  attach = {},        -- pending composer attachments { {path,l1,l2,lang,text} }
  paste_images = {},  -- pending pasted images { {type="image", data=<b64>, mimeType} }
  pending = {},       -- id -> extension_ui_request awaiting an answer
  stream = {},        -- id -> partial streaming assistant text (live)
  stream_since = {},  -- id -> os.time() when streaming began (elapsed counter)
  lastdur = {},       -- id -> seconds the last completed turn worked
  edited = {},        -- id -> set of paths the agent edited this turn (reload at turn end)
  idle_since = {},    -- id -> os.time() when the session last went idle
  folds = {},         -- id -> { [msgIndex]=true }
  plan = {},          -- id -> { done, total, phase } | false  (cached, refreshed slowly)
  devenv = {},        -- ctx -> "running"|"stopped"|"broken"  (devenv link health, cached)
  orphans = {},       -- ctx[] with a running slice but no live session (from cockpit-devenv orphans)
  nav_hist = {},      -- session-visit history (ids, oldest→newest); Ctrl-o/Ctrl-i walk it
  nav_idx = 0,        -- current position in nav_hist
  nav_lock = false,   -- true while nav_session drives view_session (so it doesn't re-record)
  show_all = false,   -- roster: false = attention queue only, true = every session
  roster_filter = "", -- roster: live name substring filter ("/" to set, esc clears)
  displayed = {},     -- the sessions actually shown in the roster (filtered), in order
  chat_line_msg = {}, -- chat bufline(0-idx) -> msgIndex
  scroll_to_msg = {}, -- id -> msgIndex: pending "jump to this message" (cross-session search)
  chat_blocks = {},   -- 1-indexed buflines that start a message block
  readbuf = "",
  spin = 0,
  timer = nil,
  saved_gcr = nil,
}

local render, render_roster, render_chat, render_changes, handle, on_read, try_connect, connect, send, git_changes, refresh_git_changes
local start_session, view_session, open_picker, ensure_buf, focus_composer, refresh_plans, refresh_plan_one, refresh_devenv, sync_approval_keys
local session_cwd, load_plan, answer, apply_prompt_mode
local on_cockpit_active -- reconciles the rail's selection with the cockpit active context
local on_agent_jump -- Super+i: select a session by name (works even without a cockpit tab)
local reflect_context, cockpit_context, cockpit_sync -- view_session side-effects (defined later)
local teardown_session -- full teardown: stop pi + close context + wt remove (defined later)
local follow_edit -- live-follow the agent's edits into the editor window (defined later)
local target_editor_win, capture_editor -- editor-director helpers (defined later)
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

-- The rail restyles markview's markdown groups (accent headings, cyan inline
-- code) so chat messages read well. Those groups are GLOBAL, so writing them
-- directly would leak into every markdown buffer (e.g. the plan on the left).
-- Scope them to a highlight namespace the chat window alone resolves against
-- (nvim_win_set_hl_ns); everything undefined here falls back to the global
-- theme, so the plan keeps markview.lua's styling.
local MDNS = api.nvim_create_namespace("agent-md")

--------------------------------------------------------------------------------
-- highlights
--------------------------------------------------------------------------------
-- lift an 0xRRGGBB integer toward white by `amt` per channel → a guaranteed
-- elevation over the Normal background, whatever the theme.

local function set_hl()
  local p = palette()
  local nb = api.nvim_get_hl(0, { name = "Normal" })
  -- "on-accent" text/glyph colour for filled pills, keycaps, cursors: the theme
  -- BACKGROUND, so it contrasts with an accent-coloured fill in BOTH modes. Lead
  -- with the palette's bg — Normal's bg isn't always captured in light mode, and
  -- the old dark hex fallback then put dark text on the (dark) light-mode green
  -- pill (dark-on-dark).
  local dark = p.bg or (nb and nb.bg) or 0x12161b
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
  -- idle STATUS SWATCH: the theme's amber-yellow so a resting session carries warmth
  -- (distinct from needs-input=accent and streaming=green).
  hl("AgentSwatchIdle", { fg = p.yellow or "#d9b06a" })
  hl("AgentAccent", { fg = accent, bold = true })
  -- Neutral heading colour for titles/section labels: orange is a SIGNAL (selection,
  -- active state, identity), not the colour of every header — a bold near-fg reads as
  -- a heading while keeping the accent rare and meaningful.
  hl("AgentTitle", { fg = p.fg or "#c7ccd1", bold = true })
  hl("AgentFocusName", { fg = p.fg or "#c7ccd1", bold = true }) -- focused-but-not-open row
  hl("AgentMuted", { fg = p.fg_muted or "#5c6773" })
  hl("AgentFile", { fg = p.fg or "#c7ccd1" }) -- neutral file-path text (status lives on the dot)
  hl("AgentHunkRange", { fg = p.blue or p.cyan or "#5aa9e6" }) -- hunk line-range in the chat
  -- approval-card key caps (a subtle elevated pill behind the key char)
  hl("AgentKeyOk", { fg = p.green or "#5fca8b", bg = cardbg, bold = true })
  hl("AgentKeyNo", { fg = p.red or "#e5675f", bg = cardbg, bold = true })
  hl("AgentKeyNum", { fg = accent, bg = cardbg, bold = true })
  hl("AgentAttn", { fg = attn, bold = true })
  hl("AgentDivider", { fg = p.bg_surface2 or p.bg_secondary or "#2a3038" }) -- subtle line

  -- focus-ring card (elevated fill + solid accent edge). The edge is a bg-filled
  -- cell, not a ▌ glyph, so it's continuous across rows (glyphs leave inter-row
  -- gaps in fonts that don't draw block chars full-height).
  hl("AgentCard", { bg = cardbg })
  -- active-session name chip: a distinct elevation from the box surface / AgentCard so
  -- the selected name reads as its own pill (bg_surface3 / selection tone).
  hl("AgentNameCard", { bg = p.bg_surface3 or p.bg_selection or p.bg_surface2 or cardbg })
  -- chat: your (user) message blocks get a subtle full-width background; the agent's
  -- turn-recap (✧ …) gets a lighter callout background. Both are HIGHLIGHTS (no border
  -- chars in the buffer) so yanking the chat still copies clean text.
  -- distinct HUES so the three chat fills don't blend: you = cool blue-grey (matches the
  -- blue role bar), summary = green-grey (recap/done), code stays neutral grey (AgentCode).
  hl("AgentUserBg", { bg = p.bg_info or p.bg_surface2 or cardbg })
  hl("AgentSummaryBg", { bg = p.bg_success or p.bg_surface3 or cardbg })
  -- full-line background for fenced code blocks in the chat: applied via
  -- line_hl_group so it spans the whole rail width (a uniform rectangle), unlike
  -- markview's char-level bg which stops at the text and reads ragged.
  hl("AgentCode", { bg = cardbg })
  hl("AgentBarSolid", { bg = accent }) -- the roster's focus edge — ONLY drawn while the roster pane is focused
  hl("AgentSel", { bg = p.bg_surface3 or p.bg_selection or surface, bold = true }) -- picker selection bar
  -- volt-style scope-box surfaces: two elevations off the theme's surface ladder so
  -- boxes read as distinct filled panels and can be layered (a box, an inner box).
  hl("AgentBox", { bg = surface })
  hl("AgentBoxAlt", { bg = p.bg_surface2 or cardbg or surface })

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
  -- keycap chip: dark legend on a bright neutral cap (like a physical key), so it reads
  -- clearly against the dark rail — brighter than the surface-tone AgentKeyMuted.
  hl("AgentKeyCap", { fg = dark, bg = p.fg_muted or "#707B84", bold = true })
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
  local function hlmd(n, o) api.nvim_set_hl(MDNS, n, o) end
  -- the chat window resolves highlights through MDNS, which supersedes its
  -- winhighlight — so the WinSeparator:AgentDivider remap must live here too,
  -- else the chat's borders fall back to the default separator.
  hlmd("WinSeparator", { fg = p.bg_surface2 or p.bg_secondary or "#2a3038" })
  -- fenced code blocks sit on the elevated card tone so they read as a distinct
  -- block (surface alone is ~indistinguishable from the chat bg). Inline code
  -- stays on the calmer surface so ref chips don't shout.
  local codebg = p.bg_surface2 or p.bg_selection or surface
  hlmd("MarkviewInlineCode", { fg = code, bg = surface })
  hlmd("MarkviewCode", { bg = codebg })
  hlmd("MarkviewCodeInfo", { fg = p.fg_muted or "#5c6773", bg = codebg })
  hlmd("MarkviewCodeFg", { bg = codebg })
  hlmd("@markup.raw.markdown_inline", { fg = code, bg = surface })
  hlmd("@markup.raw.block.markdown", { bg = codebg })
  for i = 1, 6 do
    hlmd("MarkviewHeading" .. i, { fg = accent, bold = true })
    hlmd("MarkviewHeading" .. i .. "Sign", { fg = accent })
  end
  hlmd("MarkviewListItemMinus", { fg = p.blue or "#5aa9e6" })
  hlmd("MarkviewListItemStar", { fg = p.blue or "#5aa9e6" })
  hlmd("MarkviewListItemPlus", { fg = p.blue or "#5aa9e6" })
end

--------------------------------------------------------------------------------
-- message helpers
--------------------------------------------------------------------------------
-- One-line summary of a tool call: name + the bit that matters (path / command /
-- mcp target), so the chat shows WHAT the agent is doing, not just final prose.
local function tool_hint(c)
  local a = c.arguments or c.input or c.args or {}
  local name = c.name or c.tool or "tool"
  local function clip(s) s = (s or ""):gsub("%s+", " "); if #s > 64 then s = s:sub(1, 61) .. "…" end; return s end
  if name == "read" or name == "write" or name == "edit" or name == "apply_patch" then
    local p = a.path or a.file_path or a.filePath or ""
    return "⚙ " .. name .. (p ~= "" and (" " .. vim.fn.fnamemodify(p, ":.")) or "")
  elseif name == "bash" or name == "shell" then
    return "⚙ bash " .. clip(a.command or a.cmd)
  elseif name == "grep" or name == "ripgrep" or name == "search_files" then
    return "⚙ grep " .. clip(a.pattern or a.query or a.regex)
  elseif name == "glob" or name == "find" then
    return "⚙ glob " .. clip(a.pattern or a.glob or a.query)
  elseif name == "list" or name == "ls" then
    local p = a.path or a.dir or a.directory or ""
    return "⚙ ls " .. (p ~= "" and vim.fn.fnamemodify(p, ":.") or "")
  elseif name == "webfetch" or name == "web_fetch" or name == "fetch" then
    return "⚙ fetch " .. clip(a.url or a.uri)
  elseif name == "websearch" or name == "web_search" then
    return "⚙ web " .. clip(a.query or a.q)
  elseif name == "mcp" then
    local bits = {}
    if a.server then bits[#bits + 1] = a.server end
    if a.tool then bits[#bits + 1] = a.tool elseif a.search then bits[#bits + 1] = "search:" .. a.search end
    return "⚙ mcp " .. table.concat(bits, " ")
  end
  return "⚙ " .. name
end

local THINK = "✻ " -- collapsed-thinking marker (a dim one-liner, not the answer)

local function tool_edit(c)
  local a = c.arguments or c.input or c.args or {}
  local path = a.path or a.file_path or a.filePath
  if not path then return nil, nil end
  return "⚙ edit " .. fn.fnamemodify(path, ":."), { { path = path } }
end

-- Flatten a message's content blocks into displayable text. Beyond the final
-- prose (text blocks), surface the agent's WORK: thinking (💭), tool calls
-- (⚙ read/edit/bash/…), and inline diffs for edits — otherwise a turn that's all
-- tool calls looks empty.
local function msg_text(msg, cwd)
  local t, hunks = {}, {}
  for _, c in ipairs((msg and msg.content) or {}) do
    if c.type == "text" and c.text then
      -- Strip <system-reminder>…</system-reminder> blocks: pi injects these into
      -- the turn as CONTEXT for the agent (worktree state, task nudges), not for
      -- the human to read — raw in the chat they're just noise. A turn that was
      -- ONLY a reminder collapses to empty and is dropped downstream (the
      -- empty-text filter), so reminder-only turns vanish entirely.
      local txt = c.text:gsub("%s*<system%-reminder>.-</system%-reminder>%s*", "\n")
      txt = txt:gsub("^%s+", ""):gsub("%s+$", "")
      if txt ~= "" then t[#t + 1] = txt end
    elseif c.type == "thinking" then
      local th = c.thinking or c.text or ""
      if type(th) == "string" and th:gsub("%s", "") ~= "" then
        -- Collapse thinking to a dim one-liner: it's reasoning noise, not the
        -- answer. Prefer the agent's own bold **title**, else the first line.
        local summary = th:match("%*%*(.-)%*%*") or th:match("^%s*([^\n]+)") or "thinking"
        summary = summary:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 76)
        t[#t + 1] = THINK .. summary
      end
    elseif c.type == "toolCall" or c.type == "tool_use" then
      local txt, hs = nil, nil
      if c.name == "edit" or c.name == "write" then txt, hs = tool_edit(c) end
      if txt then
        t[#t + 1] = txt
        for _, h in ipairs(hs) do hunks[#hunks + 1] = h end
      else
        t[#t + 1] = tool_hint(c)
      end
    end
  end
  return table.concat(t, "\n\n"), hunks
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

-- format an elapsed SECONDS count (not a timestamp) → "45s" / "2m 14s" / "1h 3m"
local function fmt_el(el)
  if not el or el < 1 then return nil end
  if el < 60 then return el .. "s" end
  if el < 3600 then return string.format("%dm %ds", math.floor(el / 60), el % 60) end
  return string.format("%dh %dm", math.floor(el / 3600), math.floor((el % 3600) / 60))
end

-- Resolve a session's visual state: glyph, name-highlight, pill text/groups.
-- A pending approval overrides the daemon status with a "needs input" state.
session_state = function(a)
  -- `swatch` = the status-square colour (distinct per state so the roster reads at a
  -- glance instead of a wall of grey); `name` stays the label/text colour.
  if S.pending[a.id] then
    return { key = "needs_input", glyph = GLYPH.needs_input, name = "AgentAttn", swatch = "AgentAccent",
      pill = "AgentPillAttn", cap = "AgentCapAttn", label = "needs input" }
  end
  local st = a.status or "idle"
  if st == "streaming" then
    local d = dur(S.stream_since[a.id])
    return { key = "streaming", glyph = SPIN[(S.spin % #SPIN) + 1], name = "AgentStream", swatch = "AgentStream",
      pill = "AgentPillStream", cap = "AgentCapStream", label = d and ("working " .. d) or "working" }
  elseif st == "error" then
    return { key = "error", glyph = GLYPH.error, name = "AgentErr", swatch = "AgentErr",
      pill = "AgentPillErr", cap = "AgentCapErr", label = "error" }
  elseif st == "reconnecting" then
    -- pi crashed; the supervisor is respawning it. Amber + spinner so it reads as a
    -- transient hiccup, not a dead session.
    return { key = "reconnecting", glyph = SPIN[(S.spin % #SPIN) + 1], name = "AgentAttn", swatch = "AgentAttn",
      pill = "AgentPillAttn", cap = "AgentCapAttn", label = "reconnecting…" }
  end
  local d = dur(S.idle_since[a.id])
  -- idle is the resting state: plain readable text, no pill (a filled pill's
  -- dark-on-blue is fragile against darker theme blues, and idle shouldn't shout).
  -- The swatch is a soft amber so idle sessions still carry colour.
  return { key = "idle", glyph = GLYPH.idle, name = "AgentIdle", swatch = "AgentSwatchIdle", plain = true,
    pill = "AgentIdle", cap = "AgentIdle", label = d and ("idle " .. d) or "idle" }
end

-- Session display name: prefer the ticket id (every-1234) embedded in the
-- cwd-derived session name, else the raw name — keeps header/roster readable.
local function short_name(n)
  if not n then return "?" end
  -- Primary worktree sessions are named after the worktree dir (lovable.daphen-<slug>):
  -- collapse those to the bare ticket id. Sub-agents spawned INTO a worktree get bare
  -- custom names (every-2457-explore-ui) — keep the tail so siblings are told apart
  -- (else the whole every-2457 family renders as one indistinguishable "every-2457").
  local core = n:gsub("^lovable%.daphen%-", "")
  local primary = core ~= n
  core = core:gsub("^lovable%.", "")
  local ticket = core:match("%a+%-%d+")
  if not ticket then return (core ~= "" and core) or n end
  if primary then return ticket end
  local tail = core:match((ticket:gsub("%-", "%%-")) .. "%-(.+)$")
  return tail and (ticket .. " · " .. tail) or ticket
end

-- A sub-agent is a bare ticket-prefixed name WITH a tail (every-2457-explore-ui),
-- spawned into a worktree by its parent agent — as opposed to the primary worktree
-- session (lovable.daphen-…) or the orchestrator (lovable). The roster marks these
-- with a ↳ so a fanned-out family doesn't read as duplicate top-level sessions.
local function is_subagent(n)
  if not n or n:match("^lovable%.") then return false end
  return n:match("^%a+%-%d+%-.+") ~= nil
end

-- One file-stat row (path + right-aligned, colour-coded +adds −dels) sized to the
-- rail width W. The path is head-truncated with … so a long monorepo path never
-- soft-wraps and splits the number column onto a second, breakindented row (the
-- old layout padded every path to the LONGEST path's column, which forced the
-- numbers off-width). acol/dcol are pre-padded sign columns so several rows' signs
-- line up; omit them for a plain (no-stats) row. Caller recolours via line:find.
local function file_row(W, indent, path, acol, dcol)
  local nums = acol and (acol .. "  " .. dcol) or nil
  local nw = nums and fn.strdisplaywidth(nums) or 0
  local budget = W - fn.strdisplaywidth(indent) - nw - (nums and 3 or 1)
  if budget > 4 and fn.strdisplaywidth(path) > budget then
    path = "…" .. path:sub(#path - budget + 2)
  end
  local left = indent .. path
  if not nums then return left end
  local gap = W - fn.strdisplaywidth(left) - nw - 1
  return left .. string.rep(" ", math.max(2, gap)) .. nums
end

-- Usable width of the rail's middle pane, minus the widest gutter it can show
-- (3-col relativenumber when focused) + a safety col, so rows fit whether or not
-- the cursor is in the pane.
local function rail_width()
  local w = (S.chatwin and api.nvim_win_is_valid(S.chatwin)) and api.nvim_win_get_width(S.chatwin) or 60
  return w - 2 -- window minus the 2-col left gutter → box spans border-to-border to the
  -- pane's right edge, exactly where the chat text (same 2-col gutter) wraps.
end

-- A volt-style scope box: SQUARE corners + a filled surface behind the whole box, so
-- scopes read as distinct panels (not just outlined). `push(l[,path])` appends a line,
-- returns its 0-based index; `decor` collects { line, fg?, bg?, cs, ce } (byte columns,
-- later fg wins; bg is a low-priority line fill). `body(add)` builds content via
-- add(text, segs, path, l1) where segs = {{cs,ce,grp},…} are byte columns RELATIVE to
-- `text`. The box insets content to W-4 cols, shifts segs past "│ ", tints the border
-- muted + title accent, and fills every row with `surface` (default AgentBox).
local BOX_L = "│  " -- left border + 2 spaces: 5 bytes (│ is 3, 2 spaces). Inner-left pad.
-- title_above=true renders the heading on its OWN line above a uniform-bordered box
-- (like volt's Activity panel) — no title inset in the top border, so the border is a
-- single flat colour instead of the two-tone (bright title + muted rule) that read as
-- "two different colours". Use it wherever the inset title fights the border.
local function box(push, decor, W, icon, title, body, surface, title_above, pad, nofill, noborder)
  W = math.max(16, W)
  if noborder then
    -- borderless titled section: a bold header (aligned with title_above boxes) + content
    -- indented to match a bordered box's inner column, no outline/fill. For sub-lists where
    -- a full frame is clutter — the title + trailing gap separate them enough.
    local head = (icon and (icon .. " ") or "") .. (title or "")
    local hln = push(head)
    decor[#decor + 1] = { line = hln, fg = "AgentTitle", cs = 0, ce = #head }
    body(function(text, segs, path, l1)
      text = text or ""
      -- indent 3 to match a bordered box's content column ("│  " = │ + 2 spaces)
      local bl = push("   " .. text, path, l1)
      for _, s in ipairs(segs or {}) do
        decor[#decor + 1] = { line = bl, fg = s[3], cs = s[1] + 3, ce = s[2] + 3 }
      end
      return bl
    end)
    push("")
    return
  end
  -- nofill → surface stays nil, so every {bg=surface} decor becomes {bg=nil} and the
  -- decor loop skips it: the box reads as outline-only (the border defines it, no fill).
  -- NOT `nofill and nil or (...)` — that Lua idiom returns the fallback even when
  -- nofill is set (nil is falsy), which silently kept the fill.
  if nofill then surface = nil else surface = surface or "AgentBox" end
  local bord = "AgentDivider" -- box outline == the chat pane's hairpin border colour
  local inner = W - 6 -- W minus "│  " (3) + "  │" (3): 2-space inner pad each side
  local head = (icon and (icon .. " ") or "") .. (title or "")
  if title_above then
    local hln = push(head)
    decor[#decor + 1] = { line = hln, fg = "AgentTitle", cs = 0, ce = #head }
    local top = "┌" .. string.rep("─", W - 2) .. "┐"
    local tl = push(top)
    decor[#decor + 1] = { line = tl, bg = surface }
    decor[#decor + 1] = { line = tl, fg = bord }
  else
    if fn.strdisplaywidth(head) > inner - 2 then
      head = fn.strcharpart(head, 0, math.max(1, inner - 3)) .. "…"
    end
    local hw = fn.strdisplaywidth(head)
    local top = "┌─ " .. head .. " " .. string.rep("─", math.max(1, W - 5 - hw)) .. "┐"
    local tl = push(top)
    decor[#decor + 1] = { line = tl, bg = surface }
    decor[#decor + 1] = { line = tl, fg = bord }
    decor[#decor + 1] = { line = tl, fg = "AgentTitle", cs = #"┌─ ", ce = #"┌─ " + #head }
  end
  local function add(text, segs, path, l1)
    text = text or ""
    -- Clamp to the inner width so a long row (path + right-aligned stats) can NEVER
    -- overflow the box: an over-long row used to push its right │ + surface fill past
    -- the others, which read as the background leaking outside the border. Truncating
    -- keeps every row exactly W → a perfect rectangle where border + fill align.
    while fn.strdisplaywidth(text) > inner and #text > 0 do
      text = fn.strcharpart(text, 0, fn.strchars(text) - 1)
    end
    local pad = math.max(0, inner - fn.strdisplaywidth(text))
    local l = BOX_L .. text .. string.rep(" ", pad) .. "  │"
    local bl = push(l, path, l1)
    decor[#decor + 1] = { line = bl, bg = surface }                        -- surface fill
    decor[#decor + 1] = { line = bl, fg = bord, cs = 0, ce = 3 }           -- left │
    decor[#decor + 1] = { line = bl, fg = bord, cs = #l - 3, ce = #l }     -- right │
    for _, s in ipairs(segs or {}) do
      decor[#decor + 1] = { line = bl, fg = s[3], cs = s[1] + #BOX_L, ce = s[2] + #BOX_L }
    end
    return bl
  end
  -- pad=true adds a blank inner row above & below the content so the box's vertical
  -- padding matches its 1-col side padding (content flush to the borders read wonky).
  if pad then add("") end
  body(add)
  if pad then add("") end
  local bl = push("└" .. string.rep("─", W - 2) .. "┘")
  decor[#decor + 1] = { line = bl, bg = surface }
  decor[#decor + 1] = { line = bl, fg = bord }
end

--------------------------------------------------------------------------------
-- prompt state machine — the SINGLE source of truth for the composer's mode while
-- the agent is asking something. Three states, derived once from S.pending:
--   idle   — no question: normal, editable composer, insert-ready.
--   type   — an input/editor prompt: editable composer, you type the answer.
--   choose — a confirm/select prompt: composer DISABLED + cursor hidden; you
--            answer with y/n or a number (bound on both panes).
-- prompt_mode() resolves the state; apply_prompt_mode() applies EVERY effect in
-- one place (keys, cursor, focus/insert, placeholder) — called on each transition.
--------------------------------------------------------------------------------
local function prompt_mode()
  local ap = S.selected and S.pending[S.selected]
  local m = ap and ap.method
  if not ap or m == "notify" then
    return { kind = "idle", editable = true, insert = true, hide_cursor = false,
      placeholder = S.selected and ("message " .. short_name(S.selected) .. "…  (/ for commands)") or "open a session first",
      placeholder_hl = "AgentMuted" }
  elseif m == "input" or m == "editor" then
    return { kind = "type", ap = ap, editable = true, insert = true, hide_cursor = false,
      placeholder = "type your reply · ⏎ to send · esc cancels", placeholder_hl = "AgentAttn" }
  else
    local ph = (m == "select") and ("↑ pick an option above · 1–" .. math.min(9, #(ap.options or {})))
      or "↑ answer above · y / n · esc cancels"
    return { kind = "choose", ap = ap, editable = false, insert = false, hide_cursor = true,
      placeholder = ph, placeholder_hl = "AgentAttn" }
  end
end

apply_prompt_mode = function()
  local pm = prompt_mode()
  if sync_approval_keys then sync_approval_keys() end -- (un)bind y/n/number for `choose`
  if S.composerwin and api.nvim_win_is_valid(S.composerwin) then
    pcall(api.nvim_set_current_win, S.composerwin)
    pcall(vim.cmd, pm.insert and "startinsert" or "stopinsert")
  end
  -- Set the cursor AFTER focusing: entering the composer fires WinLeave on the
  -- roster, whose callback restores guicursor — so our hide has to come last to win.
  if pm.hide_cursor then
    if not S.prompt_gcr then S.prompt_gcr = vim.o.guicursor end
    vim.o.guicursor = "a:AgentCursorFloat" -- bg-matching → invisible while answering
  elseif S.prompt_gcr then
    vim.o.guicursor = S.prompt_gcr; S.prompt_gcr = nil
  end
  if composer_placeholder then composer_placeholder() end
end

-- The active session isn't a roster row — it's the header of its own chat. Build
-- a rich winbar for it: name + live state (spinner when working) + plan.
local function active_winbar()
  if not S.selected then return "" end
  local a
  for _, x in ipairs(S.roster) do if x.id == S.selected then a = x break end end
  if not a then return "" end
  -- state (spinner while working) + plan progress. The session id is NOT repeated
  -- here — the lualine's project component shows it.
  local ss = session_state(a)
  -- rounded swatch (like the roster) coloured by status, then the label neutral-ish;
  -- streaming keeps its animated spinner. The swatch sits at col 2 — same column as the
  -- composer's › prompt below it, so they line up.
  local gl = (ss.key == "streaming") and ss.glyph or ICON.swatch
  -- swatch at col 2 (= the composer's › below), label at col 5 (= the composer input),
  -- so the winbar and the input line align column-for-column.
  local parts = { "%#" .. (ss.swatch or ss.name) .. "#  " .. gl .. "%#" .. ss.name .. "#  " .. ss.label }
  -- live "doing" line: the agent's current action (latest thinking summary or
  -- tool call in the in-flight stream) so a long tool-heavy turn isn't opaque —
  -- you always see WHAT it's on, not just "working". (Claude-Code style.)
  local stream = S.stream[S.selected]
  if stream and stream ~= "" then
    -- Only the current action matters, and it's always near the end — scan just
    -- the tail. Scanning the whole stream ran every 60ms spin frame, so a long
    -- tool-heavy turn made each frame O(stream length) and froze the spinner.
    if #stream > 4096 then stream = stream:sub(-4096) end
    local doing
    for line in stream:gmatch("[^\n]+") do
      if line:match("^✻ ") or line:match("^⚙ ") then doing = line end
    end
    if doing then
      doing = doing:gsub("^✻ ", ""):gsub("^⚙ ", ""):gsub("%s+", " ")
      if #doing > 56 then doing = doing:sub(1, 55) .. "…" end
      doing = doing:gsub("%%", "%%%%") -- escape for the winbar (tool args have %H%M etc.)
      parts[#parts + 1] = "%#AgentMuted#  · " .. doing
    end
  end
  -- queued messages (held until the turn ends): always-visible count in the
  -- header so it's obvious something is queued, not just a line buried in the chat.
  local q = S.queued and S.queued[S.selected]
  if q and q ~= "" then
    local n = select(2, q:gsub("\n\n", "")) + 1
    parts[#parts + 1] = "%#AgentAttn#  " .. GLYPH.queued .. " " .. n .. " queued"
  end
  -- plan progress (◆ N/N) now lives in the lualine (M.plan_chip); this header
  -- stays focused on the live working state + spinner.
  if #S.paste_images > 0 then
    parts[#parts + 1] = "%#AgentMuted#  " .. ICON.image .. " ×" .. #S.paste_images
  end
  return table.concat(parts)
end

local function refresh_active_header()
  -- Live state + spinner sit right above the input (composer winbar) — updated on
  -- every render/spin tick, so it's smooth (unlike the lualine's slow timer).
  if S.composerwin and api.nvim_win_is_valid(S.composerwin) then
    vim.wo[S.composerwin].winbar = active_winbar()
  end
  if S.view == "chat" and S.chatwin and api.nvim_win_is_valid(S.chatwin) then
    vim.wo[S.chatwin].winbar = ""
  end
end

--------------------------------------------------------------------------------
-- roster (sticky top) — focus-ring selection, no cursor, collapsible
--------------------------------------------------------------------------------
render_roster = function()
  if not (S.buf and api.nvim_buf_is_valid(S.buf) and S.ns) then return end

  -- Source of truth for "is the roster the focused pane": the ACTUAL current window,
  -- recomputed every render. The enter/leave autocmds used to set S.roster_active,
  -- but a programmatic focus could fire enter without a matching leave and leave it
  -- stuck true — so the unfocused-roster highlight crept back. Computing it here (and
  -- the spin timer re-renders periodically) makes it self-correct within a frame.
  S.roster_active = (S.win and api.nvim_win_is_valid(S.win)
    and api.nvim_get_current_win() == S.win) or false

  -- track streaming / idle start times so the pill can show elapsed
  for _, a in ipairs(S.roster) do
    if a.status == "streaming" then
      S.stream_since[a.id] = S.stream_since[a.id] or os.time()
      S.idle_since[a.id] = nil
    else
      if S.stream_since[a.id] then S.lastdur[a.id] = os.time() - S.stream_since[a.id] end
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
  -- an active name filter searches EVERY session (scope-independent) for a match.
  local filt = S.roster_filter ~= "" and S.roster_filter:lower() or nil
  local all = S.show_all or not S.selected or filt ~= nil
  local displayed, hidden = {}, 0
  for _, a in ipairs(S.roster) do
    local needs = S.pending[a.id] or a.status == "error" or a.status == "streaming"
    local hit = not filt or (a.name and a.name:lower():find(filt, 1, true))
    if not hit then
      -- filtered out by name; not counted as "idle hidden"
    elseif all or (needs and a.id ~= S.selected) then
      displayed[#displayed + 1] = a
    elseif a.id ~= S.selected then
      hidden = hidden + 1
    end
  end
  -- Nest sub-agents under their parent: a ticket that fanned out (every-2457 +
  -- every-2457-explore-ui + …) should read as ONE roster item with its workers
  -- indented beneath it, not N look-alike top-level rows. Family = worktree (cwd).
  do
    local inset = {}
    for _, a in ipairs(displayed) do inset[a.id] = true end
    -- a displayed sub-agent needs its primary present as the group header, even idle
    for _, a in ipairs(displayed) do
      if is_subagent(a.name) and a.cwd then
        for _, p in ipairs(S.roster) do
          if p.cwd == a.cwd and not is_subagent(p.name) and not inset[p.id] then
            displayed[#displayed + 1] = p; inset[p.id] = true; break
          end
        end
      end
    end
    local fam = {}
    for _, a in ipairs(displayed) do
      local k = a.cwd or a.id; fam[k] = fam[k] or {}; fam[k][#fam[k] + 1] = a
    end
    local order, seen = {}, {}
    for _, a in ipairs(displayed) do
      local k = a.cwd or a.id
      if not seen[k] then
        seen[k] = true
        local m = fam[k]
        if #m > 1 then
          table.sort(m, function(x, y) -- primary first, then subs by name
            local sx, sy = is_subagent(x.name), is_subagent(y.name)
            if sx ~= sy then return not sx end
            return (x.name or "") < (y.name or "")
          end)
          for _, s in ipairs(m) do order[#order + 1] = s end
        else
          order[#order + 1] = a
        end
      end
    end
    displayed = order
  end

  S.displayed = displayed
  if S.focus < 1 then S.focus = 1 end
  if #displayed > 0 and S.focus > #displayed then S.focus = #displayed end

  -- Which worktrees have their PRIMARY session on screen: a sub-agent only renders
  -- nested (↳ + bare tail) when its parent is actually above it. An orphaned sub
  -- (parent crashed/stopped) renders as a normal top-level row with its full name,
  -- instead of a ↳ pointing at nothing.
  local primary_present = {}
  for _, a in ipairs(displayed) do
    if not is_subagent(a.name) then primary_present[a.cwd or a.id] = true end
  end

  local lines, decor, mainline = {}, {}, {}
  local function push(l) lines[#lines + 1] = l; return #lines - 1 end

  -- The roster is one volt-style scope box: the header becomes the title, sessions
  -- are inset rows. Focus (the j/k cursor, only while the roster pane is focused) is
  -- shown as an accent LEFT BORDER on the row + a bold name — no full-row card, which
  -- would bleed the fill past the box edge. Status colour lives on the whole row.
  -- Width = window minus the 2-col left gutter, EXACTLY rail_width()'s formula, so the
  -- roster box, the chat/changes boxes, AND the chat text all share the same left border
  -- column (2) and right edge — everything in the rail lines up border-to-border.
  local W = (S.win and api.nvim_win_is_valid(S.win)) and (api.nvim_win_get_width(S.win) - 2) or rail_width()
  local offline = S.connected and "" or (GLYPH.offline .. " ")
  local title = offline .. (filt and ("/" .. S.roster_filter) or "ROSTER") .. " · " .. scope
  box(push, decor, W, ICON.session, title, function(add)
    if #displayed == 0 then
      -- compact, centred empty state: glyph inline with the headline + a muted hint —
      -- two tight lines, sized like a small roster (not a big hero block).
      local inner = math.max(12, W - 6)
      local function center(text, segs)
        local lead = string.rep(" ", math.max(0, math.floor((inner - fn.strdisplaywidth(text)) / 2)))
        local sh = {}
        for _, s in ipairs(segs or {}) do
          sh[#sh + 1] = { s[1] + #lead, (s[2] == -1) and -1 or (s[2] + #lead), s[3] }
        end
        return add(lead .. text, sh)
      end
      if filt then
        center("no match for /" .. S.roster_filter, { { 0, -1, "AgentMuted" } })
        center("esc clears the filter", { { 0, -1, "AgentMuted" } })
      elseif #S.roster == 0 then
        local g = fn.nr2char(0xf0766) -- md-plus-circle-outline
        local t = g .. "  no sessions yet"
        center(t, { { 0, #g, "AgentAccent" }, { #g, #t, "AgentTitle" } })
        center("n to start · . for the current dir", { { 0, -1, "AgentMuted" } })
      else
        -- nothing needs attention: the selected session name (ALL CAPS) as a centred
        -- title — with its plan progress (N/M + bar) inline when it has a plan —
        -- then a row with state swatches hard-LEFT and a Ctrl+t keycap hint
        -- hard-RIGHT (space-filled between, no centre dot).
        local title = ((S.selected and short_name(S.selected)) or scope):upper()
        local pl = S.selected and S.plan[S.selected]
        if pl and pl.total and pl.total > 0 then
          local frac = pl.done .. "/" .. pl.total
          local btext, bsegs = progress_bar(pl.done, pl.total, 12, "AgentStream", "AgentDivider")
          local line = title .. "   " .. frac .. "  " .. btext
          local segs = { { 0, #title, "AgentTitle" } }
          local fo = #title + 3; segs[#segs + 1] = { fo, fo + #frac, "AgentMuted" }
          local bo = fo + #frac + 2
          for _, s in ipairs(bsegs) do segs[#segs + 1] = { bo + s[1], bo + s[2], s[3] } end
          center(line, segs)
        else
          center(title, { { 0, -1, "AgentTitle" } })
        end
        add("")
        local left, segs = "", {}
        for i, a in ipairs(S.roster) do
          local ss = session_state(a)
          local gl = (ss.key == "streaming") and ss.glyph or ICON.swatch
          segs[#segs + 1] = { #left, #left + #gl, ss.swatch or ss.name }
          left = left .. gl
          if i < #S.roster then left = left .. "   " end -- gap between swatches
        end
        local right, rseg = "", {}
        local a1 = #right; right = right .. " Ctrl "; rseg[#rseg + 1] = { a1, #right, "AgentKeyCap" }
        local a2 = #right; right = right .. " + ";    rseg[#rseg + 1] = { a2, #right, "AgentMuted" }
        local a3 = #right; right = right .. " t ";    rseg[#rseg + 1] = { a3, #right, "AgentKeyCap" }
        local a4 = #right; right = right .. "  toggle roster"; rseg[#rseg + 1] = { a4, #right, "AgentMuted" }
        local inner = math.max(12, W - 6)
        local fill = string.rep(" ", math.max(1, inner - fn.strdisplaywidth(left) - fn.strdisplaywidth(right)))
        local off = #left + #fill
        for _, s in ipairs(rseg) do segs[#segs + 1] = { s[1] + off, s[2] + off, s[3] } end
        add(left .. fill .. right, segs)
      end
      return
    end
    for i, a in ipairs(displayed) do
      local sstate = session_state(a)
      local show_focus = (i == S.focus) and S.roster_active
      local isSel = (a.id == S.selected)
      -- name row. Only NEST (↳ + bare tail) when the parent is actually on screen; an
      -- orphaned sub (parent crashed/stopped) renders top-level with its FULL name.
      local sub = is_subagent(a.name) and primary_present[a.cwd or a.id]
      local nm = short_name(a.name)
      if sub then nm = nm:gsub("^.- · ", "") end
      local dr = S.drafts[a.id]
      if dr and dr:gsub("%s", "") ~= "" then nm = nm .. "  ✎" end
      -- status marker = a filled square swatch coloured by state (grey/amber/red),
      -- like a legend chip — except streaming keeps the animated spinner so working
      -- sessions still pulse. The NAME stays neutral: colour on the swatch, not the row.
      local gl = (sstate.key == "streaming") and sstate.glyph or ICON.swatch
      local lead = sub and "  ↳ " or ""
      local ntext = lead .. gl .. " " .. nm
      -- active/focused names are neutral BOLD, not orange — the card fill (active) and
      -- the border accent (cursor) carry the state, so the accent stays rare.
      local namecol = (isSel or show_focus) and "AgentFocusName" or "AgentFile"
      local g0 = #lead
      local nml = add(ntext, {
        { g0, g0 + #gl, sstate.swatch or sstate.name }, -- the swatch, status colour
        { g0 + #gl, #ntext, namecol }, -- the name, neutral
      })
      mainline[i] = nml
      -- substatus row: plain coloured label (no pill — a pill's transparent caps read
      -- muddy on the box surface). plan chip only where a plan exists (subs get none).
      local subind = sub and "  " or ""
      local stext = subind .. "  " .. sstate.label
      local segs = { { 0, #stext, sstate.name } }
      local pl = S.plan[a.id]
      if pl and pl.total and pl.total > 0 then
        local chip = "  ◆ " .. pl.done .. "/" .. pl.total
        segs[#segs + 1] = { #stext, #stext + #chip, (pl.phase == "reconciled") and "AgentStream" or "AgentMuted" }
        stext = stext .. chip
      end
      -- devenv link health: green=running, red=broken (slice down but owns the fixed
      -- ports → :3000 dead), muted=stopped. Tells you `d` will start vs just jump.
      local dctx = a.cwd and a.cwd ~= "" and cockpit_context(a.cwd)
      local dv = dctx and S.devenv[dctx]
      if dv then
        local gl = (dv == "running") and ICON.dev_up or (dv == "broken") and ICON.dev_broken or ICON.dev_down
        local hl = (dv == "running") and "AgentStream" or (dv == "broken") and "AgentErr" or "AgentMuted"
        local chip = "  " .. gl
        segs[#segs + 1] = { #stext, #stext + #chip, hl }
        stext = stext .. chip
      end
      local sml = add(stext, segs)
      -- focus: turn the box's left │ ACCENT (the char's fg, not a bg block — a bg
      -- fill read as a fat orange block interrupting the border) on both rows.
      -- current row gets a real selection bar (AgentSel surface) across the inner span
      -- of BOTH rows — bold accent text alone was too weak to spot. Span is content only
      -- (byte 3 → just before the right │) so the box border stays clean. Applies to the
      -- SELECTED session (chat open) AND the FOCUSED row (roster cursor) so navigating
      -- the list is unmistakable; focus additionally lights the left │ accent.
      -- ACTIVE/selected session → an elevated card fill (AgentCard) behind the NAME
      -- only — a chip, not a full-item block. Span " name " (the space before the name
      -- through the name + one trailing pad col), on the name row alone. Shown
      -- regardless of roster focus; the "it's open" cue.
      if isSel then
        local n1 = lines[nml + 1] or ""
        -- card wraps the whole "swatch name" unit: start one col BEFORE the swatch
        -- (leading pad) and end one col past the name (trailing pad).
        local cs = math.max(#BOX_L - 1, #BOX_L + g0 - 1)
        local ce = math.min(#n1 - 3, #BOX_L + #ntext + 1)
        decor[#decor + 1] = { line = nml, selbg = { cs, math.max(cs, ce) } }
      end
      -- CURSOR row (only while the roster is focused) → accent the left │ border. This
      -- is a FG override of the border's own colour, so it must outrank the border
      -- add_highlight (DECOR_PRIORITY_BASE) — hence the high explicit priority.
      if show_focus then
        decor[#decor + 1] = { line = nml, range = { 0, 3, "AgentAccent", 5000 } }
        decor[#decor + 1] = { line = sml, range = { 0, 3, "AgentAccent", 5000 } }
      end
    end
    if not S.show_all and hidden > 0 then
      local t = hidden .. " idle · z for all"
      add(t, { { 0, #t, "AgentMuted" } })
    end
    -- orphan devenvs: a slice is running for a worktree with no session in the roster
    -- (a leak — visible so it doesn't pile up unseen). `slice-down <dir>` clears one.
    if S.orphans and #S.orphans > 0 then
      local t = #S.orphans .. " orphan devenv" .. (#S.orphans > 1 and "s" or "") .. ": " .. table.concat(S.orphans, ", ")
      add(t, { { 0, -1, "AgentErr" } })
    end
  end, nil, true, false, true)

  vim.bo[S.buf].modifiable = true
  api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.bo[S.buf].modifiable = false
  api.nvim_buf_clear_namespace(S.buf, S.ns, 0, -1)
  for _, d in ipairs(decor) do
    -- box() emits {bg=surface} per row + {fg,cs,ce} per segment — the SAME convention
    -- render_changes/render_chat use. Honour cs/ce (span, not full-line) so the status
    -- swatch keeps its own colour instead of being overpainted by the full-line name,
    -- and paint the surface fill via an end_col range (never line_hl_group → no bleed
    -- past the right border).
    if d.bg then
      local endc = #(lines[d.line + 1] or "")
      pcall(api.nvim_buf_set_extmark, S.buf, S.ns, d.line, 0, { end_col = endc, hl_group = d.bg, priority = 40 })
    end
    if d.selbg then
      -- active session's name chip: above the box surface (40), below the fg text (so
      -- the name reads on top). A distinct elevation, not a saturated selection bar.
      pcall(api.nvim_buf_set_extmark, S.buf, S.ns, d.line, d.selbg[1],
        { end_col = d.selbg[2], hl_group = "AgentNameCard", priority = 55 })
    end
    if d.fg then pcall(api.nvim_buf_add_highlight, S.buf, S.ns, d.fg, d.line, d.cs or 0, d.ce or -1) end
    if d.card then
      pcall(api.nvim_buf_set_extmark, S.buf, S.ns, d.line, 0, { line_hl_group = "AgentCard", priority = 90 })
    end
    if d.range then
      pcall(api.nvim_buf_set_extmark, S.buf, S.ns, d.line, d.range[1],
        { end_col = d.range[2], hl_group = d.range[3], priority = d.range[4] or 160 })
    end
  end

  if S.win and api.nvim_win_is_valid(S.win) then
    pcall(api.nvim_win_set_height, S.win, math.max(1, #lines))
    if mainline[S.focus] then pcall(api.nvim_win_set_cursor, S.win, { mainline[S.focus] + 1, 0 }) end
  end
end

-- Toggle the roster between two MODES (not just show_all), top-level so both the
-- roster and the composer can bind it (z there, <C-t> from anywhere):
--   • auto (default): expand while focused, collapse to the attention queue on blur
--   • pinned-open: every session, always — survives losing focus
-- S.roster_pinned_open is the sticky flag the focus autocmds respect; show_all is
-- the rendered state (pinned → always true; auto → true only while focused).
local function toggle_roster_view()
  S.roster_pinned_open = not S.roster_pinned_open
  -- compute focus here too (render recomputes it, but we read it on the next line)
  local active = (S.win and api.nvim_win_is_valid(S.win) and api.nvim_get_current_win() == S.win) or false
  S.show_all = S.roster_pinned_open or active
  S.focus = 1
  render_roster()
end

--------------------------------------------------------------------------------
-- chat (scrollable middle) — message blocks, folds, streaming, approval card
--------------------------------------------------------------------------------
-- Build a row of key-cap buttons for the approval card. buttons =
-- { {key, label, keyhl, labelhl}, … }. Returns (line, segments) where each
-- segment is { cs, ce, fg } byte-range to highlight (key cap + label).
local function button_row(indent, buttons)
  local line, segs = indent, {}
  for i, b in ipairs(buttons) do
    if i > 1 then line = line .. "     " end
    local cs = #line
    line = line .. " " .. b.key .. " " -- caps: space-padded key char
    segs[#segs + 1] = { cs = cs, ce = #line, fg = b.keyhl }
    line = line .. "  "
    local ls = #line
    line = line .. b.label
    segs[#segs + 1] = { cs = ls, ce = #line, fg = b.labelhl }
  end
  return line, segs
end

render_chat = function(scroll)
  if not (S.chatbuf and api.nvim_buf_is_valid(S.chatbuf)) then return end
  local lines, decor = {}, {}
  S.hunknav = {} -- 1-indexed bufline -> {path, line} for navigable edit rows
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
    local empty
    if S.selected and S.reloading and S.reloading[S.selected] then
      empty = "  ↻ restarting — reloading MCP config…"
    elseif S.selected then
      empty = "  …no messages yet — compose below"
    else
      empty = "  ↑ press <CR> on a session above to open it"
    end
    decor[#decor + 1] = { line = push(empty), fg = "AgentMuted" }
  else
    if chat and chat.msgs then
      for mi, m in ipairs(chat.msgs) do
        if mi > 1 then push(""); push("") end
        local isUser = m.role == "user"
        local folded = folds[mi]
        local caret = folded and FOLDED or OPEN
        local label = isUser and "you" or "agent"
        -- your (user) messages render as a padded card: a 2-col left pad inside the bg
        -- (o), plus a blank bg row above and below. The bg is border-aligned (col 2).
        local o = isUser and "  " or ""
        local hdr = o .. caret .. " " .. BAR .. " " .. label
        if isUser then decor[#decor + 1] = { line = push("", mi), bg = "AgentUserBg" } end
        blocks[#blocks + 1] = #lines + 1 -- 1-indexed bufline of this header
        -- caret dim · a slim role-coloured bar (you=cool blue, agent=green; orange stays
        -- reserved for selection/attention) · label in neutral bold, not a saturated wash
        local bl0 = push(hdr, mi)
        if isUser then decor[#decor + 1] = { line = bl0, bg = "AgentUserBg" } end
        decor[#decor + 1] = { line = bl0, fg = "AgentMuted", cs = #o, ce = #o + #caret }
        decor[#decor + 1] = { line = bl0, fg = isUser and "AgentHunkRange" or "AgentStream", cs = #o + #caret + 1, ce = #o + #caret + 1 + #BAR }
        decor[#decor + 1] = { line = bl0, fg = "AgentTitle", cs = #o + #caret + 2 + #BAR, ce = #hdr }
        if folded then
          local n = select(2, (m.text or ""):gsub("\n", "\n")) + 1
          local fl = push(o .. "⋯ " .. n .. " lines", mi)
          decor[#decor + 1] = { line = fl, fg = "AgentMuted" }
          if isUser then decor[#decor + 1] = { line = fl, bg = "AgentUserBg" } end
        elseif isUser then
          -- plain padded prose HARD-wrapped into 2-space-padded real lines. Soft-wrap
          -- + breakindent left an unfilled bg notch on continuation rows (the same bug
          -- the summary callout had): the bg extmark doesn't paint a wrapped row's
          -- breakindent region. Each wrapped chunk as its own buffer line → the bg
          -- fills edge-to-edge and the left pad is uniform. Empty paras keep a bg row.
          local avail = math.max(20, rail_width() - 2)
          for _, para in ipairs(vim.split(m.text or "", "\n", { plain = true })) do
            local chunks = {}
            if para == "" then
              chunks = { "" }
            else
              local cur = ""
              for _, wd in ipairs(vim.split(para, " ", { plain = true })) do
                local cand = cur == "" and wd or (cur .. " " .. wd)
                if cur ~= "" and fn.strdisplaywidth(cand) > avail then chunks[#chunks + 1] = cur; cur = wd
                else cur = cand end
              end
              if cur ~= "" then chunks[#chunks + 1] = cur end
            end
            for _, ch in ipairs(chunks) do
              local bl = push(o .. ch, mi)
              decor[#decor + 1] = { line = bl, bg = "AgentUserBg" }
              decor[#decor + 1] = { line = bl, fg = "AgentFile", cs = #o, ce = -1 }
            end
          end
        else
          local hq, hi = m.hunks or {}, 0
          local in_fence = false
          for _, para in ipairs(vim.split(m.text or "", "\n", { plain = true })) do
            if para:match("^⟢") or para:match("^✧") then
              -- turn-recap callout: blank bg row above + below, and the text HARD-wrapped
              -- into 2-space-padded real lines. (Soft-wrap + breakindent left an unfilled
              -- notch in the bg on continuation rows.) ⟢ is U+27E2 (3 bytes), not ✧.
              decor[#decor + 1] = { line = push("", mi), bg = "AgentSummaryBg" }
              local avail = math.max(20, rail_width() - 2) -- chunk width inside the 2-col pad
              local cur, chunks = "", {}
              for _, wd in ipairs(vim.split(para, " ", { plain = true })) do
                local cand = cur == "" and wd or (cur .. " " .. wd)
                if cur ~= "" and fn.strdisplaywidth(cand) > avail then chunks[#chunks + 1] = cur; cur = wd
                else cur = cand end
              end
              if cur ~= "" then chunks[#chunks + 1] = cur end
              for i, ch in ipairs(chunks) do
                local bl = push("  " .. ch, mi)
                decor[#decor + 1] = { line = bl, bg = "AgentSummaryBg" }
                if i == 1 then
                  decor[#decor + 1] = { line = bl, fg = "AgentAccent", cs = 2, ce = 5 } -- ⟢
                  decor[#decor + 1] = { line = bl, fg = "AgentTitle", cs = 6, ce = -1 }
                else
                  decor[#decor + 1] = { line = bl, fg = "AgentTitle", cs = 2, ce = -1 }
                end
              end
              decor[#decor + 1] = { line = push("", mi), bg = "AgentSummaryBg" }
            else
              local nav
              if para:match("^⚙ edit ") or para:match("^⚙ write ") then
                hi = hi + 1
                nav = hq[hi]
                if nav then
                  local cwd = S.selected and session_cwd(S.selected)
                  local rel = nav.path
                  if cwd and rel:sub(1, #cwd + 1) == cwd .. "/" then rel = rel:sub(#cwd + 2) end
                  if cwd and not S.gitdiff[cwd] then git_changes(cwd) end
                  local change = cwd and S.gitdiff[cwd] and S.gitdiff[cwd].bypath[rel]
                  para = para .. string.format("  +%d -%d", change and change.add or 0, change and change.del or 0)
                end
              end
              local bl = push(para, mi)
              if nav then S.hunknav[bl + 1] = nav end
              if para:match("^%s*```") then
                in_fence = not in_fence
                decor[#decor + 1] = { line = bl, bg = "AgentCode" }
              elseif in_fence then
                decor[#decor + 1] = { line = bl, bg = "AgentCode" }
                decor[#decor + 1] = { line = bl, virt = "  " }
              elseif para:match("^⚙ ") then
                decor[#decor + 1] = { line = bl, fg = "AgentMuted" }
                decor[#decor + 1] = { line = bl, fg = "AgentMuted", cs = 0, ce = 3 }
                if nav then
                  local display = fn.fnamemodify(nav.path, ":.")
                  local fs = para:find(display, 1, true)
                  if fs then decor[#decor + 1] = { line = bl, fg = "AgentFocusName", cs = fs - 1, ce = fs - 1 + #display } end
                  local ps, pe = para:find("%+%d+")
                  if ps then decor[#decor + 1] = { line = bl, fg = "AgentStream", cs = ps - 1, ce = pe } end
                  local ms, me = para:find("%-%d+", (pe or 0) + 1)
                  if ms then decor[#decor + 1] = { line = bl, fg = "AgentErr", cs = ms - 1, ce = me } end
                end
              elseif para:sub(1, #THINK) == THINK then
                decor[#decor + 1] = { line = bl, fg = "AgentMuted" }
              end
            end
          end
        end
        if isUser then decor[#decor + 1] = { line = push("", mi), bg = "AgentUserBg" } end
      end
    end
    -- live streaming block (superseded by message_end when the turn completes)
    local sv = S.selected and S.stream[S.selected]
    if sv and sv ~= "" then
      if has_any then push(""); push("") end
      local shdr = OPEN .. " " .. BAR .. " agent"
      local sbl = push(shdr)
      decor[#decor + 1] = { line = sbl, fg = "AgentMuted", cs = 0, ce = #OPEN }
      decor[#decor + 1] = { line = sbl, fg = "AgentStream", cs = #OPEN + 1, ce = #OPEN + 1 + #BAR }
      decor[#decor + 1] = { line = sbl, fg = "AgentTitle", cs = #OPEN + 2 + #BAR, ce = #shdr }
      for _, para in ipairs(vim.split(sv, "\n", { plain = true })) do push(para) end
      lines[#lines] = lines[#lines] .. " " .. CARET
      decor[#decor + 1] = { line = #lines - 1, caret = true }
    end
  end

  -- inline approval card for the selected session
  local ap = S.selected and S.pending[S.selected]
  if ap then
    local function seg(line, segs) local bl = push(line); for _, s in ipairs(segs) do decor[#decor + 1] = { line = bl, fg = s.fg, cs = s.cs, ce = s.ce } end end
    push(""); push("")
    decor[#decor + 1] = { line = push("╭─ needs your input"), fg = "AgentApproval" }
    decor[#decor + 1] = { line = push("│"), fg = "AgentApproval" }
    if ap.title and ap.title ~= "" then
      decor[#decor + 1] = { line = push("│  " .. ap.title), fg = "AgentFocusName" }
    end
    if ap.message and ap.message ~= "" then
      for _, l in ipairs(vim.split(ap.message, "\n", { plain = true })) do
        decor[#decor + 1] = { line = push("│  " .. l), fg = "AgentMuted" }
      end
    end
    push("")
    if ap.method == "select" and ap.options then
      for oi, opt in ipairs(ap.options) do
        local line, segs = button_row("│  ", { { key = tostring(oi), label = tostring(opt), keyhl = "AgentKeyNum", labelhl = "AgentFocusName" } })
        seg(line, segs)
      end
      decor[#decor + 1] = { line = push("╰  press a number · esc cancels"), fg = "AgentMuted" }
    elseif ap.method == "input" or ap.method == "editor" then
      local line, segs = button_row("│  ", { { key = "i", label = "type a reply", keyhl = "AgentKeyNum", labelhl = "AgentFocusName" } })
      seg(line, segs)
      decor[#decor + 1] = { line = push("╰  esc cancels"), fg = "AgentMuted" }
    else
      local line, segs = button_row("│  ", {
        { key = "y", label = "yes", keyhl = "AgentKeyOk", labelhl = "AgentStream" },
        { key = "n", label = "no", keyhl = "AgentKeyNo", labelhl = "AgentErr" },
      })
      seg(line, segs)
      decor[#decor + 1] = { line = push("╰  esc cancels"), fg = "AgentMuted" }
    end
  end

  -- error block: a pi/daemon failure (e.g. model quota/auth) that would otherwise
  -- leave the turn silently empty. Cleared on the next send / successful stream.
  local errmsg = S.selected and S.errors and S.errors[S.selected]
  if errmsg then
    push(""); push("")
    decor[#decor + 1] = { line = push("╭─ " .. ICON.xmark .. " error"), fg = "AgentErr" }
    for _, l in ipairs(vim.split(errmsg, "\n", { plain = true })) do
      decor[#decor + 1] = { line = push("│ " .. l), fg = "AgentErr" }
    end
    decor[#decor + 1] = { line = push("╰ send again to retry"), fg = "AgentMuted" }
  end

  -- footer: agent is done and nothing awaits you → mark the end of the chat.
  -- "done" must key off the SESSION STATUS (streaming), not just the text-stream
  -- buffer — between tool calls the stream buffer is empty but the agent is still
  -- working, and showing "done" there is wrong.
  local sstatus
  for _, a in ipairs(S.roster) do if a.id == S.selected then sstatus = a.status break end end
  -- "working" spans the WHOLE turn (agent_start→agent_end), not per-round: agentd
  -- flips status idle↔streaming per tool round, so between rounds stream is empty
  -- and status briefly idle — without turn_active the "done" separator flashes
  -- mid-turn. turn_active is cleared on agent_end / error / abort.
  local working = S.selected and ((S.stream[S.selected] and S.stream[S.selected] ~= "")
    or sstatus == "streaming"
    or (S.turn_active and S.turn_active[S.selected]))
  if has_any and not working and not ap and not errmsg then
    local el = S.selected and fmt_el(S.lastdur[S.selected])
    local sum = S.summary and S.summary[S.selected]
    local pl = S.selected and S.plan[S.selected]
    -- prefer the agent's own one-line recap (⟢), else the plain done+elapsed.
    push(""); push("")
    if sum and sum.recap then
      -- Turn recap: render it with the SAME bg callout as the persisted message
      -- summary (hard-wrapped 2-space-padded lines), so the live done-divider and the
      -- message-history summary look identical instead of flat-here, bg'd-there.
      local text = "⟢ " .. sum.recap
      if pl and pl.total and pl.total > 0 then text = text .. " · ◆ " .. pl.done .. "/" .. pl.total .. " steps" end
      if el then text = text .. " · " .. el end
      decor[#decor + 1] = { line = push(""), bg = "AgentSummaryBg" }
      local avail = math.max(20, rail_width() - 2)
      local cur, chunks = "", {}
      for _, wd in ipairs(vim.split(text, " ", { plain = true })) do
        local cand = cur == "" and wd or (cur .. " " .. wd)
        if cur ~= "" and fn.strdisplaywidth(cand) > avail then chunks[#chunks + 1] = cur; cur = wd
        else cur = cand end
      end
      if cur ~= "" then chunks[#chunks + 1] = cur end
      for i, ch in ipairs(chunks) do
        local bl = push("  " .. ch)
        decor[#decor + 1] = { line = bl, bg = "AgentSummaryBg" }
        if i == 1 then
          decor[#decor + 1] = { line = bl, fg = "AgentAccent", cs = 2, ce = 5 } -- ⟢
          decor[#decor + 1] = { line = bl, fg = "AgentTitle", cs = 6, ce = -1 }
        else
          decor[#decor + 1] = { line = bl, fg = "AgentTitle", cs = 2, ce = -1 }
        end
      end
      decor[#decor + 1] = { line = push(""), bg = "AgentSummaryBg" }
    else
      -- no agent recap → a light done divider (the ✓ marker + blank line above read
      -- as the divider; no ───── rules, which used to spill past the rail width).
      decor[#decor + 1] = { line = push(ICON.check .. (el and (" done in " .. el) or " done")), fg = "AgentIdle" }
    end
    -- touched files this turn, path + colour-coded +adds −dels (no bar; same look
    -- as the changes view). Only when the agent actually edited something.
    if sum and sum.files and #sum.files > 0 then
      local W, aw, dw = rail_width(), 0, 0
      for _, f in ipairs(sum.files) do
        aw = math.max(aw, #("+" .. f.add)); dw = math.max(dw, #("-" .. f.del))
      end
      for _, f in ipairs(sum.files) do
        local as, ds = "+" .. f.add, "-" .. f.del
        local acol = string.rep(" ", aw - #as) .. as
        local dcol = string.rep(" ", dw - #ds) .. ds
        local line = file_row(W, "  ", f.path, acol, dcol)
        local bl = push(line)
        decor[#decor + 1] = { line = bl, fg = "AgentMuted" }
        local ps, pe = line:find("%+%d+")
        if ps then decor[#decor + 1] = { line = bl, fg = "AgentStream", cs = ps - 1, ce = pe } end
        local ms, me = line:find("%-%d+", (pe or 0) + 1)
        if ms then decor[#decor + 1] = { line = bl, fg = "AgentErr", cs = ms - 1, ce = me } end
      end
    end
  end

  -- A message sent while the agent was mid-turn is QUEUED: NOT delivered yet — the
  -- agent hasn't seen it — it sends by itself when the current turn ends. Render it
  -- as an unmistakable "waiting" block (attn header + a ┆ pending gutter on every
  -- line) so it never reads like an already-sent/read message. Once it's delivered
  -- (turn ends, or esc = send now) it moves up into the chat as a normal user turn,
  -- which the agent is then reading — that transition IS the read signal.
  local q = S.selected and S.queued and S.queued[S.selected]
  if q and q ~= "" then
    push("")
    decor[#decor + 1] = { line = push("  " .. GLYPH.queued .. " queued — not sent yet, the agent hasn't read this"), fg = "AgentAttn" }
    decor[#decor + 1] = { line = push("     sends when this turn ends   ·   esc = send now"), fg = "AgentMuted" }
    for _, para in ipairs(vim.split(q, "\n", { plain = true })) do
      local ln = push("  ┆ " .. para)
      decor[#decor + 1] = { line = ln, fg = "AgentMuted" }
      decor[#decor + 1] = { line = ln, range = { 2, 5, "AgentAttn" } } -- ┆ pending gutter (U+2506, 3 bytes)
    end
  end

  -- Sticky-bottom: BEFORE the rebuild, capture whether you were at the bottom + your
  -- exact view, and whether this render switches session. Used below so a streaming
  -- message doesn't yank you down when you've scrolled up to read history — while a
  -- switch/open still lands on the newest message.
  local switched = S.chat_last_rendered ~= S.selected
  S.chat_last_rendered = S.selected
  local force_bottom = S.force_bottom -- one-shot: a user send forces scroll-to-bottom
  S.force_bottom = nil
  local was_bottom, saved_view = true, nil
  if S.chatwin and api.nvim_win_is_valid(S.chatwin) and S.view == "chat" then
    pcall(api.nvim_win_call, S.chatwin, function()
      saved_view = fn.winsaveview()
      was_bottom = fn.line("w$") >= fn.line("$") -- last visible row is the last buffer line
    end)
  end

  vim.bo[S.chatbuf].modifiable = true
  api.nvim_buf_set_lines(S.chatbuf, 0, -1, false, lines)
  vim.bo[S.chatbuf].modifiable = false
  api.nvim_buf_clear_namespace(S.chatbuf, S.ns, 0, -1)
  for _, d in ipairs(decor) do
    if d.bg then
      -- priority 190 puts our full-line fill ABOVE markview's code-block bg. On
      -- nvim 0.12 line_hl_group fills every screen row of a wrapped line, but
      -- markview's block padding (higher default priority) was winning on the
      -- wrapped continuation rows and leaving them unfilled — the ragged tail on
      -- long code lines. Winning the priority makes the rectangle uniform. bg-only,
      -- so markview's syntax fg still layers on top.
      pcall(api.nvim_buf_set_extmark, S.chatbuf, S.ns, d.line, 0, { line_hl_group = d.bg, priority = 190 })
    end
    if d.fg then pcall(api.nvim_buf_add_highlight, S.chatbuf, S.ns, d.fg, d.line, d.cs or 0, d.ce or -1) end
    if d.virt then
      -- inline left padding that is NOT buffer content, so yanking copies clean text
      -- (e.g. a code block's commands). Coloured to blend into the block's bg.
      pcall(api.nvim_buf_set_extmark, S.chatbuf, S.ns, d.line, 0,
        { virt_text = { { d.virt, d.virthl or "AgentCode" } }, virt_text_pos = "inline", priority = 200 })
    end
    if d.caret then
      pcall(api.nvim_buf_set_extmark, S.chatbuf, S.ns, d.line, 0, { line_hl_group = "AgentStream", priority = 80 })
    end
  end

  S.chat_line_msg = line_msg
  S.chat_blocks = blocks

  -- cursor/scroll ops only when the chat buffer is the one actually shown in the
  -- window (changes view swaps in S.changesbuf) — else a background stream would
  -- yank the changes-view cursor, and the search-jump would consume its flag
  -- against the wrong buffer. The pending jump persists until chat is visible
  -- again (toggle_view → render_chat), then fires.
  if S.chatwin and api.nvim_win_is_valid(S.chatwin) and S.view == "chat" then
    refresh_active_header()
    -- a pending cross-session-search jump wins over the bottom-scroll; land the
    -- target message at the top. Only consume the flag once its message actually
    -- renders (view_session may render before the transcript finishes loading).
    local jump = S.selected and S.scroll_to_msg[S.selected]
    -- drop a stale target (transcript shrank past it, e.g. after a rewind) so it
    -- can't block auto-scroll-to-bottom forever. Search only sets it on a loaded
    -- session, so nmsgs>0 here on the first render — this only trips if it shrank.
    if jump and jump > ((chat and chat.msgs) and #chat.msgs or 0) then
      S.scroll_to_msg[S.selected] = nil; jump = nil
    end
    local best
    if jump then
      for bl, mi in pairs(line_msg) do if mi == jump and (not best or bl < best) then best = bl end end
    end
    if best then
      S.scroll_to_msg[S.selected] = nil
      pcall(api.nvim_win_set_cursor, S.chatwin, { best + 1, 0 })
      pcall(api.nvim_win_call, S.chatwin, function() vim.cmd("normal! zt") end)
    elseif scroll and not jump and (switched or was_bottom or force_bottom) then
      -- follow the stream / land at the newest message — if you were at the bottom, just
      -- switched into this session, OR you just SENT a message (force_bottom): sending
      -- always jumps to the bottom even if you'd scrolled up to copy something.
      pcall(api.nvim_win_set_cursor, S.chatwin, { #lines, 0 })
    elseif not switched and saved_view then
      -- same session and you'd scrolled up (or a passive render): keep your place so
      -- an incoming message doesn't drag the view to the bottom.
      pcall(api.nvim_win_call, S.chatwin, function() fn.winrestview(saved_view) end)
    end
  end
  if sync_approval_keys then sync_approval_keys() end
end

render = function() render_roster(); render_chat(true) end

-- Coalesce streaming re-renders: message_update / text_delta can fire many
-- times per second, and each render_chat rebuilds the whole chat buffer (+
-- markview re-parse). Unthrottled that saturates the main loop and starves the
-- 60ms animation timer — the spinner/elapsed freeze then jump. Cap to ~1
-- render / 70ms; the final state always lands via message_end's direct render.
local _stream_pending = false
local function render_stream()
  if _stream_pending then return end
  _stream_pending = true
  vim.defer_fn(function()
    _stream_pending = false
    if S.selected and S.chatwin and api.nvim_win_is_valid(S.chatwin) then render_chat(true) end
  end, 70)
end

--------------------------------------------------------------------------------
-- daemon event handling
--------------------------------------------------------------------------------
-- Desktop ping for a BACKGROUND session (not the one you're viewing), so you
-- learn a dispatched/spawned agent needs input or finished without watching the
-- rail. The active session is skipped — you're already looking at it.
-- Shared cross-instance focus marker. Every cockpit tab is its own nvim on the
-- same agentd, so focus must be a GLOBAL fact, not a per-instance flag — else a
-- background tab toasts while you sit in the focused one. On focus we write this
-- pid; on blur/exit we clear it iff it's still ours. rail_focused() reports whether
-- ANY live rail holds it (a dead pid — crashed nvim — is ignored, self-healing).
local RAIL_FOCUS_FILE = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/agent-rail-focused"
function rail_focus_mark(on)
  if on then
    pcall(fn.writefile, { tostring(fn.getpid()) }, RAIL_FOCUS_FILE)
  else
    local ok, l = pcall(fn.readfile, RAIL_FOCUS_FILE)
    if ok and l[1] and vim.trim(l[1]) == tostring(fn.getpid()) then
      pcall(fn.writefile, {}, RAIL_FOCUS_FILE)
    end
  end
end
local function rail_focused()
  local ok, l = pcall(fn.readfile, RAIL_FOCUS_FILE)
  local pid = ok and l[1] and tonumber(vim.trim(l[1]))
  return pid ~= nil and fn.isdirectory("/proc/" .. pid) == 1
end

local function desktop_notify(session, body, urgency)
  if not session or session == S.selected then return end
  -- ANY rail focused (this instance or another) → you're at the cockpit and the
  -- roster already shows the change, so a desktop toast is pure noise. The shared
  -- marker makes a background instance stay quiet while another holds focus — that
  -- cross-instance case was the spam. Toasts only fire once every rail is blurred
  -- (you've tabbed to the browser/slack), which is exactly when you'd want a ping.
  if rail_focused() then return end
  -- Cross-instance dedup for the tabbed-away case: with no rail focused, EVERY
  -- instance would fire for the same event. Claim a short per-session lease (mtime
  -- on a shared file); if another instance claimed it in the last 10s, stand down.
  local ndir = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/agent-rail-notify"
  pcall(fn.mkdir, ndir, "p")
  local lock = ndir .. "/" .. session:gsub("[^%w%-_]", "_")
  local uvv = vim.uv or vim.loop
  local st = uvv and uvv.fs_stat(lock)
  if st and (os.time() - st.mtime.sec) < 10 then return end
  pcall(fn.writefile, { tostring(os.time()) }, lock)
  local name = session
  for _, a in ipairs(S.roster) do
    if a.id == session then name = short_name(a.name or session); break end
  end
  pcall(fn.jobstart, { "notify-send", "-u", urgency or "normal", "-a", "agent-rail",
    "agent · " .. name, body or "" }, { detach = true })
end

-- Best-effort extraction of an incremental text chunk from a streaming event.
local function delta_text(m)
  if type(m.text) == "string" then return m.text end
  if type(m.delta) == "table" and type(m.delta.text) == "string" then return m.delta.text end
  if type(m.content) == "string" then return m.content end
  return nil
end

-- When a decision lands, scroll the open plan buffer to it so the user reads
-- the decision and answers in the chat. The request title is the plan heading
-- (the skill sets it to the decision's `### D#:` line); match it, else fall
-- back to the first unresolved decision marker. Never steals focus.
local function reveal_decision(title)
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    local name = api.nvim_buf_get_name(api.nvim_win_get_buf(w))
    if name:match("/plans/[^/]*%.md$") then
      local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(w), 0, -1, false)
      local needle = title and title:lower():gsub("^%s+", "")
      local hit
      for i, l in ipairs(lines) do
        local low = l:lower()
        if needle and needle ~= "" and low:find(needle, 1, true) then hit = i; break end
        if not hit and (low:find("your call:", 1, true) or l:match("^###%s+d%d")) then hit = hit or i end
      end
      if hit then
        api.nvim_win_call(w, function()
          api.nvim_win_set_cursor(w, { hit, 0 })
          vim.cmd("normal! zz")
        end)
      end
      return
    end
  end
end

-- Deterministic agent→buffer sync. The rail knows every file the agent edited
-- this turn (from the edit/write hunks); at turn end (writes settled) reload each
-- OPEN buffer from disk and refresh its hunk signs — so the change shows even if
-- the inotify file-watcher missed it. A buffer with unsaved edits is never
-- clobbered; we flag the conflict instead.
local function sync_edited(cwd, paths)
  for path in pairs(paths or {}) do
    local abs = fn.fnamemodify(fn.expand(path:match("^/") and path or ((cwd or fn.getcwd()) .. "/" .. path)), ":p")
    local bufnr
    for _, b in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(b) and fn.fnamemodify(api.nvim_buf_get_name(b), ":p") == abs then bufnr = b; break end
    end
    if bufnr then
      if vim.bo[bufnr].modified then
        vim.notify("agent edited " .. fn.fnamemodify(abs, ":.") .. " — you have unsaved changes; not reloaded", vim.log.levels.WARN)
      else
        pcall(vim.cmd, "checktime " .. bufnr)
        pcall(function() require("hunk-nvim.signs").refresh(bufnr) end)
      end
    end
  end
end

handle = function(obj)
  -- Any event carrying a session id (except a get_entries response, which is a
  -- reply to us, not pi working) means that pi is alive → disarm its wedge watchdog.
  if obj.session and obj.type ~= "response" and S.awaiting then S.awaiting[obj.session] = nil end
  local t = obj.type
  if t == "roster" then
    S.roster = obj.sessions or {}
    table.sort(S.roster, function(a, b) return (a.name or "") < (b.name or "") end)
    render_roster()
    -- reconcile with the cockpit active context: adopts the persisted active on
    -- startup and picks up a session that appears after a context switch, so the
    -- two can't drift apart (no-op once already in sync).
    if on_cockpit_active then on_cockpit_active() end
    -- auto-open the session for THIS nvim's worktree (opening nvim in a context
    -- should land you in its chat). One-shot: skip once anything's selected.
    if not S.autopened and not S.selected then
      local cwd = fn.getcwd()
      for _, a in ipairs(S.roster) do
        if a.cwd and (cwd == a.cwd or cwd:sub(1, #a.cwd + 1) == a.cwd .. "/") then
          S.autopened = true
          view_session(a.id, a.cwd)
          break
        end
      end
    end
  elseif t == "sources" then
    S.sources = obj.sources or {}
  elseif t == "response" and obj.command == "cycle_model" then
    local m = obj.data and obj.data.model
    local name = m and (m.id or m.modelId or m.name or m.model) or "?"
    local lvl = obj.data and obj.data.thinkingLevel
    vim.notify("agent: model → " .. tostring(name) .. (lvl and ("  ·  " .. tostring(lvl)) or ""))
  elseif t == "response" and obj.command == "cycle_thinking_level" then
    vim.notify("agent: reasoning → " .. tostring(obj.data and obj.data.level or "?"))
  elseif t == "response" and obj.command == "get_entries" and obj.data and obj.data.entries then
    -- We load history via get_entries (not get_messages): get_messages returns only
    -- the post-compaction window, so a compacted session's chat starts mid-turn and
    -- can't scroll back to the prompt. get_entries carries the whole append-only tree
    -- incl. pre-compaction history. Reconstruct the ACTIVE branch by walking parentId
    -- from leafId to the root — that keeps the full linear history and drops abandoned
    -- branches (rewinds / alternate takes).
    local cwd = session_cwd(obj.session)
    local byid = {}
    for _, e in ipairs(obj.data.entries) do if e.id then byid[e.id] = e end end
    local chain, seen, cur = {}, {}, obj.data.leafId
    while cur and byid[cur] and not seen[cur] do
      seen[cur] = true
      chain[#chain + 1] = byid[cur]
      cur = byid[cur].parentId
    end
    local msgs = {}
    for i = #chain, 1, -1 do -- chain is leaf→root; render root→leaf
      local m = chain[i].type == "message" and chain[i].message
      if m and (m.role == "user" or m.role == "assistant") then
        local text, hunks = msg_text(m, cwd)
        if text:gsub("%s", "") ~= "" then
          msgs[#msgs + 1] = { role = m.role, text = text, hunks = hunks }
        end
      end
    end
    -- Never blank a populated chat if reconstruction came back empty (broken leaf).
    if #msgs > 0 or not S.chat[obj.session] then S.chat[obj.session] = { msgs = msgs } end
    if S.reloading then S.reloading[obj.session] = nil end -- pi's back, restart done
    if obj.session == S.selected then render_chat(true) end
  elseif t == "rewound" and obj.session then
    -- true rewind landed: pi respawned on the truncated session. Reload the
    -- (now shorter) history and drop the removed message back into the composer
    -- to edit and resend. get_entries waits for the respawned pi's stdin.
    S.stream[obj.session] = nil
    send({ type = "get_entries", session = obj.session })
    if obj.session == S.selected and S.composerbuf and api.nvim_buf_is_valid(S.composerbuf) then
      local msg = obj.message or ""
      api.nvim_buf_set_lines(S.composerbuf, 0, -1, false, vim.split(msg, "\n", { plain = true }))
      render_chips(); composer_placeholder()
      if S.composerwin and api.nvim_win_is_valid(S.composerwin) then
        api.nvim_set_current_win(S.composerwin)
        pcall(api.nvim_win_set_cursor, S.composerwin, { api.nvim_buf_line_count(S.composerbuf), 0 })
        vim.cmd("startinsert!")
      end
    end
  elseif t == "message_start" and obj.session and obj.message and obj.message.role == "user" then
    -- echo the user prompt — covers prompts injected via wt-send / plan dispatch
    -- that the composer never optimistically echoed. Dedup vs a just-echoed one.
    local text = msg_text(obj.message, session_cwd(obj.session))
    if text:gsub("%s", "") ~= "" then
      local c = S.chat[obj.session] or { msgs = {} }
      local last = c.msgs[#c.msgs]
      -- the optimistic echo appends an image marker ("  🖼×N") the server echo
      -- doesn't carry — strip it before comparing, else image messages dedup-miss
      -- and render twice.
      local lasttext = last and last.role == "user" and (last.text or ""):gsub("%s*" .. ICON.image .. "×%d+%s*$", "") or nil
      if lasttext ~= text then
        c.msgs[#c.msgs + 1] = { role = "user", text = text }
        S.chat[obj.session] = c
        if obj.session == S.selected then render_chat(true) end
      end
    end
  elseif t == "message_update" and obj.session then
    -- pi streams the growing assistant message here (NOT text_delta): partial.content
    -- is the full content-so-far — text + thinking + tool calls — so rendering it live
    -- via msg_text is how the chat shows the agent working in real time.
    local ev = obj.assistantMessageEvent
    local partial = ev and ev.partial
    if partial and type(partial.content) == "table" then
      if S.errors then S.errors[obj.session] = nil end
      S.stream[obj.session] = msg_text({ content = partial.content }, session_cwd(obj.session))
      if obj.session == S.selected then render_stream() end
    end
  elseif t == "message_end" and obj.session then
    local m = obj.message or {}
    local text, hunks = msg_text(m, session_cwd(obj.session))
    S.stream[obj.session] = nil -- finalize any live stream
    if m.role ~= "assistant" or text:gsub("%s", "") == "" then
      if obj.session == S.selected then render_chat(false) end
      return
    end
    local c = S.chat[obj.session] or { msgs = {} }
    c.msgs[#c.msgs + 1] = { role = "assistant", text = text, hunks = hunks }
    S.chat[obj.session] = c
    if hunks and #hunks > 0 then
      S.edited[obj.session] = S.edited[obj.session] or {}
      for _, h in ipairs(hunks) do
        if h.path then S.edited[obj.session][h.path] = true end
      end
      if obj.session == S.selected then
        local last = hunks[#hunks]
        if last and last.path then follow_edit(session_cwd(obj.session), last.path, nil) end
      end
    end
    if obj.session == S.selected then render_chat(true) end
  elseif (t == "text_delta" or t == "content_block_delta" or t == "message_delta" or t == "text") and obj.session then
    local chunk = delta_text(obj)
    if chunk and chunk ~= "" then
      if S.errors then S.errors[obj.session] = nil end -- new output → clear stale error
      S.stream[obj.session] = (S.stream[obj.session] or "") .. chunk
      if obj.session == S.selected then render_stream() end
    end
  elseif t == "agent_start" and obj.session then
    -- whole turn begins (once, before all rounds) → mark active so the "done"
    -- footer stays hidden through the between-round idle gaps until agent_end.
    S.turn_active = S.turn_active or {}
    S.turn_active[obj.session] = true
    -- a new turn started → invalidate any pending debounced "finished" notify
    -- (the session isn't done, it's churning — e.g. a review moving to its next phase)
    if S.notify_gen then S.notify_gen[obj.session] = (S.notify_gen[obj.session] or 0) + 1 end
    if S.summary then S.summary[obj.session] = nil end -- last turn's recap is stale now
    if obj.session == S.selected then render_chat(false) end
  elseif t == "turn_end" and obj.session then
    -- pi fires turn_end PER TOOL ROUND (verified), not once per prompt — so just
    -- finalize this round's stream. The true whole-turn-done is agent_end below;
    -- notifying here would fire once per round (the mid-turn spam).
    S.stream[obj.session] = nil
    if obj.session == S.selected then render_chat(false) end
  elseif t == "agent_end" and obj.session then
    -- the ENTIRE turn is complete (fires once, after every round).
    S.stream[obj.session] = nil
    if S.turn_active then S.turn_active[obj.session] = nil end
    local flushed_queue = false
    if S.queued and S.queued[obj.session] then
      -- a message queued mid-turn becomes the next turn now (only at true end,
      -- so it isn't injected between the agent's own tool rounds)
      local q = S.queued[obj.session]; S.queued[obj.session] = nil
      local cq = S.chat[obj.session] or { msgs = {} }
      cq.msgs[#cq.msgs + 1] = { role = "user", text = q }
      S.chat[obj.session] = cq
      send({ type = "prompt", session = obj.session, message = q })
      flushed_queue = true
    elseif not S.pending[obj.session] and obj.session ~= S.selected then
      -- DEBOUNCED "finished" notify. agent_end fires per turn, and an autonomous
      -- skill (a PR review) runs MANY turns back-to-back — notifying on each is the
      -- spam. Instead wait for the session to go QUIET: schedule the notify, and if
      -- a new turn starts first (agent_start bumps notify_gen) it's cancelled. So it
      -- fires exactly once, when the session actually stops and is waiting for you.
      S.notify_gen = S.notify_gen or {}
      local gen = (S.notify_gen[obj.session] or 0) + 1
      S.notify_gen[obj.session] = gen
      local sess = obj.session
      vim.defer_fn(function()
        if (S.notify_gen or {})[sess] ~= gen then return end          -- superseded by a newer turn
        if S.turn_active and S.turn_active[sess] then return end       -- working again
        if sess == S.selected then return end                          -- you're looking at it
        if S.pending and S.pending[sess] then return end               -- blocked on you (its own notify)
        desktop_notify(sess, "finished — ready for you", "normal")
      end, 8000)
    end
    -- If the turn produced NO assistant reply (last message is still the user's
    -- prompt), the answer was dropped — almost always mid-turn context
    -- compaction on a near-full session. Say so instead of rendering silence.
    -- Skip when we just appended a queued prompt (its answer is still coming), and
    -- guard S.errors (lazily created — nil on a session's first clean turn).
    local c = S.chat[obj.session]
    if not flushed_queue and c and c.msgs and #c.msgs > 0 and c.msgs[#c.msgs].role == "user"
      and not (S.errors and S.errors[obj.session]) then
      c.msgs[#c.msgs + 1] = { role = "assistant",
        text = THINK .. "no reply — the turn ended without an answer (likely context compaction). Re-ask, or start a fresh session for research-heavy tasks." }
    end
    -- writes settled → reload the exact files the agent edited (see sync_edited)
    local ed = S.edited[obj.session]
    if ed then S.edited[obj.session] = nil; vim.schedule(function() sync_edited(session_cwd(obj.session), ed) end) end
    -- Turn recap for the done divider: pull the agent's ⟢ one-liner out of the final
    -- assistant message (stripping the marker line so it isn't shown twice), and pair
    -- it with the +adds/−dels of the files it touched this turn.
    S.summary = S.summary or {}
    local recap
    local last = c and c.msgs and c.msgs[#c.msgs]
    if last and last.role == "assistant" and type(last.text) == "string" then
      local kept = {}
      for _, ln in ipairs(vim.split(last.text, "\n", { plain = true })) do
        local m = ln:match("^%s*⟢%s*(.+)")
        if m then recap = m else kept[#kept + 1] = ln end
      end
      if recap then
        local body = (table.concat(kept, "\n")):gsub("%s+$", "")
        if body == "" then table.remove(c.msgs) else last.text = body end
      end
    end
    local files = {}
    if ed then
      -- A turn can edit files across REPOS (the code worktree + the vault plan .md),
      -- so resolve each file's OWN git root and diff each root once. A single shared
      -- cwd (session_cwd, or one arbitrary file's root) picked the wrong repo when
      -- next(ed) landed on the vault plan → the code files matched nothing (+0/-0)
      -- and weren't stripped (full ~-paths).
      local roots, changes_by_root = {}, {}
      local function root_of(p)
        local dir = fn.fnamemodify(p, ":h")
        if roots[dir] ~= nil then return roots[dir] end
        local r = fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })[1]
        r = (r and r ~= "") and r or false
        roots[dir] = r
        if r and not changes_by_root[r] then
          local by = {}
          for _, x in ipairs(git_changes(r)) do by[x.path] = x end -- keys are repo-relative
          changes_by_root[r] = by
        end
        return r
      end
      local names = {}
      for p in pairs(ed) do names[#names + 1] = p end
      table.sort(names)
      for _, p in ipairs(names) do
        -- strip to repo-relative (matches git_changes' keys so the +adds/−dels line
        -- up); files whose root we can't resolve fall back to ~-relative.
        local root = root_of(p)
        local rel, x
        if root and p:sub(1, #root + 1) == root .. "/" then
          rel = p:sub(#root + 2)
          x = changes_by_root[root][rel]
        else
          rel = fn.fnamemodify(p, ":~")
        end
        files[#files + 1] = {
          path = rel,
          add = (x and x.add) or 0,
          del = (x and x.del) or 0,
        }
      end
    end
    S.summary[obj.session] = { recap = recap, files = files }
    refresh_plans() -- capture final plan progress now the turn's done (the streaming sweep stopped)
    if obj.session == S.selected then render_chat(false) end
  elseif t == "extension_ui_request" then
    local m = obj.method
    if m == "notify" then
      vim.notify("[" .. (obj.session or "agent") .. "] " .. (obj.message or ""), vim.log.levels.INFO)
    elseif m == "confirm" or m == "select" or m == "input" or m == "editor" then
      -- only genuine questions become an inline approval card / "needs input"
      S.pending[obj.session] = obj
      desktop_notify(obj.session, (obj.title or "needs your input"), "critical")
      render_roster()
      if obj.session == S.selected then
        render_chat(true)
        reveal_decision(obj.title)
        apply_prompt_mode() -- one place applies keys/cursor/focus/placeholder
      end
    end
    -- setStatus/setWidget/setTitle/set_editor_text: UI directives, not questions —
    -- ignored (surfacing them as approvals was the spurious "setStatus" card)
  elseif t == "error" then
    -- surface pi/daemon failures that would otherwise vanish as an empty turn
    -- (e.g. a quota/auth error on the model call)
    local msg = obj.error or obj.message
    if type(msg) == "table" then msg = msg.message or msg.text end
    local sid = obj.session or S.selected
    if sid then
      if S.turn_active then S.turn_active[sid] = nil end -- turn ended (in error) → clear active
      -- During a /reload, the ~2s pi-boot gap yields an expected "pi not running"
      -- / "no running session" — swallow ONLY those while reloading. Any other
      -- error (or these outside a reload) still surfaces normally.
      local ms = tostring(msg or "")
      local transient = S.reloading and S.reloading[sid]
        and (ms:match("pi not running") or ms:match("no running session"))
      if not transient then
        S.errors = S.errors or {}
        S.errors[sid] = tostring(msg or "unknown error")
        S.stream[sid] = nil
        if sid == S.selected then render_chat(true) end
      end
    else
      vim.notify("agent error: " .. tostring(msg or "unknown"), vim.log.levels.ERROR)
    end
  end
end

on_read = function(err, chunk)
  -- err or nil chunk = the daemon closed the pipe (restart, socket drop). Flip
  -- to disconnected and self-heal: without this S.connected stays true forever
  -- on the first success, so a dropped socket left the roster silently empty
  -- with no recovery until nvim restarted.
  if err or not chunk then
    if S.connected then
      S.connected = false
      pcall(function() if S.pipe then S.pipe:close() end end)
      S.pipe = nil
      S.readbuf = ""
      vim.schedule(function()
        render_roster() -- show the offline glyph
        -- re-request the roster on reconnect: the daemon only pushes it on
        -- change, so a fresh connection needs an explicit list_sources.
        connect(function() send({ type = "list_sources" }) end)
      end)
    end
    return
  end
  S.last_recv = os.time() -- heartbeat: agentd pings every 3s; absence = dead pipe
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
  S.connecting = true
  local p = uv.new_pipe(false)
  p:connect(sock(), function(cerr)
    if not cerr then
      S.connecting = false
      S.pipe = p
      S.connected = true
      S.last_recv = os.time() -- fresh connection: don't flag it stale immediately
      S.ever_connected = true
      p:read_start(vim.schedule_wrap(on_read))
      -- flush anything queued while we were down so a daemon restart / socket
      -- drop is transparent: messages you sent mid-outage get delivered now,
      -- in order, instead of being silently lost.
      if S.outbox and #S.outbox > 0 then
        local pending = S.outbox; S.outbox = {}
        for _, m in ipairs(pending) do
          pcall(function() p:write(vim.json.encode(m) .. "\n") end)
        end
      end
      vim.schedule(function() render_roster() end)
      if cb then vim.schedule(cb) end
      return
    end
    pcall(function() p:close() end)
    -- Only spawn a daemon on the very first boot attempt: a reconnect after a
    -- drop (S.ever_connected) means the daemon is normally already up and just
    -- blipped — spawning a duplicate would race the socket bind and log-spam.
    if tries == 0 and not S.ever_connected then
      vim.schedule(function()
        fn.jobstart({ agentd_bin(), "--scope", scope, "--repo", scope_root() }, { detach = true })
      end)
    end
    -- Never give up: fast retries (200ms) for the first ~6s while a
    -- just-spawned daemon boots, then back off to a steady 2s poll so a longer
    -- daemon restart still reconnects on its own without an nvim restart.
    local delay = (tries < 30) and 200 or 2000
    local tm = uv.new_timer()
    tm:start(delay, 0, function() tm:close(); try_connect(cb, tries + 1) end)
  end)
end

connect = function(cb)
  if S.connected then if cb then cb() end return end
  if S.connecting then return end -- a retry loop is already spinning
  try_connect(cb, 0)
end

-- queue a message for delivery after (re)connect. Skip list_sources — the
-- reconnect callback re-requests it anyway — and cap so a long outage can't grow
-- the queue unbounded.
local function enqueue(obj)
  if not obj or obj.type == "list_sources" then return end
  S.outbox = S.outbox or {}
  if #S.outbox < 50 then S.outbox[#S.outbox + 1] = obj end
end

-- drop the (now-known-dead) pipe and kick a reconnect that re-requests state.
local function drop_and_reconnect()
  if S.connected then
    S.connected = false
    pcall(function() if S.pipe then S.pipe:close() end end)
    S.pipe = nil; S.readbuf = ""
  end
  S.turn_active = {} -- connection reset → lost turn tracking; don't leave "working" stuck
  render_roster()
  connect(function() send({ type = "list_sources" }) end)
end

send = function(obj)
  if not (S.connected and S.pipe) then
    -- not connected: DON'T silently drop it (the old bug) — queue it and kick a
    -- reconnect so it's delivered once the socket is back.
    enqueue(obj)
    connect(function() send({ type = "list_sources" }) end)
    return
  end
  -- Wedge watchdog: stamp when a prompt goes out. A live pi acks with agent_start
  -- in a second or two; if NOTHING comes back for WEDGE_SECS the pi is stuck, and
  -- the spin timer auto-reloads + reseeds it (see start_spin). Cleared in handle()
  -- the instant any event for the session arrives.
  if obj.type == "prompt" and obj.session then
    S.awaiting = S.awaiting or {}
    S.awaiting[obj.session] = os.time()
  end
  -- write with an error callback: a failed write means the peer died without a
  -- read-side EOF (exactly the daemon-restart case) — self-heal instead of
  -- losing the message to a dead pipe forever.
  S.pipe:write(vim.json.encode(obj) .. "\n", function(werr)
    if werr then vim.schedule(function() enqueue(obj); drop_and_reconnect() end) end
  end)
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

-- Request a session's history, then re-request (only while it's still empty) a
-- couple times: on spawn/open, pi may still be resuming its session (--continue)
-- when the first request lands, so the chat would show "no messages yet" until a
-- manual 'r'. The gated retries load the restored history automatically.
local function reload_messages(sid)
  send({ type = "get_entries", session = sid })
  for _, delay in ipairs({ 700, 1800 }) do
    vim.defer_fn(function()
      local c = S.chat[sid]
      if S.connected and (not c or not c.msgs or #c.msgs == 0) then
        send({ type = "get_entries", session = sid })
      end
    end, delay)
  end
end

-- Cleanly restart a session's pi: stop it, then respawn. pi --continue resumes
-- the conversation (cwd-keyed session file) AND re-reads mcp.json, so a newly
-- added MCP server loads — the one-gesture replacement for the x+. dance and the
-- external pkill. The short delay lets the stop tear down before spawn re-adds
-- (spawn is idempotent-by-name, so it'd no-op against a not-yet-removed entry).
local function reload_session(sid, cwd, seed)
  if not (sid and cwd and cwd ~= "") then vim.notify("agent-nvim: open a session first"); return end
  send({ type = "stop", session = sid })
  S.stream[sid] = nil
  -- mark reloading so the ~2s pi-boot gap shows "restarting…" instead of a
  -- scary "pi not running" error; cleared when messages land (pi's back), with a
  -- safety timeout so a genuinely-dead pi still surfaces its error eventually.
  S.reloading = S.reloading or {}
  S.reloading[sid] = true
  vim.defer_fn(function() if S.reloading then S.reloading[sid] = nil end end, 12000)
  if sid == S.selected then render_chat(false) end
  vim.notify("agent-nvim: restarting " .. short_name(sid) .. " — reloading MCP config…")
  vim.defer_fn(function()
    -- carry the seed IN the spawn so the daemon delivers it the moment pi's stdin
    -- is ready (event-driven) — used by the wedge watchdog to resend the prompt
    -- that got no response, without racing the fresh pi's cold start.
    local spawn = { type = "spawn", session = sid, cwd = cwd }
    if seed and seed ~= "" then spawn.prompt = seed end
    send(spawn)
    reload_messages(sid)
  end, 400)
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
  reload_messages(name)
  reroot(cwd)
  load_draft(name)
  refresh_plans()
  render_active()
end

view_session = function(name, cwd)
  save_draft()
  -- Remember what the OUTGOING session had in the editor so returning restores it
  -- (per-session, so one session's file can never bleed into another's).
  if S.selected and S.selected ~= name then capture_editor(S.selected) end
  S.dash_expand = false -- each session's dashboard opens collapsed
  S.selected = name
  -- record the visit for Ctrl-o/Ctrl-i (jumplist-for-sessions): a fresh view drops any
  -- forward history and appends, unless we're being driven BY nav_session (nav_lock).
  if not S.nav_lock and name and S.nav_hist[S.nav_idx] ~= name then
    for i = #S.nav_hist, S.nav_idx + 1, -1 do S.nav_hist[i] = nil end
    S.nav_hist[#S.nav_hist + 1] = name
    S.nav_idx = #S.nav_hist
  end
  reload_messages(name)
  reroot(cwd)
  -- refresh ONLY the switched-to session's plan (1 git call) so its dashboard/chip are
  -- fresh — before reflect_context renders the dashboard. The rest of the roster stays
  -- cached and refreshes on the slow tick. (Full refresh_plans here was O(sessions)
  -- sync git calls on every switch — the swap lag.)
  for _, a in ipairs(S.roster) do if a.id == name then refresh_plan_one(a); break end end
  reflect_context(cwd) -- restore this session's editor (S.editor[name]) or show the dashboard
  cockpit_sync(cwd)    -- drive the cockpit devenv tab + Super+T active marker to match
  load_draft(name)
  render_active()
end

-- Ctrl-o / Ctrl-i walk the session-visit history like a jumplist (delta -1 = back to
-- an older session, +1 = forward). Bound buffer-locally in the rail panes ONLY, so a
-- real editor window keeps the actual jumplist. Skips history entries whose session is
-- gone, and sets nav_lock so the resulting view_session doesn't re-record the hop.
local function nav_session(delta)
  local i = S.nav_idx
  while true do
    i = i + delta
    if i < 1 or i > #S.nav_hist then return end
    local id = S.nav_hist[i]
    if id ~= S.selected then
      local found, cwd = false, nil
      for _, a in ipairs(S.roster) do if a.id == id then found, cwd = true, a.cwd; break end end
      if found then
        S.nav_idx = i
        S.nav_lock = true
        pcall(view_session, id, cwd)
        S.nav_lock = false
        return
      end
    end
  end
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
  S.timer:start(60, 60, vim.schedule_wrap(function() -- 60ms/frame, matches the Diagswipe loader
    if not (S.win and api.nvim_win_is_valid(S.win)) then return end
    local streaming = false
    for _, a in ipairs(S.roster) do
      if a.status == "streaming" then streaming = true; break end
    end
    S.tick = (S.tick or 0) + 1
    -- ~18s plan-progress refresh, but ONLY while a session is streaming: it spawns
    -- a synchronous git per session, and plan progress can't change while idle —
    -- running it on every idle tick was a periodic UI hitch all day. Switching
    -- sessions (view_session) and finishing a turn (agent_end) refresh on demand.
    if streaming and S.tick % 300 == 0 then refresh_plans() end
    -- devenv link health polls on the idle tick too (~6s): a slice can start/stop
    -- while agents are idle, unlike plan progress. Async, so it never blocks render.
    if S.tick % 100 == 0 then refresh_devenv() end
    -- Watchdog: guarantee liveness even if a socket EOF is somehow missed. If we
    -- ever find ourselves disconnected (and no retry loop is already spinning),
    -- kick a reconnect. This is why the rail stays alive on its own — no manual
    -- :AgentReconnect needed.
    if S.tick % 33 == 0 then
      if S.connected and S.pipe and S.last_recv and (os.time() - S.last_recv > 10) then
        -- Heartbeat: agentd broadcasts a ping every 3s. >10s of silence means the
        -- pipe is dead even though we still think we're connected (writes to it
        -- don't error) — exactly the "stopped responding" wedge. Force a
        -- reconnect (drops the pipe, re-dials, flushes the outbox).
        drop_and_reconnect()
      elseif not S.connected and not S.connecting then
        connect(function() send({ type = "list_sources" }) end)
      end
      -- Wedge watchdog: a prompt with NO event for a long time means pi is stuck
      -- (alive but not processing — the "goes stale, have to /reload" case). Auto
      -- stop+respawn it and reseed the prompt via the spawn so nothing's lost. One
      -- shot per wedge (the reseed doesn't re-arm awaiting) + a 90s cooldown, so it
      -- can never reload-loop. TIMEOUT: a reasoning model (gpt-5.x) on a long prompt
      -- can take 20-40s to its FIRST streamed event, so 12s false-fired and reseeded
      -- → the message sent twice. 60s clears that; a truly-stuck pi is silent longer.
      if S.connected and S.awaiting then
        local now = os.time()
        for aid, t in pairs(S.awaiting) do
          if now - t > 60 then
            S.awaiting[aid] = nil
            S.last_autoreload = S.last_autoreload or {}
            if not S.last_autoreload[aid] or now - S.last_autoreload[aid] > 90 then
              S.last_autoreload[aid] = now
              local cwd
              for _, a in ipairs(S.roster) do if a.id == aid then cwd = a.cwd; break end end
              if cwd then
                vim.notify("agent-nvim: " .. short_name(aid) .. " unresponsive — reloading + resending", vim.log.levels.WARN)
                reload_session(aid, cwd, S.last_sent and S.last_sent[aid])
              end
            end
          end
        end
      end
      -- Recover an empty chat for a live selected session: a background-spawned
      -- session (e.g. an agent-review) can stream its first turn before we're
      -- watching it, and reload_messages only retried get_entries for ~2s — far
      -- less than a review's first round. If the selected session is streaming
      -- (or reloading) yet we have neither finalized messages nor a live stream,
      -- re-pull the history until it lands.
      if S.connected and S.selected then
        local live = S.reloading and S.reloading[S.selected]
        if not live then
          for _, a in ipairs(S.roster) do
            if a.id == S.selected and a.status == "streaming" then live = true; break end
          end
        end
        local c = S.chat[S.selected]
        local streaming_now = S.stream[S.selected] and S.stream[S.selected] ~= ""
        if live and not streaming_now and (not c or not c.msgs or #c.msgs == 0) then
          send({ type = "get_entries", session = S.selected })
        end
      end
    end
    if streaming then
      S.spin = S.spin + 1
      -- The winbar spinner is the one you watch — a cheap string set, so animate
      -- it every frame. render_roster rebuilds a whole buffer + decor; at 60ms
      -- that competed with streaming renders and made the whole thing wonky, so
      -- render both the winbar and the roster every frame: both are cheap (the
      -- roster is a handful of lines) and the real lag was the git diff (now
      -- async) + chat render (now throttled), not this. Every-frame = smooth spinner.
      -- The spinner lives in the COMPOSER winbar, visible in both chat + changes
      -- views — refresh it every frame regardless of view, else switching to the
      -- changes view freezes it. (refresh_active_header guards the chat winbar on
      -- view internally, so the "changes ·" winbar isn't clobbered.)
      refresh_active_header()
      render_roster()
    elseif S.tick % 33 == 0 then
      render_roster() -- ~2s refresh so idle durations tick up
    end
    -- safety-net reconcile (~2s): guarantees the rail↔cockpit sync converges even
    -- if a filesystem event was missed. Guarded by S.cockpit_ctx, so it's a no-op
    -- whenever the two already agree.
    if S.tick % 33 == 0 and on_cockpit_active then on_cockpit_active() end
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
  local extra = #S.attach + #S.paste_images -- chip virt-lines above the input
  -- True display height (wrapped content + the top/bottom pad + chip virt-lines).
  -- The old "grew out of nowhere on niri navigation" was a transient from a focus
  -- redraw; it's corrected by re-running this on FocusGained (see M.open), not by
  -- second-guessing the height here — that dropped the pads and killed the margin.
  local ok, h = pcall(api.nvim_win_text_height, S.composerwin, {})
  local all = (ok and type(h) == "table" and h.all) or (api.nvim_buf_line_count(S.composerbuf) + extra)
  all = math.max(1, math.min(all, COMPOSER_MAX + extra))
  pcall(api.nvim_win_set_height, S.composerwin, all)
end

composer_placeholder = function()
  api.nvim_buf_clear_namespace(S.composerbuf, S.composer_ns, 0, -1)
  local pm = prompt_mode()
  vim.bo[S.composerbuf].modifiable = pm.editable
  if composer_empty() then
    pcall(api.nvim_buf_set_extmark, S.composerbuf, S.composer_ns, 0, 0, {
      virt_text = { { pm.placeholder, pm.placeholder_hl } }, virt_text_pos = "overlay",
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
  -- A blank line between the status winbar and the input so the status reads as
  -- its own thing, not part of the input box. Attachment chips float above the input.
  local vls = { { { "", "Normal" } } }
  for _, at in ipairs(S.attach) do
    local loc = at.path
    if at.l1 then loc = loc .. ":" .. at.l1 .. (at.l2 and at.l2 ~= at.l1 and ("-" .. at.l2) or "") end
    local tag = (at.lang and at.lang ~= "") and ("  " .. at.lang) or ""
    vls[#vls + 1] = { { CHIP_BAR .. " ", "AgentChipBar" }, { " " .. loc .. tag .. " ", "AgentChip" } }
  end
  for i, img in ipairs(S.paste_images) do
    vls[#vls + 1] = { { CHIP_BAR .. " ", "AgentChipBar" }, { "  image " .. i .. " · " .. img.mimeType .. " ", "AgentChip" } }
  end
  pcall(api.nvim_buf_set_extmark, S.composerbuf, S.chip_ns, 0, 0, { virt_lines = vls, virt_lines_above = true })
  -- And a blank below the input so it doesn't butt the lualine bar.
  local last = math.max(0, api.nvim_buf_line_count(S.composerbuf) - 1)
  pcall(api.nvim_buf_set_extmark, S.composerbuf, S.chip_ns, last, 0,
    { virt_lines = { { { "", "Normal" } } }, virt_lines_above = false })
  composer_resize()
end

add_attachment = function(at)
  S.attach[#S.attach + 1] = at
  render_chips()
end

local function clear_attachments()
  S.attach = {}
  S.paste_images = {}
  render_chips(); refresh_active_header() -- also clear the winbar 🖼 count
end

-- <C-v>: paste the clipboard. An image → attach it (sent to the agent as a real
-- image on the next send); otherwise the text is inserted at the cursor.
local function paste_clipboard()
  local img_type
  for _, t in ipairs(fn.systemlist({ "wl-paste", "--list-types" })) do
    if t:match("^image/") then img_type = t; break end
  end
  if img_type then
    local b64 = fn.system({ "sh", "-c", "wl-paste --no-newline --type " .. img_type .. " | base64 -w0" }):gsub("%s+$", "")
    if b64 ~= "" then
      S.paste_images[#S.paste_images + 1] = { type = "image", data = b64, mimeType = img_type }
      render_chips(); refresh_active_header() -- chip + always-visible winbar count are
      -- the confirmation — no notification (the popup was redundant noise).
    end
  else
    local txt = fn.getreg("+")
    if txt == "" then txt = (fn.system({ "wl-paste", "--no-newline" }) or ""):gsub("%s+$", "") end
    if txt ~= "" then pcall(vim.api.nvim_paste, txt, false, -1) end
  end
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
    S.stream[S.selected] = nil
    if S.turn_active and S.selected then S.turn_active[S.selected] = nil end
    render_chat(false)
  elseif cmd == "steer" then
    send({ type = "steer", session = S.selected, message = rest })
  elseif cmd == "clear" then
    S.chat[S.selected] = { msgs = {} }; S.stream[S.selected] = nil; render_chat(true)
  elseif cmd == "diff" then
    pcall(vim.cmd, "tab Git diff")
  elseif cmd == "plan" then
    -- default to the active session's plan (matched by branch) — no picker
    local cwd = S.selected and session_cwd(S.selected)
    local plan = cwd and load_plan(cwd)
    pcall(function() require("plan-nvim").open(plan and plan.key or nil) end)
  elseif cmd == "retry" then
    send({ type = "follow_up", session = S.selected, message = "retry the previous step" })
  elseif cmd == "model" then
    send({ type = "cycle_model", session = S.selected }) -- next model; response shows it
  elseif cmd == "think" then
    send({ type = "cycle_thinking_level", session = S.selected }) -- next reasoning level
  elseif cmd == "reload" then
    -- restart this session's pi so it re-reads mcp.json (new MCP servers, config
    -- edits). Rail-side stop+spawn — no x+. dance, no external pkill.
    reload_session(S.selected, S.selected and session_cwd(S.selected))
  elseif cmd == "help" then
    M.help()
  else
    -- Not a rail command → let it through to pi as a prompt. pi owns its own
    -- slash commands / skills (e.g. /plan-ticket), so the rail must not swallow them.
    return false
  end
  return true
end

--------------------------------------------------------------------------------
-- slash picker: live-filtered menu of rail commands + pi templates/skills while
-- you type `/…` in the composer (before a space). Floats above the input.
--------------------------------------------------------------------------------
local RAIL_CMDS = {
  { "abort", "stop the current turn" }, { "steer", "steer mid-turn <msg>" },
  { "clear", "clear the chat" }, { "diff", "open a git diff tab" },
  { "plan", "open the plan view" }, { "retry", "retry the previous step" },
  { "model", "switch the model (cycle)" }, { "think", "cycle reasoning level" },
  { "reload", "restart pi · reload MCP config" },
  { "help", "rail cheatsheet" },
}

-- pi commands the rail forwards straight to pi as a prompt (NOT intercepted by
-- run_slash). Only pi's PROMPT-INVOCABLE commands work this way — i.e. its
-- extension/prompt/skill commands (RpcSlashCommand.source). pi's built-in TUI
-- commands (/reload, /compact, /copy, /context, …) do NOT execute in --mode rpc;
-- they arrive as ordinary text, so they must NOT be listed here or they mislead.
-- These two are pi-mcp-adapter EXTENSION commands and do execute via the rail.
-- (A dynamic feed from pi's get_commands RPC would list the full accurate set —
-- see agent-rail.md follow-ups.)
local PI_CMDS = {
  { "mcp-auth", "authenticate an MCP server <name>" },
  { "mcp", "MCP server status" },
}

local function slash_items()
  local items = {}
  for _, c in ipairs(RAIL_CMDS) do
    items[#items + 1] = { insert = "/" .. c[1] .. " ", label = "/" .. c[1], hint = c[2] }
  end
  for _, c in ipairs(PI_CMDS) do
    items[#items + 1] = { insert = "/" .. c[1] .. " ", label = "/" .. c[1], hint = c[2] }
  end
  -- plan-ticket lifecycle: offer each phase and mark the one that's next given the
  -- plan's current phase (cached in S.plan). Sends the same string plan-nvim does.
  local pl = S.selected and S.plan[S.selected]
  local phase = pl and pl.phase
  local suffix = (pl and pl.key) and (" " .. pl.key) or ""
  local nextflag = ({ draft = "--finalize", planned = "--finalize", finalized = "--go",
    implementing = "--reconcile", reconciled = "--amend" })[phase or ""] or ""
  for _, p in ipairs({
    { "", "draft the plan" }, { "--finalize", "bake decisions + how-it-works" },
    { "--go", "implement the plan" }, { "--reconcile", "reconcile after --go" },
    { "--amend", "fold in new scope" },
  }) do
    local flagpart = p[1] ~= "" and (" " .. p[1]) or ""
    local hint = p[2]
    if p[1] == nextflag then hint = hint .. "   ← next" .. (phase and ("  (now: " .. phase .. ")") or "") end
    items[#items + 1] = { insert = "/plan-ticket" .. flagpart .. suffix .. " ", label = "/plan-ticket" .. flagpart, hint = hint }
  end
  -- expand only the ~, then glob the pattern — expanding the wildcard inside
  -- fn.expand and re-globbing returns nothing (the bug that hid the skills).
  local pdir = fn.expand("~/.pi/agent/prompts")
  for _, f in ipairs(fn.glob(pdir .. "/*.md", true, true)) do
    local n = fn.fnamemodify(f, ":t:r")
    items[#items + 1] = { insert = "/" .. n .. " ", label = "/" .. n, hint = "pi template" }
  end
  local sdir = fn.expand("~/.pi/agent/skills")
  for _, d in ipairs(fn.glob(sdir .. "/*", true, true)) do
    if fn.isdirectory(d) == 1 then
      local n = fn.fnamemodify(d, ":t")
      items[#items + 1] = { insert = "/skill:" .. n .. " ", label = "/skill:" .. n, hint = "pi skill" }
    end
  end
  return items
end

local SL = { win = nil, buf = nil, items = nil, sel = 1 }

local function sl_close()
  if SL.win and api.nvim_win_is_valid(SL.win) then pcall(api.nvim_win_close, SL.win, true) end
  SL.win, SL.buf, SL.items = nil, nil, nil
end

local function sl_render()
  if not SL.items or #SL.items == 0 then sl_close(); return end
  local lines, width = {}, 12
  for _, it in ipairs(SL.items) do
    local l = string.format("  %-18s %s", it.label, it.hint or "")
    lines[#lines + 1] = l
    width = math.max(width, #l + 1)
  end
  if not (SL.buf and api.nvim_buf_is_valid(SL.buf)) then SL.buf = api.nvim_create_buf(false, true) end
  vim.bo[SL.buf].modifiable = true
  api.nvim_buf_set_lines(SL.buf, 0, -1, false, lines)
  vim.bo[SL.buf].modifiable = false
  local cfg = { relative = "cursor", anchor = "SW", row = 0, col = 0, width = width,
    height = math.min(#lines, 14), style = "minimal", border = "rounded", focusable = false, zindex = 200 }
  if SL.win and api.nvim_win_is_valid(SL.win) then
    api.nvim_win_set_config(SL.win, cfg)
  else
    SL.win = api.nvim_open_win(SL.buf, false, cfg)
    -- match the LSP-hover float: theme's rounded border + float bg, not a custom card
    vim.wo[SL.win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
  end
  api.nvim_buf_clear_namespace(SL.buf, S.ns, 0, -1)
  pcall(api.nvim_buf_set_extmark, SL.buf, S.ns, SL.sel - 1, 0, { line_hl_group = "AgentSel" })
  -- scroll the (unfocused) float so the selection stays visible past the fold —
  -- this is how C-n reaches the skills that sit below the rail commands.
  pcall(api.nvim_win_set_cursor, SL.win, { SL.sel, 0 })
end

local function sl_update()
  if not (S.composerwin and api.nvim_get_current_win() == S.composerwin) then sl_close(); return end
  local line = api.nvim_get_current_line()
  if not line:match("^/%S*$") then sl_close(); return end
  local pfx = line:lower()
  local matches = {}
  for _, it in ipairs(slash_items()) do
    local lab = it.label:lower()
    if lab:sub(1, #pfx) == pfx or lab:find(pfx:sub(2), 1, true) then matches[#matches + 1] = it end
  end
  if #matches == 0 then sl_close(); return end
  SL.items = matches
  if not SL.sel or SL.sel > #matches then SL.sel = 1 end
  sl_render()
end

local function sl_open() return SL.win ~= nil and api.nvim_win_is_valid(SL.win) end
local function sl_move(d)
  if not (sl_open() and SL.items) then return false end
  SL.sel = ((SL.sel - 1 + d) % #SL.items) + 1
  sl_render()
  return true
end
local function sl_accept()
  if not (sl_open() and SL.items and SL.items[SL.sel]) then return false end
  local ins = SL.items[SL.sel].insert
  api.nvim_set_current_line(ins)
  pcall(api.nvim_win_set_cursor, 0, { 1, #ins })
  sl_close()
  return true
end

-- Re-enter insert in the composer AFTER the current mapping returns. <C-s>'s
-- stopinsert only lands on mapping-return, so a synchronous startinsert! during
-- the call gets overridden and you drop to normal — scheduling ours to run last
-- wins, keeping you typing-ready after every send.
local function stay_in_composer()
  vim.schedule(function()
    if S.composerwin and api.nvim_win_is_valid(S.composerwin) then
      pcall(api.nvim_set_current_win, S.composerwin)
      vim.cmd("startinsert!")
    end
  end)
end

composer_send = function()
  if not S.selected then vim.notify("agent-nvim: open a session first (<CR>)", vim.log.levels.INFO); return end
  local text = table.concat(api.nvim_buf_get_lines(S.composerbuf, 0, -1, false), "\n"):gsub("%s+$", "")
  -- a pending prompt takes over the input: <CR> submits an input answer, and a
  -- confirm/select is answered with y/n/number (not by sending a message)
  local pm = prompt_mode()
  if pm.kind == "type" then
    answer({ value = text })
    api.nvim_buf_set_lines(S.composerbuf, 0, -1, false, { "" }); render_chips()
    return
  elseif pm.kind == "choose" then
    vim.notify("answer the prompt above — y / n or a number")
    return
  end
  if text == "" and #S.attach == 0 and #S.paste_images == 0 then return end

  -- slash command (only when there are no attachments and it's a lone command)
  if #S.attach == 0 and text:match("^/%S") and run_slash(text) then
    api.nvim_buf_set_lines(S.composerbuf, 0, -1, false, { "" })
    render_chips(); composer_placeholder()
    return
  end

  if S.errors then S.errors[S.selected] = nil end -- clear last error on retry
  S.last_sent = S.last_sent or {}
  S.last_sent[S.selected] = text -- for Esc-restore (edit + resend the last message)
  local prompt = build_prompt(text)
  local imgs = (#S.paste_images > 0) and vim.deepcopy(S.paste_images) or nil
  local c = S.chat[S.selected] or { msgs = {} }

  -- Sending mid-turn QUEUES locally (held in the rail, flushed on turn_end) so
  -- you can still cancel or edit it with Esc — unlike a fired-off follow_up.
  -- Images can't be queued, so a message with attachments always sends now.
  local working = S.stream[S.selected] and S.stream[S.selected] ~= ""
  if working and not imgs then
    S.queued = S.queued or {}
    S.queued[S.selected] = (S.queued[S.selected] and (S.queued[S.selected] .. "\n\n") or "") .. prompt
    S.chat[S.selected] = c
    S.drafts[S.selected] = nil
    clear_attachments()
    api.nvim_buf_set_lines(S.composerbuf, 0, -1, false, { "" })
    render_chips(); composer_placeholder()
    render_chat(false) -- show the queued indicator
    stay_in_composer()
    return
  end

  c.msgs[#c.msgs + 1] = { role = "user", text = prompt .. (imgs and ("  " .. ICON.image .. "×" .. #imgs) or "") } -- optimistic echo
  S.chat[S.selected] = c
  S.force_bottom = true -- a fresh send always lands at the bottom, even if scrolled up
  render_chat(true)
  send({ type = "prompt", session = S.selected, message = prompt, images = imgs })
  S.drafts[S.selected] = nil
  clear_attachments()
  api.nvim_buf_set_lines(S.composerbuf, 0, -1, false, { "" })
  render_chips(); composer_placeholder()
  stay_in_composer()
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
    S.force_bottom = true
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

-- Collapse (zM) / expand (zR) every message in the open chat at once — the
-- Claude-Code "read a long transcript top-down" move: fold all to skim headers,
-- unfold to read. Preserves cursor by re-rendering in place.
local function chat_fold_all(folded)
  if not S.selected then return end
  local chat = S.chat[S.selected]
  if not (chat and chat.msgs) then return end
  local f = {}
  if folded then for mi = 1, #chat.msgs do f[mi] = true end end
  S.folds[S.selected] = f
  render_chat(false)
end

-- cwd of a roster session by id
session_cwd = function(id)
  for _, a in ipairs(S.roster) do if a.id == id then return a.cwd end end
  return nil
end

-- The active session's id + cwd, for callers that want to route to "the agent"
-- (e.g. plan-nvim's <C-p> ask-about-selection from any buffer). nil if none open.
function M.active_session()
  if not S.selected then return nil end
  return { id = S.selected, cwd = session_cwd(S.selected) }
end

-- open a file in the main editor window (not a rail pane), at an optional line.
-- Relative paths resolve against the session's worktree.
local function is_editor_win(w, candidate)
  if not w or not api.nvim_win_is_valid(w) then return false end
  if api.nvim_win_get_tabpage(w) ~= api.nvim_get_current_tabpage() then return false end
  if w == S.win or w == S.chatwin or w == S.composerwin then return false end
  if api.nvim_win_get_config(w).relative ~= "" then return false end
  if not candidate then return true end
  local b = api.nvim_win_get_buf(w)
  return vim.bo[b].buftype == "" and not api.nvim_buf_get_name(b):match("agent%-")
end

target_editor_win = function()
  if is_editor_win(S.editor_win, false) then return S.editor_win end
  S.editor_win = nil
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if is_editor_win(w, true) then
      S.editor_win = w
      vim.g.agent_editor_win = w
      return w
    end
  end
  vim.g.agent_editor_win = nil
  return nil
end

M.editor_win = target_editor_win

local function open_in_editor(cwd, path, line)
  local file = path:match("^/") and path or ((cwd or fn.getcwd()) .. "/" .. path)
  file = fn.expand(file)
  if fn.filereadable(file) == 0 then vim.notify("agent-nvim: not readable — " .. path, vim.log.levels.WARN); return end
  local target = target_editor_win()
  if not target then
    vim.cmd("topleft vsplit")
    S.editor_win = api.nvim_get_current_win()
    vim.g.agent_editor_win = S.editor_win
    target = S.editor_win
  end
  api.nvim_set_current_win(target)
  pcall(vim.cmd, "edit " .. fn.fnameescape(file))
  if line then pcall(api.nvim_win_set_cursor, 0, { tonumber(line), 0 }) end
end

-- Follow the cursor to a hunk line WITHOUT stealing focus — but only if the file
-- is ALREADY open in a window (hover previews, it never opens a new file; <CR>
-- does the opening). Dedups redundant work.
local function reveal_file(cwd, path, line)
  if not line then return end
  local file = fn.fnamemodify(fn.expand(path:match("^/") and path or ((cwd or fn.getcwd()) .. "/" .. path)), ":p")
  local target
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if fn.fnamemodify(api.nvim_buf_get_name(api.nvim_win_get_buf(w)), ":p") == file then target = w; break end
  end
  if not target then return end -- only follow files already open
  local key = file .. ":" .. tostring(line)
  if S._reveal == key then return end
  S._reveal = key
  api.nvim_win_call(target, function()
    pcall(api.nvim_win_set_cursor, target, { tonumber(line), 0 })
    vim.cmd("normal! zz")
  end)
end

-- Live-follow: as the agent edits files this turn, OPEN the edited file in the
-- editor window and land on the changed line — without stealing focus. Unlike
-- reveal_file, it opens files not yet shown (that's why the editor stayed on the
-- plan while other files were edited). Only fires when focus is in the rail (an
-- agent-* window): if you've clicked into the code to read/edit, it leaves you
-- alone. Skips when the target buffer has unsaved changes. Toggle: S.follow_edits.
follow_edit = function(cwd, path, line)
  if not path or S.follow_edits == false then return end
  -- Never follow into plan machinery sidecars: a /plan-ticket turn writes the
  -- reviewable .md and THEN its progress.json, so following the last edit would
  -- dump you in raw JSON instead of the rendered plan. Skipping them keeps the
  -- editor on the .md (which plan-nvim renders) — the thing you actually review.
  if path:match("%.progress%.json$") or path:match("%.review%.json$")
    or path:match("/plans/.*%.diagram%.html$") then return end
  local cur = api.nvim_get_current_win()
  if not api.nvim_buf_get_name(api.nvim_win_get_buf(cur)):match("agent%-") then return end -- you're in the code
  local file = fn.fnamemodify(fn.expand(path:match("^/") and path or ((cwd or fn.getcwd()) .. "/" .. path)), ":p")
  if fn.filereadable(file) ~= 1 then return end
  -- Avante-style reveal: pi's edit tool carries NO line numbers, so resolve the
  -- reveal line from the authoritative git diff instead — jump to the file's first
  -- changed hunk so the change is on-screen (signs mark the rest), not the file top.
  if not line and cwd then
    local rel = file:sub(1, #cwd + 1) == cwd .. "/" and file:sub(#cwd + 2) or path
    if not S.gitdiff[cwd] then git_changes(cwd) end
    local change = S.gitdiff[cwd] and S.gitdiff[cwd].bypath[rel]
    if change and change.hunks and change.hunks[1] then line = change.hunks[1].l1 end
  end
  local target = target_editor_win()
  if not target or vim.bo[api.nvim_win_get_buf(target)].modified then return end
  local key = file .. ":" .. tostring(line or 0)
  if S._follow == key then return end
  S._follow = key
  api.nvim_win_call(target, function()
    if fn.fnamemodify(api.nvim_buf_get_name(0), ":p") ~= file then
      pcall(vim.cmd, "edit " .. fn.fnameescape(file))
    end
    if line then pcall(api.nvim_win_set_cursor, target, { tonumber(line), 0 }); vim.cmd("normal! zz") end
  end)
end

-- reverse bridge: open the file referenced in the nearest fenced-code header
-- (```lang path:l1-l2). Opens in the main editor window, not the rail.
-- find a `path[:line]` token spanning the cursor column on one line (agent prose
-- often names files inline: "see agent-nvim/init.lua:409"). Requires a .ext or a
-- :line so ordinary words don't match. col is 0-indexed byte.
local function inline_ref(line, col)
  local i = 1
  while true do
    local s, e, tok = line:find("([%w%._%-/]+%.%w+:?%d*)", i)
    if not s then return nil end
    if col + 1 >= s and col + 1 <= e then return tok end
    i = e + 1
  end
end

local function chat_open_ref()
  if not (S.chatwin and api.nvim_win_is_valid(S.chatwin)) then return end
  local pos = api.nvim_win_get_cursor(S.chatwin)
  local cur = pos[1]
  local all = api.nvim_buf_get_lines(S.chatbuf, 0, -1, false)
  local s = cur
  while s >= 1 and not (all[s] and all[s]:match("^```")) do s = s - 1 end
  local loc = all[s] and all[s]:match("^```%S*%s+(%S+)")
  if not loc then
    -- no fenced-code file header — try an inline path:line under the cursor
    local tok = inline_ref(all[cur] or "", pos[2])
    if tok then
      local p, l1 = tok:match("^([^:]+):(%d+)")
      open_in_editor(S.selected and session_cwd(S.selected), p or tok, l1)
      return
    end
    vim.notify("agent-nvim: no file reference at cursor", vim.log.levels.INFO); return
  end
  local path, l1 = loc:match("^([^:]+):(%d+)")
  open_in_editor(nil, path or loc, l1)
end

-- extract an http(s) URL spanning the cursor column, trailing sentence
-- punctuation stripped. col is 0-indexed byte.
local function url_under_cursor(line, col)
  local i = 1
  while true do
    local s, e, u = line:find("(https?://[%w%._~:/%?#%[%]@!$&'()*+,;=%%~-]+)", i)
    if not s then return nil end
    if col + 1 >= s and col + 1 <= e then return (u:gsub("[%.,%)%]}>\"']+$", "")) end
    i = e + 1
  end
end

-- gx in the chat: open the URL under the cursor (PR / preview / docs links the
-- agent emits) via the system opener, in the work browser.
local function chat_open_url()
  if not (S.chatwin and api.nvim_win_is_valid(S.chatwin)) then return end
  local pos = api.nvim_win_get_cursor(S.chatwin)
  local line = api.nvim_buf_get_lines(S.chatbuf, pos[1] - 1, pos[1], false)[1] or ""
  local u = url_under_cursor(line, pos[2])
  if not u then vim.notify("agent-nvim: no URL at cursor", vim.log.levels.INFO); return end
  if vim.ui.open then vim.ui.open(u) else fn.jobstart({ "xdg-open", u }, { detach = true }) end
  vim.notify("agent-nvim: opening " .. u)
end

-- <CR>/gf on a chat edit row opens that file; exact hunk navigation lives in
-- the changes view. Other rows fall back to fenced-code file references.
local function chat_open()
  if not (S.chatwin and api.nvim_win_is_valid(S.chatwin)) then return end
  local nav = S.hunknav and S.hunknav[api.nvim_win_get_cursor(S.chatwin)[1]]
  if not nav then return chat_open_ref() end
  open_in_editor(S.selected and session_cwd(S.selected), nav.path, nil)
end

-- yank the single line under the cursor. markview conceals the ``` fence lines,
-- so the cursor at the top/bottom of a block sits on a fence delimiter in the
-- buffer even though you see code — redirect to the adjacent code line so yy
-- copies what you see, not "```".
local function chat_yank_line()
  if not (S.chatwin and api.nvim_win_is_valid(S.chatwin)) then return end
  local cur = api.nvim_win_get_cursor(S.chatwin)[1]
  local all = api.nvim_buf_get_lines(S.chatbuf, 0, -1, false)
  local yl = cur -- the line actually yanked (may differ from the cursor at a fence)
  if (all[cur] or ""):match("^```") then
    if all[cur + 1] and not all[cur + 1]:match("^```") then yl = cur + 1
    elseif all[cur - 1] and not all[cur - 1]:match("^```") then yl = cur - 1 end
  end
  local line = all[yl] or ""
  fn.setreg("+", line); fn.setreg('"', line)
  -- manual setreg doesn't fire TextYankPost, so flash the yanked line ourselves.
  -- Flash the line that was YANKED (not the cursor's fence line), in a dedicated
  -- ns, and at a priority ABOVE the chat's code-block bg (190) so it reads solid
  -- like a normal-buffer yank instead of being washed out on code lines.
  S.flashns = S.flashns or api.nvim_create_namespace("agent-yank-flash")
  pcall(vim.hl.range, S.chatbuf, S.flashns, "IncSearch",
    { yl - 1, 0 }, { yl - 1, 0 }, { regtype = "V", inclusive = true, timeout = 150, priority = 200 })
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

-- Copy the LAST agent reply's full text to the clipboard (Claude-Code parity —
-- "copy response"). Whole message, not just the code block under the cursor.
local function chat_yank_reply()
  local c = S.selected and S.chat[S.selected]
  if not (c and c.msgs) then vim.notify("agent-nvim: no reply to copy"); return end
  for i = #c.msgs, 1, -1 do
    if c.msgs[i].role == "assistant" then
      local text = c.msgs[i].text or ""
      fn.setreg("+", text); fn.setreg('"', text)
      vim.notify("agent-nvim: copied last agent reply (" .. #text .. " chars)")
      return
    end
  end
  vim.notify("agent-nvim: no agent reply to copy")
end

-- Copy the WHOLE conversation as role-labelled markdown — for handing the
-- transcript to another agent or pasting into the vault. Thinking is skipped
-- (it's dimmed noise in the chat; not useful downstream).
local function chat_yank_convo()
  local c = S.selected and S.chat[S.selected]
  if not (c and c.msgs and #c.msgs > 0) then vim.notify("agent-nvim: no conversation to copy"); return end
  local out = {}
  for _, m in ipairs(c.msgs) do
    local text = m.text or ""
    if text ~= "" then
      out[#out + 1] = (m.role == "user" and "## you" or "## agent")
      out[#out + 1] = text
      out[#out + 1] = ""
    end
  end
  local md = table.concat(out, "\n")
  fn.setreg("+", md); fn.setreg('"', md)
  vim.notify("agent-nvim: copied conversation (" .. #c.msgs .. " messages, " .. #md .. " chars)")
end

-- Cross-session search: grep every loaded transcript for a substring, pick a hit,
-- jump straight to that session + message. Claude Code has no cross-session
-- search — this is the orchestrator's "which agent mentioned X" move.
local function chat_search()
  local ok, q = pcall(vim.fn.input, { prompt = "search all sessions: " })
  if not ok or not q or q == "" then return end
  local ql, matches, unloaded = q:lower(), {}, {}
  for _, a in ipairs(S.roster) do
    local c = S.chat[a.id]
    if not (c and c.msgs and #c.msgs > 0) then
      -- transcripts load lazily on open, so an unopened session can't be searched
      unloaded[#unloaded + 1] = a.id
    end
    if c and c.msgs then
      for mi, m in ipairs(c.msgs) do
        for _, line in ipairs(vim.split(m.text or "", "\n", { plain = true })) do
          if line:lower():find(ql, 1, true) then
            local snip = vim.trim(line)
            if #snip > 56 then snip = snip:sub(1, 53) .. "…" end
            matches[#matches + 1] = { id = a.id, cwd = a.cwd, mi = mi,
              label = short_name(a.name) .. "  ·  " .. (m.role == "user" and "you: " or "") .. snip }
            break -- one hit per message
          end
        end
      end
    end
  end
  -- warm unopened transcripts so the NEXT search covers them: responses land in
  -- S.chat without touching the current view (get_entries only renders the
  -- selected session). One round-trip per session, bounded by the roster size.
  for _, id in ipairs(unloaded) do send({ type = "get_entries", session = id }) end
  local coverage = #unloaded > 0 and ("  ·  " .. #unloaded .. " now loading — search again to include") or ""
  if #matches == 0 then vim.notify("agent-nvim: no matches for '" .. q .. "'" .. coverage); return end
  vim.ui.select(matches, { prompt = "matches (" .. #matches .. ")" .. coverage, format_item = function(it) return it.label end },
    function(choice)
      if not choice then return end
      S.scroll_to_msg[choice.id] = choice.mi
      if choice.id ~= S.selected then view_session(choice.id, choice.cwd) else render_chat(false) end
    end)
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
load_plan = function(cwd)
  if not cwd or cwd == "" then return nil end -- nil cwd → malformed `git -C` call
  local dir = plandir(cwd)
  if not dir then return nil end
  local branch = fn.system({ "git", "-C", cwd, "branch", "--show-current" }):gsub("%s+$", "")
  -- A plan belongs to a ticket/feature branch. `main`/`master` is shared across
  -- repos and many old progress.json files recorded branch:"main", so matching on
  -- it leaks a stray plan onto every main-checkout session (e.g. the orchestrator).
  if branch == "" or branch == "main" or branch == "master" then return nil end
  for _, f in ipairs(fn.globpath(dir, "*.progress.json", false, true)) do
    local ok, data = pcall(function() return vim.json.decode(table.concat(fn.readfile(f), "\n")) end)
    if ok and type(data) == "table" and data.branch == branch then
      return { progress = data, key = fn.fnamemodify(f, ":t"):gsub("%.progress%.json$", "") }
    end
  end
  return nil
end

-- On session switch, keep the editor honest: a file open from ANOTHER session's
-- worktree is stale in the new context (the path may not even exist there), so
-- swap it for the new session's plan (if any) or a clean scratch. A file not
-- under any session's worktree (e.g. ~/nixos) is your own work — left untouched.
-- Runs via win_call so it never steals focus from the rail.
-- Session dashboard shown in the editor when a session has no plan open and no
-- edited file yet — instead of a bare empty buffer. Shows plan status + flow,
-- the worktree's changed files, and a bottom-right action box (open plan / app /
-- devenv / Linear ticket). Left unnamed (like enew) so lualine shows no filename
-- and reflect_context treats it as replaceable. Reused across sessions; the
-- editor follows the agent's edits away from it during a turn.
-- Does this cwd map to a registered cockpit context (so devenv/app shortcuts are
-- real)? "main" always; a daphen worktree only if it's in the contexts state.
local function cockpit_ctx_registered(cwd)
  local ctx = cockpit_context and cockpit_context(cwd)
  if not ctx then return nil end
  if ctx == "main" then return ctx end
  local ok, list = pcall(fn.readfile, (os.getenv("HOME") or "") .. "/.local/state/cockpit/contexts")
  if ok and list then for _, l in ipairs(list) do if l == ctx then return ctx end end end
  return nil
end

-- The active Linear cycle + its tickets, as cached by the orchestrator agent
-- (nvim can't reach Linear/MCP itself). Shape:
--   { cycle = { name, starts, ends, progress = { done, total } },
--     tickets = { { id, title, priority (0..4), state, slug }, ... } }
-- `slug` is the cockpit-add name (keeps the ticket prefix, e.g. every-1234-…).
local function read_cycle()
  local p = (os.getenv("HOME") or "") .. "/.local/state/lovable/cycle.json"
  if fn.filereadable(p) ~= 1 then return nil end
  local ok, data = pcall(function() return vim.json.decode(table.concat(fn.readfile(p), "\n")) end)
  if ok and type(data) == "table" then return data end
  return nil
end

local dash_keys
-- The session dashboard: the editor's resting view when a session has no file
-- open. A session HUD — its plan status + flow, its worktree's changed files, and
-- a bottom-right action box whose rows exist ONLY when their target does (devenv/
-- app only for a registered cockpit context, plan only with a plan, ticket only
-- with a ticket id). Reused across sessions; unnamed so lualine shows no filename.
local function show_scratch(win, cwd)
  if not (S.scratchbuf and api.nvim_buf_is_valid(S.scratchbuf)) then
    S.scratchbuf = api.nvim_create_buf(false, true)
    vim.bo[S.scratchbuf].buftype = "nofile"
    vim.bo[S.scratchbuf].bufhidden = "hide"
    vim.bo[S.scratchbuf].swapfile = false
  end
  local buf = S.scratchbuf
  -- text width = window minus its gutter (number/sign/fold cols). Using the full
  -- window width right-aligned the +/− columns past the text area, clipping −dels.
  local wi = fn.getwininfo(win)[1]
  local W = math.max(48, api.nvim_win_get_width(win) - ((wi and wi.textoff) or 0))
  local H = math.max(12, api.nvim_win_get_height(win))
  local lines, decor = {}, {}
  local function push(l) lines[#lines + 1] = l or ""; return #lines - 1 end
  local function hl(ln, grp, cs, ce) decor[#decor + 1] = { ln = ln, grp = grp, cs = cs or 0, ce = ce or -1 } end
  -- a small-caps accent section label + muted detail on one line
  local function section(label, detail)
    local ln = push("  " .. label .. (detail and ("   " .. detail) or ""))
    hl(ln, "AgentMuted")
    hl(ln, "AgentTitle", 2, 2 + #label)
    return ln
  end
  local nm = short_name(S.selected) or fn.fnamemodify(cwd, ":t")
  local tik = (S.selected or ""):match("%a+%-%d+")
  local ctx = cockpit_ctx_registered(cwd)
  local root = ctx == "main" -- the orchestrator (main checkout) → a fleet dashboard

  -- masthead: accent bar + session name, worktree path beneath
  push(""); push("")
  hl(push("  ▍ " .. nm .. (root and "  ·  orchestrator" or "")), "AgentAccent")
  hl(push(file_row(W - 2, "    ", fn.fnamemodify(cwd, ":~"))), "AgentMuted")
  push("")


  -- PLAN — only if the session has a plan
  local pl = load_plan(cwd)
  if pl and pl.progress then
    local pg = pl.progress
    local done, total = 0, 0
    for _, s in ipairs(pg.flow or {}) do total = total + 1; if s.status == "done" then done = done + 1 end end
    section("PLAN", pl.key .. " · " .. (pg.phase or "?") .. (total > 0 and ("   ◆ " .. done .. "/" .. total) or ""))
    -- #18-style flow gauge: a big progress bar under the header, count on the left.
    if total > 0 then
      local label = "      " .. done .. "/" .. total .. " "
      local barw = math.max(10, math.min(56, (W - 2) - #label))
      local btext, bsegs = progress_bar(done, total, barw, "AgentStream", "AgentDivider")
      local ln = push(label .. btext)
      hl(ln, "AgentMuted", 0, #label)
      for _, sg in ipairs(bsegs) do hl(ln, sg[3], sg[1] + #label, sg[2] + #label) end
    end
    local savail = math.max(12, (W - 2) - 8)
    for _, s in ipairs(pg.flow or {}) do
      local g = s.status == "done" and "●" or (s.status == "active" and "◐" or "○")
      local grp = s.status == "done" and "AgentStream" or (s.status == "active" and "AgentAccent" or "AgentIdle")
      local step = s.step or ""
      if #step > savail then step = step:sub(1, savail - 1) .. "…" end
      local ln = push("      " .. g .. " " .. step)
      hl(ln, "AgentFile"); hl(ln, grp, 6, 6 + #g)
    end
    push("")
  end

  -- ACTIONS — built BEFORE the changes list so the box height is known and the
  -- list can be capped to leave room. (A long diff used to push the box off the
  -- bottom of the window.) One source of truth drives both the box and the keymaps;
  -- a row is present only when its target exists.
  local home = os.getenv("HOME") or ""
  local acts = {}
  local function act(k, l, f) acts[#acts + 1] = { key = k, label = l, fn = f } end
  if pl and pl.key then
    act("p", "plan", function() pcall(function() require("plan-nvim").open(pl.key) end) end)
  end
  if ctx then
    act("d", "devenv", function()
      -- re-establish the session↔devenv link: ensure the tab exists, start the slice
      -- if it's down, route the fixed ports here, focus. Idempotent however it broke.
      fn.jobstart({ home .. "/.config/niri/scripts/cockpit-devenv", ctx }, { detach = true })
      vim.defer_fn(function() if refresh_devenv then refresh_devenv() end end, 1500)
    end)
    -- open the context's dev-preview URL in the work browser (+ focus it), via the
    -- cockpit config's cockpit_open_app hook — which computes the wt-proxy preview URL.
    -- The old action only launched browser-work, so it focused Helium but loaded nothing.
    act("a", "app", function()
      fn.jobstart({ "bash", "-c",
        'source "$HOME/.config/cockpit/config" 2>/dev/null && cockpit_open_app "$1"',
        "cockpit-app", ctx }, { detach = true })
    end)
  end
  if root then
    act("n", "session", function() if open_picker then open_picker() end end) -- start/pick a session
  end
  if tik then
    act("l", tik:upper(), function()
      local u = "https://linear.app/lovable/issue/" .. tik:upper()
      if vim.ui.open then vim.ui.open(u) else fn.jobstart({ "xdg-open", u }, { detach = true }) end
    end)
  end
  act("c", "changes", function()
    -- flip the rail's middle pane to the Changes view: the buffer must be SWAPPED
    -- into the window (render_changes only fills changesbuf), then focus + top.
    S.view = "changes"
    if S.chatwin and api.nvim_win_is_valid(S.chatwin) and S.changesbuf then
      api.nvim_win_set_buf(S.chatwin, S.changesbuf)
      if render_changes then render_changes() end
      pcall(api.nvim_set_current_win, S.chatwin)
      pcall(api.nvim_win_set_cursor, S.chatwin, { 1, 0 })
    end
  end)
  act("r", "refresh", function() show_scratch(win, cwd) end)
  local boxh = #acts + 2 -- ┌ … ┘ rows the box will occupy at the bottom

  local openmap, expand_ln, sessmap, ticketmap, teardownmap = {}, nil, {}, {}, {} -- file/toggle/session/ticket/teardown rows
  if root then
    -- ORCHESTRATOR fleet: the other sessions it coordinates, selectable (<CR>/o).
    local others = {}
    for _, a in ipairs(S.roster) do if a.id ~= S.selected then others[#others + 1] = a end end
    section("SESSIONS", #others == 0 and "none active" or (#others .. " active"))
    local nw = 0
    for _, a in ipairs(others) do nw = math.max(nw, #short_name(a.name)) end
    for _, a in ipairs(others) do
      local ss = session_state(a)
      local nm2 = short_name(a.name)
      local pl2 = S.plan[a.id]
      local prog = (pl2 and pl2.total and pl2.total > 0) and ("  ◆ " .. pl2.done .. "/" .. pl2.total) or ""
      -- STATIC status dot, not the animated spinner glyph: the dashboard is a
      -- snapshot (not re-rendered per frame), so a spinner frame would sit frozen
      -- and read as broken. The live spinner lives in the roster; here ● = working.
      local dot = ({ streaming = "●", needs_input = "◆", error = "✕" })[ss.key] or "○"
      local line = "  " .. dot .. " " .. nm2 .. string.rep(" ", nw - #nm2) .. "   " .. ss.label .. prog
      local ln = push(line)
      sessmap[ln] = { id = a.id, cwd = a.cwd }
      hl(ln, "AgentFile")                        -- name, neutral base
      hl(ln, ss.name, 2, 2 + #dot)               -- status dot, coloured
      hl(ln, "AgentMuted", 6 + #dot + nw, -1)    -- state + plan progress, muted
    end
    if #others == 0 then hl(push("      no other sessions · n starts one"), "AgentMuted") end
    push("")

    -- CYCLE + TICKETS from the agent-cached cycle.json. Tickets in priority order;
    -- <CR>/o on one confirms + cockpit-adds a session for it. Sessions already
    -- running for a ticket are marked ●.
    local cyc = read_cycle()
    if cyc and cyc.cycle then
      local cy = cyc.cycle
      local span = (cy.starts and cy.ends) and (" · " .. cy.starts .. "–" .. cy.ends) or ""
      local cprog = (cy.progress and cy.progress.total and cy.progress.total > 0)
        and ("   ◆ " .. (cy.progress.done or 0) .. "/" .. cy.progress.total) or ""
      section("CYCLE", (cy.name or "current") .. span .. cprog)
      -- split OPEN (actionable) from DONE — a finished ticket isn't something you
      -- kick off, so it goes in a dim group below, not mixed into the priority list.
      local open, done = {}, {}
      for _, t in ipairs(cyc.tickets or {}) do
        if t.done then done[#done + 1] = t else open[#open + 1] = t end
      end
      table.sort(open, function(x, y)
        local px = (x.priority == 0 or x.priority == nil) and 99 or x.priority
        local py = (y.priority == 0 or y.priority == nil) and 99 or y.priority
        if px ~= py then return px < py end
        return (x.id or "") < (y.id or "") -- stable tiebreak within a priority
      end)
      local have = {} -- ticket id → its live roster session entry (for ●-marker + teardown)
      for _, a in ipairs(S.roster) do
        local t = (a.name or ""):match("%a+%-%d+"); if t then have[t:upper()] = a end
      end
      local prigrp = { [1] = "AgentErr", [2] = "AgentAccent", [3] = "AgentFile", [4] = "AgentMuted" }
      local idw = 0
      for _, t in ipairs(open) do idw = math.max(idw, #(t.id or "")) end
      section("TICKETS", #open .. " open · ⏎ starts a session")
      local fit = math.max(1, math.min(#open, H - #lines - boxh - (#done > 0 and 4 or 3)))
      local cap = S.dash_expand and #open or fit
      for i = 1, cap do
        local t = open[i]
        local id = t.id or "?"
        local live = have[id:upper()]
        local mark = live and "●" or "○" -- ● = a session already exists for it
        local avail = math.max(10, (W - 2) - (4 + idw + 3 + 8))
        local title = t.title or ""
        if #title > avail then title = title:sub(1, avail - 1) .. "…" end
        local line = "  " .. mark .. " " .. id .. string.rep(" ", idw - #id) .. "   " .. title
        local ln = push(line)
        ticketmap[ln] = { id = id, slug = t.slug, live = live, title = t.title }
        hl(ln, "AgentFile")                                       -- id + title, neutral
        hl(ln, prigrp[t.priority] or "AgentMuted", 2, 2 + #mark)  -- priority-coloured marker
      end
      if #open > fit then
        expand_ln = push("      " .. (S.dash_expand and "⏶ show less" or ("… " .. (#open - fit) .. " more")) .. "   ⏎")
        hl(expand_ln, "AgentMuted")
      end
      -- DONE — dim. A done ticket that STILL has a session/worktree is offered for
      -- teardown (⊘ + ⏎); the rest are just ✓. Teardown-able ones sort first.
      if #done > 0 then
        table.sort(done, function(x, y)
          local hx = have[(x.id or ""):upper()] and 0 or 1
          local hy = have[(y.id or ""):upper()] and 0 or 1
          if hx ~= hy then return hx < hy end
          return (x.id or "") < (y.id or "")
        end)
        push("")
        section("DONE", tostring(#done))
        for i = 1, math.min(#done, 5) do
          local t = done[i]
          local sess = have[(t.id or ""):upper()]
          local mark = sess and "⊘" or ICON.check
          local suffix = sess and "   ⏎ teardown" or ""
          local ln = push("  " .. mark .. " " .. (t.id or "?") .. "  " .. (t.title or "") .. suffix)
          hl(ln, "AgentMuted")
          if sess then
            hl(ln, "AgentErr", 2, 2 + #mark) -- ⊘ flags a lingering session to clean up
            teardownmap[ln] = { id = sess.id, cwd = sess.cwd, ticket = t.id }
          end
        end
        if #done > 5 then hl(push("      … " .. (#done - 5) .. " more"), "AgentMuted") end
      end
      push("")
    end
  else
  -- CHANGES — the session worktree's diff (empty on main; "clean" for a known ctx).
  -- File rows are openable (<CR>/o); the list is capped to the rows left above the
  -- action box so the box stays on-screen, with a toggle line to expand/collapse.
  local ch = git_changes(cwd)
  if #ch > 0 then
    local ta, td = 0, 0
    for _, c in ipairs(ch) do ta = ta + c.add; td = td + c.del end
    section("CHANGES", #ch .. (#ch == 1 and " file · +" or " files · +") .. ta .. " -" .. td)
    local aw, dw = 0, 0
    for _, c in ipairs(ch) do aw = math.max(aw, #("+" .. c.add)); dw = math.max(dw, #("-" .. c.del)) end
    local fitcap = math.max(1, math.min(#ch, H - #lines - boxh - 3)) -- what fits above the box
    local cap = S.dash_expand and #ch or fitcap
    for i = 1, cap do
      local c = ch[i]
      local acol = string.rep(" ", aw - #("+" .. c.add)) .. "+" .. c.add
      local dcol = string.rep(" ", dw - #("-" .. c.del)) .. "-" .. c.del
      local line = file_row(W - 2, "      • ", c.path, acol, dcol)
      local ln = push(line)
      openmap[ln] = c.path -- <CR>/o opens it
      hl(ln, "AgentFile")
      hl(ln, "AgentMuted", 6, 9) -- the • bullet
      local ps, pe = line:find("%+%d+"); if ps then hl(ln, "AgentStream", ps - 1, pe) end
      local ms, me = line:find("%-%d+", (pe or 0) + 1); if ms then hl(ln, "AgentErr", ms - 1, me) end
    end
    if not S.dash_expand and #ch > fitcap then
      expand_ln = push("      … " .. (#ch - fitcap) .. " more   ⏎")
      hl(expand_ln, "AgentMuted")
    elseif S.dash_expand and #ch > fitcap then
      expand_ln = push("      ⏶ show less   ⏎")
      hl(expand_ln, "AgentMuted")
    end
    push("")
  elseif ctx then
    section("CHANGES", "working tree clean")
    push("")
  end
  end

  local labels, inner = {}, 0
  for _, a in ipairs(acts) do
    local s = "  " .. a.key .. "   " .. a.label .. "  "; labels[#labels + 1] = s; inner = math.max(inner, #s)
  end
  local box = { "┌" .. string.rep("─", inner) .. "┐" }
  for _, s in ipairs(labels) do box[#box + 1] = "│" .. s .. string.rep(" ", inner - #s) .. "│" end
  box[#box + 1] = "└" .. string.rep("─", inner) .. "┘"
  local leftpad = math.max(1, W - (inner + 2) - 2)
  local target = math.max(#lines + 1, H - #box - 1)
  while #lines < target do push("") end
  for bi, bl in ipairs(box) do
    local ln = push(string.rep(" ", leftpad) .. bl)
    hl(ln, "AgentMuted")
    if bi > 1 and bi <= #labels + 1 then hl(ln, "AgentAccent", leftpad + 5, leftpad + 6) end
  end

  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, S.ns, 0, -1)
  for _, d in ipairs(decor) do pcall(api.nvim_buf_add_highlight, buf, S.ns, d.grp, d.ln, d.cs, d.ce) end
  S.dash = { open = openmap, sessions = sessmap, tickets = ticketmap, teardown = teardownmap, expand_ln = expand_ln, cwd = cwd, win = win } -- <CR>/o targets
  dash_keys(buf, acts)
  pcall(api.nvim_win_set_buf, win, buf)
end

-- Bind the dashboard's action keys buffer-locally. Clear the full known set first
-- so a row that vanished (e.g. devenv when the session isn't a cockpit context)
-- can't leave a stale keymap behind. <CR>/o are context-sensitive: open the file
-- row under the cursor, toggle the …more/less line, else run the first action.
dash_keys = function(buf, acts)
  for _, k in ipairs({ "p", "d", "a", "l", "n", "c", "r", "<CR>", "o" }) do pcall(vim.keymap.del, "n", k, { buffer = buf }) end
  local function map(lhs, f) vim.keymap.set("n", lhs, f, { buffer = buf, nowait = true, silent = true }) end
  for _, a in ipairs(acts) do map(a.key, a.fn) end
  local function enter()
    local d = S.dash or {}
    local ln0 = api.nvim_win_get_cursor(0)[1] - 1
    if d.teardown and d.teardown[ln0] then
      local t = d.teardown[ln0]
      teardown_session(t.id, t.cwd)
      if d.win and api.nvim_win_is_valid(d.win) then vim.defer_fn(function() show_scratch(d.win, d.cwd) end, 500) end
    elseif d.tickets and d.tickets[ln0] then
      local t = d.tickets[ln0]
      if t.live then
        vim.notify("agent: " .. t.id .. " already has a session")
      elseif t.slug and t.slug ~= "" then
        -- cockpit-spawn = the full ticket kickoff in one command (same script any
        -- agent can call): cockpit context (worktree + devenv + nvim tab, registered,
        -- no focus steal) AND a seeded roster agent. One source of truth for "spawn a
        -- ticket", so the button and an agent's `cockpit-spawn` do the exact same thing.
        local seed = "Work " .. t.id .. (t.title and t.title ~= "" and (": " .. t.title) or "")
          .. "\n\nStart with /plan-ticket " .. t.id .. " to scope it, then implement."
        if vim.fn.confirm("Spawn a session for " .. t.id .. "?  (" .. t.slug .. ")", "&Yes\n&No", 2) == 1 then
          local home = os.getenv("HOME") or ""
          fn.jobstart({ home .. "/.local/bin/cockpit-spawn", t.slug, seed }, { detach = true })
          vim.notify("agent: spawning session · " .. t.slug)
        end
      else
        vim.notify("agent: " .. t.id .. " has no slug in cycle.json")
      end
    elseif d.sessions and d.sessions[ln0] then
      local s = d.sessions[ln0]; view_session(s.id, s.cwd) -- switch to the session under the cursor
    elseif d.open and d.open[ln0] then
      open_in_editor(d.cwd, d.open[ln0], nil) -- open the changed file under the cursor
    elseif d.expand_ln and ln0 == d.expand_ln then
      S.dash_expand = not S.dash_expand
      if d.win and api.nvim_win_is_valid(d.win) then show_scratch(d.win, d.cwd) end
    elseif acts[1] then
      acts[1].fn()
    end
  end
  map("<CR>", enter) -- also shadows the global treesitter <CR>
  map("o", enter)
end

-- Capture what the editor pane is showing for a session, so switching back
-- restores it. A real file → its abs path; the dashboard/scratch or an empty
-- buffer → nil (no file → the dashboard is this session's resting view).
capture_editor = function(session)
  if not session then return end
  local ed = target_editor_win()
  if not ed then return end
  S.editor = S.editor or {}
  local b = api.nvim_win_get_buf(ed)
  if S.scratchbuf and b == S.scratchbuf then
    S.editor[session] = nil
  else
    local n = api.nvim_buf_get_name(b)
    S.editor[session] = (n ~= "" and vim.bo[b].buftype == "") and fn.fnamemodify(n, ":p") or nil
  end
end

-- The editor director — the SINGLE decision of what the editor shows for the
-- active session: restore the file it had open (captured on switch-away), else
-- the dashboard. Per-session storage means one session's file can never bleed
-- into another's, so there are no stale/owner/blank/greeter heuristics.
reflect_context = function(cwd)
  if not cwd or cwd == "" then return end
  local ed = target_editor_win()
  if not ed then return end
  local want = S.editor and S.selected and S.editor[S.selected]
  if want and fn.filereadable(want) == 1 then
    if fn.fnamemodify(api.nvim_buf_get_name(api.nvim_win_get_buf(ed)), ":p") ~= fn.fnamemodify(want, ":p") then
      api.nvim_win_call(ed, function() pcall(vim.cmd, "edit " .. fn.fnameescape(want)) end)
    end
  else
    show_scratch(ed, cwd)
  end
end

-- Return the editor to the active session's dashboard (forget the open file so
-- the director stops restoring it). The way back after opening a file.
local function to_dashboard()
  if not S.selected then return end
  S.editor = S.editor or {}
  S.editor[S.selected] = nil
  local cwd = session_cwd(S.selected)
  if cwd and cwd ~= "" then reflect_context(cwd) end
end

-- Map a session cwd to its cockpit context name (~/work/lovable → "main";
-- ~/work/lovable.daphen-<ctx> → "<ctx>"). nil if it isn't a lovable worktree.
cockpit_context = function(cwd)
  local home = os.getenv("HOME") or ""
  if cwd == home .. "/work/lovable" then return "main" end
  return fn.fnamemodify(cwd or "", ":t"):match("^lovable%.daphen%-(.+)$")
end

-- Full teardown of a session (vs the light `x` = stop only): stop the pi session,
-- then tear down its cockpit context — close its tabs in every cockpit window,
-- deregister it, and `wt remove` the worktree (cockpit-remove refuses on dirty/
-- unmerged trees, so unshipped work is never lost). Confirms first; never main.
teardown_session = function(id, cwd)
  local ctx = cwd and cockpit_context(cwd)
  local what = ctx or short_name(id)
  local msg = "Tear down " .. what .. "?   stop session"
    .. (ctx and ctx ~= "main" and ("  +  close context  +  wt remove daphen/" .. ctx) or "")
  if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then return end
  if id then send({ type = "stop", session = id }); if S.selected == id then S.selected = nil end end
  if ctx and ctx ~= "main" then
    fn.jobstart({ (os.getenv("HOME") or "") .. "/.config/niri/scripts/cockpit-remove", ctx }, { detach = true })
  end
  vim.notify("agent-nvim: tearing down " .. what)
  render_roster()
end

-- Sync the cockpit to the rail's active session: switch the devenv tab + the
-- active-context marker (what the Super+T picker reads) to this session's
-- context — WITHOUT touching the nvim tab (you're already in the rail). Only for
-- sessions that map to a real, registered cockpit context (or the main checkout).
-- S.cockpit_ctx guards the reverse sync (Super+T → rail) from ping-ponging back.
cockpit_sync = function(cwd)
  local ctx = cockpit_context(cwd)
  if not ctx then return end
  local home = os.getenv("HOME") or ""
  if ctx ~= "main" then
    local ok, list = pcall(fn.readfile, home .. "/.local/state/cockpit/contexts")
    local found = false
    if ok then for _, l in ipairs(list) do if l == ctx then found = true; break end end end
    if not found then return end
  end
  if S.cockpit_ctx == ctx then return end -- already synced (avoids a switch loop)
  S.cockpit_ctx = ctx
  fn.jobstart({ "sh", "-c",
    "COCKPIT_SWITCH_WINDOWS=devenv " .. home .. "/.config/niri/scripts/cockpit-switch " .. fn.shellescape(ctx) },
    { detach = true })
end

-- Reverse sync: when the cockpit's active context changes (you switched via the
-- Super+T picker), select the matching session in the rail. S.cockpit_ctx guards
-- against reacting to the rail's own cockpit_sync writes (no ping-pong).
local cockpit_watch
on_cockpit_active = function()
  local home = os.getenv("HOME") or ""
  local ok, lines = pcall(fn.readfile, home .. "/.local/state/cockpit/active")
  if not ok or not lines[1] then return end
  local ctx = vim.trim(lines[1])
  if ctx == "" or ctx == S.cockpit_ctx then return end
  for _, a in ipairs(S.roster) do
    if cockpit_context(a.cwd) == ctx then
      S.cockpit_ctx = ctx -- pre-set so view_session's cockpit_sync no-ops (no loop)
      if a.id ~= S.selected then view_session(a.id, a.cwd) end
      return
    end
  end
end
-- Super+i jump-by-NAME: a notification names a session (short_name), which the
-- dispatch drops into cockpit/agent-jump. Selecting it here — rather than via a
-- context switch — reaches sessions with NO cockpit tab too (wt-spawned agents,
-- sub-agents): the roster is cross-context, so any tab's rail can show any session.
-- view_session's cockpit_sync switches context when the cwd IS a registered one,
-- and no-ops otherwise, so both tabbed and tab-less sessions land correctly.
on_agent_jump = function()
  local home = os.getenv("HOME") or ""
  local ok, lines = pcall(fn.readfile, home .. "/.local/state/cockpit/agent-jump")
  if not ok or not lines[1] then return end
  local want = vim.trim(lines[1])
  if want == "" then return end
  for _, a in ipairs(S.roster) do
    if a.id == want or short_name(a.name) == want then
      if a.id ~= S.selected then view_session(a.id, a.cwd) end
      -- land IN the rail: focus the chat pane so the turn is right there to read
      if S.chatwin and api.nvim_win_is_valid(S.chatwin) then
        pcall(api.nvim_set_current_win, S.chatwin)
      end
      return
    end
  end
end
local function start_cockpit_watch()
  if cockpit_watch then return end
  local dir = (os.getenv("HOME") or "") .. "/.local/state/cockpit"
  if fn.isdirectory(dir) == 0 then return end
  cockpit_watch = uv.new_fs_event()
  if not cockpit_watch then return end
  -- watch the DIR: cockpit-switch replaces `active` via atomic rename, which a
  -- file-level watch would miss.
  cockpit_watch:start(dir, {}, function(err, filename)
    if err then return end
    if filename == "active" or filename == ".active.tmp" then
      vim.schedule(on_cockpit_active)
    elseif filename == "agent-jump" then
      vim.schedule(on_agent_jump)
    end
  end)
end

local function parse_git_diff(lines)
  local files, bypath, current, oldpath, hunk = {}, {}, nil, nil, nil
  local function file(path)
    if not bypath[path] then
      bypath[path] = { path = path, add = 0, del = 0, hunks = {} }
      files[#files + 1] = bypath[path]
    end
    return bypath[path]
  end
  for _, line in ipairs(lines or {}) do
    if line:match("^diff %-%-git ") then
      current, oldpath, hunk = nil, nil, nil
    elseif line:match("^%-%-%- ") then
      oldpath = line:sub(5):gsub("^a/", "")
    elseif line:match("^%+%+%+ ") then
      local path = line:sub(5):gsub("^b/", "")
      if path == "/dev/null" then path = oldpath end
      current = path and file(path) or nil
      hunk = nil
    elseif current and line:match("^@@ ") then
      local os, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      oc, nc = tonumber(oc ~= "" and oc or 1), tonumber(nc ~= "" and nc or 1)
      ns, os = tonumber(ns), tonumber(os)
      hunk = {
        old_l1 = os, old_l2 = oc == 0 and os or os + oc - 1,
        l1 = ns, l2 = nc == 0 and ns or ns + nc - 1,
        add = 0, del = 0,
      }
      current.hunks[#current.hunks + 1] = hunk
    elseif current and hunk and line:sub(1, 1) == "+" then
      hunk.add = hunk.add + 1
      current.add = current.add + 1
    elseif current and hunk and line:sub(1, 1) == "-" then
      hunk.del = hunk.del + 1
      current.del = current.del + 1
    end
  end
  table.sort(files, function(a, b) return a.path < b.path end)
  return { files = files, bypath = bypath }
end

refresh_git_changes = function(cwd, path)
  if not cwd or fn.isdirectory(cwd) ~= 1 then return end
  if path and not S.gitdiff[cwd] then path = nil end
  local ok, signs = pcall(require, "hunk-nvim.signs")
  local base = ok and signs.base_for and signs.base_for(cwd) or "HEAD"
  if not base or base == "" then base = "HEAD" end
  local args = { "git", "-C", cwd, "diff", "--no-color", "--no-ext-diff", "--unified=0", base }
  if path and path ~= "" then args[#args + 1] = "--"; args[#args + 1] = path end
  local previous = S.diff_jobs[cwd]
  if previous and previous > 0 then pcall(fn.jobstop, previous) end
  S.diff_jobs[cwd] = nil
  local output = {}
  local job = fn.jobstart(args, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do if line ~= "" then output[#output + 1] = line end end
    end,
    on_exit = function(id, code)
      if S.diff_jobs[cwd] ~= id then return end
      S.diff_jobs[cwd] = nil
      if code ~= 0 then return end
      vim.schedule(function()
        local parsed = parse_git_diff(output)
        if path and S.gitdiff[cwd] then
          local cache = S.gitdiff[cwd]
          cache.bypath[path] = nil
          for _, change in ipairs(parsed.files) do cache.bypath[change.path] = change end
          cache.files = {}
          for _, change in pairs(cache.bypath) do cache.files[#cache.files + 1] = change end
          table.sort(cache.files, function(a, b) return a.path < b.path end)
        else
          S.gitdiff[cwd] = parsed
        end
        if S.selected and session_cwd(S.selected) == cwd then
          if S.view == "changes" then render_changes() else render_chat(false) end
        end
      end)
    end,
  })
  if job and job > 0 then S.diff_jobs[cwd] = job end
end

git_changes = function(cwd)
  local cache = cwd and S.gitdiff[cwd]
  if cwd and not cache and not S.diff_jobs[cwd] then refresh_git_changes(cwd) end
  return cache and cache.files or {}
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
-- Refresh ONE session's cached plan (a sync git + glob + plan-file reads). Broken out
-- so a session switch can refresh just the session it lands on instead of the whole
-- roster — the full sweep is O(sessions) sync git calls and was the swap lag.
refresh_plan_one = function(a)
  -- Sub-agents share the parent's worktree, so load_plan would hand them the ticket's
  -- plan too — but the plan belongs to the MAIN agent. Subs get none.
  if is_subagent(a.name) then
    S.plan[a.id] = false
  elseif a.cwd and a.cwd ~= "" then
    local plan = load_plan(a.cwd)
    if plan then
      local flow, done = plan.progress.flow or {}, 0
      for _, s in ipairs(flow) do if s.status == "done" then done = done + 1 end end
      S.plan[a.id] = { done = done, total = #flow, phase = plan.progress.phase, key = plan.key }
    else
      S.plan[a.id] = false
    end
  end
end
refresh_plans = function()
  for _, a in ipairs(S.roster) do refresh_plan_one(a) end
end

-- Devenv link health, cached per CONTEXT (not per session — the slice is a property
-- of the worktree, and a family of sessions shares one cwd). Async: `cockpit-devenv
-- status` shells out per unique ctx + `orphans` once, and each result schedules a
-- roster repaint. Mirrors refresh_plans' cadence but runs on the idle tick too, since
-- a slice can start/stop while agents are idle.
refresh_devenv = function()
  -- devenv is a lovable-monorepo concept — only the lovable scope has slices. On any
  -- other scope (personal/nixos), skip entirely: no chips, and crucially no orphan
  -- surfacing (cockpit-devenv orphans scans ~/work/lovable*, so a personal rail was
  -- flagging lovable devenvs as "orphans" because no personal session claims them).
  if scope ~= "lovable" then S.devenv = {}; S.orphans = {}; return end
  local home = os.getenv("HOME") or ""
  local script = home .. "/.config/niri/scripts/cockpit-devenv"
  if fn.executable(script) == 0 then return end
  local seen = {}
  for _, a in ipairs(S.roster) do
    local ctx = a.cwd and a.cwd ~= "" and cockpit_context(a.cwd)
    if ctx and not seen[ctx] then
      seen[ctx] = true
      local out = {}
      pcall(fn.jobstart, { script, "status", ctx }, {
        stdout_buffered = true,
        on_stdout = function(_, d) for _, l in ipairs(d or {}) do if l ~= "" then out[#out + 1] = l end end end,
        on_exit = function()
          local st = (out[1] or ""):gsub("%s+", "")
          if st ~= "" and S.devenv[ctx] ~= st then
            S.devenv[ctx] = st
            vim.schedule(function() if render_roster then render_roster() end end)
          end
        end,
      })
    end
  end
  -- orphans = running slices whose ctx has no session in the roster
  local oout = {}
  pcall(fn.jobstart, { script, "orphans" }, {
    stdout_buffered = true,
    on_stdout = function(_, d) for _, l in ipairs(d or {}) do if l ~= "" then oout[#oout + 1] = l end end end,
    on_exit = function()
      local orphans = {}
      for _, dir in ipairs(oout) do
        local ctx = cockpit_context(dir)
        if ctx and not seen[ctx] then orphans[#orphans + 1] = ctx end
      end
      S.orphans = orphans
      vim.schedule(function() if render_roster then render_roster() end end)
    end,
  })
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
    local W = rail_width()
    local plan = load_plan(cwd)
    local changes = git_changes(cwd)
    local bypath = {}
    for _, c in ipairs(changes) do bypath[c.path] = c end
    local inner = W - 6 -- match box()'s inner (│  … │ with 2-space pads)

    -- Emit file rows INTO a box via add(): status colour on the leading dot only,
    -- path neutral, +adds green / −dels red, right-aligned + head-truncated to fit
    -- the box's inner width. segs are byte columns relative to the row text.
    local function box_files(add, rows)
      local aw, dw = 0, 0
      for _, r in ipairs(rows) do
        if r.add then
          aw = math.max(aw, #("+" .. r.add)); dw = math.max(dw, #("-" .. r.del))
        end
      end
      for _, r in ipairs(rows) do
        local indent = r.dot .. " "
        local text, segs
        if not r.add then
          text = file_row(inner, indent, r.path)
          segs = { { 0, #text, "AgentFile" }, { 0, #r.dot, r.grp } }
        else
          local as, ds = "+" .. r.add, "-" .. r.del
          local acol = string.rep(" ", aw - #as) .. as
          local dcol = string.rep(" ", dw - #ds) .. ds
          text = file_row(inner, indent, r.path, acol, dcol)
          segs = { { 0, #text, "AgentFile" }, { 0, #r.dot, r.grp } }
          local ps, pe = text:find("%+%d+")
          if ps then segs[#segs + 1] = { ps - 1, pe, "AgentStream" } end
          local ms, me = text:find("%-%d+", (pe or 0) + 1)
          if ms then segs[#segs + 1] = { ms - 1, me, "AgentErr" } end
        end
        -- File row only (navigable to its first hunk). Per-hunk ↳ breakdown is
        -- intentionally NOT listed here — the file view stays a compact files+counts
        -- summary; hunk-level detail belongs in the chat during real-time editing.
        local first = r.hunks and r.hunks[1]
        add(text, segs, r.path, first and first.l1)
      end
    end

    -- diffstat as (text, segs) for placement inside a box; nil when no changes.
    local function diffstat()
      local ta, td = 0, 0
      for _, c in ipairs(changes) do ta = ta + (c.add or 0); td = td + (c.del or 0) end
      if #changes == 0 then return nil end
      local s = #changes .. (#changes == 1 and " file   +" or " files   +") .. ta .. "  -" .. td
      local segs = { { 0, #s, "AgentMuted" } }
      local ps, pe = s:find("%+%d+")
      if ps then segs[#segs + 1] = { ps - 1, pe, "AgentStream" } end
      local ms, me = s:find("%-%d+", (pe or 0) + 1)
      if ms then segs[#segs + 1] = { ms - 1, me, "AgentErr" } end
      return s, segs
    end

    if plan then
      local pg = plan.progress
      box(push, decor, W, ICON.plan, "PLAN · " .. plan.key .. " · " .. (pg.phase or "?"), function(add)
        local ds, dsegs = diffstat(); if ds then add(ds, dsegs) end
        local flow = pg.flow or {}
        if #flow > 0 then
          local done = 0
          for _, s in ipairs(flow) do if s.status == "done" then done = done + 1 end end
          local label = done .. "/" .. #flow .. " "
          local btext, bsegs = progress_bar(done, #flow, math.max(8, inner - #label - 1))
          local text = label .. btext
          local segs = { { 0, #label, "AgentMuted" } }
          for _, sg in ipairs(bsegs) do segs[#segs + 1] = { sg[1] + #label, sg[2] + #label, sg[3] } end
          add(text, segs)
        end
        for _, step in ipairs(flow) do
          local g = step.status == "done" and "●" or (step.status == "active" and "◐" or "○")
          local grp = step.status == "done" and "AgentStream" or (step.status == "active" and "AgentAccent" or "AgentIdle")
          local t = g .. " " .. (step.step or "")
          -- status colour on the DOT only; the step text stays neutral (not a green wash)
          add(t, { { 0, #g, grp }, { #g, #t, "AgentFile" } })
        end
      end, nil, false, false, true, true)
      local rows = {}
      for _, pf in ipairs(pg.planned or {}) do
        local c = bypath[pf.file]
        rows[#rows + 1] = {
          dot = pf.status == "done" and "●" or (pf.status == "touched" and "◐" or "○"),
          grp = pf.status == "done" and "AgentStream" or (pf.status == "touched" and "AgentAccent" or "AgentIdle"),
          path = pf.file, add = c and c.add, del = c and c.del, hunks = c and c.hunks,
        }
        bypath[pf.file] = nil
      end
      box(push, decor, W, ICON.files, "FILES", function(add) box_files(add, rows) end, nil, true, false, true, false)
      local drift = {}
      for _, c in pairs(bypath) do drift[#drift + 1] = c end
      if #drift > 0 then
        table.sort(drift, function(a, b) return a.path < b.path end)
        box(push, decor, W, ICON.warn, "UNPLANNED", function(add)
          for _, c in ipairs(drift) do
            box_files(add, { { dot = "⚠", grp = "AgentAttn", path = c.path, add = c.add, del = c.del, hunks = c.hunks } })
          end
        end, nil, false, false, true, true)
      end
    else
      box(push, decor, W, ICON.changes, "CHANGES · " .. base(cwd), function(add)
        local ds, dsegs = diffstat(); if ds then add(ds, dsegs) end
        if #changes == 0 then
          add("no changes on this branch", { { 0, #"no changes on this branch", "AgentMuted" } })
        else
          local rows = {}
          for _, c in ipairs(changes) do
            rows[#rows + 1] = { dot = ICON.file_change, grp = "AgentIdle", path = c.path, add = c.add, del = c.del, hunks = c.hunks }
          end
          box_files(add, rows)
        end
      end, nil, true, false, true)
    end

    local mcp = session_mcp(cwd)
    if #mcp > 0 then
      box(push, decor, W, ICON.mcp, "MCP", function(add)
        for _, s in ipairs(mcp) do
          local t = ICON.mcp .. " " .. s
          add(t, { { 0, #t, "AgentIdle" } })
        end
      end, nil, false, false, true, true)
    end
  end

  vim.bo[S.changesbuf].modifiable = true
  api.nvim_buf_set_lines(S.changesbuf, 0, -1, false, lines)
  vim.bo[S.changesbuf].modifiable = false
  api.nvim_buf_clear_namespace(S.changesbuf, S.ns, 0, -1)
  for _, d in ipairs(decor) do
    -- bg first (low-priority line fill = the box surface), so the fg char highlights
    -- layer on top. honour cs/ce so sub-range fg highlights land (the +adds/−dels).
    if d.bg then
      -- fill EXACTLY the box's own width (the line's bytes), not the whole window —
      -- a line_hl_group would bleed the surface past the right border to the edge.
      local endc = #(lines[d.line + 1] or "")
      if endc > 0 then
        pcall(api.nvim_buf_set_extmark, S.changesbuf, S.ns, d.line, 0, { end_col = endc, hl_group = d.bg, priority = 40 })
      end
    end
    if d.fg then pcall(api.nvim_buf_add_highlight, S.changesbuf, S.ns, d.fg, d.line, d.cs or 0, d.ce or -1) end
  end
  S.changes_open = openmap
  if S.chatwin and api.nvim_win_is_valid(S.chatwin) and S.view == "changes" then
    -- no winbar: it showed "changes · <full worktree name>", a redundant path (the
    -- boxes + composer already identify the session). The PLAN box title carries context.
    vim.wo[S.chatwin].winbar = ""
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

-- ]f / [f — jump to the next/prev changed-file row in the changes view (rows are
-- interleaved with plan steps / mcp lines, so plain j/k is slow). Wraps.
local function changes_file_jump(delta)
  if not (S.chatwin and api.nvim_win_is_valid(S.chatwin) and S.view == "changes") then return end
  local cur0 = api.nvim_win_get_cursor(S.chatwin)[1] - 1
  local keys = {}
  for k in pairs(S.changes_open) do keys[#keys + 1] = k end
  if #keys == 0 then return end
  table.sort(keys)
  local target
  if delta > 0 then
    for _, k in ipairs(keys) do if k > cur0 then target = k; break end end
    target = target or keys[1]
  else
    for i = #keys, 1, -1 do if keys[i] < cur0 then target = keys[i]; break end end
    target = target or keys[#keys]
  end
  api.nvim_win_set_cursor(S.chatwin, { target + 1, 2 })
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
answer = function(payload)
  local ap = S.selected and S.pending[S.selected]
  if not ap then return end
  -- echo the reply into the chat so there's a record of what you answered
  local label = payload.cancelled and "cancelled"
    or (payload.confirmed ~= nil and (payload.confirmed and "approved" or "declined"))
    or (payload.value ~= nil and tostring(payload.value)) or nil
  if label and label ~= "" then
    local c = S.chat[S.selected] or { msgs = {} }
    c.msgs[#c.msgs + 1] = { role = "user", text = "↳ " .. label }
    S.chat[S.selected] = c
  end
  if ap.mock then
    vim.notify("mock approval → " .. vim.inspect(payload))
  else
    local msg = { type = "extension_ui_response", session = ap.session, id = ap.id }
    for k, v in pairs(payload) do msg[k] = v end
    send(msg)
  end
  S.pending[S.selected] = nil
  render_roster(); render_chat(true)
  apply_prompt_mode() -- prompt cleared → re-enable + insert-ready composer
end

-- Bind the answer keys (y/n confirm, 1-9 select) on the chat buffer ONLY while
-- an approval card is showing for the selected session — otherwise they'd steal
-- count prefixes and yanks from normal chat navigation.
local approval_keys_on = false
sync_approval_keys = function()
  if not (S.chatbuf and api.nvim_buf_is_valid(S.chatbuf)) then return end
  local want = prompt_mode().kind == "choose" -- y/n/number only for confirm/select
  if want == approval_keys_on then return end
  approval_keys_on = want
  local keys = { "y", "n", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
  local bufs = { S.chatbuf, S.composerbuf }
  if not want then
    for _, b in ipairs(bufs) do
      if b then for _, k in ipairs(keys) do pcall(vim.keymap.del, "n", k, { buffer = b }) end end
    end
    return
  end
  local yes = function() if S.selected and S.pending[S.selected] then answer({ confirmed = true }) end end
  local no = function() if S.selected and S.pending[S.selected] then answer({ confirmed = false }) end end
  local function pick(d)
    return function()
      local a = S.selected and S.pending[S.selected]
      if a and a.method == "select" and a.options and a.options[d] then answer({ value = a.options[d] }) end
    end
  end
  -- both the chat and the (disabled, cursor-hidden) composer answer, so you don't
  -- have to move — the composer is in normal mode during confirm/select prompts.
  for _, b in ipairs(bufs) do
    if b and api.nvim_buf_is_valid(b) then
      local o = { buffer = b, nowait = true, silent = true }
      vim.keymap.set("n", "y", yes, o); vim.keymap.set("n", "n", no, o)
      for d = 1, 9 do vim.keymap.set("n", tostring(d), pick(d), o) end
    end
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
  -- floats are read-only navigation surfaces — hide the cursor here too. One fixed
  -- group (cleared each open) — floats are modal, so per-buffer named groups just
  -- leaked one augroup per float opened.
  local grp = api.nvim_create_augroup("AgentFloatCursor", { clear = true })
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
    " roster   attention queue · z show all · / filter by name · s search all transcripts",
    "          j/k move · <CR> open · ]a/[a next needing you · n new · . cwd",
    "          x stop · a abort · <C-r> restart pi (reload MCP) · p peek · <Esc> clear filter",
    " chat     <Tab> changes · ]m/[m message · za/zM/zR fold · yr reply · yc convo",
    "          gf open ref (hunk · fence · inline path:line) · gx open url · i compose",
    " changes  <CR> open file · ]f/[f next file · <Tab> back to chat · r refresh",
    " composer <CR> send · <C-s> send(insert) · <C-f> attach · <C-↑/↓> scroll chat",
    "          <C-x> drop attachments · q roster · / commands",
    "",
    " anywhere R focus roster · <leader>a toggle · <leader>A quick-message active session",
    "          <leader>as (visual) send selection · :AgentSend / File / Diff / Diagnostics",
    "",
    " slash    rail: /abort /steer /clear /diff /plan /retry /model /think /reload /help",
    "          pi:   /mcp-auth /mcp · skills/templates · (TUI cmds like /reload don't run via rpc)",
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
  xmap("]f", function() changes_file_jump(1) end)
  xmap("[f", function() changes_file_jump(-1) end)
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
  cmap("zM", function() chat_fold_all(true) end)  -- collapse every message
  cmap("zR", function() chat_fold_all(false) end) -- expand every message
  cmap("Y", function() chat_yank_code() end)
  cmap("yy", function() chat_yank_line() end)  -- yank the single line you see (skips ``` fences)
  cmap("yr", function() chat_yank_reply() end) -- yank (copy) the last agent reply
  cmap("yc", function() chat_yank_convo() end) -- yank the whole conversation as md
  cmap("gf", function() chat_open() end)
  cmap("gx", function() chat_open_url() end) -- open the URL under the cursor
  cmap("<C-o>", function() nav_session(-1) end) -- session jumplist: back
  cmap("<C-i>", function() nav_session(1) end)  -- session jumplist: forward
  cmap("<CR>", function() chat_open() end)
  cmap("<Esc>", function()
    -- a pending approval? Esc cancels it (real: sends {cancelled}; mock: just clears)
    if S.selected and S.pending[S.selected] then answer({ cancelled = true }); return end
    if S.win and api.nvim_win_is_valid(S.win) then api.nvim_set_current_win(S.win) end
  end)
  -- y/n/digit answer keys are bound only while an approval card is up (see
  -- sync_approval_keys) so they don't swallow count prefixes (22k) or yank (y)

  -- The chat gutter is ALWAYS a fixed 2-col statuscolumn — the width never changes,
  -- so chat text stays put (col 5 inner, aligned with the composer input) regardless
  -- of focus. Within those 2 cols we paint the RELATIVE line number when the chat
  -- window is focused (for count-motions like 12j) and blanks when it isn't — so the
  -- numbers appear on focus without ever shifting the text. (The old native
  -- relativenumber toggle changed numberwidth and shifted the text col 2↔3.)
  -- relnum for a VISIBLE line ≤ window height, so 2 digits always fit; the cursor
  -- line (relnum 0) stays blank. g:statusline_winid is the window being drawn.
  _G.__AgentChatStc = function()
    -- focused = the chat window is the actually-current window. (Don't use
    -- g:statusline_winid — it isn't set during 'statuscolumn' eval, only statusline/
    -- winbar, so the old check always failed and the gutter was permanently blank.)
    if not (S.chatwin and api.nvim_get_current_win() == S.chatwin) then return "  " end
    local r = vim.v.relnum
    if r == 0 then return "  " end
    if r > 99 then return "99" end
    return string.format("%2d", r)
  end
  local CHAT_STC = "%!v:lua.__AgentChatStc()"
  local chatnum = api.nvim_create_augroup("AgentChatNum", { clear = true })
  api.nvim_create_autocmd({ "WinEnter", "BufEnter", "WinLeave", "BufLeave" }, {
    group = chatnum, buffer = S.chatbuf,
    callback = function()
      if S.chatwin and api.nvim_win_is_valid(S.chatwin) then
        vim.wo[S.chatwin].number = false
        vim.wo[S.chatwin].relativenumber = false
        -- re-assigning the statuscolumn repaints it, so focus in/out (this autocmd
        -- fires on the chat window's WinEnter/WinLeave) flips numbers ↔ blanks.
        vim.wo[S.chatwin].statuscolumn = CHAT_STC
      end
    end,
  })

  -- hover-follow: as the cursor lands on a hunk range, scroll the file (if it's
  -- already open) to that line — no focus steal, no opening files
  api.nvim_create_autocmd("CursorMoved", {
    group = chatnum, buffer = S.chatbuf,
    callback = function()
      if not (S.chatwin and api.nvim_win_is_valid(S.chatwin)) then return end
      local nav = S.hunknav and S.hunknav[api.nvim_win_get_cursor(S.chatwin)[1]]
      if nav then reveal_file(S.selected and session_cwd(S.selected), nav.path, nav.line) end
    end,
  })

  -- composer keymaps
  -- <C-u>/<C-d> (and <C-Up>/<C-Down>) scroll the TRANSCRIPT half-page without
  -- leaving the composer — scroll_chat drives the chat window via win_call, so
  -- the composer cursor never moves. Mapping C-u/C-d in insert mode trades away
  -- readline kill-line / unindent there (fine for a short message input).
  local function scroll_chat(up)
    if not (S.chatwin and api.nvim_win_is_valid(S.chatwin)) then return end
    local keys = api.nvim_replace_termcodes(up and "<C-u>" or "<C-d>", true, false, true)
    pcall(api.nvim_win_call, S.chatwin, function() vim.cmd("normal! " .. keys) end)
  end
  vim.keymap.set({ "n", "i" }, "<C-u>", function() scroll_chat(true) end, { buffer = S.composerbuf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-d>", function() scroll_chat(false) end, { buffer = S.composerbuf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-Up>", function() scroll_chat(true) end, { buffer = S.composerbuf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-Down>", function() scroll_chat(false) end, { buffer = S.composerbuf, nowait = true, silent = true })
  -- <C-t> toggles the roster expand/collapse from the input too (not just the roster
  -- pane), in insert and normal — so you never have to leave the composer to do it.
  vim.keymap.set({ "n", "i" }, "<C-t>", toggle_roster_view, { buffer = S.composerbuf, nowait = true, silent = true })
  vim.keymap.set("n", "<CR>", composer_send, { buffer = S.composerbuf, nowait = true, silent = true })
  vim.keymap.set("i", "<C-s>", function() vim.cmd("stopinsert"); composer_send() end, { buffer = S.composerbuf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-x>", function() clear_attachments() end, { buffer = S.composerbuf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-f>", function() vim.cmd("stopinsert"); M.attach_file() end, { buffer = S.composerbuf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-v>", paste_clipboard, { buffer = S.composerbuf, nowait = true, silent = true })
  -- Ctrl-o/Ctrl-i = session jumplist (back/forward through visited sessions), in both
  -- modes. Buffer-local so plain nvim keeps the real jumplist. <C-i>≠<Tab> under
  -- kitty's enhanced keyboard protocol, so this doesn't shadow the composer's <Tab>.
  vim.keymap.set({ "n", "i" }, "<C-o>", function() nav_session(-1) end, { buffer = S.composerbuf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-i>", function() nav_session(1) end, { buffer = S.composerbuf, nowait = true, silent = true })
  vim.keymap.set("n", "q", function()
    save_draft()
    if S.win and api.nvim_win_is_valid(S.win) then api.nvim_set_current_win(S.win) end
  end, { buffer = S.composerbuf, nowait = true })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = S.composerbuf,
    -- render_chips (not just composer_resize) so the top pad extmark is re-anchored
    -- at row 0 every edit — otherwise it drifts down with inserted lines and draws
    -- a phantom blank line mid-buffer.
    callback = function() render_chips(); composer_placeholder(); sl_update() end,
  })
  api.nvim_create_autocmd("InsertLeave", { buffer = S.composerbuf, callback = sl_close })
  -- Robustness: always re-derive the composer state (editable + placeholder) from
  -- the current S.selected when the composer is entered, so a missed render can
  -- never leave you stuck showing "open a session first" while a session is open.
  api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    buffer = S.composerbuf,
    callback = function() composer_placeholder() end,
  })

  -- Slash picker: while it's open, these drive it; otherwise they fall through to
  -- their normal insert-mode behaviour (newline / esc / literal tab).
  local function passthru(keys)
    api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "n", false)
  end
  -- <CR> in insert sends (picker open → accept the completion instead). Newlines
  -- are a normal-mode action (o/O), so the input stays a one-keystroke send.
  vim.keymap.set("i", "<CR>", function()
    if not sl_accept() then vim.cmd("stopinsert"); composer_send() end
  end, { buffer = S.composerbuf, nowait = true })
  -- Esc, Claude-Code style: interrupt a running turn; otherwise pull the last
  -- sent message back into the composer to edit and resend. is_working() also
  -- catches the pre-first-token "thinking" window via the roster status.
  local function is_working()
    if S.selected and S.stream[S.selected] and S.stream[S.selected] ~= "" then return true end
    for _, a in ipairs(S.roster) do if a.id == S.selected then return a.status == "streaming" end end
    return false
  end
  local function esc_action()
    -- Esc while the agent is working: interrupt the turn AND immediately send any
    -- queued message — so BOTH your messages land in context (the interrupted
    -- turn + the queued follow-up), like Claude Code. Idle → rewind.
    if is_working() then
      local sid = S.selected
      send({ type = "abort", session = sid })
      S.stream[sid] = nil
      if S.turn_active then S.turn_active[sid] = nil end
      local q = sid and S.queued and S.queued[sid]
      if q and q ~= "" then
        S.queued[sid] = nil
        local c = S.chat[sid] or { msgs = {} }
        c.msgs[#c.msgs + 1] = { role = "user", text = q }
        S.chat[sid] = c
        -- Send AFTER the abort settles: firing the prompt in the same tick races
        -- pi's turn teardown and the prompt gets dropped (the bug — it interrupted
        -- but never sent the queued item). A short defer lands it on a ready pi.
        vim.defer_fn(function() send({ type = "prompt", session = sid, message = q }) end, 450)
        vim.notify("interrupted — sending your queued message")
      else
        vim.notify("agent: interrupted")
      end
      render_chat(false)
      return true
    end
    -- idle → TRUE rewind: agentd truncates the session to before the last user
    -- turn and respawns pi; the "rewound" event brings the removed message back
    -- into the composer (see handle). Falls back to a local restore if offline.
    if S.selected and S.connected then
      send({ type = "rewind", session = S.selected })
      return true
    end
    local last = S.selected and S.last_sent and S.last_sent[S.selected]
    if last and last ~= "" then
      api.nvim_buf_set_lines(S.composerbuf, 0, -1, false, vim.split(last, "\n", { plain = true }))
      render_chips(); composer_placeholder()
      if S.composerwin and api.nvim_win_is_valid(S.composerwin) then
        api.nvim_set_current_win(S.composerwin)
        pcall(api.nvim_win_set_cursor, S.composerwin, { api.nvim_buf_line_count(S.composerbuf), 0 })
        vim.cmd("startinsert!")
      end
      return true
    end
    return false
  end
  vim.keymap.set("i", "<Esc>", function()
    if sl_open() then sl_close(); return end
    -- Esc from insert just returns to normal mode, like everywhere else in vim —
    -- never interrupts. Interrupting the agent is a normal-mode action (n <Esc> →
    -- esc_action below), so it can't fire while you're mid-sentence in the composer.
    passthru("<Esc>")
  end, { buffer = S.composerbuf, nowait = true })
  vim.keymap.set("n", "<Esc>", function()
    if not esc_action() then pcall(vim.cmd, "nohlsearch") end
  end, { buffer = S.composerbuf, nowait = true, silent = true })
  vim.keymap.set("i", "<C-n>", function() if not sl_move(1) then passthru("<C-n>") end end, { buffer = S.composerbuf, nowait = true })
  vim.keymap.set("i", "<C-p>", function() if not sl_move(-1) then passthru("<C-p>") end end, { buffer = S.composerbuf, nowait = true })
  -- C-hjkl from insert: leave insert and jump to the adjacent panel. C-j/C-k also
  -- drive the slash picker while it's open.
  vim.keymap.set("i", "<C-j>", function() if not sl_move(1) then passthru("<Esc><C-w>j") end end, { buffer = S.composerbuf, nowait = true })
  vim.keymap.set("i", "<C-k>", function() if not sl_move(-1) then passthru("<Esc><C-w>k") end end, { buffer = S.composerbuf, nowait = true })
  vim.keymap.set("i", "<C-h>", "<Esc><C-w>h", { buffer = S.composerbuf, nowait = true })
  vim.keymap.set("i", "<C-l>", "<Esc><C-w>l", { buffer = S.composerbuf, nowait = true })
  vim.keymap.set("i", "<Tab>", function() if not sl_move(1) then toggle_view() end end, { buffer = S.composerbuf, nowait = true })
  vim.keymap.set("n", "<Tab>", function() toggle_view() end, { buffer = S.composerbuf, nowait = true, silent = true })
  vim.keymap.set("i", "<S-Tab>", function() if not sl_move(-1) then passthru("<S-Tab>") end end, { buffer = S.composerbuf, nowait = true })

  -- roster keymaps
  local function map(lhs, fn_) vim.keymap.set("n", lhs, fn_, { buffer = S.buf, nowait = true, silent = true }) end
  local function move(delta) S.focus = S.focus + delta; render_roster() end
  map("j", function() move(1) end)
  map("k", function() move(-1) end)
  map("<Down>", function() move(1) end)
  map("<Up>", function() move(-1) end)
  map("g", function() S.focus = 1; render_roster() end)
  map("G", function() S.focus = #S.displayed; render_roster() end)
  -- Enter opens the session AND drops you in its composer (insert mode), ready
  -- to type — even if it was already the active one (then just focus, no reload).
  map("<CR>", function()
    local a = S.displayed[S.focus]
    if not a then return end
    if a.id ~= S.selected then view_session(a.id, a.cwd) end
    focus_composer()
  end)
  map("i", function() focus_composer() end)
  map("n", function() open_picker() end)
  map(".", function() local d = fn.getcwd(); start_session(fn.fnamemodify(d, ":t"), d) end)
  map("x", function() -- stop the session (light: keeps the worktree + devenv to resume)
    local a = S.displayed[S.focus]
    if a then send({ type = "stop", session = a.id }); if S.selected == a.id then S.selected = nil end end
  end)
  map("X", function() -- full teardown: stop + close context + wt remove (confirms)
    local a = S.displayed[S.focus]
    if a then teardown_session(a.id, a.cwd) end
  end)
  map("a", function() local a = S.displayed[S.focus]; if a then send({ type = "abort", session = a.id }); S.stream[a.id] = nil; render_chat(false) end end)
  -- d: re-establish (or jump to) the focused session's devenv link — same gesture as
  -- the dashboard `d`. The chip tells you whether it'll start or just focus.
  map("d", function()
    local a = S.displayed[S.focus]
    if not (a and a.cwd and a.cwd ~= "") then return end
    local ctx = cockpit_context(a.cwd)
    if not ctx then return end
    local home = os.getenv("HOME") or ""
    fn.jobstart({ home .. "/.config/niri/scripts/cockpit-devenv", ctx }, { detach = true })
    vim.defer_fn(function() if refresh_devenv then refresh_devenv() end end, 1500)
  end)
  map("<C-o>", function() nav_session(-1) end) -- session jumplist: back
  map("<C-i>", function() nav_session(1) end)  -- session jumplist: forward
  -- z / <C-t>: expand (every session) ⇄ collapse (attention queue — the default)
  map("z", toggle_roster_view)
  map("<C-t>", toggle_roster_view)
  -- / filters the roster by session name (searches every session); esc clears.
  map("/", function()
    local ok, q = pcall(vim.fn.input, { prompt = "filter sessions: ", default = S.roster_filter })
    if ok then S.roster_filter = q or ""; S.focus = 1; render_roster() end
  end)
  map("<Esc>", function()
    if S.roster_filter ~= "" then S.roster_filter = ""; S.focus = 1; render_roster() end
  end)
  map("s", function() chat_search() end) -- grep every transcript → jump to the hit
  map("p", function() M.peek() end)
  -- ]a / [a — cycle to the next/prev session that needs YOU (pending approval or
  -- error), across the whole roster, and open it. Juggling many agents: jump
  -- straight to whoever is waiting rather than hunting the roster.
  local function attention_jump(delta)
    local q = {}
    for _, a in ipairs(S.roster) do
      if S.pending[a.id] or a.status == "error" then q[#q + 1] = a end
    end
    if #q == 0 then vim.notify("agent-nvim: nothing needs you"); return end
    local at = 0
    for i, a in ipairs(q) do if a.id == S.selected then at = i break end end
    local nxt = q[((at - 1 + delta) % #q) + 1]
    if nxt.id ~= S.selected then view_session(nxt.id, nxt.cwd) end
    focus_composer()
  end
  map("]a", function() attention_jump(1) end)
  map("[a", function() attention_jump(-1) end)
  map("r", function() if S.selected then send({ type = "get_entries", session = S.selected }) end end)
  -- <C-r>: restart the focused session's pi (reload mcp.json / new MCP servers) —
  -- the clean one-key replacement for the x+. dance.
  map("<C-r>", function()
    local a = S.displayed[S.focus]
    local sid = (a and a.id) or S.selected
    reload_session(sid, sid and session_cwd(sid))
  end)
  map("?", function() M.help() end)
  map("q", function() M.close() end)

  -- hide the cursor while in the roster (focus ring stands in for it)
  local grp = api.nvim_create_augroup("AgentRailCursor", { clear = true })
  api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = grp, buffer = S.buf,
    callback = function()
      if not S.saved_gcr then S.saved_gcr = vim.o.guicursor end
      vim.o.guicursor = "a:AgentCursorRoster"
      -- (S.roster_active is computed in render_roster from the current window)
      -- focusing the roster to switch sessions → show them all (collapses on leave).
      -- Gated on S.built: nvim_win_set_buf during M.open fires BufEnter here before
      -- the chat/composer windows exist — render_roster then shrinks the roster to
      -- fit its (empty) content, and the next `belowright split` dies with E36
      -- "not enough room", aborting the rail half-built. Only render once the rail
      -- is fully constructed (i.e. a real user focus, not construction).
      if S.built then
        if not S.roster_pinned_open then S.show_all = true end -- auto-expand (pinned already shows all)
        if render_roster then render_roster() end
      end
    end,
  })
  api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = grp, buffer = S.buf,
    callback = function()
      if S.saved_gcr then vim.o.guicursor = S.saved_gcr end
      if S.built then
        if not S.roster_pinned_open then S.show_all = false end -- collapse on blur UNLESS pinned open
        -- deferred: at WinLeave the roster is STILL the current window, so a
        -- synchronous render would recompute roster_active=true and flash the
        -- highlight back on. Schedule it so focus has settled to the new window.
        if render_roster then vim.schedule(render_roster) end
      end
    end,
  })

  -- Guard the rail panes: only their OWN buffer may live in a rail window. Any picker
  -- (<leader>ff, <C-f>, …), a raw :edit, or cockpit_open_plan can DISPLAY a file in a
  -- rail window — sometimes WITHOUT focusing it, so checking only the focused window
  -- missed it and the file clobbered the pane (that's how files kept landing in the
  -- roster/composer). Instead sweep EVERY rail window on any buffer/window enter: if a
  -- pane holds a foreign buffer, restore its own buffer and bounce the intruder to the
  -- editor. Scheduled so it runs after the open settles; the bounce re-fires this but
  -- the panes are correct by then, so it's a no-op (no loop).
  local function bounce(win, cur)
    local ed = target_editor_win and target_editor_win()
    if ed and ed ~= win and api.nvim_buf_is_valid(cur) then pcall(api.nvim_win_set_buf, ed, cur) end
  end
  local function enforce_rail_panes()
    if not S.built then return end
    for _, c in ipairs({ { S.win, S.buf }, { S.composerwin, S.composerbuf } }) do
      local win, want = c[1], c[2]
      if win and api.nvim_win_is_valid(win) and want and api.nvim_buf_is_valid(want) then
        local cur = api.nvim_win_get_buf(win)
        if cur ~= want then
          pcall(api.nvim_win_set_buf, win, want)
          bounce(win, cur)
        end
      end
    end
    -- chat pane: chatbuf AND changesbuf are both legit; anything else is an intruder
    if S.chatwin and api.nvim_win_is_valid(S.chatwin) then
      local cur = api.nvim_win_get_buf(S.chatwin)
      if cur ~= S.chatbuf and cur ~= S.changesbuf then
        if api.nvim_buf_is_valid(S.chatbuf) then pcall(api.nvim_win_set_buf, S.chatwin, S.chatbuf) end
        bounce(S.chatwin, cur)
      end
    end
  end
  api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinEnter" }, {
    group = grp,
    callback = vim.schedule_wrap(enforce_rail_panes),
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

--------------------------------------------------------------------------------
-- open / close
--------------------------------------------------------------------------------
function M.open()
  ensure_buf()
  if S.win and api.nvim_win_is_valid(S.win) then api.nvim_set_current_win(S.win); return end

  vim.cmd("botright vsplit") -- rail on the right (more reading whitespace there)
  S.win = api.nvim_get_current_win()
  api.nvim_win_set_buf(S.win, S.buf)
  api.nvim_win_set_width(S.win, math.max(40, math.min(120, math.floor(vim.o.columns * 0.40)))) -- 40% of the window, capped at 120 cols
  vim.wo[S.win].winfixwidth = true
  vim.wo[S.win].number = false; vim.wo[S.win].relativenumber = false; vim.wo[S.win].signcolumn = "no"
  vim.wo[S.win].foldcolumn = "0"
  -- 2-col left gutter, IDENTICAL to the chat window's, so the roster box and the
  -- chat/changes boxes share the same left margin + width (see the W = win-4 below,
  -- matching rail_width) — every box in the rail lines up.
  vim.wo[S.win].statuscolumn = "  "
  vim.wo[S.win].wrap = true
  vim.wo[S.win].cursorline = false
  vim.wo[S.win].winhighlight = "WinSeparator:AgentDivider"
  -- pane separation via a blank gap, not a ─ rule: blank the horizontal separator
  -- chars (the line that read as a "divider under the box") + eob, keeping only the
  -- thin vertical │ side border.
  vim.wo[S.win].fillchars = "eob: ,horiz: ,horizup: ,horizdown: "

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
  vim.wo[S.chatwin].statuscolumn = "%!v:lua.__AgentChatStc()" -- 2-col gutter; relnum on focus, blank off (see __AgentChatStc)
  vim.wo[S.chatwin].fillchars = "eob: "
  -- MDNS scopes the rail's markdown styling to this window AND carries WinSeparator
  -- (see set_hl) — it supersedes winhighlight, so we don't set winhighlight here.
  pcall(api.nvim_win_set_hl_ns, S.chatwin, MDNS)

  vim.cmd("belowright split")
  S.composerwin = api.nvim_get_current_win()
  api.nvim_win_set_buf(S.composerwin, S.composerbuf)
  api.nvim_win_set_height(S.composerwin, 1)
  vim.wo[S.composerwin].winfixheight = true
  vim.wo[S.composerwin].number = false; vim.wo[S.composerwin].relativenumber = false; vim.wo[S.composerwin].signcolumn = "no"
  vim.wo[S.composerwin].foldcolumn = "0"; vim.wo[S.composerwin].wrap = true
  -- wrap at word boundaries, not mid-word. NO breakindent: the composer text has no
  -- per-line indent, so the fixed 5-col statuscolumn already lands wrapped rows at the
  -- input column (col 5) on its own — and breakindent + a statuscolumn can miscompute
  -- the wrapped-row width and wrap early (an orphaned word on its own row).
  vim.wo[S.composerwin].linebreak = true; vim.wo[S.composerwin].breakindent = false
  -- prompt marker only on the very first physical row (virtnum==0 keeps it off
  -- wrapped continuation rows of a long first line)
  -- 5-col gutter: the › prompt sits at col 2 (the box-border column) and the input
  -- starts at col 5 (the box-content column), so the composer lines up with the chat
  -- text + box content above it, and the input gets left padding.
  vim.wo[S.composerwin].statuscolumn = "%#AgentAccent#%{v:lnum==1&&v:virtnum==0?'  ›  ':'     '}"
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
  start_cockpit_watch() -- Super+T context switches → select the matching session

  -- Track terminal focus so desktop_notify stays silent while you're in nvim (the
  -- roster already shows the change) and only toasts once you've tabbed away.
  -- SHARED across instances: every cockpit tab is a separate nvim all wired to the
  -- same agentd, so a per-instance flag let a BACKGROUND tab toast while you sat in
  -- the focused one. rail_focus_mark writes this nvim's pid to a shared file on
  -- focus (clears it on blur/exit); desktop_notify suppresses while ANY live rail
  -- holds it. So "a rail is focused" is global, not per-window.
  S.nvim_focused = true
  rail_focus_mark(true)
  local fgrp = api.nvim_create_augroup("AgentRailFocus", { clear = true })
  api.nvim_create_autocmd("FocusGained", { group = fgrp, callback = function()
    S.nvim_focused = true
    rail_focus_mark(true)
    -- a focus redraw can leave the composer mis-sized (win_text_height transient);
    -- recompute once the layout settles.
    vim.defer_fn(function() pcall(composer_resize) end, 50)
  end })
  api.nvim_create_autocmd("FocusLost", { group = fgrp, callback = function()
    S.nvim_focused = false
    rail_focus_mark(false)
  end })
  api.nvim_create_autocmd("VimLeavePre", { group = fgrp, callback = function() rail_focus_mark(false) end })

  connect(function() send({ type = "list_sources" }); render() end)
  vim.defer_fn(function() if S.win and api.nvim_win_is_valid(S.win) then refresh_plans(); render_roster() end end, 300)
  render()
  -- rail is now fully constructed: focus autocmds may resize/expand from here on
  S.built = true
  -- Focus already landed on the roster during construction (set_current_win
  -- above), but the expand-on-focus autocmd was gated out because S.built was
  -- still false then — so mirror it now: a roster you're focused on shows ALL
  -- sessions, not just the attention queue (which hides an already-selected
  -- idle session, reading as "nothing needs attention" on startup).
  if api.nvim_get_current_win() == S.win then
    S.roster_active = true
    S.show_all = true
    render_roster()
  end
end

function M.close()
  S.built = false
  save_draft()
  stop_spin()
  if S.editorwin and api.nvim_win_is_valid(S.editorwin) then
    vim.wo[S.editorwin].winhighlight = S.editor_wh or ""
  end
  S.editorwin = nil
  if S.saved_gcr then vim.o.guicursor = S.saved_gcr end
  -- Guarantee a non-rail window survives the close: if the rail is the only split
  -- (e.g. the editor was closed / the plan took the whole layout), closing the last
  -- rail window throws E444. Open a scratch window first so there's something left.
  local rail = {}
  for _, k in ipairs({ "win", "chatwin", "composerwin" }) do
    if S[k] and api.nvim_win_is_valid(S[k]) then rail[S[k]] = true end
  end
  local survivor = false
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if not rail[w] then survivor = true; break end
  end
  if not survivor then pcall(vim.cmd, "topleft new") end
  for _, w in ipairs({ "composerwin", "chatwin", "win" }) do
    if S[w] and api.nvim_win_is_valid(S[w]) then pcall(api.nvim_win_close, S[w], true) end
    S[w] = nil
  end
end

function M.toggle()
  if S.win and api.nvim_win_is_valid(S.win) then M.close() else M.open() end
end

-- The rail's active-session status for the lualine — state · plan progress ·
-- model · cost. The session id (every-2585) is NOT repeated here; the lualine's
-- project component already shows it. Was the composer winbar; moved down.
function M.statusline()
  if not S.selected then return "" end
  local a
  for _, x in ipairs(S.roster) do if x.id == S.selected then a = x break end end
  if not a then return "▸ " .. short_name(S.selected) end
  local ss = session_state(a)
  local parts = { ss.glyph .. " " .. ss.label }
  local pl = S.plan[a.id]
  if pl and pl.total and pl.total > 0 then parts[#parts + 1] = "◆ " .. pl.done .. "/" .. pl.total end
  return table.concat(parts, " · ")
end

-- Just the active session's plan progress (◆ done/total) for the lualine — the
-- "work items", moved down out of the composer winbar (which keeps only the live
-- working state). Empty when there's no active session or no plan.
function M.plan_chip()
  if not S.selected then return "" end
  local pl = S.plan[S.selected]
  if pl and pl.total and pl.total > 0 then return "◆ " .. pl.done .. "/" .. pl.total end
  return ""
end

--------------------------------------------------------------------------------
-- setup
--------------------------------------------------------------------------------
function M.setup(opts)
  opts = opts or {}
  load_qsicons()
  target_editor_win()
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
  api.nvim_create_autocmd("User", {
    pattern = "FileWatcherChanged",
    callback = function(event)
      local cwd = S.selected and session_cwd(S.selected)
      local path = event.data and event.data.path
      if not cwd or not path or path:sub(1, #cwd + 1) ~= cwd .. "/" then return end
      local rel = path:sub(#cwd + 2)
      -- fast path: async, per-file git diff + hunk signs ~75ms after the write
      local timer = S.diff_timers[cwd] or uv.new_timer()
      S.diff_timers[cwd] = timer
      timer:stop()
      timer:start(75, 0, vim.schedule_wrap(function() refresh_git_changes(cwd, rel) end))
      -- live-follow: track the agent into the editor AS it writes (not at turn end),
      -- coalesced so a multi-file burst doesn't thrash the window. Leading+trailing
      -- throttle: jump ~130ms after the first change (once the diff above has landed
      -- so follow_edit finds the hunk line), then at most once per 600ms, always
      -- ending on the newest file. Cheap — follow_edit reads the in-memory diff (no
      -- git spawn), self-guards focus (no steal while you're editing), dedups repeats.
      S.follow_pending = { cwd = cwd, path = path }
      if not S.follow_cd then
        local function fire()
          local p = S.follow_pending; S.follow_pending = nil
          if p then follow_edit(p.cwd, p.path, nil) end
        end
        vim.defer_fn(fire, 130)
        S.follow_cd = uv.new_timer()
        S.follow_cd:start(600, 0, vim.schedule_wrap(function()
          if S.follow_cd then S.follow_cd:stop(); pcall(function() S.follow_cd:close() end) end
          S.follow_cd = nil
          if S.follow_pending then fire() end
        end))
      end
    end,
  })

  api.nvim_create_user_command("AgentRail", function() M.toggle() end, {})
  api.nvim_create_user_command("AgentReconnect", function()
    S.connected = false
    pcall(function() if S.pipe then S.pipe:close() end end)
    S.pipe, S.readbuf, S.connecting = nil, "", false
    render_roster()
    connect(function() send({ type = "list_sources" }) end)
  end, {})
  api.nvim_create_user_command("AgentReroot", function(o) reroot(o.args) end, { nargs = 1 })
  api.nvim_create_user_command("AgentDash", to_dashboard, {}) -- editor back to the session dashboard
  -- global: jump the editor to the active session's dashboard from ANY buffer
  -- (no-ops when there's no session, so it's a safe always-on binding). <leader>D
  -- rather than gd — bare gd is LSP go-to-definition.
  vim.keymap.set("n", "<leader>D", to_dashboard, { desc = "Agent: session dashboard" })
  api.nvim_create_user_command("AgentFollow", function()
    S.follow_edits = not (S.follow_edits ~= false)
    vim.notify("agent-nvim: live-follow edits " .. (S.follow_edits and "on" or "off"))
  end, {})
  api.nvim_create_user_command("AgentSend", function() M.send_range() end, { range = true })
  api.nvim_create_user_command("AgentSendFile", function() M.send_file() end, {})
  api.nvim_create_user_command("AgentSendDiff", function() M.send_diff() end, {})
  api.nvim_create_user_command("AgentSendDiagnostics", function() M.send_diagnostics() end, {})
  api.nvim_create_user_command("AgentMsg", function() M.send_message() end, {})
  -- Open a file in a real editor window, NEVER a rail buffer: open_in_editor skips
  -- every agent-* window and makes a fresh vsplit if only the rail is up. The
  -- review-pr skill calls this (`:AgentEdit <path>`) so the review .md can't land in
  -- the composer/chat even when a rail pane is focused.
  api.nvim_create_user_command("AgentEdit", function(o) open_in_editor(nil, o.args, nil) end,
    { nargs = 1, complete = "file" })
  -- preview the approval card without a real agent: :AgentMockApproval [confirm|select|input]
  api.nvim_create_user_command("AgentMockApproval", function(o)
    M.open()
    if not S.selected then
      if not S.roster or #S.roster == 0 then S.roster = { { id = "mock", name = "mock-0000", cwd = fn.getcwd(), status = "idle" } } end
      S.selected = S.roster[1].id
    end
    local sid = S.selected
    local samples = {
      confirm = { method = "confirm", title = "Approve adding this test cleanup to the plan boundary?",
        message = "useDsFrameSelection.test.ts is outside the plan's surface area, but it tests the code being removed — leaving it fails CI.",
        session = sid, id = "mock", mock = true },
      select = { method = "select", title = "How should the boundary grow?",
        message = "The test file is outside scope.",
        options = { "approve & add to boundary", "decline, find another way", "skip the file" },
        session = sid, id = "mock", mock = true },
      input = { method = "input", title = "Name the new view wrapper?", message = "Used as the component + file name.",
        session = sid, id = "mock", mock = true },
    }
    S.pending[sid] = samples[o.args ~= "" and o.args or "confirm"] or samples.confirm
    render_roster(); render_chat(true)
    apply_prompt_mode()
  end, { nargs = "?", complete = function() return { "confirm", "select", "input" } end })

  -- R (normally Replace mode — unused here) → jump straight to the roster from
  -- anywhere. M.open focuses the roster if the rail is already up, else opens it.
  vim.keymap.set("n", "R", function() M.open() end, { desc = "Focus agent roster" })

  -- Remember which rail pane you were last in, so returning to the rail with
  -- <C-l> lands you back there (e.g. the composer) instead of nvim's positional
  -- guess. Native <C-w>l picks the rightward window by cursor row, which loses
  -- your place in the stacked rail.
  local function rail_set()
    local r = {}
    for _, k in ipairs({ "win", "chatwin", "composerwin" }) do
      if S[k] and api.nvim_win_is_valid(S[k]) then r[S[k]] = true end
    end
    return r
  end
  api.nvim_create_autocmd("WinEnter", {
    callback = function()
      if rail_set()[api.nvim_get_current_win()] then
        S.last_rail_win = api.nvim_get_current_win()
      end
    end,
  })
  -- Rail-aware window motion: if a directional move lands you IN the rail from the
  -- editor, jump to the pane you last used (last_rail_win) instead of nvim's
  -- positional guess — so returning from the editor keeps your place, regardless of
  -- which direction the rail sits or which motion you use. Bound on both <C-h>/<C-l>
  -- and the raw <C-w>h/<C-w>l so mouse-free navigation of any style is covered.
  -- Intentional jumps (R → roster, M.open) don't go through here, so they're honored.
  local function wincmd_rail_aware(dir)
    local rail = rail_set()
    local was_rail = rail[api.nvim_get_current_win()]
    -- Capture the remembered pane BEFORE the move: wincmd fires WinEnter on the
    -- pane it lands on (positionally, usually the roster), whose recorder would
    -- overwrite S.last_rail_win to that pane before we get to read it.
    local remembered = S.last_rail_win
    vim.cmd("wincmd " .. dir)
    if not was_rail and rail[api.nvim_get_current_win()]
      and remembered and rail[remembered] then
      api.nvim_set_current_win(remembered)
    end
  end
  for _, d in ipairs({ "h", "l" }) do
    vim.keymap.set("n", "<C-" .. d .. ">", function() wincmd_rail_aware(d) end,
      { desc = "Window " .. d .. " (rail-aware)" })
    vim.keymap.set("n", "<C-w>" .. d, function() wincmd_rail_aware(d) end,
      { desc = "Window " .. d .. " (rail-aware)" })
  end
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
  -- Open by default. Scope (which daemon) is still auto-detected — AGENT_SCOPE or
  -- the lovable niri workspace → lovable, else personal — but the rail always opens,
  -- rather than depending on that (fragile) detection to even show up. Opt out with
  -- AGENT_RAIL_NOAUTOSTART=1 or setup({ autostart = false }).
  local autostart = opts.autostart
  if autostart == nil then autostart = vim.env.AGENT_RAIL_NOAUTOSTART == nil end
  if autostart then
    -- The rail owns the editor's default view (per-session dashboard), so tell
    -- plan-nvim not to auto-open the plan on boot (it raced boot and clobbered the
    -- roster). The plan is still one keypress away — `p` on the dashboard.
    vim.g.plan_nvim_no_autoopen = true
    local RAIL_BUFS = { ["agent-rail"] = 1, ["agent-chat"] = 1, ["agent-changes"] = 1, ["agent-composer"] = 1 }
    local function boot()
      -- A session / `-S` / kitty-session restore can leave the tab with stray
      -- windows — rail-husk panes AND ordinary file windows (the last-edited note),
      -- any of which otherwise pollute the rail layout, e.g. a restored markdown
      -- file ending up in the roster pane. Collapse to ONE window (closes every
      -- stray, whatever its buffer), wipe rail-husk buffers so M.open recreates them
      -- fresh, then build a clean rail. (boot() only — M.open itself must never
      -- :only, since it's also the interactive toggle.)
      pcall(vim.cmd, "silent! only")
      for _, b in ipairs(api.nvim_list_bufs()) do
        if RAIL_BUFS[fn.fnamemodify(api.nvim_buf_get_name(b), ":t")] then
          pcall(api.nvim_buf_delete, b, { force = true })
        end
      end
      S.win, S.chatwin, S.composerwin = nil, nil, nil
      S.buf, S.chatbuf, S.changesbuf, S.composerbuf = nil, nil, nil, nil
      M.open()
    end
    -- schedule so it runs after VimEnter's session restore, not during it
    if vim.v.vim_did_enter == 1 then
      vim.schedule(boot)
    else
      api.nvim_create_autocmd("VimEnter", { once = true, callback = function() vim.schedule(boot) end })
    end
  end
end

return M
