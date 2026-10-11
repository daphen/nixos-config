-- Cockpit — the rail for orchestrating agentd sessions.
-- agents. Three stacked windows in one column:
--   • roster  (top, sticky)   — sessions with live state, focus-ring selection
--   • chat    (middle, scrolls)— the active session's transcript, markdown+TS
--   • composer(bottom, grows)  — a real editable buffer with attachment chips
--
-- Persisted window mode selects scope; launch environment is only a fallback.
-- QML work watches two daemons; this client uses agentd-lovable, not agentd-work.
--
-- Rail keys — roster:  j/k move · <CR> open · ]a/[a next needing you · n new
--                      . cwd · x stop · a abort · <C-r> restart pi · z all · / filter · s search · r refresh · ? help · q close
--          — chat:     ]m/[m next/prev message · <Tab> changes view · Y yank code
--                      za fold msg · zM/zR fold/unfold all · yr reply · yc convo
--                      i compose · <Esc> back to roster · (y/n answer approvals)
--          — composer: <CR> send · <C-s> send-from-insert · <C-↑/↓> scroll chat · <C-x> drop attachments
--                      q back to roster · /slash commands · @ path hints
-- Anywhere: <leader>as (visual) send selection · :CockpitSend[File|Diff|Diagnostics]
local M = {}

local uv = vim.uv or vim.loop
local api = vim.api
local fn = vim.fn


local function cockpit_env(name)
  local current = vim.env["COCKPIT_" .. name]
  return current and current ~= "" and current or vim.env["HEIDR_" .. name]
end


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
  step_done = "●",
  step_active = "◐",
  step_todo = "○",
  tests = "☑",
  work = "▪",
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
  -- NO nucleo "chip" (a microchip — nonsensical as a session marker); fall through to the
  -- ICON_FALLBACK swatch = mdi-square-rounded (U+F14FB), a filled rounded square.
  image = "image",
  check = "check",
  xmark = "xmark",
  file_change = "pen-3",
  step_done = "circle-half-dotted-check",
  step_active = "half-dotted-circle-play",
  step_todo = "circle-half-dotted-check-outline",
  tests = "clipboard-check",
  work = "box",
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


local mode_dir = fn.expand("~/.local/state/cockpit")
local instance = vim.env.COCKPIT_INSTANCE
local mode_name = "mode-" .. (instance and instance ~= "" and instance or "main")
local mode_path = mode_dir .. "/" .. mode_name
local function normalized_scope(value)
  return (value == "work" or value == "lovable") and "lovable" or "personal"
end
local function persisted_scope()
  local file = io.open(mode_path, "r")
  if not file then return nil end
  local value = vim.trim(file:read("*a")); file:close()
  if value == "work" or value == "personal" then return normalized_scope(value) end
end
local function detect_scope()
  local saved = persisted_scope()
  if saved then return saved end
  local env = cockpit_env("SCOPE")
  if env and env ~= "" then return normalized_scope(env) end
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
local local_scope_state = {}
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
  plan_inventory = { needs = {}, implementing = {}, reconciled = {} },
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
  readbuf = {},
  spin = 0,
  timer = nil,
  saved_gcr = nil,
}

local handle, on_read, try_connect, connect, send, git_changes, refresh_git_changes, parse_git_diff
local refresh_dashboard, hide_banner
local start_session, view_session, open_picker, refresh_plans, refresh_plan_one, refresh_plan_bindings, refresh_devenv
local session_cwd, load_plan
local on_cockpit_active -- reconciles the rail's selection with the cockpit active context
local reflect_context, cockpit_context, cockpit_sync -- view_session side-effects (defined later)
local teardown_session -- full teardown: stop pi + close context + wt remove (defined later)
local follow_edit -- live-follow the agent's edits into the editor window (defined later)
local target_editor_win, capture_editor -- editor-director helpers (defined later)

--------------------------------------------------------------------------------
-- small utils
--------------------------------------------------------------------------------
local function sock() return (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/agentd-" .. scope .. ".sock" end
local function scope_root() return fn.expand(ROOTS[scope] or fn.getcwd()) end
local function base(dir) return fn.fnamemodify(dir, ":t") end
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
  -- blend `base` (hex string or 0xRRGGBB int) toward `tint` by `amt` (0..1) → hex string.
  -- Used for the chat message tints: mixing the theme bg toward blue yields a dark blue in
  -- dark mode and a light periwinkle (not a washed grey) in light mode — same hue both ways.
  local function to_rgb(c)
    if type(c) == "number" then return math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256 end
    local s = tostring(c):gsub("#", "")
    return tonumber(s:sub(1, 2), 16) or 0, tonumber(s:sub(3, 4), 16) or 0, tonumber(s:sub(5, 6), 16) or 0
  end
  local function mix(base, tint, amt)
    local br, bg, bb = to_rgb(base)
    local tr, tg, tb = to_rgb(tint)
    return string.format("#%02x%02x%02x",
      math.floor(br + (tr - br) * amt + 0.5),
      math.floor(bg + (tg - bg) * amt + 0.5),
      math.floor(bb + (tb - bb) * amt + 0.5))
  end

  hl("CockpitStream", { fg = p.green or "#5fca8b" })
  hl("CockpitErr", { fg = p.red or "#e5675f" })
  -- idle = secondary-emphasis text: readable in both modes (fg_secondary sits between
  -- fg and fg_muted, so it darkens in light mode instead of washing out)
  hl("CockpitIdle", { fg = p.fg_secondary or p.fg_muted or "#8a95a3" })
  -- Softer electric for the small rail elements (spinner, session-name text, roster
  -- dots): slightly LIGHTER than the dark electric so it doesn't glare at small sizes,
  -- and slightly DARKER than the light electric (lighter would wash out on white).
  local elec_soft = (vim.o.background == "light") and "#0000c4" or "#7385ff"
  -- idle STATUS SWATCH: the softer electric for a resting session — the roster swatches
  -- read off this. Streaming still reads apart via its animated spinner glyph, not colour.
  -- (distinct from needs-input=accent and streaming=electric).
  hl("CockpitSwatchIdle", { fg = elec_soft })
  hl("CockpitAccent", { fg = accent, bold = true })
  hl("CockpitAgentEdit", { fg = api.nvim_get_hl(0, { name = "Cursor", link = false }).bg or accent })
  -- Electric: the dashboard's own accent (matches the HEIÐR banner ink). Scoped to
  -- the resting view so the rail's orange signal stays untouched everywhere else.
  hl("CockpitElectric", { fg = "#5566ff", bold = true })
  -- Softer electric variant — the spinner + streaming session name read off this.
  hl("CockpitElectricSoft", { fg = elec_soft, bold = true })
  -- active dashboard tab: an Electric pill (elevated bg) so the selected view reads at a
  -- glance against the dimmed inactive tabs, without a full box on the border line.
  hl("CockpitTabActive", { fg = "#5566ff", bg = p.item_selected or p.bg_selection or cardbg, bold = true })
  -- Neutral heading colour for titles/section labels: orange is a SIGNAL (selection,
  -- active state, identity), not the colour of every header — a bold near-fg reads as
  -- a heading while keeping the accent rare and meaningful.
  hl("CockpitTitle", { fg = p.fg or "#c7ccd1", bold = true })
  hl("CockpitFocusName", { fg = p.fg or "#c7ccd1", bold = true }) -- focused-but-not-open row
  hl("CockpitMuted", { fg = p.fg_muted or "#5c6773" })
  hl("CockpitFile", { fg = p.fg or "#c7ccd1" }) -- neutral file-path text (status lives on the dot)
  hl("CockpitHunkRange", { fg = p.blue or p.cyan or "#5aa9e6" }) -- hunk line-range in the chat
  -- Only paths that actually RESOLVE get this, so the underline is a promise: <CR> opens it.
  hl("CockpitPathRef", { fg = p.blue or p.cyan or "#5aa9e6", underline = true })
  -- approval-card key caps (a subtle elevated pill behind the key char)
  hl("CockpitKeyOk", { fg = p.green or "#5fca8b", bg = cardbg, bold = true })
  hl("CockpitKeyNo", { fg = p.red or "#e5675f", bg = cardbg, bold = true })
  hl("CockpitKeyNum", { fg = accent, bg = cardbg, bold = true })
  hl("CockpitAttn", { fg = attn, bold = true })
  hl("CockpitDivider", { fg = p.bg_surface2 or p.bg_secondary or "#2a3038" }) -- subtle line

  -- focus-ring card (elevated fill + solid accent edge). The edge is a bg-filled
  -- cell, not a ▌ glyph, so it's continuous across rows (glyphs leave inter-row
  -- gaps in fonts that don't draw block chars full-height).
  hl("CockpitCard", { bg = cardbg })
  -- active-session name chip: the shared selected-item tone keeps it distinct
  -- from the structural box surface.
  hl("CockpitNameCard", { bg = p.item_selected or p.bg_selection or cardbg })
  -- chat: your (user) message blocks get a subtle full-width background; the agent's
  -- turn-recap (✧ …) gets a lighter callout background. Both are HIGHLIGHTS (no border
  -- chars in the buffer) so yanking the chat still copies clean text.
  -- All three lean BLUE (blended into the theme bg so they track light/dark), kept distinct
  -- by depth + hue: you = electric-blue (strongest, matches the role bar), summary = a lighter
  -- sky-blue so the recap still reads apart, code = a barely-there blue-neutral.
  local elec = "#5566ff"
  local light = vim.o.background == "light"
  -- you: electric in dark (matches the role bar); in light, electric blends to a pinkish
  -- periwinkle, so lean to a truer blue AND drop the alpha hard — light fills read heavy.
  local you_tint = light and "#2b6bf5" or elec
  hl("CockpitUserBg", { bg = mix(dark, you_tint, light and 0.09 or 0.15) })
  hl("CockpitSummaryBg", { bg = mix(dark, p.blue or "#5aa9e6", light and 0.05 or 0.12) })
  -- full-line background for fenced code blocks in the chat: applied via
  -- line_hl_group so it spans the whole rail width (a uniform rectangle), unlike
  -- markview's char-level bg which stops at the text and reads ragged.
  hl("CockpitCode", { bg = mix(dark, elec, light and 0.03 or 0.09) })
  hl("CockpitBarSolid", { bg = accent }) -- the roster's focus edge — ONLY drawn while the roster pane is focused
  hl("CockpitSel", { bg = p.item_cursor or p.bg_surface3 or surface, bold = true }) -- picker selection bar
  -- volt-style scope-box surfaces: two elevations off the theme's surface ladder so
  -- boxes read as distinct filled panels and can be layered (a box, an inner box).
  hl("CockpitBox", { bg = surface })
  hl("CockpitBoxAlt", { bg = p.bg_surface2 or cardbg or surface })

  -- pills + rounded caps
  hl("CockpitPillStream", { fg = dark, bg = p.green or "#5fca8b", bold = true })
  hl("CockpitPillErr", { fg = dark, bg = p.red or "#e5675f", bold = true })
  hl("CockpitPillIdle", { fg = dark, bg = p.blue or "#5aa9e6" })
  hl("CockpitPillAttn", { fg = dark, bg = attn, bold = true })
  hl("CockpitCapStream", { fg = p.green or "#5fca8b" })
  hl("CockpitCapErr", { fg = p.red or "#e5675f" })
  hl("CockpitCapIdle", { fg = p.blue or "#5aa9e6" })
  hl("CockpitCapAttn", { fg = attn })

  -- composer chips + keycaps + caret
  hl("CockpitChip", { fg = p.fg or "#c7ccd1", bg = surface })
  hl("CockpitChipBar", { fg = accent })
  hl("CockpitKey", { fg = dark, bg = accent, bold = true })
  hl("CockpitKeyMuted", { fg = p.fg or "#c7ccd1", bg = surface })
  -- keycap chip: dark legend on a bright neutral cap (like a physical key), so it reads
  -- clearly against the dark rail — brighter than the surface-tone CockpitKeyMuted.
  hl("CockpitKeyCap", { fg = dark, bg = p.fg_muted or "#707B84", bold = true })
  hl("CockpitCaret", { fg = accent, bold = true })
  hl("CockpitApproval", { fg = attn, bold = true })

  -- Cursor hiding by colour-match (blend=100 is unreliable in some terminals):
  -- in the roster the cursor parks on the accent bar → paint it accent; in
  -- floats it sits on Normal bg → paint it Normal. Chat/composer keep a real cursor.
  hl("CockpitCursorRoster", { fg = accent, bg = accent, blend = 100 })
  hl("CockpitCursorFloat", { fg = dark, bg = dark, blend = 100 })

  -- markview markdown groups from the theme so chat messages pop. Inline code gets
  -- a calm distinct hue (cyan) on the subtle surface bg — distinguishable from body
  -- text, but not the accent orange (which floods a code-dense chat, see #156/#157).
  local code = p.cyan or p.blue or "#7dcfff"
  local function hlmd(n, o) api.nvim_set_hl(MDNS, n, o) end
  -- the chat window resolves highlights through MDNS, which supersedes its
  -- winhighlight — so the WinSeparator:CockpitDivider remap must live here too,
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
  -- Locator snippet: the text the edit INSERTS, so live-follow can land on the
  -- actual hunk instead of the file's first one. Covers pi's edit arg spellings
  -- and multi-edit payloads (last block wins — it is the freshest position).
  local snip = a.newText or a.new_text or a.new_string or a.newStr
  if not snip and type(a.edits) == "table" and #a.edits > 0 then
    local e = a.edits[#a.edits]
    if type(e) == "table" then snip = e.newText or e.new_text or e.new_string end
  end
  if not snip and c.name == "write" then snip = a.content or a.text end
  if type(snip) ~= "string" or snip == "" then snip = nil end
  if snip and #snip > 4000 then snip = snip:sub(1, 4000) end
  return "⚙ edit " .. fn.fnamemodify(path, ":."), { { path = path, snippet = snip } }
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

-- Peel the ⟢ recap line out of the trailing assistant message(s) of a turn and
-- return it. The recap belongs to the done-divider summary callout ONLY; left in
-- the message it renders inline as a near-identical DUPLICATE of that callout (the
-- "two summaries" bug). Runs both live (agent_end) AND on get_entries reconstruction
-- — a reopened session rebuilds msgs from the transcript with the ⟢ line intact, so
-- stripping only at agent_end let the dupe reappear after any reload. Walks back to
-- the user-turn boundary; the last assistant message's recap (first seen) wins.
local function strip_recap(msgs)
  if not msgs then return nil end
  local recap
  for i = #msgs, 1, -1 do
    local m = msgs[i]
    if not m or m.role ~= "assistant" then break end
    if type(m.text) == "string" and m.text:find("⟢") then
      local kept, r = {}, nil
      for _, ln in ipairs(vim.split(m.text, "\n", { plain = true })) do
        local mm = ln:match("^%s*⟢%s*(.+)")
        if mm then r = mm else kept[#kept + 1] = ln end
      end
      if r then
        recap = recap or r
        local body = (table.concat(kept, "\n")):gsub("%s+$", "")
        if body == "" then table.remove(msgs, i) else m.text = body end
      end
    end
  end
  return recap
end


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

-- A sub-agent was spawned by another session. agentd stamps the spawner's name as
-- `parent` on every spawn (the same field registry.isLineage gates on) — that's
-- authoritative and immune to how the parent chose to name its worker. Sessions from
-- before that field (restored/legacy) fall back to the old name-shape heuristic: a
-- bare ticket-prefixed name WITH a tail (every-2457-explore-ui), as opposed to the
-- primary worktree session (lovable.daphen-…) or the orchestrator (lovable). The
-- roster nests subs under their parent with a ↳ so a fan-out reads as one family.
-- Takes the session table (not a bare name) so it can consult `parent`.
local function is_subagent(a)
  if not a then return false end
  if a.parent and a.parent ~= "" then return true end -- authoritative
  local n = a.name
  if not n or n:match("^lovable%.") then return false end
  return n:match("^%a+%-%d+%-.+") ~= nil -- legacy fallback
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
-- pid plus selected session; on blur/exit we clear it iff it's still ours. rail_focused() reports whether
-- ANY live rail holds it (a dead pid — crashed nvim — is ignored, self-healing).
local RAIL_FOCUS_FILE = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/agent-rail-focused"
local function rail_focused(session)
  local ok, l = pcall(fn.readfile, RAIL_FOCUS_FILE)
  if not ok then return false end
  local pid = l[1] and tonumber(vim.trim(l[1]))
  local selected = l[2] and vim.trim(l[2]) or ""
  return pid ~= nil and fn.isdirectory("/proc/" .. pid) == 1
    and (selected == "" or not session or selected == session)
end

local function desktop_notify(session, body, urgency)
  if not session then return end
  -- The selected session in the focused rail is already visible. Other sessions
  -- still notify, including one selected in a rail that is currently blurred.
  if rail_focused(session) then return end
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
    "-h", "string:cockpit-scope:" .. scope, "-h", "string:cockpit-session:" .. name,
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

-- Warn when an agent wrote a buffer that also has unsaved local edits.
local function warn_edited_conflicts(cwd, paths)
  for path in pairs(paths or {}) do
    local abs = fn.fnamemodify(fn.expand(path:match("^/") and path or ((cwd or fn.getcwd()) .. "/" .. path)), ":p")
    local bufnr
    for _, b in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(b) and fn.fnamemodify(api.nvim_buf_get_name(b), ":p") == abs then bufnr = b; break end
    end
    if bufnr then
      if vim.bo[bufnr].modified then
        vim.notify("agent edited " .. fn.fnamemodify(abs, ":.") .. " — you have unsaved changes; not reloaded", vim.log.levels.WARN)
      end
    end
  end
end

-- Normalize a pi edit path (may be relative to the session cwd or absolute) to an
-- absolute path, so per-session edit attribution can be compared against the
-- inotify path (always absolute) without format mismatch.
local function edit_abs(cwd, path)
  if not path or path == "" then return nil end
  return fn.fnamemodify(fn.expand(path:match("^/") and path or ((cwd or fn.getcwd()) .. "/" .. path)), ":p")
end

handle = function(obj, reply_scope)
  if obj.type == "changes" and obj.session then
    local w = S.workspace
    local request = w and (S.diff_jobs[w.remoteCwd] or S.diff_jobs[w.cwd])
    if request and reply_scope == request.scope and obj.id == request.id
        and obj.session == request.session and obj.cwd == request.cwd then
        local files, bypath = {}, {}
        for _, source in ipairs(obj.files or {}) do
          local parsed = parse_git_diff(vim.split(source.patch or "", "\n", { plain = true }))
          local change = parsed.bypath[source.path] or parsed.files[1] or { hunks = {} }
          for key, value in pairs(source) do change[key] = value end
          change.add, change.del = tonumber(source.add) or 0, tonumber(source.del) or 0
          change.path = source.path
          files[#files + 1], bypath[change.path] = change, change
        end
        table.sort(files, function(a, b) return a.path < b.path end)
        local snapshot = { files = files, bypath = bypath, at = os.time(), head = obj.head,
          base = obj.base, branch = obj.branch, diff = obj.diff, error = obj.error }
        S.gitdiff[w.remoteCwd], S.gitdiff[w.cwd] = snapshot, snapshot
        S.diff_jobs[w.remoteCwd], S.diff_jobs[w.cwd] = nil, nil
        if request.pipe and not request.pipe:is_closing() then request.pipe:close() end
        if request.done then request.done(snapshot) end
        if refresh_dashboard then refresh_dashboard() end
        pcall(function() require("cockpit.chin").refresh() end)
    end
    return
  end
  -- Any event carrying a session id (except a get_entries response, which is a
  -- reply to us, not pi working) means that pi is alive → disarm its wedge watchdog.
  if obj.session and obj.type ~= "response" and S.awaiting then S.awaiting[obj.session] = nil end
  local t = obj.type
  if t == "roster" then
    S.roster = obj.sessions or {}
    -- Order by RECENCY (most-recently-active first) so the top — where Super+T/R lands you —
    -- is the session you most likely want. Streaming sessions float to the top; idle ones
    -- sort by when they last finished (idle_since); name breaks ties.
    local now = os.time()
    local function rk(a) return S.stream_since[a.id] and now or (S.idle_since[a.id] or 0) end
    table.sort(S.roster, function(a, b)
      local ra, rb = rk(a), rk(b)
      if ra ~= rb then return ra > rb end
      return (a.name or "") < (b.name or "")
    end)
    local plan_binding_changed = refresh_plan_bindings and refresh_plan_bindings()
    if plan_binding_changed and refresh_dashboard then refresh_dashboard() end
    -- Fresh cockpit nvim: land on the ORCHESTRATOR's Cockpit dashboard instead of the
    -- stock splash. Once, first roster only, and only when nvim was started bare (no
    -- file args, untouched empty buffer) — a restarted pane otherwise sat on the NVIM
    -- splash until the first session switch re-landed it.
    if cockpit_env("COCKPIT") == "1" and not S._landed_default then
      S._landed_default = true
      vim.schedule(function()
        if S.workspace or fn.argc() ~= 0 then return end
        local b = api.nvim_get_current_buf()
        if api.nvim_buf_get_name(b) ~= "" or vim.bo[b].modified then return end
        if api.nvim_buf_line_count(b) > 1 or (api.nvim_buf_get_lines(b, 0, 1, false)[1] or "") ~= "" then return end
        local d = default_session()
        if not d then return end
        S.selected = d.id
        local ed = target_editor_win()
        local landing = scope == "personal" and scope_root() or d.cwd
        if ed and landing and landing ~= "" then show_scratch(ed, landing) end
      end)
    end
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
    -- Cap the reconstruction to the most recent CHAT_CAP messages by default. A big session
    -- (2662: 1558 entries / ~7MB) is otherwise msg_text-formatted AND rendered in full on
    -- open — that's the multi-second first-open lag (old turns carry huge tool outputs). We
    -- only format the tail; `zo` in the chat loads the rest on demand.
    local CHAT_CAP = 80
    local full = S.chat_full and S.chat_full[obj.session]
    local active = {} -- user/assistant messages, chronological (chain is leaf→root)
    for i = #chain, 1, -1 do
      local m = chain[i].type == "message" and chain[i].message
      if m and (m.role == "user" or m.role == "assistant") then active[#active + 1] = m end
    end
    local start = (full or #active <= CHAT_CAP) and 1 or (#active - CHAT_CAP + 1)
    local msgs = {}
    for i = start, #active do
      local m = active[i]
      local text, hunks = msg_text(m, cwd)
      if text:gsub("%s", "") ~= "" then
        msgs[#msgs + 1] = { role = m.role, text = text, hunks = hunks }
      end
    end
    -- Peel the trailing turn's ⟢ recap out of the rebuilt tail so it renders only in
    -- the done-divider callout, not inline too. Seed S.summary only when nothing's set
    -- live (a fresh reopen) — never clobber a live summary that carries steps/elapsed.
    local rc = strip_recap(msgs)
    if rc then
      S.summary = S.summary or {}
      if not (S.summary[obj.session] and S.summary[obj.session].recap) then
        S.summary[obj.session] = { recap = rc, files = (S.summary[obj.session] or {}).files }
      end
    end
    -- Never blank a populated chat if reconstruction came back empty (broken leaf).
    if #msgs > 0 or not S.chat[obj.session] then S.chat[obj.session] = { msgs = msgs, more = start - 1 } end
    if S.reloading then S.reloading[obj.session] = nil end -- pi's back, restart done
  elseif t == "rewound" and obj.session then
    -- true rewind landed: pi respawned on the truncated session. Reload the
    -- (now shorter) history and drop the removed message back into the composer
    -- to edit and resend. get_entries waits for the respawned pi's stdin.
    S.stream[obj.session] = nil
    send({ type = "get_entries", session = obj.session })
    if obj.session == S.selected and S.composerbuf and api.nvim_buf_is_valid(S.composerbuf) then
      local msg = obj.message or ""
      api.nvim_buf_set_lines(S.composerbuf, 0, -1, false, vim.split(msg, "\n", { plain = true }))
      if S.composerwin and api.nvim_win_is_valid(S.composerwin) then
        api.nvim_set_current_win(S.composerwin)
        pcall(api.nvim_win_set_cursor, S.composerwin, { api.nvim_buf_line_count(S.composerbuf), 0 })
        vim.cmd("startinsert!")
      end
    end
  elseif t == "message_start" and obj.session and obj.message and obj.message.role == "user" then
    -- echo the user prompt — covers prompts injected via `agent send` / plan dispatch
    -- that the composer never optimistically echoed. Dedup vs a just-echoed one.
    local text = msg_text(obj.message, session_cwd(obj.session))
    if text:gsub("%s", "") ~= "" then
      local c = S.chat[obj.session] or { msgs = {} }
      local last = c.msgs[#c.msgs]
      -- Dedup the server echo against the optimistic one, WHITESPACE-INSENSITIVELY. The
      -- optimistic echo carries what you typed (plus an image marker "  🖼×N"); the server
      -- copy is msg_text-trimmed and can differ in leading/internal whitespace (an injected
      -- context prefix, indent) — an exact compare missed and the turn rendered twice.
      local norm = function(s)
        return (s or ""):gsub("%s*" .. ICON.image .. "×%d+%s*$", ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
      end
      local lasttext = last and last.role == "user" and norm(last.text) or nil
      if lasttext ~= norm(text) then
        c.msgs[#c.msgs + 1] = { role = "user", text = text }
        S.chat[obj.session] = c
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
      local scwd = session_cwd(obj.session)
      local text, hunks = msg_text({ content = partial.content }, scwd)
      S.stream[obj.session] = text
      -- Record this session's edits live so semantic follow and conflict warnings
      -- stay attributed when multiple agents share one working directory.
      -- ONLY record paths that are real files on disk: this event streams the edit
      -- tool's path a char at a time, so a partial like "/home/daph" would otherwise
      -- get recorded as its own "edited file" (the prefix-row garbage). A partial
      -- never exists as a file; the complete path does once the edit is written.
      if hunks and #hunks > 0 then
        S.edited[obj.session] = S.edited[obj.session] or {}
        for _, h in ipairs(hunks) do
          local abs = edit_abs(scwd, h.path)
          -- Keep the freshest locator snippet for semantic follow.
          if abs and fn.filereadable(abs) == 1 then
            S.edited[obj.session][abs] = h.snippet or S.edited[obj.session][abs] or true
          end
        end
      end
    end
  elseif t == "message_end" and obj.session then
    local m = obj.message or {}
    local text, hunks = msg_text(m, session_cwd(obj.session))
    S.stream[obj.session] = nil -- finalize any live stream
    if m.role ~= "assistant" or text:gsub("%s", "") == "" then
      return
    end
    local c = S.chat[obj.session] or { msgs = {} }
    c.msgs[#c.msgs + 1] = { role = "assistant", text = text, hunks = hunks }
    S.chat[obj.session] = c
    if hunks and #hunks > 0 then
      S.edited[obj.session] = S.edited[obj.session] or {}
      local scwd = session_cwd(obj.session)
      for _, h in ipairs(hunks) do
        local abs = edit_abs(scwd, h.path)
        if abs then S.edited[obj.session][abs] = h.snippet or S.edited[obj.session][abs] or true end
      end
      if obj.session == S.selected then
        local last = hunks[#hunks]
        if last and last.path then follow_edit(scwd, last.path, nil, nil, nil, last.snippet) end
      end
    end
  elseif (t == "text_delta" or t == "content_block_delta" or t == "message_delta" or t == "text") and obj.session then
    local chunk = delta_text(obj)
    if chunk and chunk ~= "" then
      if S.errors then S.errors[obj.session] = nil end -- new output → clear stale error
      S.stream[obj.session] = (S.stream[obj.session] or "") .. chunk
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
  elseif t == "turn_end" and obj.session then
    -- pi fires turn_end PER TOOL ROUND (verified), not once per prompt — so just
    -- finalize this round's stream. The true whole-turn-done is agent_end below;
    -- notifying here would fire once per round (the mid-turn spam).
    S.stream[obj.session] = nil
  elseif t == "changes" and obj.session then
    -- Server-streamed working-tree diff from a REMOTE agentd: populate the diff
    -- cache + re-render CHANGES without the files being local. Same parser + re-render
    -- path as the local git watcher. follow_edit resolves a remote path through the
    -- vm-sync mirror, so a remote session live-follows into the mirrored file.
    local cwd = obj.cwd or session_cwd(obj.session)
    if cwd and type(obj.diff) == "string" then
      S.gitdiff[cwd] = parse_git_diff(vim.split(obj.diff, "\n", { plain = true }))
      if S.selected and session_cwd(S.selected) == cwd then
      end
      if S.dash and S.dash.cwd == cwd then refresh_dashboard() end
    end
  elseif t == "agent_end" and obj.session then
    -- the ENTIRE turn is complete (fires once, after every round).
    S.stream[obj.session] = nil
    if S.turn_active then S.turn_active[obj.session] = nil end
    local flushed_queue = false
    -- STEER FALLBACK: a message steered mid-turn is best-effort — pi strands it if the
    -- turn ends right after accepting it. If this agent_end lands within STEER_GRACE of
    -- the steer, the turn was too short to have consumed it → re-send as a fresh prompt
    -- (the guaranteed delivery). It's ALREADY echoed in the chat from steer time, so we
    -- fire the prompt WITHOUT re-echoing. A longer turn is assumed to have consumed it.
    local STEER_GRACE = 3
    if S.steer_pending and S.steer_pending[obj.session] then
      local sp = S.steer_pending[obj.session]; S.steer_pending[obj.session] = nil
      if (os.time() - (sp.at or 0)) < STEER_GRACE then
        -- Stranded: reposition the steer echo to the END (it becomes this fresh turn's
        -- prompt, after the turn that ignored it) so message_start's re-echo dedups
        -- against it instead of appending a duplicate.
        local cq = S.chat[obj.session]
        if cq and cq.msgs then
          for i = #cq.msgs, 1, -1 do
            local m = cq.msgs[i]
            if m and m.steer and m.text == sp.text then table.remove(cq.msgs, i); break end
          end
          cq.msgs[#cq.msgs + 1] = { role = "user", text = sp.text }
        end
        send({ type = "prompt", session = obj.session, message = sp.text })
        flushed_queue = true -- answer still coming → suppress the no-reply auto-resend
      end
    end
    if not flushed_queue and S.queued and S.queued[obj.session] then
      -- a message queued mid-turn becomes the next turn now (only at true end, so it
      -- isn't injected between the agent's own tool rounds) — guaranteed to get answered.
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
    if c and c.msgs and #c.msgs > 0 then
      local last = c.msgs[#c.msgs]
      S.autoresend = S.autoresend or {}
      if last.role == "assistant" then
        S.autoresend[obj.session] = nil -- a real answer landed → clear the resend guard
      elseif not flushed_queue and last.role == "user" and not (S.errors and S.errors[obj.session]) then
        -- turn ended with your message UNANSWERED (usually mid-turn context compaction
        -- dropped the reply). Auto-resend it ONCE to get an answer; the per-session counter
        -- caps it at a single retry so a genuinely stuck (full-context) session can't loop.
        local tries = S.autoresend[obj.session] or 0
        if tries < 1 and last.text and last.text ~= "" then
          S.autoresend[obj.session] = tries + 1
          send({ type = "prompt", session = obj.session, message = last.text })
        else
          S.autoresend[obj.session] = nil
          c.msgs[#c.msgs + 1] = { role = "assistant",
            text = THINK .. "no reply even after a resend — likely a full context. Re-ask, or start a fresh session for research-heavy tasks." }
        end
      end
    end
    local ed = S.edited[obj.session]
    if ed then S.edited[obj.session] = nil; vim.schedule(function() warn_edited_conflicts(session_cwd(obj.session), ed) end) end
    -- Turn recap for the done divider: pull the agent's ⟢ one-liner out of the final
    -- assistant message (stripping the marker line so it isn't shown twice), and pair
    -- it with the +adds/−dels of the files it touched this turn.
    S.summary = S.summary or {}
    local recap = strip_recap(c and c.msgs)
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
          untracked = not x, -- no git-diff entry (new/untracked file or outside any repo)
        }
      end
    end
    S.summary[obj.session] = { recap = recap, files = files }
    refresh_plans() -- capture final plan progress now the turn's done (the streaming sweep stopped)
    if obj.session == S.selected then refresh_dashboard() end
  elseif t == "extension_ui_request" then
    local m = obj.method
    if m == "notify" then
      vim.notify("[" .. (obj.session or "agent") .. "] " .. (obj.message or ""), vim.log.levels.INFO)
    elseif m == "confirm" or m == "select" or m == "input" or m == "editor" then
      -- only genuine questions become an inline approval card / "needs input"
      S.pending[obj.session] = obj
      desktop_notify(obj.session, (obj.title or "needs your input"), "critical")
      if obj.session == S.selected then
        reveal_decision(obj.title)
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
      end
    else
      vim.notify("agent error: " .. tostring(msg or "unknown"), vim.log.levels.ERROR)
    end
  end
end

-- Joining only at newlines keeps a multi-MB event linear; appending each chunk to a
-- string buffer copied the whole line per 64 KB read and peaked at tens of GB.
local function each_line(parts, chunk, on_line)
  local start, nl = 1, chunk:find("\n", 1, true)
  while nl do
    parts[#parts + 1] = chunk:sub(start, nl - 1)
    local line = table.concat(parts)
    for i = #parts, 1, -1 do parts[i] = nil end
    start = nl + 1
    nl = chunk:find("\n", start, true)
    on_line(line)
  end
  if start <= #chunk then parts[#parts + 1] = chunk:sub(start) end
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
      S.readbuf = {}
      vim.schedule(function()
        -- re-request the roster on reconnect: the daemon only pushes it on
        -- change, so a fresh connection needs an explicit list_sources.
        connect(function() send({ type = "list_sources" }) end)
      end)
    end
    return
  end
  S.last_recv = os.time() -- heartbeat: agentd pings every 3s; absence = dead pipe
  each_line(S.readbuf, chunk, function(line)
    if #line > 0 then
      local ok, obj = pcall(vim.json.decode, line)
      if ok and type(obj) == "table" then handle(obj) end
    end
  end)
end

-- Remote agentd: COCKPIT_AGENTD_ADDR="host:port" (legacy HEIDR fallback) connects over
-- TCP (a tailnet IP, or a localhost SSH-forwarded port) instead of the local
-- unix socket. The daemon protocol is transport-agnostic NDJSON, so only the
-- connect call differs — nvim still runs locally, only events cross the wire.
local function remote_addr()
  if persisted_scope() then return nil end
  local a = cockpit_env("AGENTD_ADDR")
  if not a or a == "" then return nil end
  local host, port = a:match("^(.-):(%d+)$")
  if host and port then return host, tonumber(port) end
  return nil
end

try_connect = function(cb, tries)
  tries = tries or 0
  S.connecting = true
  local rhost, rport = remote_addr()
  local stream = rhost and uv.new_tcp() or uv.new_pipe(false)
  S.pipe = stream
  local function on_conn(cerr)
    if S.pipe ~= stream then return end
    if not cerr then
      S.connecting = false
      S.pipe = stream
      S.connected = true
      S.last_recv = os.time() -- fresh connection: don't flag it stale immediately
      S.ever_connected = true
      stream:read_start(vim.schedule_wrap(function(err, chunk)
        if S.pipe == stream then on_read(err, chunk) end
      end))
      -- flush anything queued while we were down so a daemon restart / socket
      -- drop is transparent: messages you sent mid-outage get delivered now,
      -- in order, instead of being silently lost.
      if S.outbox and #S.outbox > 0 then
        local pending = S.outbox; S.outbox = {}
        for _, m in ipairs(pending) do
          pcall(function() stream:write(vim.json.encode(m) .. "\n") end)
        end
      end
      vim.schedule(function()
        if S.pipe ~= stream then return end
        if cb then cb() end
      end)
      return
    end
    pcall(function() stream:close() end)
    -- Only cold-start a LOCAL daemon on first boot; a remote one can't be spawned
    -- from here, and a reconnect after a drop means it's normally already up.
    if not rhost and tries == 0 and not S.ever_connected then
      vim.schedule(function()
        if S.pipe ~= stream then return end
        -- Start it THROUGH SYSTEMD, never as a detached child. Launching the binary
        -- directly created a second daemon that bound the same socket outside the
        -- unit's cgroup, so `systemctl restart` replaced only one of them and the
        -- rail talked to whichever bound last — a split brain where the restarted
        -- daemon showed an empty roster while the orphan still owned the live pi
        -- processes (hit twice on 2026-08-25). systemd is idempotent here: if the
        -- unit is already running this is a no-op.
        fn.jobstart({ "systemctl", "--user", "start", "agentd-" .. scope }, { detach = true })
      end)
    end
    -- Never give up: fast retries (200ms) for the first ~6s while a
    -- just-spawned daemon boots, then back off to a steady 2s poll so a longer
    -- daemon restart still reconnects on its own without an nvim restart.
    local delay = (tries < 30) and 200 or 2000
    local tm = uv.new_timer()
    tm:start(delay, 0, function()
      tm:close()
      if S.pipe == stream then try_connect(cb, tries + 1) end
    end)
  end
  if rhost then
    stream:connect(rhost, rport, on_conn)
  else
    stream:connect(sock(), on_conn)
  end
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
    S.pipe = nil; S.readbuf = {}
  end
  S.turn_active = {} -- connection reset → lost turn tracking; don't leave "working" stuck
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
  local pipe = S.pipe
  pipe:write(vim.json.encode(obj) .. "\n", function(werr)
    if werr then vim.schedule(function()
      if S.pipe == pipe then enqueue(obj); drop_and_reconnect() end
    end) end
  end)
end

--------------------------------------------------------------------------------
-- re-root + session lifecycle
--------------------------------------------------------------------------------
-- "is this cwd inside a work tree" is invariant for a given dir, but fn.system git
-- forks a subprocess that BLOCKS the switch every time — so memoize per cwd. A
-- session's worktree doesn't stop being a repo mid-life, so a stale-cache risk isn't
-- real here; this removes one synchronous git fork from every session switch.
local function reroot(cwd)
  if not cwd or cwd == "" then return end
  if fn.getcwd() == cwd then return end -- already rooted here (e.g. parent ↔ its sub-agent) — nothing to do
  local rec = vim.g.cockpit_debug_switch and {} or nil
  local function step(label, f)
    if not rec then f(); return end
    local t0 = vim.loop.hrtime(); f(); rec[#rec + 1] = string.format("%s=%.1fms", label, (vim.loop.hrtime() - t0) / 1e6)
  end
  -- cd WITHOUT firing autocmds: a plain :tcd fires DirChanged synchronously, and its
  -- handlers (gitsigns et al.) re-scan git on the whole monorepo — ~600-900ms, the bulk
  -- of every switch. Do the cheap cd now; the git isrepo probe is memoised per cwd.
  step("tcd", function() pcall(vim.cmd, "noautocmd tcd " .. fn.fnameescape(cwd)) end)
  step("plan_bind", function() pcall(function() require("plan-nvim").bind() end) end)
  if rec then
    pcall(fn.writefile, { "  reroot: " .. table.concat(rec, " ") }, "/tmp/cockpit-switch-timing.log", "a")
  end
  vim.schedule(function()
    if fn.getcwd() ~= cwd then return end
    pcall(api.nvim_exec_autocmds, "DirChanged", { modeline = false })
  end)
end


start_session = function(name, cwd)
  -- if a session with this name already runs, OPEN it (don't re-spawn — that
  -- restarts pi and wipes its history); only spawn a genuinely new one
  for _, a in ipairs(S.roster) do
    if a.id == name or a.name == name then return view_session(a.id, a.cwd or cwd) end
  end
  S.selected = name
  send({ type = "spawn", session = name, cwd = cwd })
  reroot(cwd)
  refresh_plans()
end


view_session = function(name, cwd)
  -- Remember what the OUTGOING session had in the editor so returning restores it
  -- (per-session, so one session's file can never bleed into another's).
  if S.selected and S.selected ~= name then capture_editor(S.selected) end
  S.dash_expand = false -- each session's dashboard opens collapsed
  S.selected = name
  reroot(cwd)
  reflect_context(cwd) -- restore editor or show dashboard (sync: deferring it let another buffer open in the gap and got clobbered)
  cockpit_sync(cwd)    -- drive cockpit devenv tab + Super+T marker
  -- Refresh the plan after the switch has painted; it's a sync git call.
  vim.schedule(function()
    if S.selected ~= name then return end -- switched away again before we ran
    for _, a in ipairs(S.roster) do
      if a.id == name then refresh_plan_one(a); break end
    end
    if S.selected == name then reflect_context(cwd) end
  end)
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

-- The dashboard hides the editor gutter (number/sign/fold columns) for a clean
-- resting view; a real file restores it to the user's global defaults. Toggled by
-- the two file-show paths + show_scratch so it can never get stuck off.
local function editor_gutter(win, on)
  if not (win and api.nvim_win_is_valid(win)) then return end
  pcall(function()
    -- Clear any statuscolumn that leaked from the chat pane: its %!__CockpitChatStc() drew a
    -- bare, marginless 2-col gutter on the editor that only rendered numbers for the chat
    -- window (hence "numbers vanish when the editor is focused").
    vim.wo[win].statuscolumn = ""
    if on then
      -- Restore the editor window to the GLOBAL default (options.lua sets number +
      -- relativenumber). Cockpit never forces its own values here — it only RESTORES what
      -- the dashboard turned off — so the gutter matches plain nvim everywhere else.
      -- FORCE number + relativenumber on (options.lua's intent). We can't derive from the
      -- global: something in the plugin/loader path resets vim.go.number to OFF after
      -- startup (even the VimEnter re-assert loses in the cockpit nvim), so a derived value
      -- came back false and the gutter vanished. Hardcoding the default is the reliable fix.
      vim.wo[win].number = true
      vim.wo[win].relativenumber = true
      vim.wo[win].numberwidth = (vim.go.numberwidth and vim.go.numberwidth > 0) and vim.go.numberwidth or 4
      vim.wo[win].signcolumn = "yes"
      vim.wo[win].foldcolumn = "0"
    else
      vim.wo[win].number = false
      vim.wo[win].relativenumber = false
      vim.wo[win].signcolumn = "no"
      vim.wo[win].foldcolumn = "0"
    end
  end)
end

-- A remote session's cwd is a VM path; vm-sync keeps a local mirror of the same
-- worktree, so translate before giving up on a file that "isn't readable".
local function mirror_of(p)
  if not p then return nil end
  local t = p:match("^/home/[^/]+/src/lovable%-([%w%-%.]+)")
  local root = t and (fn.expand("~/work/lovable.daphen-" .. t))
    or (p:match("^/home/[^/]+/src/lovable$") and fn.expand("~/work/lovable"))
  if root and fn.isdirectory(root) == 1 then return root end
  return nil
end

-- Resolve a path the agent named into something openable here: as given, then
-- rebased onto the local mirror (both for a bare path under a remote cwd and for
-- an absolute VM path).
local function resolvable(cwd, path)
  local direct = fn.expand(path:match("^/") and path or ((cwd or fn.getcwd()) .. "/" .. path))
  if fn.filereadable(direct) == 1 then return direct end
  local m = mirror_of(cwd)
  if m and not path:match("^/") then
    local rebased = fn.expand(m .. "/" .. path)
    if fn.filereadable(rebased) == 1 then return rebased end
  end
  local vroot, rest = path:match("^(/home/[^/]+/src/lovable[%w%-%.]*)/(.+)$")
  local vm = vroot and mirror_of(vroot)
  if vm then
    local rebased = fn.expand(vm .. "/" .. rest)
    if fn.filereadable(rebased) == 1 then return rebased end
  end
  return nil
end


local function open_in_editor(cwd, path, line)
  local file = resolvable(cwd, path)
  if not file then vim.notify("Cockpit: not readable — " .. path, vim.log.levels.WARN); return end
  local target = target_editor_win()
  if not target then
    vim.cmd("topleft vsplit")
    S.editor_win = api.nvim_get_current_win()
    vim.g.agent_editor_win = S.editor_win
    target = S.editor_win
  end
  api.nvim_set_current_win(target)
  pcall(vim.cmd, "edit " .. fn.fnameescape(file))
  editor_gutter(target, true)
  if hide_banner then hide_banner() end -- a real file is showing now → drop the dashboard banner float
  if line then pcall(api.nvim_win_set_cursor, 0, { tonumber(line), 0 }) end
end


-- Live-follow: as the agent edits files this turn, OPEN the edited file in the
-- editor window and land on the changed line — without stealing focus. Unlike
-- reveal_file, it opens files not yet shown (that's why the editor stayed on the
-- plan while other files were edited). Only fires when focus is in the rail (an
-- agent-* window): if you've clicked into the code to read/edit, it leaves you
-- alone. Skips when the target buffer has unsaved changes. Toggle: S.follow_edits.
local function edit_mark_state(workspace)
  workspace = workspace or S.workspace
  if not workspace then return end
  local key = workspace.scope .. "/" .. workspace.id
  S.workspace_editors = S.workspace_editors or {}
  local state = S.workspace_editors[key] or {}
  state.edit_ns = state.edit_ns or api.nvim_create_namespace("cockpit-edit-flash:" .. key)
  S.workspace_editors[key] = state
  return state
end

local function clear_edit_highlight(ns)
  if not ns then return end
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
  end
end

local function edit_mark_opts(id)
  return { id = id, sign_text = "▌", sign_hl_group = "CockpitAgentEdit", priority = 5000 }
end

local function mark_edit(buf, ns, added_lines)
  if not ns or type(added_lines) ~= "table" or #added_lines == 0 then return end
  local marked = {}
  for _, extmark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})) do
    marked[extmark[2] + 1] = true
  end
  for _, row in ipairs(added_lines) do
    row = tonumber(row)
    if row and not marked[row] and row >= 1 and row <= api.nvim_buf_line_count(buf) then
      api.nvim_buf_set_extmark(buf, ns, row - 1, 0, edit_mark_opts())
      marked[row] = true
    end
  end
end

local function checktime_preserving_edit_marks(buf, ns)
  local marks = ns and api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) or {}
  if #marks == 0 then vim.cmd.checktime(); return end
  local before = api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.cmd.checktime()
  local after = api.nvim_buf_get_lines(buf, 0, -1, false)
  if vim.deep_equal(before, after) then return end
  local ok, hunks = pcall(vim.diff, table.concat(before, "\n") .. "\n",
    table.concat(after, "\n") .. "\n", { result_type = "indices", algorithm = "histogram" })
  if not ok then return end
  for _, mark in ipairs(marks) do
    local row, shift, mapped = mark[2] + 1, 0
    for _, hunk in ipairs(hunks) do
      local old_start, old_count, new_start, new_count = unpack(hunk)
      if old_count == 0 then
        if row > old_start then shift = shift + new_count end
      elseif row < old_start then
        break
      elseif row >= old_start + old_count then
        shift = shift + new_count - old_count
      elseif new_count > 0 then
        mapped = new_start + math.min(row - old_start, new_count - 1)
        break
      else
        mapped = false
        break
      end
    end
    mapped = mapped == nil and row + shift or mapped
    if mapped then
      api.nvim_buf_set_extmark(buf, ns, mapped - 1, 0, edit_mark_opts(mark[1]))
    else
      api.nvim_buf_del_extmark(buf, ns, mark[1])
    end
  end
end

local function ignored_edit_path(path)
  return path:match("%.progress%.json$") or path:match("%.review%.json$")
    or path:match("/plans/.*%.diagram%.html$")
end

local function edit_timestamp(at)
  if type(at) == "number" then return at end
  if type(at) ~= "string" then return nil end
  local numeric = tonumber(at)
  if numeric then return numeric end
  local base, fraction = at:match("^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)%.?(%d*)[Zz]$")
  if not base then return nil end
  local seconds = fn.strptime("%Y-%m-%dT%H:%M:%S%z", base .. "+0000")
  if seconds < 0 then return nil end
  local millis = tonumber((fraction .. "000"):sub(1, 3)) or 0
  return seconds * 1000 + millis
end

local function record_edit(workspace_scope, id, cwd, path, added_lines, replace, at, line, edit_id)
  if not workspace_scope or not id or not path or S.follow_edits == false
    or ignored_edit_path(path) then return false end
  local timestamp = edit_timestamp(at)
  if not timestamp then return false end
  local state = edit_mark_state({ scope = workspace_scope, id = id })
  if not state then return false end
  local stale = state.edit_at
    and (timestamp < state.edit_at or (replace and timestamp == state.edit_at))
  if stale and not (replace and edit_id and edit_id == state.last_edit_id) then return false end
  local file = resolvable(cwd, path)
  if not file then return false end
  file = fn.fnamemodify(file, ":p")
  local buf = fn.bufnr(file)
  if buf >= 0 and vim.bo[buf].modified then return false end
  if buf < 0 then buf = fn.bufadd(file) end
  if not api.nvim_buf_is_loaded(buf) then fn.bufload(buf) end
  if not api.nvim_buf_is_valid(buf) or vim.bo[buf].modified then return false end
  local file_changed = state.follow_file ~= file
  if replace or file_changed then
    clear_edit_highlight(state.edit_ns)
    state.follow_file = file
  end
  local program_nav = S._program_nav
  S._program_nav = true
  local ok = pcall(api.nvim_buf_call, buf, function()
    checktime_preserving_edit_marks(buf, state.edit_ns)
    if replace then api.nvim_buf_clear_namespace(buf, state.edit_ns, 0, -1) end
    mark_edit(buf, state.edit_ns, added_lines)
  end)
  S._program_nav = program_nav
  if not ok then return false end
  state.edit_at = math.max(state.edit_at or timestamp, timestamp)
  state.last_edit_id = edit_id
  local current = S.workspace
  if not (current and current.scope == workspace_scope and current.id == id) then
    local row = (type(line) == "number" or type(line) == "string") and tonumber(line) or nil
    if not row and type(added_lines) == "table" then row = tonumber(added_lines[1]) end
    row = math.max(1, math.min(row or 1, api.nvim_buf_line_count(buf)))
    state.buf = buf
    state.view = { lnum = row, col = 0,
      topline = math.max(1, row - math.floor(api.nvim_win_get_height(api.nvim_get_current_win()) / 2)) }
  end
  return true, file_changed
end

function M.record_edit(workspace_scope, id, cwd, path, added_lines, replace, at, line, edit_id)
  return record_edit(workspace_scope, id, cwd, path, added_lines, replace == true, at, line, edit_id)
end

follow_edit = function(cwd, path, line, external, external_force, snippet, added_lines)
  if not path or S.follow_edits == false then return end
  -- Never follow into plan machinery sidecars: a /plan-ticket turn writes the
  -- reviewable .md and THEN its progress.json, so following the last edit would
  -- dump you in raw JSON instead of the rendered plan. Skipping them keeps the
  -- editor on the .md (which plan-nvim renders) — the thing you actually review.
  if ignored_edit_path(path) then return end
  local cur = api.nvim_get_current_win()
  -- "You're in the code" gate — only for the in-nvim rail, where browsing the rail is
  -- what current-buffer==agent-* means. An EXTERNAL driver (the cockpit rail) has no
  -- agent buffers at all; its equivalent gate lives in M.follow_remote.
  if not external and not api.nvim_buf_get_name(api.nvim_win_get_buf(cur)):match("agent%-") then return end
  local file = resolvable(cwd, path)
  if not file then return end
  file = fn.fnamemodify(file, ":p")
  -- Avante-style reveal: pi's edit tool carries NO line numbers, so resolve the
  -- reveal line from the authoritative git diff instead — jump to the file's first
  -- changed hunk so the change is on-screen (signs mark the rest), not the file top.
  -- Hunk-accurate reveal: find the freshly-inserted text on disk and land THERE.
  -- Pick the snippet's most distinctive line (longest trimmed, ≥8 chars, falling
  -- back to ≥3) and take its LAST occurrence — under repeated edits the newest
  -- insertion is the one further down more often than not.
  if not line and snippet then
    local needle
    for _, sl in ipairs(vim.split(snippet, "\n", { plain = true })) do
      local tl = sl:gsub("^%s+", ""):gsub("%s+$", "")
      if #tl >= 3 and (not needle or #tl > #needle) then needle = tl end
    end
    if needle and #needle >= 3 then
      local ok, flines = pcall(fn.readfile, file)
      if ok and type(flines) == "table" then
        for i = #flines, 1, -1 do
          if flines[i]:find(needle, 1, true) then line = i; break end
        end
      end
    end
  end
  if not line and cwd then
    local rel = file:sub(1, #cwd + 1) == cwd .. "/" and file:sub(#cwd + 2) or path
    if not S.gitdiff[cwd] then git_changes(cwd) end
    local change = S.gitdiff[cwd] and S.gitdiff[cwd].bypath[rel]
    if change and change.hunks and change.hunks[1] then line = change.hunks[1].l1 end
  end
  line = tonumber(line)
  local target = target_editor_win()
  local destination = fn.bufnr(file)
  if not target or vim.bo[api.nvim_win_get_buf(target)].modified
    or (destination >= 0 and vim.bo[destination].modified) then return end
  -- The user took the wheel: any buffer they opened THEMSELVES pauses follow
  -- until they return to rest (dashboard) or switch sessions. Programmatic opens
  -- (this function) are marked so the BufEnter watcher can tell them apart.
  local edit_state = edit_mark_state()
  local function adopt_edit_file()
    if edit_state and edit_state.follow_file ~= file then
      clear_edit_highlight(edit_state.edit_ns)
      edit_state.follow_file = file
    end
  end
  if S._follow_paused and not external_force then
    if fn.fnamemodify(api.nvim_buf_get_name(api.nvim_win_get_buf(target)), ":p") == file then
      adopt_edit_file()
      api.nvim_win_call(target, function()
        checktime_preserving_edit_marks(api.nvim_get_current_buf(), edit_state and edit_state.edit_ns)
        mark_edit(api.nvim_get_current_buf(), edit_state and edit_state.edit_ns, added_lines)
      end)
    end
    return
  end
  adopt_edit_file()
  S._program_nav = true
  api.nvim_win_call(target, function()
    if fn.fnamemodify(api.nvim_buf_get_name(0), ":p") ~= file then
      pcall(function() vim.cmd.edit(fn.fnameescape(file)) end)
    end
    checktime_preserving_edit_marks(api.nvim_get_current_buf(), edit_state and edit_state.edit_ns)
    if line then
      local row = math.max(1, math.min(line, api.nvim_buf_line_count(0)))
      api.nvim_win_set_cursor(target, { row, 0 })
      vim.cmd("normal! zz")
    end
    mark_edit(api.nvim_get_current_buf(), edit_state and edit_state.edit_ns, added_lines)
  end)
  vim.schedule(function() S._program_nav = nil end)
  editor_gutter(target, true) -- a real file is showing → restore number/sign/fold cols (the dashboard turned them off)
  if hide_banner then hide_banner() end
  pcall(function() require("cockpit.chin").refresh() end)
end


--------------------------------------------------------------------------------
-- changes view: plan (progress.json) first, git diff as fallback/overlay
--------------------------------------------------------------------------------
-- the vault plans dir if present, else the worktree's local .plans
-- Both plan locations, in preference order. Not "vault if it exists, else the repo": a
-- session that ran on a box had no vault THERE, so plan-ticket wrote into the worktree,
-- and its plan is invisible from here — the dashboard showed no PLAN tab for every
-- remote ticket. The vault still wins when both hold a match.
local function plandirs(cwd)
  local out = {}
  local vault = fn.expand("~/personal/notes/storage/plans")
  if fn.isdirectory(vault) == 1 then out[#out + 1] = vault end
  local inrepo = (cwd or fn.getcwd()) .. "/.plans"
  if fn.isdirectory(inrepo) == 1 then out[#out + 1] = inrepo end
  return out
end

-- find the plan for a session's worktree: by the session's explicit plan binding
-- (roster `plan`, set at spawn), else by the branch its progress.json recorded,
-- else by the ticket id in the worktree's own name
load_plan = function(cwd)
  if not cwd or cwd == "" then return nil end -- nil cwd → malformed `git -C` call
  -- Explicit binding wins. Match the selected session before cwd: several sessions
  -- may share one directory while carrying unrelated plans.
  local bound
  for _, a in ipairs(S.roster or {}) do
    if (a.id == S.selected or a.name == S.selected) and a.cwd == cwd then bound = a; break end
  end
  if not bound and (not S.selected or S.selected == "") then
    for _, a in ipairs(S.roster or {}) do if a.cwd == cwd then bound = a; break end end
  end
  if S.workspace and S.workspace.cwd == cwd then bound = S.workspace end
  if bound and bound.plan and bound.plan ~= "" then
    for _, dir in ipairs(plandirs(cwd)) do
      local f = dir .. "/" .. bound.plan .. ".progress.json"
      if fn.filereadable(f) == 1 then
        local ok, data = pcall(function() return vim.json.decode(table.concat(fn.readfile(f), "\n")) end)
        if ok and type(data) == "table" then
          local review
          local rf = dir .. "/" .. bound.plan .. ".review.json"
          if fn.filereadable(rf) == 1 then
            local rok, rdata = pcall(function() return vim.json.decode(table.concat(fn.readfile(rf), "\n")) end)
            if rok and type(rdata) == "table" then review = rdata end
          end
          return { progress = data, key = bound.plan, review = review }
        end
      end
    end
  end
  local branch = fn.system({ "git", "-C", cwd, "branch", "--show-current" }):gsub("%s+$", "")
  -- A plan belongs to a ticket/feature branch. `main`/`master` is shared across
  -- repos and many old progress.json files recorded branch:"main", so matching on
  -- it leaks a stray plan onto every main-checkout session (e.g. the orchestrator).
  if branch == "main" or branch == "master" then branch = "" end
  -- Fallback key: a worktree realigned to a remote HEAD sits DETACHED, where
  -- --show-current is empty and branch matching can never hit. The worktree is named
  -- lovable.daphen-<ticket>, which identifies the plan just as well. Safe against the
  -- main-checkout leak above: the main checkout carries no ticket in its name.
  local tik = fn.fnamemodify(cwd, ":t"):match("%a+%-%d+")
  if branch == "" and not tik then return nil end
  for _, dir in ipairs(plandirs(cwd)) do
    for _, f in ipairs(fn.globpath(dir, "*.progress.json", false, true)) do
      local ok, data = pcall(function() return vim.json.decode(table.concat(fn.readfile(f), "\n")) end)
      local key = fn.fnamemodify(f, ":t"):gsub("%.progress%.json$", "")
      local hit = ok and type(data) == "table"
        and ((branch ~= "" and data.branch == branch) or (tik and key:upper() == tik:upper()))
      if hit then
        local review
        local rf = dir .. "/" .. key .. ".review.json"
        if fn.filereadable(rf) == 1 then
          local rok, rdata = pcall(function() return vim.json.decode(table.concat(fn.readfile(rf), "\n")) end)
          if rok and type(rdata) == "table" then review = rdata end
        end
        return { progress = data, key = key, review = review }
      end
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
local dashboard_view = require("cockpit.dashboard")

hide_banner = function()
  if S.banner_placement then
    pcall(function() S.banner_placement:close() end)
    S.banner_placement = nil
  end
  if S.banner_win and api.nvim_win_is_valid(S.banner_win) then
    pcall(api.nvim_win_close, S.banner_win, true)
  end
  S.banner_win = nil
end

local function show_scratch(win, cwd)
  if not (S.scratchbuf and api.nvim_buf_is_valid(S.scratchbuf)) then
    S.scratchbuf = api.nvim_create_buf(false, true)
    vim.bo[S.scratchbuf].buftype = "nofile"
    vim.bo[S.scratchbuf].bufhidden = "hide"
    vim.bo[S.scratchbuf].swapfile = false
  end

  local buf = S.scratchbuf
  local width = math.max(32, api.nvim_win_get_width(win) - 4)
  local height = math.max(12, api.nvim_win_get_height(win))
  local name = (S.selected and short_name(S.selected)) or fn.fnamemodify(cwd, ":t")
  local ticket = (S.selected or ""):match("%a+%-%d+")
    or fn.fnamemodify(cwd or "", ":t"):match("%a+%-%d+")
  local ctx = cockpit_ctx_registered(cwd)
  local root = (S.workspace and S.workspace.profile == "lovable-orchestrator")
    or ctx == "main" or (scope == "personal" and cwd == scope_root())
  local plan = load_plan(cwd)
  -- A session dash for a path with nothing to show renders as a blank page, so fall
  -- back to the scope home view. But a REMOTE session's cwd (a VM path that does not
  -- exist here) is a different problem wearing the same clothes: falling through
  -- silently showed the ticket list while the session's real diff sat unreachable on
  -- the VM, which is how EVERY-2447 looked like "no files" for hours. Name it instead.
  local remote_missing = not root and cwd ~= "" and vim.fn.isdirectory(cwd) == 0
  if remote_missing then
    S.remote_cwd = cwd
  else
    S.remote_cwd = nil
    if not S.workspace and not root and not ctx and not plan and #(git_changes(cwd) or {}) == 0 then
      root = true
      cwd = scope_root()
    end
  end
  local home = os.getenv("HOME") or ""
  local acts, handlers = {}, {}

  local function act(key, label, callback)
    acts[#acts + 1] = { id = "key:" .. key, key = key, label = label }
    handlers["key:" .. key] = callback
  end

  if plan and plan.key then
    act("p", "plan", function() pcall(function() require("plan-nvim").open(plan.key) end) end)
  end
  if ctx then
    act("d", "devenv", function()
      fn.jobstart({ home .. "/.config/niri/scripts/cockpit-devenv", ctx }, { detach = true })
      vim.defer_fn(function() if refresh_devenv then refresh_devenv() end end, 1500)
    end)
  end

  local review_number = (cwd or ""):match("lovable%.review%-(%d+)")
    or (S.selected or ""):match("^review%-pr%-(%d+)")
  local target = review_number and ("review-pr-" .. review_number)
    or (ticket and ticket:lower()) or (ctx and ctx ~= "main" and ctx or nil)
  for _, agent in ipairs(S.roster) do
    if agent.id == S.selected then target = agent.name; break end
  end
  if target then
    act("a", "app", function()
      fn.jobstart({ home .. "/.config/niri/scripts/cockpit-app", target }, {
        detach = true,
        on_exit = function(_, code)
          if code ~= 0 then vim.schedule(function() vim.notify("app: no live session/port for " .. target) end) end
        end,
      })
    end)
  end
  if root then act("n", "session", function() if open_picker then open_picker() end end) end

  if review_number then
    act("l", "open PR", function()
      fn.jobstart({ "gh", "pr", "view", review_number, "--web" }, { cwd = cwd, detach = true })
    end)
    local artifact = home .. "/personal/notes/storage/reviews/pr-" .. review_number .. ".md"
    if fn.filereadable(artifact) == 1 then
      act("r", "review", function()
        S.editor = S.editor or {}
        if S.selected then S.editor[S.selected] = artifact end
        open_in_editor(cwd, artifact, nil)
      end)
    end
  elseif ticket then
    act("l", "linear", function()
      local url = "https://linear.app/lovable/issue/" .. ticket:upper()
      if vim.ui.open then vim.ui.open(url) else fn.jobstart({ "xdg-open", url }, { detach = true }) end
    end)
  end

  local spec = {
    scope = scope,
    kind = root and "home" or "session",
    identity = root and (scope == "personal" and "HOME" or "LOVABLE") or (name or "SESSION"),
    cwd = cwd,
    actions = acts,
    expanded = S.dash_expand,
    remote_cwd = S.remote_cwd,
  }

  if root and scope == "personal" then
    spec.inventory = S.plan_inventory or { needs = {}, implementing = {}, reconciled = {} }
    for _, group in ipairs({ spec.inventory.needs or {}, spec.inventory.implementing or {}, spec.inventory.reconciled or {} }) do
      for _, item in ipairs(group) do
        handlers["plan:" .. item.slug] = function()
          if item.session then view_session(item.session.id, item.session.cwd)
          else vim.notify("unbound — P in the rail binds it") end
          pcall(function() require("plan-nvim").open(item.slug) end)
        end
      end
    end
  elseif root then
    spec.cycle = read_cycle()
    spec.live_tickets = {}
    for _, agent in ipairs(S.roster) do
      local id = (agent.name or ""):match("%a+%-%d+")
      if id then spec.live_tickets[id:upper()] = agent end
    end
    spec.ticket_limit = math.max(1, height - 18)
    if spec.cycle then
      for _, item in ipairs(spec.cycle.tickets or {}) do
        local id = item.id or ""
        local live = spec.live_tickets[id:upper()]
        handlers["ticket:" .. id] = function()
          if live then
            vim.notify("agent: " .. id .. " already has a session")
          elseif id ~= "" then
            local seed = "Work " .. id .. (item.title and item.title ~= "" and (": " .. item.title) or "")
              .. "\n\nStart with /plan-ticket " .. id .. " to scope it, then implement."
            if vim.fn.confirm("Spawn a session for " .. id .. "?", "&Yes\n&No", 2) == 1 then
              fn.jobstart({ home .. "/.local/bin/cockpit-spawn", id:lower(), seed }, { detach = true })
              vim.notify("agent: spawning session · " .. id:lower())
            end
          else
            vim.notify("agent: ticket has no id in cycle.json")
          end
        end
        if live then
          handlers["teardown:" .. live.id] = function()
            teardown_session(live.id, live.cwd)
            vim.defer_fn(function() if api.nvim_win_is_valid(win) then show_scratch(win, cwd) end end, 500)
          end
        end
      end
    end
  else
    local changes = git_changes(cwd)
    local tests = {}
    if plan and plan.review and type(plan.review.verification) == "table" then
      for _, verification in ipairs(plan.review.verification) do
        if not (verification.command and verification.command ~= "") then tests[#tests + 1] = verification end
      end
    end
    local pending = 0
    for _, test in ipairs(tests) do if (test.result or "pending") ~= "pass" then pending = pending + 1 end end
    local tabs = {}
    if plan and plan.progress then tabs[#tabs + 1] = "plan" end
    if #tests > 0 then tabs[#tabs + 1] = "tests" end
    if ctx or #changes > 0 then tabs[#tabs + 1] = "changes" end

    S.dash_tests_seen = S.dash_tests_seen or {}
    if S.selected and pending > 0 and not S.dash_tests_seen[S.selected] then
      S.dash_view = "tests"
      S.dash_tests_seen[S.selected] = true
    elseif S.selected and pending == 0 then
      S.dash_tests_seen[S.selected] = nil
    end
    if not vim.tbl_contains(tabs, S.dash_view) then S.dash_view = tabs[1] end
    spec.plan = plan
    spec.tests = tests
    spec.changes = changes
    spec.tabs = tabs
    spec.active_tab = S.dash_view
    spec.change_limit = math.max(1, height - 12)
    for index, change in ipairs(changes) do
      handlers["file:" .. index] = function() open_in_editor(cwd, change.path, nil) end
    end
  end

  handlers.expand = function()
    S.dash_expand = not S.dash_expand
    if api.nvim_win_is_valid(win) then show_scratch(win, cwd) end
  end

  local model = dashboard_view.build(spec)
  local lines, line_actions = dashboard_view.text(model, width)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, S.ns, 0, -1)

  S.dash = {
    cwd = cwd,
    win = win,
    views = model.tabs or {},
    acts = acts,
    model = model,
    handlers = handlers,
    line_actions = line_actions,
  }
  dash_keys(buf, acts)
  pcall(api.nvim_win_set_buf, win, buf)
  editor_gutter(win, false)
  hide_banner()
  pcall(function() require("cockpit.chin").refresh() end)
  S.dash_w = api.nvim_win_is_valid(win) and api.nvim_win_get_width(win) or nil
end

dash_keys = function(buf, acts)
  for _, key in ipairs({ "p", "d", "a", "l", "n", "r", "i", "<CR>", "o", "<Tab>" }) do
    pcall(vim.keymap.del, "n", key, { buffer = buf })
  end
  local function map(lhs, callback)
    vim.keymap.set("n", lhs, callback, { buffer = buf, nowait = true, silent = true })
  end
  local function dispatch(id)
    local handler = S.dash and S.dash.handlers and S.dash.handlers[id]
    if handler then handler() end
  end
  for _, item in ipairs(acts) do map(item.key, function() dispatch(item.id) end) end
  map("i", function()
    fn.jobstart({ fn.expand("~/.config/niri/scripts/cockpit-ipc"), "focusComposer" }, {
      env = { COCKPIT_NVIM_SOCK = vim.env.NVIM_LISTEN_ADDRESS or "", HEIDR_NVIM_SOCK = vim.env.NVIM_LISTEN_ADDRESS or "" },
      detach = true,
    })
  end)
  local function next_tab()
    local dash = S.dash or {}
    local views = dash.views or {}
    if #views < 2 then return end
    local current = 1
    for index, view in ipairs(views) do if view == S.dash_view then current = index; break end end
    S.dash_view = views[(current % #views) + 1]
    if dash.win and api.nvim_win_is_valid(dash.win) then show_scratch(dash.win, dash.cwd) end
  end
  local function enter(line)
    local dash = S.dash or {}
    local line_number = line or (api.nvim_win_get_cursor(0)[1] - 1)
    local id = dash.line_actions and dash.line_actions[line_number]
    if id then dispatch(id)
    elseif acts[1] then dispatch(acts[1].id) end
  end
  S.dash_tab = next_tab
  S.dash_enter = enter
  map("<Tab>", next_tab)
  map("<CR>", enter)
  map("o", enter)
end

-- Re-render the dashboard if it's the editor's current view — called on turn-end so
-- the CHANGES/TESTS tabs update live and the Tests auto-switch fires when the agent
-- reaches the testing stage. No-op if a real file is open instead.
refresh_dashboard = function()
  if not (S.scratchbuf and api.nvim_buf_is_valid(S.scratchbuf)) then return end
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(w) and api.nvim_win_get_buf(w) == S.scratchbuf then
      -- The cwd ALREADY on screen wins over S.selected's: when the cockpit rail drives this
      -- nvim it renders a session's LOCAL mirror path, which is not what agentd reports as
      -- that session's cwd — resolving through S.selected re-rendered a different worktree
      -- (or nothing at all, when nothing is selected in this nvim).
      local cwd = (S.dash and S.dash.cwd) or (S.selected and session_cwd(S.selected))
      if cwd then pcall(show_scratch, w, cwd) end
      return
    end
  end
end

function M.dashboard_snapshot()
  local d = S.dash
  local active = false
  if d and d.win and api.nvim_win_is_valid(d.win) and S.scratchbuf and api.nvim_buf_is_valid(S.scratchbuf) then
    active = api.nvim_win_get_buf(d.win) == S.scratchbuf
  end
  return { active = active, model = (d and d.model) or {} }
end

function M.git_summary(cwd)
  cwd = cwd or fn.getcwd()
  local cache = S.gitdiff[cwd]
  local w = S.workspace
  local remote = w and w.remoteCwd and w.remoteCwd ~= "" and (cwd == w.cwd or cwd == w.remoteCwd)
  if not cache then
    if not S.diff_jobs[cwd] then refresh_git_changes(cwd) end
    return remote and { authoritative = true, loading = true } or nil
  end
  if remote then
    if (os.time() - (cache.at or 0)) > 20 and not S.diff_jobs[cwd] then refresh_git_changes(cwd) end
    if cache.error then return { authoritative = true, error = cache.error } end
    local add, del = 0, 0
    for _, change in ipairs(cache.files or {}) do add = add + (change.add or 0); del = del + (change.del or 0) end
    return { authoritative = true, add = add, del = del, head = cache.head, base = cache.base }
  end
  -- Externally-changed trees (a mutagen mirror sync) never fire an nvim event, so a
  -- diff computed mid-sync would otherwise be reported forever. Re-run in the
  -- background once the value ages out; the stale number still renders this frame.
  --
  -- The TTL alone was not enough: when the VM merged origin/main into every-2447 the
  -- mirror's HEAD jumped ~320 commits ahead of the LOCAL origin/main, the base resolved
  -- against a pre-merge trunk, and the chin reported +96602/-25739 for a four-file diff.
  -- HEAD is the honest invalidator — one rev-parse, and it catches a mutagen write the
  -- moment it lands rather than up to 20s later.
  local head = (fn.systemlist({ "git", "-C", cwd, "rev-parse", "HEAD" }) or {})[1]
  local moved = head and cache.head and head ~= cache.head
  if moved and not S.diff_jobs[cwd] then
    -- A HEAD that outran the local trunk ref makes merge-base — and therefore the whole
    -- diff — meaningless. Refresh the ref first, in the background, then recompute.
    fn.jobstart({ "git", "-C", cwd, "fetch", "--quiet", "--no-tags", "origin", "main" }, {
      on_exit = function() vim.schedule(function() refresh_git_changes(cwd) end) end,
    })
  elseif (os.time() - (cache.at or 0)) > 20 and not S.diff_jobs[cwd] then
    refresh_git_changes(cwd)
  end
  local add, del = 0, 0
  for _, change in ipairs(cache.files or {}) do
    add = add + (change.add or 0)
    del = del + (change.del or 0)
  end
  return { add = add, del = del }
end

function M.dashboard_action(id)
  id = tostring(id or "")
  local handler = S.dash and S.dash.handlers and S.dash.handlers[id]
  if handler then
    handler()
  elseif id == "tab" then
    if S.dash_tab then S.dash_tab() end
  elseif id:sub(1, 4) == "tab:" then
    local want = id:sub(5)
    local d = S.dash or {}
    if vim.tbl_contains(d.views or {}, want) then
      S.dash_view = want
      if d.win and api.nvim_win_is_valid(d.win) then show_scratch(d.win, d.cwd) end
    end
  elseif id:sub(1, 4) == "row:" then
    local line = tonumber(id:sub(5))
    if line and S.dash_enter then S.dash_enter(line) end
  elseif id:sub(1, 4) == "key:" then
    local key = id:sub(5)
    if key == "i" then
      vim.fn.jobstart({ vim.fn.expand("~/.config/niri/scripts/cockpit-ipc"), "focusComposer" },
        { env = { COCKPIT_NVIM_SOCK = vim.env.NVIM_LISTEN_ADDRESS or "", HEIDR_NVIM_SOCK = vim.env.NVIM_LISTEN_ADDRESS or "" }, detach = true })
    end
  end
  return ""
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
  -- A plan still in its PLANNING life (draft/planned — not implementing or
  -- reconciled) is what you switched here to deal with: open it instead of the
  -- dashboard. A remembered editor file still wins (you were mid-something).
  if not (want and fn.filereadable(want) == 1) then
    local plan = load_plan(cwd)
    local phase = plan and plan.progress and plan.progress.phase
    -- Pin the plan only in its KNOWN planning phases. Matching "anything that
    -- isn't implementing/reconciled" meant an off-schema phase a worker invented
    -- ("amendment-approved") pinned the plan over the dash forever.
    if plan and (phase == "draft" or phase == "planned" or phase == nil) then
      local pfile = fn.expand("~/personal/notes/storage/plans/") .. plan.key .. ".md"
      if fn.filereadable(pfile) == 0 then pfile = cwd .. "/.plans/" .. plan.key .. ".md" end
      if fn.filereadable(pfile) == 1 then
        S._program_nav = true
        api.nvim_win_call(ed, function() pcall(vim.cmd, "edit " .. fn.fnameescape(pfile)) end)
        vim.schedule(function() S._program_nav = nil end)
        editor_gutter(ed, true)
        if hide_banner then hide_banner() end
        return
      end
    end
  end
  if want and fn.filereadable(want) == 1 then
    if fn.fnamemodify(api.nvim_buf_get_name(api.nvim_win_get_buf(ed)), ":p") ~= fn.fnamemodify(want, ":p") then
      -- Plugin-driven restore, not user navigation — must not pause live-follow.
      S._program_nav = true
      api.nvim_win_call(ed, function() pcall(vim.cmd, "edit " .. fn.fnameescape(want)) end)
      vim.schedule(function() S._program_nav = nil end)
    end
    editor_gutter(ed, true)
    if hide_banner then hide_banner() end -- restored a file → hide the banner float
  else
    show_scratch(ed, cwd)
  end
end

-- Return the editor to the active session's dashboard (forget the open file so
-- the director stops restoring it). The way back after opening a file.
-- The orchestrator when present (the main-checkout session), else the first roster
-- entry — what a fresh cockpit nvim (or <leader>D with nothing selected) should land on.
local function default_session()
  local main = (os.getenv("HOME") or "") .. "/work/lovable"
  for _, a in ipairs(S.roster) do if a.cwd == main then return a end end
  return S.roster[1]
end

local function to_dashboard()
  if S.workspace then
    local w = S.workspace
    return M.workspace(w.scope, w.id, w.cwd, w.plan, "dashboard", "", w.profile, w.sourceScope, w.remoteCwd)
  end
  if scope == "personal" then
    local ed = target_editor_win()
    if not ed then return end
    local cwd = scope_root()
    local buf = api.nvim_win_get_buf(ed)
    local path = api.nvim_buf_get_name(buf)
    if path ~= "" and vim.bo[buf].buftype == "" then
      local ok, root = pcall(vim.fs.root, path, ".git")
      if ok and root and root ~= "" then cwd = root end
    end
    show_scratch(ed, cwd)
    return
  end
  -- Nothing selected happens in a FRESH cockpit nvim (only the QML rail selects, and it
  -- only drives this nvim on a switch): fall back to the orchestrator instead of a
  -- silent no-op — that silent return was "<leader>D stopped opening the dash".
  if not S.selected then
    local d = default_session()
    if d then
      S.selected = d.id
    else
      -- No roster yet (fresh Cockpit nvim before the rail's first drive): render
      -- the dashboard for the current cwd instead of silently doing nothing.
      local ed = target_editor_win()
      if ed then show_scratch(ed, fn.getcwd()) end
      return
    end
  end
  S.editor = S.editor or {}
  S.editor[S.selected] = nil
  local cwd = session_cwd(S.selected)
  reflect_context((cwd and cwd ~= "") and cwd or fn.getcwd())
end

-- Public: render the session dashboard for an explicit absolute cwd, independent
-- of S.selected. For external drivers (the Quickshell cockpit rail) that pick the
-- session themselves and drive this nvim over the RPC socket.
-- Public: live-follow one agent edit, driven from OUTSIDE (the Quickshell rail). The
-- rail is the only component that sees every scope's events AND maps a remote session's
-- paths onto the local mirror — this nvim's own client spans one scope, so cockpit
-- live-follow cannot originate in here. Both args are LOCAL absolute paths.
-- How long a "I'm reading here" pause survives without any cursor movement. Focusing
-- the rail (or another window) sends nvim no signal, so without this the pause latched
-- forever and a parent watching a streaming child silently followed nothing.
local FOLLOW_PAUSE_TTL = 45
local function follow_pause_expired()
  return S._follow_paused and (os.time() - (S._follow_paused_at or 0)) > FOLLOW_PAUSE_TTL
end

function M.follow_remote(cwd, path, force, line, needle_b64, added_lines)
  if follow_pause_expired() then S._follow_paused, S._follow_paused_at = nil, nil end
  -- v:null over --remote-expr arrives as vim.NIL, which is TRUTHY in Lua —
  -- unnormalized it read as "a line was given", skipping both the snippet
  -- search and the git fallback (every follow landed at the file top).
  if line == vim.NIL or line == 0 then line = nil end
  if needle_b64 == vim.NIL then needle_b64 = nil end
  if added_lines == vim.NIL then added_lines = nil end
  -- Optional hunk locator from the rail: the edit's most distinctive inserted
  -- line, base64ed so quoting can't break the --remote-expr transport.
  local snippet
  if type(needle_b64) == "string" and needle_b64 ~= "" and vim.base64 then
    local ok, dec = pcall(vim.base64.decode, needle_b64)
    if ok and type(dec) == "string" and dec ~= "" then snippet = dec end
  end
  local ed = target_editor_win()
  if not ed then return "" end
  if force then
    S._follow_paused = nil; follow_edit(cwd, path, line, true, true, snippet, added_lines); return ""
  end
  local bn = api.nvim_buf_get_name(api.nvim_win_get_buf(ed))
  -- Follow only while the editor rests on session context — never yank the user out
  -- of their own unrelated file. Session context is: the dashboard (unnamed scratch),
  -- the session's worktree, a PLAN buffer (watching the plan of a working session is
  -- the follow use-case, not a detour), or whatever file the follow itself opened
  -- last (a multi-repo plan otherwise self-blocks after its first out-of-repo edit).
  local plans = fn.expand("~/personal/notes/storage/plans/")
  local mark_state = edit_mark_state()
  local ours = mark_state and mark_state.follow_file
  local stale = (os.time() - (S._follow_paused_at or 0)) > FOLLOW_PAUSE_TTL
  if bn ~= "" and not stale and not (cwd and cwd ~= "" and bn:sub(1, #cwd) == cwd)
     and bn:sub(1, #plans) ~= plans and not bn:find("/%.plans/")
     and bn ~= ours then return "" end
  follow_edit(cwd, path, line, true, nil, snippet, added_lines)
  return ""
end

function M.workspace_cwd()
  local w = S.workspace
  if not w then return fn.getcwd() end
  if fn.isdirectory(w.cwd) == 1 then return w.cwd end
  if w.remoteCwd and w.remoteCwd ~= "" then return w.cwd end
  vim.notify("Cockpit: " .. w.id .. " checkout missing: " .. w.cwd, vim.log.levels.WARN)
  return nil
end

local function sync_scope()
  local next_scope = persisted_scope()
  if not next_scope then
    if uv.fs_stat(mode_path) then return end
    next_scope = detect_scope()
  end
  if next_scope == scope then return end
  local dash = M.dashboard_snapshot().active and S.dash or nil
  local_scope_state[scope] = { drafts = S.drafts, outbox = S.outbox }
  local saved = local_scope_state[next_scope] or {}
  S.drafts, S.outbox = saved.drafts or {}, saved.outbox or {}
  local pipe = S.pipe
  S.pipe, S.connected, S.connecting, S.readbuf = nil, false, false, {}
  if pipe and not pipe:is_closing() then pipe:close() end
  scope = next_scope
  S.selected, S.workspace, S.dash, S._follow, S.cockpit_ctx = nil, nil, nil, nil, nil
  for _, key in ipairs({ "roster", "sources", "chat", "pending", "stream", "stream_since", "lastdur", "edited", "idle_since", "folds", "plan", "devenv", "orphans", "nav_hist", "displayed", "awaiting", "turn_active" }) do
    S[key] = {}
  end
  S.focus, S.nav_idx, S.autopened = 1, 0, false
  if dash and api.nvim_win_is_valid(dash.win) then
    api.nvim_win_call(dash.win, function() vim.cmd.cd(fn.fnameescape(scope_root())) end)
    show_scratch(dash.win, scope_root())
  end
  connect(function() send({ type = "list_sources" }) end)
  pcall(function() require("cockpit.chin").refresh() end)
end

function M.workspace(workspace_scope, id, cwd, plan, view, latest, profile, source_scope, remote_cwd)
  sync_scope()
  if persisted_scope() and normalized_scope(workspace_scope) ~= scope then return "" end
  local snacks = package.loaded["snacks"]
  if snacks and snacks.picker then
    for _, picker in ipairs(snacks.picker.get()) do picker:close() end
  end
  local ed = target_editor_win()
  if not ed then return "" end
  local previous = S.workspace
  local buf = api.nvim_win_get_buf(ed)
  local path = api.nvim_buf_get_name(buf)
  S.workspace_editors = S.workspace_editors or {}
  if previous and vim.bo[buf].buftype == "" and path:sub(1, #previous.cwd + 1) == previous.cwd .. "/"
      and not path:find("/%.plans/") then
    local key = previous.scope .. "/" .. previous.id
    local state = S.workspace_editors[key] or {}
    state.buf, state.view = buf, api.nvim_win_call(ed, fn.winsaveview)
    S.workspace_editors[key] = state
  end
  local same = previous and previous.scope == workspace_scope and previous.id == id
    and previous.sourceScope == source_scope and previous.remoteCwd == remote_cwd
  if previous and (not same or previous.cwd ~= cwd) then
    local pending = S.diff_jobs[previous.cwd]
    if pending and pending.job then pcall(fn.jobstop, pending.job) end
    if pending and pending.pipe and not pending.pipe:is_closing() then pending.pipe:close() end
    S.diff_jobs[previous.cwd] = nil
    if previous.remoteCwd then S.diff_jobs[previous.remoteCwd] = nil end
  end
  if remote_cwd and remote_cwd ~= "" and not (same and previous.remoteCwd == remote_cwd) then
    local pending = S.diff_jobs[cwd]
    if pending and pending.job then pcall(fn.jobstop, pending.job) end
    if pending and pending.pipe and not pending.pipe:is_closing() then pending.pipe:close() end
    S.gitdiff[cwd], S.gitdiff[remote_cwd], S.diff_jobs[cwd] = nil, nil, nil
  end
  S.workspace = { scope = workspace_scope, id = id, cwd = cwd, plan = plan, profile = profile,
    sourceScope = source_scope, remoteCwd = remote_cwd }
  S.selected = id
  if fn.getcwd(ed) ~= cwd and fn.isdirectory(cwd) == 1 then
    api.nvim_win_call(ed, function() vim.cmd.cd(fn.fnameescape(cwd)) end)
  end
  if view == "cycle" then
    local dashboard = M.dashboard_snapshot().active
    local on_plan = path:find("/%.plans/") or path:find("/notes/storage/plans/", 1, true)
    view = same and (dashboard and "code" or (on_plan and "dashboard" or (plan ~= "" and "plan" or "dashboard"))) or "code"
  end
  S._follow_paused = view ~= "" and view ~= "dashboard"
  S._follow_paused_at = os.time()
  S._program_nav = true
  local function open_file(file)
    api.nvim_win_call(ed, function()
      if fn.fnamemodify(api.nvim_buf_get_name(0), ":p") ~= fn.fnamemodify(file, ":p") then
        vim.cmd.edit(fn.fnameescape(file))
      end
    end)
    editor_gutter(ed, true)
    if hide_banner then hide_banner() end
  end
  local function show_view()
    if view == "plan" then
      if plan == "" then vim.notify("Cockpit: " .. id .. " has no bound plan"); return end
      local file = cwd .. "/.plans/" .. plan .. ".md"
      if fn.filereadable(file) == 0 then file = fn.expand("~/personal/notes/storage/plans/") .. plan .. ".md" end
      if fn.filereadable(file) == 0 then vim.notify("Cockpit: plan file missing: " .. plan); return end
      open_file(file)
      return
    end
    if view == "dashboard" or (fn.isdirectory(cwd) == 0 and not (remote_cwd and remote_cwd ~= "" and view == "diff")) then
      show_scratch(ed, cwd)
      if view == "diff" or view == "code" then M.workspace_cwd() end
      return
    end
    local saved = S.workspace_editors[workspace_scope .. "/" .. id]
    local restored = false
    if view ~= "" and saved and saved.buf and api.nvim_buf_is_valid(saved.buf) then
      local name = api.nvim_buf_get_name(saved.buf)
      local owned = name:sub(1, #cwd + 1) == cwd .. "/" or name == saved.follow_file
      if owned and fn.filereadable(name) == 1 then
        api.nvim_win_set_buf(ed, saved.buf)
        if saved.view then api.nvim_win_call(ed, function() fn.winrestview(saved.view) end) end
        restored = true
      end
    end
    if not restored and latest ~= "" and not latest:find("/%.plans/")
        and not latest:find("/notes/storage/plans/", 1, true) and fn.filereadable(latest) == 1 then
      open_file(latest)
      if view == "" then M.follow_remote(cwd, latest, true) end
      restored = true
    end
    if view == "diff" or (view == "code" and not restored) then
      if not restored then api.nvim_win_set_buf(ed, api.nvim_create_buf(true, false)) end
      api.nvim_set_current_win(ed)
      vim.cmd.CockpitChanges()
    elseif not restored then
      show_scratch(ed, cwd)
    end
  end
  local ok, err = pcall(show_view)
  S._program_nav = nil
  if not ok then vim.notify("Cockpit: " .. tostring(err), vim.log.levels.ERROR) end
  pcall(function() require("cockpit.chin").refresh() end)
  return ""
end

function M.dashboard(cwd, id)
  S._follow_paused = nil  -- back at rest: live-follow may drive again
  -- Capture the OUTGOING session's editor file before adopting the new one:
  -- rail-driven switches used to always land on the dashboard, losing the file
  -- the user was working in (the cycle-plan-then-back-to-dash complaint).
  if S.selected then capture_editor(S.selected) end
  -- Adopt the session being shown. The rail picked it and drives us over RPC, but the
  -- selection is what this nvim keys its own per-session state off (the editor file it
  -- restores, the tests auto-switch), so leaving it unset made every externally-driven
  -- dashboard sessionless. Match on the worktree's NAME, not the path: agentd reports a
  -- remote session's cwd as the box sees it, while we are handed the local mirror.
  if id and id ~= "" then
    S.selected = id
  elseif cwd and cwd ~= "" then
    local want = fn.fnamemodify(cwd, ":t")
    for _, a in ipairs(S.roster or {}) do
      if a.cwd and fn.fnamemodify(a.cwd, ":t") == want then S.selected = a.id; break end
    end
  end
  -- reflect_context, not bare scratch: restore the file this session had open
  -- (captured on switch-away); the dashboard is the at-rest fallback. A
  -- deliberate dashboard (to_dashboard / <leader>D) clears the memory first.
  reflect_context(cwd)
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
  vim.notify("Cockpit: tearing down " .. what)
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

on_cockpit_active = function()
  if S.workspace then return end
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

parse_git_diff = function(lines)
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

refresh_git_changes = function(cwd, path, done)
  local w = S.workspace
  local remote = w and w.remoteCwd and w.remoteCwd ~= "" and (cwd == w.cwd or cwd == w.remoteCwd)
  if remote then
    local previous = S.diff_jobs[w.remoteCwd] or S.diff_jobs[w.cwd]
    if previous then previous.done = done or previous.done; return end
    local source_scope = w.sourceScope
    local request = { id = string.format("nvim-diff-%d-%d", fn.getpid(), uv.hrtime()), done = done,
      scope = source_scope, session = w.id, cwd = w.remoteCwd }
    S.gitdiff[w.remoteCwd], S.gitdiff[w.cwd] = nil, nil
    S.diff_jobs[w.remoteCwd], S.diff_jobs[w.cwd] = request, request
    local function fail(message)
      if S.diff_jobs[w.remoteCwd] ~= request then return end
      local snapshot = { files = {}, bypath = {}, at = os.time(), error = message }
      S.gitdiff[w.remoteCwd], S.gitdiff[w.cwd] = snapshot, snapshot
      S.diff_jobs[w.remoteCwd], S.diff_jobs[w.cwd] = nil, nil
      if request.pipe and not request.pipe:is_closing() then request.pipe:close() end
      if request.done then request.done(snapshot) end
      pcall(function() require("cockpit.chin").refresh() end)
    end
    if not source_scope or source_scope == "" then fail("VM diff source scope unavailable"); return end
    local pipe, pending = uv.new_pipe(false), {}
    request.pipe = pipe
    pipe:connect((os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/agentd-" .. source_scope .. ".sock", function(err)
      vim.schedule(function()
        if S.diff_jobs[w.remoteCwd] ~= request then return end
        if err then fail("VM diff connection failed: " .. tostring(err)); return end
        pipe:read_start(vim.schedule_wrap(function(read_err, chunk)
          if S.diff_jobs[w.remoteCwd] ~= request then return end
          if read_err or not chunk then fail("VM diff connection closed"); return end
          each_line(pending, chunk, function(line)
            local ok, reply = pcall(vim.json.decode, line)
            if ok and type(reply) == "table" and reply.type == "changes" then handle(reply, source_scope) end
          end)
        end))
        pipe:write(vim.json.encode({ type = "get_changes", session = w.id, id = request.id }) .. "\n")
      end)
    end)
    vim.defer_fn(function()
      if S.diff_jobs[w.remoteCwd] ~= request then return end
      fail("VM diff request timed out")
    end, 10000)
    return
  end
  if not cwd or fn.isdirectory(cwd) ~= 1 then if done then done(nil, "checkout unavailable") end; return end
  if path and not S.gitdiff[cwd] then path = nil end
  local ok, signs = pcall(require, "hunk-nvim.signs")
  local base = ok and signs.base_for and signs.base_for(cwd) or "HEAD"
  if not base or base == "" then base = "HEAD" end
  -- A repo with no commits has no HEAD: diff against the empty tree so a brand-new
  -- project shows everything as added instead of an empty CHANGES view.
  if base == "HEAD" and fn.systemlist({ "git", "-C", cwd, "rev-parse", "-q", "--verify", "HEAD" })[1] == nil then
    base = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  end
  local previous = S.diff_jobs[cwd]
  if previous and previous.job then pcall(fn.jobstop, previous.job) end
  local request, output, untracked = { files = 0, too_large = false }, {}, {}
  local max_files = cwd:match("/work/lovable%.daphen%-every%-%d+$") and 200 or math.huge
  S.diff_jobs[cwd] = request
  local function apply()
    if S.diff_jobs[cwd] ~= request then return end
    S.diff_jobs[cwd] = nil
    local parsed = request.too_large and { files = {}, bypath = {}, unready = true } or parse_git_diff(output)
    for _, u in ipairs(untracked) do
      if not parsed.bypath[u.path] then
        local h = { old_l1 = 0, old_l2 = 0, l1 = 1, l2 = math.max(1, u.lines), add = u.lines, del = 0 }
        local change = { path = u.path, add = u.lines, del = 0, hunks = { h } }
        parsed.bypath[u.path] = change
        parsed.files[#parsed.files + 1] = change
      end
    end
    table.sort(parsed.files, function(a, b) return a.path < b.path end)
    if path and S.gitdiff[cwd] then
      local cache = S.gitdiff[cwd]
      cache.bypath[path] = nil
      for _, change in ipairs(parsed.files) do cache.bypath[change.path] = change end
      cache.files = {}
      for _, change in pairs(cache.bypath) do cache.files[#cache.files + 1] = change end
      table.sort(cache.files, function(a, b) return a.path < b.path end)
    else
      parsed.at = os.time()
      parsed.head = (fn.systemlist({ "git", "-C", cwd, "rev-parse", "HEAD" }) or {})[1]
      S.gitdiff[cwd] = parsed
    end
    if S.selected and session_cwd(S.selected) == cwd then
    end
    if refresh_dashboard and S.dash and S.dash.cwd == cwd then refresh_dashboard() end
    pcall(function() require("cockpit.chin").refresh() end)
    if done then done(S.gitdiff[cwd]) end
  end
  local function count_untracked(files)
    local next_file, active = 1, 0
    local function pump()
      if S.diff_jobs[cwd] ~= request then return end
      if next_file > #files and active == 0 then vim.schedule(apply); return end
      while active < 24 and next_file <= #files do
        local rel = files[next_file]
        next_file, active = next_file + 1, active + 1
        local lines, offset = 0, 0
        local function complete(fd)
          if fd then vim.uv.fs_close(fd) end
          untracked[#untracked + 1] = { path = rel, lines = math.min(lines, 500) }
          active = active - 1
          pump()
        end
        vim.uv.fs_open(cwd .. "/" .. rel, "r", 438, function(err, fd)
          if err then complete() return end
          local function read_more()
            vim.uv.fs_read(fd, 65536, offset, function(read_err, data)
              if read_err or not data or data == "" or lines >= 500 then complete(fd) return end
              offset = offset + #data
              local _, n = data:gsub("\n", "")
              lines = lines + n
              read_more()
            end)
          end
          read_more()
        end)
      end
    end
    pump()
  end
  local args = { "git", "-C", cwd, "diff", "--no-color", "--no-ext-diff", "--unified=0", base }
  if path and path ~= "" then args[#args + 1] = "--"; args[#args + 1] = path end
  local partial = ""
  request.job = fn.jobstart(args, {
    on_stdout = function(_, data)
      if not data or #data == 0 then return end
      data[1] = partial .. data[1]
      partial = data[#data]
      for index = 1, #data - 1 do
        local line = data[index]
        if line:match("^diff %-%-git ") then
          request.files = request.files + 1
          if request.files > max_files then request.too_large = true; pcall(fn.jobstop, request.job); return end
        end
        if line ~= "" then output[#output + 1] = line end
      end
    end,
    on_exit = function(_, code)
      if S.diff_jobs[cwd] ~= request then return end
      if request.too_large then vim.schedule(apply); return end
      if code ~= 0 then S.diff_jobs[cwd] = nil; return end
      if partial ~= "" then output[#output + 1] = partial end
      local files = {}
      request.job = fn.jobstart({ "git", "-C", cwd, "ls-files", "--others", "--exclude-standard" }, {
        stdout_buffered = true,
        on_stdout = function(_, data)
          for _, f in ipairs(data or {}) do
            if f ~= "" and not f:match("^%.heidr%-pastes/") and not f:match("^agents/") then
              files[#files + 1] = f
              if request.files + #files > max_files then request.too_large = true; break end
            end
          end
        end,
        on_exit = function() if request.too_large then apply() else count_untracked(files) end end,
      })
    end,
  })
  if not request.job or request.job <= 0 then S.diff_jobs[cwd] = nil end
end

git_changes = function(cwd)
  local cache = cwd and S.gitdiff[cwd]
  if cwd and not cache and not S.diff_jobs[cwd] then refresh_git_changes(cwd) end
  return cache and cache.files or {}
end

function M.git_snapshot(cwd, fresh, done)
  cwd = cwd or M.workspace_cwd()
  local w = S.workspace
  local remote = cwd and w and w.remoteCwd and w.remoteCwd ~= "" and (cwd == w.cwd or cwd == w.remoteCwd)
  if not remote then return false end
  if fresh then refresh_git_changes(cwd, nil, done); return true end
  local cache = S.gitdiff[cwd]
  if not cache and not S.diff_jobs[cwd] then refresh_git_changes(cwd, nil, done) end
  return cache or true
end


-- refresh the cached plan progress for every rostered session (git + file reads,
-- so called sparingly: on select, on open, and on a slow timer — not per render)
-- Refresh ONE session's cached plan (a sync git + glob + plan-file reads). Broken out
-- so a session switch can refresh just the session it lands on instead of the whole
-- roster — the full sweep is O(sessions) sync git calls and was the swap lag.
refresh_plan_one = function(a)
  -- Sub-agents share the parent's worktree, so load_plan would hand them the ticket's
  -- plan too — but the plan belongs to the MAIN agent. Subs get none.
  if is_subagent(a) then
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
refresh_plan_bindings = function()
  local bound, changed = {}, false
  for _, a in ipairs(S.roster) do
    if a.plan and a.plan ~= "" then bound[a.plan] = a end
  end
  for _, group in pairs(S.plan_inventory or {}) do
    for _, row in ipairs(group) do
      local next_session = bound[row.slug]
      if (row.session and row.session.id or nil) ~= (next_session and next_session.id or nil) then changed = true end
      row.session = next_session
    end
  end
  return changed
end

local function refresh_plan_inventory()
  local groups = { needs = {}, implementing = {}, reconciled = {} }
  local bound = {}
  for _, a in ipairs(S.roster) do
    if a.plan and a.plan ~= "" then bound[a.plan] = a end
  end
  local dir = fn.expand("~/personal/notes/storage/plans")
  for _, path in ipairs(fn.glob(dir .. "/*.progress.json", false, true)) do
    local ok, progress = pcall(function() return vim.json.decode(table.concat(fn.readfile(path), "\n")) end)
    if ok and type(progress) == "table" then
      local slug = fn.fnamemodify(path, ":t"):gsub("%.progress%.json$", "")
      local md = dir .. "/" .. slug .. ".md"
      local mok, mlines = pcall(fn.readfile, md)
      local body = mok and table.concat(mlines, "\n") or ""
      local status = body:match("> Status:%s*`([^`]+)`") or progress.phase or "draft"
      local flow, done = progress.flow or {}, 0
      for _, step in ipairs(flow) do if step.status == "done" then done = done + 1 end end
      local complete = #flow > 0 and done == #flow
      local bucket
      if body:find("%(unresolved%)") or status == "draft" or status == "amended"
          or (complete and status ~= "reconciled") then
        bucket = "needs"
      elseif status == "reconciled" or progress.phase == "reconciled" then
        bucket = "reconciled"
      else
        bucket = "implementing"
      end
      groups[bucket][#groups[bucket] + 1] = {
        slug = slug, path = md, done = done, total = #flow,
        session = bound[slug], mtime = math.max(fn.getftime(path), fn.getftime(md)),
      }
    end
  end
  local function newer(a, b)
    if a.mtime ~= b.mtime then return a.mtime > b.mtime end
    return a.slug < b.slug
  end
  table.sort(groups.needs, newer)
  table.sort(groups.implementing, newer)
  table.sort(groups.reconciled, newer)
  while #groups.reconciled > 5 do table.remove(groups.reconciled) end
  S.plan_inventory = groups
end

refresh_plans = function()
  for _, a in ipairs(S.roster) do refresh_plan_one(a) end
  refresh_plan_inventory()
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
  -- SINGLE-FLIGHT. cockpit-devenv shells out (process scans) and under load can run
  -- slower than the poll cadence. Without this guard, each tick stacks another
  -- status-per-ctx + orphans batch on top of the still-running one; with several rail
  -- instances alive that cascaded into a fork bomb (thousands of bash). Never start a
  -- new poll while the previous batch is in flight; a stuck batch self-clears after
  -- 30s so a hung job can't lock refresh out forever.
  local now = os.time()
  if S.devenv_inflight and S.devenv_inflight_at and (now - S.devenv_inflight_at) < 30 then return end
  local home = os.getenv("HOME") or ""
  local script = home .. "/.config/niri/scripts/cockpit-devenv"
  if fn.executable(script) == 0 then return end
  S.devenv_inflight = true
  S.devenv_inflight_at = now
  local pending = 1 -- the orphans job; each status job below adds one
  local function done_one()
    pending = pending - 1
    if pending <= 0 then S.devenv_inflight = false end
  end
  local seen = {}
  for _, a in ipairs(S.roster) do
    local ctx = a.cwd and a.cwd ~= "" and cockpit_context(a.cwd)
    if ctx and not seen[ctx] then
      seen[ctx] = true
      pending = pending + 1
      local out = {}
      local ok = pcall(fn.jobstart, { script, "status", ctx }, {
        stdout_buffered = true,
        on_stdout = function(_, d) for _, l in ipairs(d or {}) do if l ~= "" then out[#out + 1] = l end end end,
        on_exit = function()
          local st = (out[1] or ""):gsub("%s+", "")
          if st ~= "" and S.devenv[ctx] ~= st then
            S.devenv[ctx] = st
          end
          done_one()
        end,
      })
      if not ok then done_one() end -- jobstart failed → don't leak the in-flight counter
    end
  end
  -- orphans = running slices whose ctx has no session in the roster
  local oout = {}
  local ok = pcall(fn.jobstart, { script, "orphans" }, {
    stdout_buffered = true,
    on_stdout = function(_, d) for _, l in ipairs(d or {}) do if l ~= "" then oout[#oout + 1] = l end end end,
    on_exit = function()
      local orphans = {}
      for _, dir in ipairs(oout) do
        local ctx = cockpit_context(dir)
        if ctx and not seen[ctx] then orphans[#orphans + 1] = ctx end
      end
      S.orphans = orphans
      done_one()
    end,
  })
  if not ok then done_one() end
end


--------------------------------------------------------------------------------
-- responsive dividers
--------------------------------------------------------------------------------
-- Dividers between the stacked rail panes are neovim's own window separators
-- (WinSeparator, styled via winhighlight below) — no custom winbar rule, which
-- would double up with the separator.


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
-- User navigation pauses live-follow: entering any real file that follow did not
-- open itself means "I'm reading this" — the agent's edits must not yank the view.
-- Returning to the dashboard (scratch) or switching sessions resumes.
vim.api.nvim_create_autocmd("BufEnter", {
  group = vim.api.nvim_create_augroup("CockpitFollowPause", { clear = true }),
  callback = function(ev)
    if S._program_nav then return end
    local name = vim.api.nvim_buf_get_name(ev.buf)
    if name == "" or vim.bo[ev.buf].buftype == "nofile" then
      S._follow_paused = nil                                  -- scratch/dash = at rest
      return
    end
    local state = edit_mark_state()
    local ours = state and state.follow_file
    -- Plan buffers are spectating, not working — they must never pause follow
    -- (watching the plan of a working session is follow's main use-case).
    if name:find("/notes/storage/plans/", 1, true) or name:find("/%.plans/") then return end
    if name ~= ours then S._follow_paused, S._follow_paused_at = true, os.time() end
  end,
})
-- Reading counts, not just navigating: moving the cursor in a real file means
-- "I'm here" even when it's the very file follow opened (a session whose cwd is
-- a parent dir makes every file "session context", so BufEnter alone never
-- paused and follow kept yanking mid-read). Follow's own jumps are wrapped in
-- _program_nav and don't trip this.
vim.api.nvim_create_autocmd("CursorMoved", {
  group = "CockpitFollowPause",
  callback = function(ev)
    if S._program_nav or S._follow_paused then return end
    local name = vim.api.nvim_buf_get_name(ev.buf)
    if name == "" or vim.bo[ev.buf].buftype == "nofile" then return end
    if name:find("/notes/storage/plans/", 1, true) or name:find("/%.plans/") then return end
    S._follow_paused, S._follow_paused_at = true, os.time()
  end,
})

-- The session bound to a plan slug, from the LIVE roster (cross-scope — the
-- work scope's persist lives on the VM, invisible to local file scans).
function M.session_for_plan(slug)
  if not slug or slug == "" then return nil end
  for _, a in ipairs(S.roster or {}) do
    if a.plan == slug and (a.name or a.rawName) then return a.rawName or a.name end
  end
end

function M.setup(opts)
  opts = opts or {}
  load_qsicons()
  target_editor_win()
  -- Embedded cockpit (TermView env): the QML chin renders the statusline; feed it.
  if cockpit_env("COCKPIT") == "1" then pcall(function() require("cockpit.chin").setup() end) end
  scope = persisted_scope() or (opts.scope and normalized_scope(opts.scope)) or scope
  if opts.scopes then ROOTS = opts.scopes end
  S.ns = api.nvim_create_namespace("agent_nvim")
  S.composer_ns = api.nvim_create_namespace("agent_nvim_composer")
  S.chip_ns = api.nvim_create_namespace("agent_nvim_chips")
  S.pad_ns = api.nvim_create_namespace("agent_nvim_chatpad")
  set_hl()
  fn.mkdir(mode_dir, "p")
  local mode_watch = uv.new_fs_event()
  mode_watch:start(mode_dir, {}, vim.schedule_wrap(function(err, name)
    if not err and (not name or name == mode_name) then sync_scope() end
  end))
  api.nvim_create_autocmd("VimLeavePre", { once = true, callback = function()
    mode_watch:stop(); mode_watch:close()
  end })
  vim.defer_fn(set_hl, 200) -- win over markview's own group setup on load
  api.nvim_create_autocmd("ColorScheme", {
    callback = function() set_hl(); vim.defer_fn(set_hl, 120) end,
  })
  api.nvim_create_user_command("CockpitReroot", function(o) reroot(o.args) end, { nargs = 1 })
  api.nvim_create_user_command("CockpitDash", to_dashboard, {}) -- editor back to the session dashboard
  -- global: jump the editor to the active session's dashboard from ANY buffer
  -- (no-ops when there's no session, so it's a safe always-on binding). <leader>D
  -- rather than gd — bare gd is LSP go-to-definition.
  vim.keymap.set("n", "<leader>D", to_dashboard, { desc = "Cockpit: session dashboard" })
  api.nvim_create_user_command("CockpitFollow", function()
    S.follow_edits = not (S.follow_edits ~= false)
    vim.notify("Cockpit: live-follow edits " .. (S.follow_edits and "on" or "off"))
  end, {})
  -- Open a file in a real editor window, NEVER a rail buffer: open_in_editor skips
  -- every agent-* window and makes a fresh vsplit if only the rail is up. The
  -- review-pr skill calls this (`:CockpitEdit <path>`) so the review .md can't land in
  -- the composer/chat even when a rail pane is focused.
  api.nvim_create_user_command("CockpitEdit", function(o) open_in_editor(nil, o.args, nil) end,
    { nargs = 1, complete = "file" })
  -- Legacy Heidr* spellings of the remaining commands.
  for _, suffix in ipairs({ "Reroot", "Dash", "Follow", "Edit" }) do
    api.nvim_create_user_command("Heidr" .. suffix, function(o)
      local prefix = o.range > 0 and (o.line1 .. "," .. o.line2) or ""
      local args = o.args ~= "" and (" " .. o.args) or ""
      vim.cmd(prefix .. "Cockpit" .. suffix .. args)
    end, { nargs = "*", range = true })
  end

  -- The banner is a float anchored over the editor window and belongs to the DASHBOARD
  -- only. If that window switches to any real buffer (a file the agent or you opened via
  -- a path that skips hide_banner), close it so it never draws over code — a catch-all
  -- for the open paths the explicit hide_banner calls miss.
  api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinEnter", "WinClosed" }, {
    callback = function()
      if not (S.banner_win and api.nvim_win_is_valid(S.banner_win)) then return end
      -- if the dashboard buffer isn't visible in ANY window, the banner has nothing to
      -- sit over → close it (catch-all for every path that leaves a real file showing).
      local shown = false
      for _, w in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_is_valid(w) and api.nvim_win_get_buf(w) == S.scratchbuf then shown = true break end
      end
      if not shown and hide_banner then hide_banner() end
    end,
  })
  -- Line gutter is DEFAULT-IN: driven off the buffer a window shows, not off each file-open
  -- path (so none can forget it — that was the follow_edit bug). Only the dashboard scratch
  -- opts OUT; floats manage themselves.
  api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinEnter" }, {
    callback = function()
      for _, w in ipairs(api.nvim_list_wins()) do
        local cfg = api.nvim_win_get_config(w)
        if cfg.relative == nil or cfg.relative == "" then
          editor_gutter(w, api.nvim_win_get_buf(w) ~= S.scratchbuf)
        end
      end
    end,
  })
  -- Auto-reflow the dashboard only when the editor pane's WIDTH actually changes.
  -- The dashboard layout depends on width, not height — and toggling the roster (a
  -- DIFFERENT pane) fires WinResized too. Re-rendering + re-placing the banner on
  -- those unrelated resizes was what broke the card (and flickered). Gate on a real
  -- width change so a roster toggle / height-only resize leaves the dashboard alone.
  local dash_reflow_pending = false
  api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    callback = function()
      if dash_reflow_pending then return end
      if not (S.scratchbuf and api.nvim_buf_is_valid(S.scratchbuf)) then return end
      dash_reflow_pending = true
      vim.schedule(function()
        dash_reflow_pending = false
        for _, w in ipairs(api.nvim_list_wins()) do
          if api.nvim_win_is_valid(w) and api.nvim_win_get_buf(w) == S.scratchbuf then
            if api.nvim_win_get_width(w) ~= S.dash_w then -- width changed → reflow; else no-op
              local cwd = (S.dash and S.dash.cwd) or (S.selected and session_cwd(S.selected))
              if cwd then pcall(show_scratch, w, cwd) end
            end
          end
        end
      end)
    end,
  })
  if cockpit_env("TITLE") then
    -- Cockpit-shell nvim (QML rail drives it over RPC): render the at-rest home
    -- dash on boot so the pane is never blank before the rail's first drive.
    local function first_dash() vim.schedule(function() if not S.workspace then M.dashboard(scope_root()) end end) end
    if vim.v.vim_did_enter == 1 then first_dash()
    else api.nvim_create_autocmd("VimEnter", { once = true, callback = first_dash }) end
  end
end

return M
