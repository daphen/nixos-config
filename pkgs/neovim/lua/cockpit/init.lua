-- Cockpit — the rail for orchestrating agentd sessions.
-- agents. Three stacked windows in one column:
--   • roster  (top, sticky)   — sessions with live state, focus-ring selection
--   • chat    (middle, scrolls)— the active session's transcript, markdown+TS
--   • composer(bottom, grows)  — a real editable buffer with attachment chips
--
-- Scope = one agentd instance = one socket. Set COCKPIT_SCOPE per niri workspace to
-- get independent rails (e.g. lovable vs personal).
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

local WIDTH = 80
local COMPOSER_MAX = 12

local function cockpit_env(name)
  local current = vim.env["COCKPIT_" .. name]
  return current and current ~= "" and current or vim.env["HEIDR_" .. name]
end

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

-- A volt-style progress bar: `width` vertical bars, the first `done/total` share in
-- `fillhl`, the rest in `emptyhl`. Returns (text, segs) where segs are byte columns
-- (each │ is 3 bytes) so callers drop it straight into a box row or a decor line.
local function progress_bar(done, total, width, fillhl, emptyhl)
  width = width or 16
  total = math.max(1, total or 1)
  local filled = math.max(0, math.min(width, math.floor((done / total) * width + 0.5)))
  local s = string.rep("┃", width) -- heavy vertical: matches the quickshell minimap tick thickness
  return s, { { 0, filled * 3, fillhl or "CockpitStream" }, { filled * 3, width * 3, emptyhl or "CockpitMuted" } }
end

-- Scope resolution: an explicit COCKPIT_SCOPE wins (with HEIDR_SCOPE fallback); otherwise
-- derive from the focused niri workspace — the `lovable` workspace hosts lovable
-- work, everything else (and off-niri) is personal. So an nvim started anywhere on
-- the lovable workspace is a lovable rail, not just the cockpit's launch command.
local function detect_scope()
  local env = cockpit_env("SCOPE")
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
  readbuf = "",
  spin = 0,
  timer = nil,
  saved_gcr = nil,
}

local render, render_roster, render_chat, render_changes, handle, on_read, try_connect, connect, send, git_changes, refresh_git_changes, parse_git_diff
local refresh_dashboard, hide_banner
local start_session, view_session, open_picker, ensure_buf, focus_composer, refresh_plans, refresh_plan_one, refresh_plan_bindings, refresh_devenv, sync_approval_keys
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
  -- Electric: the dashboard's own accent (matches the HEIÐR banner ink). Scoped to
  -- the resting view so the rail's orange signal stays untouched everywhere else.
  hl("CockpitElectric", { fg = "#5566ff", bold = true })
  -- Softer electric variant — the spinner + streaming session name read off this.
  hl("CockpitElectricSoft", { fg = elec_soft, bold = true })
  -- active dashboard tab: an Electric pill (elevated bg) so the selected view reads at a
  -- glance against the dimmed inactive tabs, without a full box on the border line.
  hl("CockpitTabActive", { fg = "#5566ff", bg = p.bg_surface3 or p.bg_selection or cardbg, bold = true })
  -- Neutral heading colour for titles/section labels: orange is a SIGNAL (selection,
  -- active state, identity), not the colour of every header — a bold near-fg reads as
  -- a heading while keeping the accent rare and meaningful.
  hl("CockpitTitle", { fg = p.fg or "#c7ccd1", bold = true })
  hl("CockpitFocusName", { fg = p.fg or "#c7ccd1", bold = true }) -- focused-but-not-open row
  hl("CockpitMuted", { fg = p.fg_muted or "#5c6773" })
  hl("CockpitFile", { fg = p.fg or "#c7ccd1" }) -- neutral file-path text (status lives on the dot)
  hl("CockpitHunkRange", { fg = p.blue or p.cyan or "#5aa9e6" }) -- hunk line-range in the chat
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
  -- active-session name chip: a distinct elevation from the box surface / CockpitCard so
  -- the selected name reads as its own pill (bg_surface3 / selection tone).
  hl("CockpitNameCard", { bg = p.bg_surface3 or p.bg_selection or p.bg_surface2 or cardbg })
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
  hl("CockpitSel", { bg = p.bg_surface3 or p.bg_selection or surface, bold = true }) -- picker selection bar
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
    return { key = "needs_input", glyph = GLYPH.needs_input, name = "CockpitAttn", swatch = "CockpitAccent",
      pill = "CockpitPillAttn", cap = "CockpitCapAttn", label = "needs input" }
  end
  local st = a.status or "idle"
  if st == "streaming" then
    local d = dur(S.stream_since[a.id])
    -- Electric (not green): the spinner + "working" label ARE the loading indicator, so they
    -- carry the dashboard's electric accent; green (CockpitStream) stays reserved for success
    -- semantics (diff +adds, plan-done, tests-pass, devenv running).
    return { key = "streaming", glyph = SPIN[(S.spin % #SPIN) + 1], name = "CockpitElectricSoft", swatch = "CockpitElectricSoft",
      pill = "CockpitPillStream", cap = "CockpitCapStream", label = d and ("working " .. d) or "working" }
  elseif st == "error" then
    return { key = "error", glyph = GLYPH.error, name = "CockpitErr", swatch = "CockpitErr",
      pill = "CockpitPillErr", cap = "CockpitCapErr", label = "error" }
  elseif st == "reconnecting" then
    -- pi crashed; the supervisor is respawning it. Amber + spinner so it reads as a
    -- transient hiccup, not a dead session.
    return { key = "reconnecting", glyph = SPIN[(S.spin % #SPIN) + 1], name = "CockpitAttn", swatch = "CockpitAttn",
      pill = "CockpitPillAttn", cap = "CockpitCapAttn", label = "reconnecting…" }
  end
  local d = dur(S.idle_since[a.id])
  -- idle is the resting state: plain readable text, no pill (a filled pill's
  -- dark-on-blue is fragile against darker theme blues, and idle shouldn't shout).
  -- The swatch is a soft amber so idle sessions still carry colour.
  return { key = "idle", glyph = GLYPH.idle, name = "CockpitIdle", swatch = "CockpitSwatchIdle", plain = true,
    pill = "CockpitIdle", cap = "CockpitIdle", label = d and ("idle " .. d) or "idle" }
end

-- Session display name: prefer the ticket id (every-1234) embedded in the
-- cwd-derived session name, else the raw name — keeps header/roster readable.
local function profile_label(profile)
  return ({
    ["lovable-orchestrator"] = "ORCH",
    ["lovable-worker"] = "WORK",
    ["lovable-reviewer"] = "REVIEW",
    ["lovable-watcher"] = "WATCH",
    chat = "CHAT",
    coding = "CODE",
  })[profile] or "?"
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

-- The roster row a session belongs under: a sub → its parent's name (authoritative)
-- or, for a legacy parent-less sub, its worktree cwd; a primary → its own name. A
-- family = a primary plus everything keyed to it. Grandchildren keyed by parent-name
-- collapse into the same family as their parent once the parent is present.
local function family_of(a)
  if a.parent and a.parent ~= "" then return "n:" .. a.parent end
  if is_subagent(a) then return "c:" .. (a.cwd or a.id) end
  return "n:" .. (a.name or a.id)
end

-- One file-stat row (path + right-aligned, colour-coded +adds −dels) sized to the
-- rail width W. The path is head-truncated with … so a long monorepo path never
-- soft-wraps and splits the number column onto a second, breakindented row (the
-- old layout padded every path to the LONGEST path's column, which forced the
-- numbers off-width). acol/dcol are pre-padded sign columns so several rows' signs
-- line up; omit them for a plain (no-stats) row. Caller recolours via line:find.
local function file_row(W, indent, path, acol, dcol)
  -- acol+dcol → the "+N  -M" stat block; acol alone → a single right-aligned label
  -- (e.g. "untracked" for files git has no diff stats for).
  local nums = acol and (dcol and (acol .. "  " .. dcol) or acol) or nil
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
-- muted + title accent, and fills every row with `surface` (default CockpitBox).
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
    decor[#decor + 1] = { line = hln, fg = "CockpitTitle", cs = 0, ce = #head }
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
  if nofill then surface = nil else surface = surface or "CockpitBox" end
  local bord = "CockpitDivider" -- box outline == the chat pane's hairpin border colour
  local inner = W - 6 -- W minus "│  " (3) + "  │" (3): 2-space inner pad each side
  local head = (icon and (icon .. " ") or "") .. (title or "")
  if title_above then
    local hln = push(head)
    decor[#decor + 1] = { line = hln, fg = "CockpitTitle", cs = 0, ce = #head }
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
    decor[#decor + 1] = { line = tl, fg = "CockpitTitle", cs = #"┌─ ", ce = #"┌─ " + #head }
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
      placeholder_hl = "CockpitMuted" }
  elseif m == "input" or m == "editor" then
    return { kind = "type", ap = ap, editable = true, insert = true, hide_cursor = false,
      placeholder = "type your reply · ⏎ to send · esc cancels", placeholder_hl = "CockpitAttn" }
  else
    local ph = (m == "select") and ("↑ pick an option above · 1–" .. math.min(9, #(ap.options or {})))
      or "↑ answer above · y / n · esc cancels"
    return { kind = "choose", ap = ap, editable = false, insert = false, hide_cursor = true,
      placeholder = ph, placeholder_hl = "CockpitAttn" }
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
    vim.o.guicursor = "a:CockpitCursorFloat" -- bg-matching → invisible while answering
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
  local parts = { "%#" .. (ss.swatch or ss.name) .. "#  " .. gl .. "%#" .. ss.name .. "#  " .. ss.label,
    "%#CockpitMuted#  · " .. profile_label(a.profile) }
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
      parts[#parts + 1] = "%#CockpitMuted#  · " .. doing
    end
  end
  -- queued messages (held until the turn ends): always-visible count in the
  -- header so it's obvious something is queued, not just a line buried in the chat.
  local q = S.queued and S.queued[S.selected]
  if q and q ~= "" then
    local n = select(2, q:gsub("\n\n", "")) + 1
    parts[#parts + 1] = "%#CockpitAttn#  " .. GLYPH.queued .. " " .. n .. " queued"
  end
  -- plan progress (◆ N/N) now lives in the lualine (M.plan_chip); this header
  -- stays focused on the live working state + spinner.
  if #S.paste_images > 0 then
    parts[#parts + 1] = "%#CockpitMuted#  " .. ICON.image .. " ×" .. #S.paste_images
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
  -- indented beneath it, not N look-alike top-level rows. Family = the parent the
  -- spawner stamped (family_of), so nesting holds regardless of how the parent named
  -- its worker; cwd is only the legacy fallback for parent-less restored subs.
  do
    local inset = {}
    for _, a in ipairs(displayed) do inset[a.id] = true end
    -- a displayed sub-agent needs its parent present as the group header, even idle.
    -- Pull it from the full roster: a named parent matches by name; a legacy cwd sub
    -- matches the non-sub session sharing its worktree.
    for _, a in ipairs(displayed) do
      if is_subagent(a) then
        local key = family_of(a)
        for _, p in ipairs(S.roster) do
          if not inset[p.id] then
            local hit = ("n:" .. (p.name or "")) == key
              or (key:sub(1, 2) == "c:" and not is_subagent(p) and ("c:" .. (p.cwd or "")) == key)
            if hit then displayed[#displayed + 1] = p; inset[p.id] = true; break end
          end
        end
      end
    end
    local fam = {}
    for _, a in ipairs(displayed) do
      local k = family_of(a); fam[k] = fam[k] or {}; fam[k][#fam[k] + 1] = a
    end
    local order, seen = {}, {}
    for _, a in ipairs(displayed) do
      local k = family_of(a)
      if not seen[k] then
        seen[k] = true
        local m = fam[k]
        if #m > 1 then
          table.sort(m, function(x, y) -- primary/header first, then subs by name
            local sx, sy = is_subagent(x), is_subagent(y)
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

  -- Which families have their header (the parent/primary) on screen: a sub-agent only
  -- renders nested (↳ + bare tail) when its parent is actually above it. An orphaned
  -- sub (parent crashed/stopped) renders as a normal top-level row with its full name,
  -- instead of a ↳ pointing at nothing. Keyed by family_of so a sub and its parent
  -- share the key (sub → parent name, primary → own name).
  local primary_present = {}
  for _, a in ipairs(displayed) do
    if not is_subagent(a) then primary_present[family_of(a)] = true end
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
    -- Collapsed = a glance card: the active session titled + one dot per session (a
    -- spinner while working). Only the EXPANDED roster (show_all — focused, or pinned via
    -- C-t) lists sessions by name. So "which worktree am I in" is always answered — a
    -- working background session can't masquerade as the active one by being the only
    -- named row on screen. (filt / no-selection still fall through to the list.)
    local collapsed = (not S.show_all) and (not filt) and (S.selected ~= nil)
    if collapsed or #displayed == 0 then
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
        center("no match for /" .. S.roster_filter, { { 0, -1, "CockpitMuted" } })
        center("esc clears the filter", { { 0, -1, "CockpitMuted" } })
      elseif #S.roster == 0 then
        local g = fn.nr2char(0xf0766) -- md-plus-circle-outline
        local t = g .. "  no sessions yet"
        center(t, { { 0, #g, "CockpitAccent" }, { #g, #t, "CockpitTitle" } })
        center("n to start · . for the current dir", { { 0, -1, "CockpitMuted" } })
      else
        -- nothing needs attention: the selected session name (ALL CAPS) as a centred
        -- title — with its plan progress (N/M + bar) inline when it has a plan —
        -- then a row with state swatches hard-LEFT and a Ctrl+t keycap hint
        -- hard-RIGHT (space-filled between, no centre dot).
        local title = ((S.selected and short_name(S.selected)) or scope):upper()
        local pl = S.selected and S.plan[S.selected]
        if pl and pl.total and pl.total > 0 then
          local frac = pl.done .. "/" .. pl.total
          local btext, bsegs = progress_bar(pl.done, pl.total, 12, "CockpitElectric", "CockpitDivider")
          local line = title .. "   " .. frac .. "  " .. btext
          local segs = { { 0, #title, "CockpitTitle" } }
          local fo = #title + 3; segs[#segs + 1] = { fo, fo + #frac, "CockpitMuted" }
          local bo = fo + #frac + 2
          for _, s in ipairs(bsegs) do segs[#segs + 1] = { bo + s[1], bo + s[2], s[3] } end
          center(line, segs)
        else
          center(title, { { 0, -1, "CockpitTitle" } })
        end
        add("")
        local left, segs = "", {}
        for i, a in ipairs(S.roster) do
          local ss = session_state(a)
          -- idle = a plain swatch dot; every non-idle state shows its own glyph so the
          -- card conveys attention at a glance: spinner while working, ? needs-input, ! error.
          local gl = ss.plain and ICON.swatch or ss.glyph
          segs[#segs + 1] = { #left, #left + #gl, ss.swatch or ss.name }
          left = left .. gl
          if i < #S.roster then left = left .. "   " end -- gap between swatches
        end
        local right, rseg = "", {}
        local a1 = #right; right = right .. " Ctrl "; rseg[#rseg + 1] = { a1, #right, "CockpitKeyCap" }
        local a2 = #right; right = right .. " + ";    rseg[#rseg + 1] = { a2, #right, "CockpitMuted" }
        local a3 = #right; right = right .. " t ";    rseg[#rseg + 1] = { a3, #right, "CockpitKeyCap" }
        local a4 = #right; right = right .. "  toggle roster"; rseg[#rseg + 1] = { a4, #right, "CockpitMuted" }
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
      -- ONE aligned row per session (Volt-style): swatch + name hard-left, metadata
      -- (status · plan · devenv-link) right-flushed into a clean column so every row's
      -- numbers and icons line up. Nest a sub-agent (↳ + bare tail) only when its
      -- parent is on screen; an orphan renders top-level with its full name.
      local sub = is_subagent(a) and primary_present[family_of(a)]
      local nm = short_name(a.name)
      if sub then nm = nm:gsub("^.- · ", "") end
      local dr = S.drafts[a.id]
      if dr and dr:gsub("%s", "") ~= "" then nm = nm .. "  ✎" end
      local gl = (sstate.key == "streaming") and sstate.glyph or ICON.swatch -- spinner while working, else the rounded-square status swatch (colour = state)
      local lead = sub and "  ↳ " or ""
      -- LEFT: swatch + name, then plan progress (Nucleo tasks glyph + N/M) right after.
      local left = lead .. gl .. " " .. nm
      local namecol = (isSel or show_focus) and "CockpitFocusName" or "CockpitFile"
      local segs = {
        { #lead, #lead + #gl, sstate.swatch or sstate.name },
        { #lead + #gl, #left, namecol },
      }
      local role = profile_label(a.profile)
      local role_start = #left
      left = left .. "  " .. role
      segs[#segs + 1] = { role_start + 2, #left, "CockpitMuted" }
      local pl = S.plan[a.id]
      if pl and pl.total and pl.total > 0 then
        local chip = "   " .. ICON.plan .. " " .. pl.done .. "/" .. pl.total
        local cs = #left; left = left .. chip
        segs[#segs + 1] = { cs, #left, (pl.phase == "reconciled") and "CockpitStream" or "CockpitMuted" }
      end
      -- RIGHT cluster: agent status, then the devenv link glyph ALL THE WAY RIGHT
      -- (green=running · red=broken · muted=stopped). The devenv column is always
      -- reserved (a blank when there's no context) so the agent status left of it
      -- aligns across every row.
      local right, rseg = "", {}
      local function radd(s, hlg)
        if right ~= "" then right = right .. "   " end
        local o = #right; right = right .. s; rseg[#rseg + 1] = { o, #right, hlg }
      end
      radd(sstate.label, sstate.name)
      local dctx = a.cwd and a.cwd ~= "" and cockpit_context(a.cwd)
      local dv = dctx and S.devenv[dctx]
      local dgl = dv and ((dv == "running") and ICON.dev_up or (dv == "broken") and ICON.dev_broken or ICON.dev_down) or " "
      radd(dgl, (dv == "running") and "CockpitStream" or (dv == "broken") and "CockpitErr" or "CockpitMuted")
      local inner = W - 6
      -- Outline the CURRENT item with the rail's hairpin box (replaces the neovim
      -- cursor): the focused row while the roster is focused, else the open session.
      -- Accent border under the j/k cursor, divider border for the resting selection.
      local boxed = (S.roster_active and i == S.focus) or (not S.roster_active and isSel)
      -- content column = inner minus "│ " (2) on the left + "   │" (4) on the right,
      -- so there's a 3-cell inset between the content and the border. Unboxed rows use
      -- the identical column ("  " left + 4 spaces right) so metadata never shifts.
      local cinner = inner - 6
      if boxed then
        local bc = show_focus and "CockpitElectric" or "CockpitDivider"
        local topstr = "┌" .. string.rep("─", inner - 2) .. "┐"
        add(topstr, { { 0, #topstr, bc } })
        local fill = string.rep(" ", math.max(2, cinner - fn.strdisplaywidth(left) - fn.strdisplaywidth(right)))
        local pre = #("│ ") -- 4 bytes (│ is 3 + space)
        local bsegs = { { 0, 3, bc } } -- left nested │
        for _, s in ipairs(segs) do bsegs[#bsegs + 1] = { s[1] + pre, s[2] + pre, s[3] } end
        local off = pre + #left + #fill
        for _, s in ipairs(rseg) do bsegs[#bsegs + 1] = { s[1] + off, s[2] + off, s[3] } end
        local body = "│ " .. left .. fill .. right .. "   │"
        bsegs[#bsegs + 1] = { #body - 3, #body, bc } -- right nested │
        mainline[i] = add(body, bsegs)
        local botstr = "└" .. string.rep("─", inner - 2) .. "┘"
        add(botstr, { { 0, #botstr, bc } })
      else
        local fill = string.rep(" ", math.max(2, cinner - fn.strdisplaywidth(left) - fn.strdisplaywidth(right)))
        local usegs = {}
        for _, s in ipairs(segs) do usegs[#usegs + 1] = { s[1] + 2, s[2] + 2, s[3] } end -- +2 bytes for "  "
        local off = 2 + #left + #fill
        for _, s in ipairs(rseg) do usegs[#usegs + 1] = { s[1] + off, s[2] + off, s[3] } end
        mainline[i] = add("  " .. left .. fill .. right .. "    ", usegs)
      end
    end
    if not S.show_all and hidden > 0 then
      local t = hidden .. " idle · z for all"
      add(t, { { 0, #t, "CockpitMuted" } })
    end
    -- orphan devenvs: a slice is running for a worktree with no session in the roster
    -- (a leak — visible so it doesn't pile up unseen). `slice-down <dir>` clears one.
    if S.orphans and #S.orphans > 0 then
      local t = #S.orphans .. " orphan devenv" .. (#S.orphans > 1 and "s" or "") .. ": " .. table.concat(S.orphans, ", ")
      add(t, { { 0, -1, "CockpitErr" } })
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
        { end_col = d.selbg[2], hl_group = "CockpitNameCard", priority = 55 })
    end
    if d.fg then pcall(api.nvim_buf_add_highlight, S.buf, S.ns, d.fg, d.line, d.cs or 0, d.ce or -1) end
    if d.card then
      pcall(api.nvim_buf_set_extmark, S.buf, S.ns, d.line, 0, { line_hl_group = "CockpitCard", priority = 90 })
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

-- Bottom-anchor a short conversation: when the rendered content occupies fewer screen
-- rows than the chat window, nvim leaves it pinned to the TOP with dead space below (a
-- short buffer can't scroll). Pad the top with blank virtual lines so the newest message
-- sits at the BOTTOM and you read upward — chat-app style. Uses its OWN namespace so it
-- can clear+recompute without touching the message decor, forces topline=1 so the pad
-- (drawn above line 1) is actually on-screen, and runs deferred too because markview
-- renders AFTER render_chat and changes the true display height.
local function bottom_anchor()
  if not (S.chatwin and api.nvim_win_is_valid(S.chatwin) and S.view == "chat") then return end
  if not (S.chatbuf and api.nvim_buf_is_valid(S.chatbuf)) then return end
  api.nvim_buf_clear_namespace(S.chatbuf, S.pad_ns, 0, -1)
  local winh = api.nvim_win_get_height(S.chatwin)
  -- CHEAP early-out: if the buffer already has ≥ winh lines, display rows ≥ line count
  -- (wrapping only ADDS rows), so the content already fills the window — no top-pad is
  -- possible. Return WITHOUT nvim_win_text_height, which scans the whole buffer (O(lines))
  -- and, run twice per render during streaming on a big transcript, was the rail's lag.
  -- Only a genuinely short buffer needs the precise display-height check below.
  if api.nvim_buf_line_count(S.chatbuf) >= winh then return end
  local ok, h = pcall(api.nvim_win_text_height, S.chatwin, {})
  local th = (ok and type(h) == "table" and h.all) or api.nvim_buf_line_count(S.chatbuf)
  if th < winh then
    local blanks = {}
    for _ = 1, (winh - th) do blanks[#blanks + 1] = { { "", "Normal" } } end
    pcall(api.nvim_buf_set_extmark, S.chatbuf, S.pad_ns, 0, 0,
      { virt_lines = blanks, virt_lines_above = true })
    pcall(api.nvim_win_call, S.chatwin, function()
      fn.winrestview({ topline = 1, lnum = api.nvim_buf_line_count(S.chatbuf), col = 0, leftcol = 0 })
    end)
  end
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
    decor[#decor + 1] = { line = push(empty), fg = "CockpitMuted" }
  else
    if chat and chat.more and chat.more > 0 then
      local t = "  ⤒ " .. chat.more .. " earlier messages — zo to load all"
      decor[#decor + 1] = { line = push(t), fg = "CockpitMuted" }
      push("")
    end
    if chat and chat.msgs then
      for mi, m in ipairs(chat.msgs) do
        if mi > 1 then push(""); push("") end
        local isUser = m.role == "user"
        local folded = folds[mi]
        local caret = folded and FOLDED or OPEN
        local label = isUser and "you" or "agent"
        -- your (user) messages: a 2-col indent (o) + blue role bar + a soft blue fill on
        -- the header and body lines (the "sent message" card). The empty blank-bg pad
        -- rows above/below are intentionally NOT re-added — the fill hugs real content only.
        local o = isUser and "  " or ""
        local hdr = o .. caret .. " " .. BAR .. " " .. label
        blocks[#blocks + 1] = #lines + 1 -- 1-indexed bufline of this header
        -- caret dim · a slim role-coloured bar (you=cool blue, agent=green; orange stays
        -- reserved for selection/attention) · label in neutral bold, not a saturated wash
        local bl0 = push(hdr, mi)
        if isUser then decor[#decor + 1] = { line = bl0, bg = "CockpitUserBg" } end
        decor[#decor + 1] = { line = bl0, fg = "CockpitMuted", cs = #o, ce = #o + #caret }
        decor[#decor + 1] = { line = bl0, fg = isUser and "CockpitHunkRange" or "CockpitStream", cs = #o + #caret + 1, ce = #o + #caret + 1 + #BAR }
        decor[#decor + 1] = { line = bl0, fg = "CockpitTitle", cs = #o + #caret + 2 + #BAR, ce = #hdr }
        if folded then
          local n = select(2, (m.text or ""):gsub("\n", "\n")) + 1
          local fl = push(o .. "⋯ " .. n .. " lines", mi)
          if isUser then decor[#decor + 1] = { line = fl, bg = "CockpitUserBg" } end
          decor[#decor + 1] = { line = fl, fg = "CockpitMuted" }
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
                -- hard-break a single token wider than the line (URLs/paths have no
                -- spaces, so word-wrap alone emits an over-long line that soft-wraps —
                -- and the bg extmark can't paint the wrapped continuation → the notch).
                while fn.strdisplaywidth(wd) > avail do
                  if cur ~= "" then chunks[#chunks + 1] = cur; cur = "" end
                  local n = avail
                  while n > 1 and fn.strdisplaywidth(fn.strcharpart(wd, 0, n)) > avail do n = n - 1 end
                  local take = fn.strcharpart(wd, 0, n)
                  chunks[#chunks + 1] = take
                  wd = wd:sub(#take + 1)
                end
                local cand = cur == "" and wd or (cur .. " " .. wd)
                if cur ~= "" and fn.strdisplaywidth(cand) > avail then chunks[#chunks + 1] = cur; cur = wd
                else cur = cand end
              end
              if cur ~= "" then chunks[#chunks + 1] = cur end
            end
            for _, ch in ipairs(chunks) do
              local bl = push(o .. ch, mi)
              decor[#decor + 1] = { line = bl, bg = "CockpitUserBg" }
              decor[#decor + 1] = { line = bl, fg = "CockpitFile", cs = #o, ce = -1 }
            end
          end
        else
          local hq, hi = m.hunks or {}, 0
          local in_fence = false
          for _, para in ipairs(vim.split(m.text or "", "\n", { plain = true })) do
            local is_recap = para:match("^⟢") or para:match("^✧")
            local recap_body = is_recap and para:gsub("^⟢%s*", ""):gsub("^✧%s*", "") or ""
            if is_recap and not recap_body:match("%S") then
              -- bare recap marker with no text → skip entirely (no empty gray band)
            elseif is_recap then
              -- turn-recap callout: a soft fill on the recap TEXT lines ONLY — no blank
              -- padded bg rows above/below. Those empty CockpitSummaryBg rows were THE gray
              -- band that showed above the next message. Text is HARD-wrapped into 2-space-
              -- padded real lines (soft-wrap+breakindent left a bg notch). ⟢ is U+27E2.
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
                decor[#decor + 1] = { line = bl, bg = "CockpitSummaryBg" }
                if i == 1 then
                  decor[#decor + 1] = { line = bl, fg = "CockpitAccent", cs = 2, ce = 5 } -- ⟢
                  decor[#decor + 1] = { line = bl, fg = "CockpitTitle", cs = 6, ce = -1 }
                else
                  decor[#decor + 1] = { line = bl, fg = "CockpitTitle", cs = 2, ce = -1 }
                end
              end
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
                decor[#decor + 1] = { line = bl, bg = "CockpitCode" }
              elseif in_fence then
                decor[#decor + 1] = { line = bl, bg = "CockpitCode" }
                decor[#decor + 1] = { line = bl, virt = "  " }
              elseif para:match("^⚙ ") then
                decor[#decor + 1] = { line = bl, fg = "CockpitMuted" }
                decor[#decor + 1] = { line = bl, fg = "CockpitMuted", cs = 0, ce = 3 }
                if nav then
                  local display = fn.fnamemodify(nav.path, ":.")
                  local fs = para:find(display, 1, true)
                  if fs then decor[#decor + 1] = { line = bl, fg = "CockpitFocusName", cs = fs - 1, ce = fs - 1 + #display } end
                  local ps, pe = para:find("%+%d+")
                  if ps then decor[#decor + 1] = { line = bl, fg = "CockpitStream", cs = ps - 1, ce = pe } end
                  local ms, me = para:find("%-%d+", (pe or 0) + 1)
                  if ms then decor[#decor + 1] = { line = bl, fg = "CockpitErr", cs = ms - 1, ce = me } end
                end
              elseif para:sub(1, #THINK) == THINK then
                decor[#decor + 1] = { line = bl, fg = "CockpitMuted" }
              end
            end
          end
        end
      end
    end
    -- live streaming block (superseded by message_end when the turn completes)
    local sv = S.selected and S.stream[S.selected]
    if sv and sv ~= "" then
      if has_any then push(""); push("") end
      local shdr = OPEN .. " " .. BAR .. " agent"
      local sbl = push(shdr)
      decor[#decor + 1] = { line = sbl, fg = "CockpitMuted", cs = 0, ce = #OPEN }
      decor[#decor + 1] = { line = sbl, fg = "CockpitStream", cs = #OPEN + 1, ce = #OPEN + 1 + #BAR }
      decor[#decor + 1] = { line = sbl, fg = "CockpitTitle", cs = #OPEN + 2 + #BAR, ce = #shdr }
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
    decor[#decor + 1] = { line = push("╭─ needs your input"), fg = "CockpitApproval" }
    decor[#decor + 1] = { line = push("│"), fg = "CockpitApproval" }
    if ap.title and ap.title ~= "" then
      decor[#decor + 1] = { line = push("│  " .. ap.title), fg = "CockpitFocusName" }
    end
    if ap.message and ap.message ~= "" then
      for _, l in ipairs(vim.split(ap.message, "\n", { plain = true })) do
        decor[#decor + 1] = { line = push("│  " .. l), fg = "CockpitMuted" }
      end
    end
    push("")
    if ap.method == "select" and ap.options then
      for oi, opt in ipairs(ap.options) do
        local line, segs = button_row("│  ", { { key = tostring(oi), label = tostring(opt), keyhl = "CockpitKeyNum", labelhl = "CockpitFocusName" } })
        seg(line, segs)
      end
      decor[#decor + 1] = { line = push("╰  press a number · esc cancels"), fg = "CockpitMuted" }
    elseif ap.method == "input" or ap.method == "editor" then
      local line, segs = button_row("│  ", { { key = "i", label = "type a reply", keyhl = "CockpitKeyNum", labelhl = "CockpitFocusName" } })
      seg(line, segs)
      decor[#decor + 1] = { line = push("╰  esc cancels"), fg = "CockpitMuted" }
    else
      local line, segs = button_row("│  ", {
        { key = "y", label = "yes", keyhl = "CockpitKeyOk", labelhl = "CockpitStream" },
        { key = "n", label = "no", keyhl = "CockpitKeyNo", labelhl = "CockpitErr" },
      })
      seg(line, segs)
      decor[#decor + 1] = { line = push("╰  esc cancels"), fg = "CockpitMuted" }
    end
  end

  -- error block: a pi/daemon failure (e.g. model quota/auth) that would otherwise
  -- leave the turn silently empty. Cleared on the next send / successful stream.
  local errmsg = S.selected and S.errors and S.errors[S.selected]
  if errmsg then
    push(""); push("")
    decor[#decor + 1] = { line = push("╭─ " .. ICON.xmark .. " error"), fg = "CockpitErr" }
    for _, l in ipairs(vim.split(errmsg, "\n", { plain = true })) do
      decor[#decor + 1] = { line = push("│ " .. l), fg = "CockpitErr" }
    end
    decor[#decor + 1] = { line = push("╰ send again to retry"), fg = "CockpitMuted" }
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
    -- Dedup the turn recap: the agent (per agentd's turnSummary) usually ends its message
    -- with the SAME ⟢/✧ line, so rendering sum.recap here too shows it TWICE. If the last
    -- assistant message already carries it, fall through to the plain done+elapsed divider
    -- (keeps the timing, drops the duplicate sentence).
    local lastm = chat and chat.msgs and chat.msgs[#chat.msgs]
    local recap_in_msg = sum and sum.recap and lastm and lastm.role == "assistant"
      and lastm.text and lastm.text:find(sum.recap, 1, true) ~= nil
    -- prefer the agent's own one-line recap (⟢), else the plain done+elapsed.
    push(""); push("")
    if sum and sum.recap and sum.recap:match("%S") and not recap_in_msg then
      -- Turn recap: render it with the SAME bg callout as the persisted message
      -- summary (hard-wrapped 2-space-padded lines), so the live done-divider and the
      -- message-history summary look identical instead of flat-here, bg'd-there.
      local text = "⟢ " .. sum.recap
      if pl and pl.total and pl.total > 0 then text = text .. " · ◆ " .. pl.done .. "/" .. pl.total .. " steps" end
      if el then text = text .. " · " .. el end
      -- fill on the recap TEXT lines only — no blank padded bg row (that was the gray band)
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
        decor[#decor + 1] = { line = bl, bg = "CockpitSummaryBg" }
        if i == 1 then
          decor[#decor + 1] = { line = bl, fg = "CockpitAccent", cs = 2, ce = 5 } -- ⟢
          decor[#decor + 1] = { line = bl, fg = "CockpitTitle", cs = 6, ce = -1 }
        else
          decor[#decor + 1] = { line = bl, fg = "CockpitTitle", cs = 2, ce = -1 }
        end
      end
    else
      -- no agent recap → a light done divider (the ✓ marker + blank line above read
      -- as the divider; no ───── rules, which used to spill past the rail width).
      decor[#decor + 1] = { line = push(ICON.check .. (el and (" done in " .. el) or " done")), fg = "CockpitIdle" }
    end
    -- touched files this turn, path + colour-coded +adds −dels (no bar; same look
    -- as the changes view). Only when the agent actually edited something.
    if sum and sum.files and #sum.files > 0 then
      local W, aw, dw = rail_width(), 0, 0
      for _, f in ipairs(sum.files) do
        if not f.untracked then aw = math.max(aw, #("+" .. f.add)); dw = math.max(dw, #("-" .. f.del)) end
      end
      for _, f in ipairs(sum.files) do
        if f.untracked then
          -- no git-diff stats → say "untracked" instead of a meaningless "+0 -0"
          local line = file_row(W, "  ", f.path, "untracked")
          decor[#decor + 1] = { line = push(line), fg = "CockpitMuted" }
        else
          local as, ds = "+" .. f.add, "-" .. f.del
          local acol = string.rep(" ", aw - #as) .. as
          local dcol = string.rep(" ", dw - #ds) .. ds
          local line = file_row(W, "  ", f.path, acol, dcol)
          local bl = push(line)
          decor[#decor + 1] = { line = bl, fg = "CockpitMuted" }
          local ps, pe = line:find("%+%d+")
          if ps then decor[#decor + 1] = { line = bl, fg = "CockpitStream", cs = ps - 1, ce = pe } end
          local ms, me = line:find("%-%d+", (pe or 0) + 1)
          if ms then decor[#decor + 1] = { line = bl, fg = "CockpitErr", cs = ms - 1, ce = me } end
        end
      end
    end
  end

  -- A message sent while the agent was mid-turn is QUEUED: NOT delivered yet — the
  -- agent hasn't seen it — it sends by itself when the current turn ends. Render it
  -- as an unmistakable "waiting" block (attn header + a ┆ pending gutter on every
  -- line) so it never reads like an already-sent/read message. When the turn ends it
  -- moves up into the chat as a normal user turn, which the agent is then reading —
  -- that transition IS the read signal. Esc pulls it BACK to the composer to edit.
  local q = S.selected and S.queued and S.queued[S.selected]
  if q and q ~= "" then
    push("")
    decor[#decor + 1] = { line = push("  " .. GLYPH.queued .. " queued — not sent yet, the agent hasn't read this"), fg = "CockpitAttn" }
    decor[#decor + 1] = { line = push("     sends when this turn ends   ·   esc = edit"), fg = "CockpitMuted" }
    for _, para in ipairs(vim.split(q, "\n", { plain = true })) do
      local ln = push("  ┆ " .. para)
      decor[#decor + 1] = { line = ln, fg = "CockpitMuted" }
      decor[#decor + 1] = { line = ln, range = { 2, 5, "CockpitAttn" } } -- ┆ pending gutter (U+2506, 3 bytes)
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

  -- INCREMENTAL buffer update: replace only the changed SUFFIX, not 0..-1. A full
  -- set_lines(0,-1) is a whole-buffer edit, so markview/treesitter re-parse the ENTIRE
  -- transcript on every 70ms streaming tick — the live-follow lag on big sessions.
  -- Streaming only appends to the tail, so the unchanged prefix is almost the whole
  -- buffer: diff for the longest common prefix and touch only from there, so the
  -- re-parse (and decor re-placement) is bounded to the growing tail. The chat buffer's
  -- lines are only ever set here, so the current buffer always equals the last render's
  -- `lines` — making the prefix comparison valid (a session switch differs at line 1 →
  -- p=0 → full replace, same as before).
  vim.bo[S.chatbuf].modifiable = true
  local old = api.nvim_buf_get_lines(S.chatbuf, 0, -1, false)
  local p, lim = 0, math.min(#old, #lines)
  while p < lim and old[p + 1] == lines[p + 1] do p = p + 1 end
  if not (p == #old and p == #lines) then -- skip a true no-op render entirely
    api.nvim_buf_set_lines(S.chatbuf, p, -1, false, vim.list_slice(lines, p + 1))
  end
  vim.bo[S.chatbuf].modifiable = false
  -- decor for the unchanged prefix [0,p) is byte-identical to last render, so its
  -- extmarks stay put; clear + re-place only [p,-1).
  api.nvim_buf_clear_namespace(S.chatbuf, S.ns, p, -1)
  -- TEMP band-debug: `:lua vim.g.cockpit_debug_band=1` then re-render → dumps every
  -- background-painted row + its exact text to /tmp/cockpit-band-debug.log, so the
  -- empty gray band's real source (bg group + which line) is unambiguous. Remove after.
  if vim.g.cockpit_debug_band then
    pcall(function()
      local out = { "== decor[] bg entries ==" }
      for _, d in ipairs(decor) do
        if d.bg then
          out[#out + 1] = string.format("line=%-4d bg=%-16s text=%q", d.line, tostring(d.bg), lines[d.line + 1] or "<nil>")
        end
      end
      -- Also enumerate EVERY extmark on the chat buffer across ALL namespaces (markview,
      -- our ns, the top-pad ns, signs) that paints a background — so a band from a source
      -- other than decor[] (markdown block bg, virt_lines padding) can't hide.
      out[#out + 1] = "== all buffer extmarks with a bg/line_hl_group =="
      local marks = api.nvim_buf_get_extmarks(S.chatbuf, -1, 0, -1, { details = true })
      for _, m in ipairs(marks) do
        local row, det = m[2], m[4] or {}
        local bg = det.line_hl_group or det.hl_group
        if bg and tostring(bg):lower():find("bg") or det.line_hl_group or det.virt_lines then
          local kind = det.line_hl_group and "line_hl" or (det.virt_lines and "virt_lines" or "hl")
          out[#out + 1] = string.format("row=%-4d %s=%s text=%q", row, kind,
            tostring(det.line_hl_group or det.hl_group or "?"), lines[row + 1] or "<nil>")
        end
      end
      local fh = io.open("/tmp/cockpit-band-debug.log", "w")
      if fh then fh:write(table.concat(out, "\n") .. "\n"); fh:close() end
    end)
  end
  for _, d in ipairs(decor) do
   if d.line >= p then
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
        { virt_text = { { d.virt, d.virthl or "CockpitCode" } }, virt_text_pos = "inline", priority = 200 })
    end
    if d.caret then
      pcall(api.nvim_buf_set_extmark, S.chatbuf, S.ns, d.line, 0, { line_hl_group = "CockpitStream", priority = 80 })
    end
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
    -- Bottom-anchor a short conversation now AND after markview settles (it renders
    -- async and changes the true display height, so the sync pass alone is unreliable).
    bottom_anchor()
    vim.defer_fn(bottom_anchor, 80)
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

-- Normalize a pi edit path (may be relative to the session cwd or absolute) to an
-- absolute path, so per-session edit attribution can be compared against the
-- inotify path (always absolute) without format mismatch.
local function edit_abs(cwd, path)
  if not path or path == "" then return nil end
  return fn.fnamemodify(fn.expand(path:match("^/") and path or ((cwd or fn.getcwd()) .. "/" .. path)), ":p")
end

handle = function(obj)
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
    render_roster()
    if plan_binding_changed and refresh_dashboard then refresh_dashboard() end
    -- Fresh cockpit nvim: land on the ORCHESTRATOR's Cockpit dashboard instead of the
    -- stock splash. Once, first roster only, and only when nvim was started bare (no
    -- file args, untouched empty buffer) — a restarted pane otherwise sat on the NVIM
    -- splash until the first session switch re-landed it.
    if cockpit_env("COCKPIT") == "1" and not S._landed_default then
      S._landed_default = true
      vim.schedule(function()
        if fn.argc() ~= 0 then return end
        local b = api.nvim_get_current_buf()
        if api.nvim_buf_get_name(b) ~= "" or vim.bo[b].modified then return end
        if api.nvim_buf_line_count(b) > 1 or (api.nvim_buf_get_lines(b, 0, 1, false)[1] or "") ~= "" then return end
        local d = default_session()
        if not d then return end
        S.selected = d.id
        local ed = target_editor_win()
        if ed and d.cwd and d.cwd ~= "" then show_scratch(ed, d.cwd) end
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
      local scwd = session_cwd(obj.session)
      local text, hunks = msg_text({ content = partial.content }, scwd)
      S.stream[obj.session] = text
      -- Record this session's edits LIVE (sub-turn) so the inotify live-follow can
      -- verify a disk change belongs to THIS session — not a co-located agent sharing
      -- the cwd. Keys are absolute to match the (absolute) inotify path.
      -- ONLY record paths that are real files on disk: this event streams the edit
      -- tool's path a char at a time, so a partial like "/home/daph" would otherwise
      -- get recorded as its own "edited file" (the prefix-row garbage). A partial
      -- never exists as a file; the complete path does once the edit is written.
      if hunks and #hunks > 0 then
        S.edited[obj.session] = S.edited[obj.session] or {}
        for _, h in ipairs(hunks) do
          local abs = edit_abs(scwd, h.path)
          if abs and fn.filereadable(abs) == 1 then S.edited[obj.session][abs] = true end
        end
      end
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
      local scwd = session_cwd(obj.session)
      for _, h in ipairs(hunks) do
        local abs = edit_abs(scwd, h.path)
        if abs then S.edited[obj.session][abs] = true end
      end
      if obj.session == S.selected then
        local last = hunks[#hunks]
        if last and last.path then follow_edit(scwd, last.path, nil) end
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
  elseif t == "changes" and obj.session then
    -- Server-streamed working-tree diff from a REMOTE agentd: populate the diff
    -- cache + re-render CHANGES without the files being local. Same parser + re-render
    -- path as the local git watcher. (follow_edit still can't OPEN a remote file — it
    -- early-returns on filereadable — so remote live-follow is diff-visibility for now.)
    local cwd = obj.cwd or session_cwd(obj.session)
    if cwd and type(obj.diff) == "string" then
      S.gitdiff[cwd] = parse_git_diff(vim.split(obj.diff, "\n", { plain = true }))
      if S.selected and session_cwd(S.selected) == cwd then
        if S.view == "changes" then render_changes() else render_chat(false) end
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
        if obj.session == S.selected then render_chat(true) end
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
    -- writes settled → reload the exact files the agent edited (see sync_edited)
    local ed = S.edited[obj.session]
    if ed then S.edited[obj.session] = nil; vim.schedule(function() sync_edited(session_cwd(obj.session), ed) end) end
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
    if obj.session == S.selected then render_chat(false); refresh_dashboard() end
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

-- Remote agentd: COCKPIT_AGENTD_ADDR="host:port" (legacy HEIDR fallback) connects over
-- TCP (a tailnet IP, or a localhost SSH-forwarded port) instead of the local
-- unix socket. The daemon protocol is transport-agnostic NDJSON, so only the
-- connect call differs — nvim still runs locally, only events cross the wire.
local function remote_addr()
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
  local function on_conn(cerr)
    if not cerr then
      S.connecting = false
      S.pipe = stream
      S.connected = true
      S.last_recv = os.time() -- fresh connection: don't flag it stale immediately
      S.ever_connected = true
      stream:read_start(vim.schedule_wrap(on_read))
      -- flush anything queued while we were down so a daemon restart / socket
      -- drop is transparent: messages you sent mid-outage get delivered now,
      -- in order, instead of being silently lost.
      if S.outbox and #S.outbox > 0 then
        local pending = S.outbox; S.outbox = {}
        for _, m in ipairs(pending) do
          pcall(function() stream:write(vim.json.encode(m) .. "\n") end)
        end
      end
      vim.schedule(function() render_roster() end)
      if cb then vim.schedule(cb) end
      return
    end
    pcall(function() stream:close() end)
    -- Only cold-start a LOCAL daemon on first boot; a remote one can't be spawned
    -- from here, and a reconnect after a drop means it's normally already up.
    if not rhost and tries == 0 and not S.ever_connected then
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
-- "is this cwd inside a work tree" is invariant for a given dir, but fn.system git
-- forks a subprocess that BLOCKS the switch every time — so memoize per cwd. A
-- session's worktree doesn't stop being a repo mid-life, so a stale-cache risk isn't
-- real here; this removes one synchronous git fork from every session switch.
local in_repo_cache = {}
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
  local in_repo = in_repo_cache[cwd]
  step("git_isrepo", function()
    if in_repo == nil then
      in_repo = fn.system({ "git", "-C", cwd, "rev-parse", "--is-inside-work-tree" }):match("true") ~= nil
      in_repo_cache[cwd] = in_repo
    end
  end)
  if rec then
    pcall(fn.writefile, { "  reroot: " .. table.concat(rec, " ") }, "/tmp/cockpit-switch-timing.log", "a")
  end
  -- The expensive tail — the DirChanged fan-out (git re-scan) and the file-watcher tree
  -- walk (~250-750ms) — runs DEFERRED, off the switch's paint path. Bail if the user has
  -- since switched to a different worktree, so we don't scan a dir we've already left.
  vim.schedule(function()
    if fn.getcwd() ~= cwd then return end
    if in_repo then pcall(function() require("file-watcher").start() end) end
    pcall(api.nvim_exec_autocmds, "DirChanged", { modeline = false })
  end)
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
  if not (sid and cwd and cwd ~= "") then vim.notify("Cockpit: open a session first"); return end
  send({ type = "stop", session = sid })
  S.stream[sid] = nil
  -- mark reloading so the ~2s pi-boot gap shows "restarting…" instead of a
  -- scary "pi not running" error; cleared when messages land (pi's back), with a
  -- safety timeout so a genuinely-dead pi still surfaces its error eventually.
  S.reloading = S.reloading or {}
  S.reloading[sid] = true
  vim.defer_fn(function() if S.reloading then S.reloading[sid] = nil end end, 12000)
  if sid == S.selected then render_chat(false) end
  vim.notify("Cockpit: restarting " .. short_name(sid) .. " — reloading MCP config…")
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

-- Switch-timing: with `:lua vim.g.cockpit_debug_switch=1`, view_session records each
-- step's wall time and appends a line to /tmp/cockpit-switch-timing.log so we can see
-- which step dominates a switch (measure before optimizing). No-op when the flag's off.
local function switch_step(rec, label, f)
  if not rec then f(); return end
  local t0 = vim.loop.hrtime()
  f()
  rec[#rec + 1] = string.format("%s=%.1fms", label, (vim.loop.hrtime() - t0) / 1e6)
end

view_session = function(name, cwd)
  local rec = vim.g.cockpit_debug_switch and {} or nil
  local t_all = rec and vim.loop.hrtime()
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
  switch_step(rec, "reload_messages", function() reload_messages(name) end)
  switch_step(rec, "reroot", function() reroot(cwd) end)
  switch_step(rec, "reflect_context", function() reflect_context(cwd) end) -- restore editor or show dashboard (sync: deferring it let another buffer open in the gap and got clobbered)
  switch_step(rec, "cockpit_sync", function() cockpit_sync(cwd) end)       -- drive cockpit devenv tab + Super+T marker
  switch_step(rec, "load_draft", function() load_draft(name) end)
  switch_step(rec, "render_active", function() render_active() end)
  if rec then
    local total = (vim.loop.hrtime() - t_all) / 1e6
    pcall(fn.writefile,
      { string.format("switch → %s  total=%.1fms  [%s]", short_name(name), total, table.concat(rec, " ")) },
      "/tmp/cockpit-switch-timing.log", "a")
  end
  -- Refresh the switched-to session's plan AFTER the switch has painted. It's a sync
  -- git call, so running it inline was the swap lag; deferring it lets the roster/chat
  -- appear instantly with the cached plan, then the dashboard/chip update a tick later
  -- if the plan changed. (reflect_context is NOT deferred — doing so let another buffer
  -- open in the gap and the deferred restore clobbered it, losing the review output.)
  vim.schedule(function()
    if S.selected ~= name then return end -- switched away again before we ran
    for _, a in ipairs(S.roster) do
      if a.id == name then refresh_plan_one(a); break end
    end
    if S.selected == name then reflect_context(cwd); render_active() end
  end)
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
    -- :CockpitReconnect needed.
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
                vim.notify("Cockpit: " .. short_name(aid) .. " unresponsive — reloading + resending", vim.log.levels.WARN)
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
  local extra = #S.attach -- file-attachment chip virt-lines; images show in the winbar 🖼 count (no growth)
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
    vls[#vls + 1] = { { CHIP_BAR .. " ", "CockpitChipBar" }, { " " .. loc .. tag .. " ", "CockpitChip" } }
  end
  -- pasted images are NOT chipped here: a per-image virt-line grows the composer, and the
  -- winbar already carries a 🖼 ×N count on a row that doesn't grow. File attachments keep
  -- their chip (the path:line ref is worth the row).
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
  pcall(api.nvim_buf_set_extmark, SL.buf, S.ns, SL.sel - 1, 0, { line_hl_group = "CockpitSel" })
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
  if not S.selected then vim.notify("Cockpit: open a session first (<CR>)", vim.log.levels.INFO); return end
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
  -- shell-style sent-message history for ↑/↓ recall (skip consecutive dupes, cap 100);
  -- a send also ends any in-progress history browsing.
  S.history = S.history or {}
  local _h = S.history[S.selected] or {}; S.history[S.selected] = _h
  if _h[#_h] ~= text then _h[#_h + 1] = text end
  if #_h > 100 then table.remove(_h, 1) end
  if S.histpos then S.histpos[S.selected] = nil end
  local prompt = build_prompt(text)
  local imgs = (#S.paste_images > 0) and vim.deepcopy(S.paste_images) or nil
  local c = S.chat[S.selected] or { msgs = {} }

  -- Sending mid-turn QUEUES locally (held in the rail, flushed on turn_end) so
  -- you can still cancel or edit it with Esc — unlike a fired-off follow_up.
  -- Images can't be queued, so a message with attachments always sends now.
  -- "working" = the whole turn (agent_start→agent_end), NOT just visible streaming.
  -- Gating on S.stream alone missed the thinking/reasoning/tool-call phase before any
  -- text streams: a message sent then took the immediate-send path and raced pi's
  -- mid-turn stdin, so it fell through. turn_active covers the entire turn → it queues.
  local working = (S.turn_active and S.turn_active[S.selected])
    or (S.stream[S.selected] and S.stream[S.selected] ~= "")
  if working and not imgs then
    -- STEER-FIRST, fall back to queue (the chosen default). Inject the message into
    -- the LIVE turn so the agent can read it mid-work — real mid-turn conversation.
    -- pi's steer is best-effort: it strands the message, unanswered, if the turn ends
    -- right after accepting it. So we arm a fallback (see agent_end): if the turn ends
    -- within STEER_GRACE of the steer — too fast to have consumed it — the message is
    -- re-sent as a fresh prompt (the delivery pi guarantees an answer for). Echoed now
    -- as a normal user turn so you see it went. Images can't steer, so they send now.
    send({ type = "steer", session = S.selected, message = prompt })
    c.msgs[#c.msgs + 1] = { role = "user", text = prompt, steer = true } -- tagged so the strand-fallback can reposition it
    S.chat[S.selected] = c
    S.steer_pending = S.steer_pending or {}
    S.steer_pending[S.selected] = { text = prompt, at = os.time() }
    S.force_bottom = true
    S.drafts[S.selected] = nil
    clear_attachments()
    api.nvim_buf_set_lines(S.composerbuf, 0, -1, false, { "" })
    render_chips(); composer_placeholder()
    render_chat(true)
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
  if not S.selected then vim.notify("Cockpit: open a session first (<CR>)", vim.log.levels.INFO); return end
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
  if not S.selected then vim.notify("Cockpit: no active session — open one first", vim.log.levels.WARN); return end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  local width = math.min(80, vim.o.columns - 6)
  local win = api.nvim_open_win(buf, true, {
    relative = "cursor", row = 1, col = 0, width = width, height = 1,
    style = "minimal", border = "rounded", title = " → " .. S.selected .. " ", title_pos = "left",
  })
  vim.wo[win].winhighlight = "Normal:Normal,FloatBorder:CockpitAccent"
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
    vim.notify("Cockpit: → " .. S.selected)
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
  if #out == 0 then vim.notify("Cockpit: no diff", vim.log.levels.INFO); return end
  add_attachment({ path = "git diff " .. (path ~= "" and path or "."), lang = "diff", text = table.concat(out, "\n") })
  ensure_open_and_compose()
end

function M.attach_file()
  vim.ui.input({ prompt = "Attach file: ", default = "", completion = "file" }, function(path)
    if not path or path == "" then return end
    local p = fn.expand(path)
    if fn.filereadable(p) == 0 then vim.notify("Cockpit: not readable — " .. path, vim.log.levels.WARN); return end
    local text = table.concat(fn.readfile(p), "\n")
    local ft = vim.filetype.match({ filename = p }) or ""
    add_attachment({ path = fn.fnamemodify(p, ":."), lang = ft, text = text })
    focus_composer()
  end)
end

function M.send_diagnostics()
  local buf = api.nvim_get_current_buf()
  local ds = vim.diagnostic.get(buf)
  if #ds == 0 then vim.notify("Cockpit: no diagnostics", vim.log.levels.INFO); return end
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

local function open_in_editor(cwd, path, line)
  local file = path:match("^/") and path or ((cwd or fn.getcwd()) .. "/" .. path)
  file = fn.expand(file)
  if fn.filereadable(file) == 0 then vim.notify("Cockpit: not readable — " .. path, vim.log.levels.WARN); return end
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
follow_edit = function(cwd, path, line, external, external_force)
  if not path or S.follow_edits == false then return end
  -- Never follow into plan machinery sidecars: a /plan-ticket turn writes the
  -- reviewable .md and THEN its progress.json, so following the last edit would
  -- dump you in raw JSON instead of the rendered plan. Skipping them keeps the
  -- editor on the .md (which plan-nvim renders) — the thing you actually review.
  if path:match("%.progress%.json$") or path:match("%.review%.json$")
    or path:match("/plans/.*%.diagram%.html$") then return end
  local cur = api.nvim_get_current_win()
  -- "You're in the code" gate — only for the in-nvim rail, where browsing the rail is
  -- what current-buffer==agent-* means. An EXTERNAL driver (the cockpit rail) has no
  -- agent buffers at all; its equivalent gate lives in M.follow_remote.
  if not external and not api.nvim_buf_get_name(api.nvim_win_get_buf(cur)):match("agent%-") then return end
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
  -- The user took the wheel: any buffer they opened THEMSELVES pauses follow
  -- until they return to rest (dashboard) or switch sessions. Programmatic opens
  -- (this function) are marked so the BufEnter watcher can tell them apart.
  if S._follow_paused and not external_force then return end
  local key = file .. ":" .. tostring(line or 0)
  if S._follow == key then return end
  S._follow = key
  S._program_nav = true
  api.nvim_win_call(target, function()
    if fn.fnamemodify(api.nvim_buf_get_name(0), ":p") ~= file then
      pcall(vim.cmd, "edit " .. fn.fnameescape(file))
    end
    if line then pcall(api.nvim_win_set_cursor, target, { tonumber(line), 0 }); vim.cmd("normal! zz") end
  end)
  vim.schedule(function() S._program_nav = nil end)
  editor_gutter(target, true) -- a real file is showing → restore number/sign/fold cols (the dashboard turned them off)
  if hide_banner then hide_banner() end
end

-- reverse bridge: open the file referenced in the nearest fenced-code header
-- (```lang path:l1-l2). Opens in the main editor window, not the rail.
-- find a `path[:line]` token spanning the cursor column on one line (agent prose
-- often names files inline: "see cockpit/init.lua:409"). Requires a .ext or a
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
    vim.notify("Cockpit: no file reference at cursor", vim.log.levels.INFO); return
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

-- URL at/near the cursor. Handles both a bare http URL AND a markdown link
-- [text](url): markview CONCEALS the ](url) part, so the cursor sits on the visible
-- TEXT, never on the URL — url_under_cursor alone always missed those. We match the
-- whole [text](url) span (so cursor-on-text works), dedup against bare URLs, and fall
-- back to the sole link on the line so gx/yank don't need pixel-precise cursoring.
local function link_at(line, col)
  local hits, seen = {}, {}
  local i = 1
  while true do -- markdown links first: span covers the whole [text](url)
    local s, e, href = line:find("%[.-%]%((%S-)%)", i)
    if not s then break end
    href = href:gsub("[%.,%)%]}>\"']+$", "")
    if not seen[href] then hits[#hits + 1] = { s = s, e = e, url = href }; seen[href] = true end
    i = e + 1
  end
  i = 1
  while true do -- bare URLs not already part of a markdown link
    local s, e, u = line:find("(https?://[%w%._~:/%?#%[%]@!$&'()*+,;=%%~-]+)", i)
    if not s then break end
    u = u:gsub("[%.,%)%]}>\"']+$", "")
    if not seen[u] then hits[#hits + 1] = { s = s, e = e, url = u }; seen[u] = true end
    i = e + 1
  end
  if #hits == 0 then return nil end
  for _, h in ipairs(hits) do if col + 1 >= h.s and col + 1 <= h.e then return h.url end end
  if #hits == 1 then return hits[1].url end
  return nil
end

-- gx in the chat: open the URL/link under the cursor (PR / preview / docs links the
-- agent emits) via the system opener, in the work browser.
local function chat_open_url()
  if not (S.chatwin and api.nvim_win_is_valid(S.chatwin)) then return end
  local pos = api.nvim_win_get_cursor(S.chatwin)
  local line = api.nvim_buf_get_lines(S.chatbuf, pos[1] - 1, pos[1], false)[1] or ""
  local u = link_at(line, pos[2])
  if not u then vim.notify("Cockpit: no link at cursor", vim.log.levels.INFO); return end
  if vim.ui.open then vim.ui.open(u) else fn.jobstart({ "xdg-open", u }, { detach = true }) end
  vim.notify("Cockpit: opening " .. u)
end

-- gy / yank a chat link's URL (the concealed href of the [text](url) under the cursor,
-- or a bare URL) to the clipboard — no more copying the raw [text](url) markdown.
local function chat_yank_url()
  if not (S.chatwin and api.nvim_win_is_valid(S.chatwin)) then return end
  local pos = api.nvim_win_get_cursor(S.chatwin)
  local line = api.nvim_buf_get_lines(S.chatbuf, pos[1] - 1, pos[1], false)[1] or ""
  local u = link_at(line, pos[2])
  if not u then vim.notify("Cockpit: no link at cursor", vim.log.levels.INFO); return end
  fn.setreg("+", u); fn.setreg('"', u)
  vim.notify("Cockpit: yanked " .. u)
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
    fn.setreg("+", all[cur] or ""); vim.notify("Cockpit: yanked line", vim.log.levels.INFO); return
  end
  local e = cur + 1
  while e <= #all and not all[e]:match("^```") do e = e + 1 end
  local body = {}
  for i = s + 1, e - 1 do body[#body + 1] = all[i] end
  fn.setreg("+", table.concat(body, "\n"))
  vim.notify("Cockpit: yanked code block (" .. #body .. " lines)", vim.log.levels.INFO)
end

-- Copy the LAST agent reply's full text to the clipboard (Claude-Code parity —
-- "copy response"). Whole message, not just the code block under the cursor.
local function chat_yank_reply()
  local c = S.selected and S.chat[S.selected]
  if not (c and c.msgs) then vim.notify("Cockpit: no reply to copy"); return end
  for i = #c.msgs, 1, -1 do
    if c.msgs[i].role == "assistant" then
      local text = c.msgs[i].text or ""
      fn.setreg("+", text); fn.setreg('"', text)
      vim.notify("Cockpit: copied last agent reply (" .. #text .. " chars)")
      return
    end
  end
  vim.notify("Cockpit: no agent reply to copy")
end

-- Copy the WHOLE conversation as role-labelled markdown — for handing the
-- transcript to another agent or pasting into the vault. Thinking is skipped
-- (it's dimmed noise in the chat; not useful downstream).
local function chat_yank_convo()
  local c = S.selected and S.chat[S.selected]
  if not (c and c.msgs and #c.msgs > 0) then vim.notify("Cockpit: no conversation to copy"); return end
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
  vim.notify("Cockpit: copied conversation (" .. #c.msgs .. " messages, " .. #md .. " chars)")
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
  if #matches == 0 then vim.notify("Cockpit: no matches for '" .. q .. "'" .. coverage); return end
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
-- The session dashboard: the editor's resting view when a session has no file
-- open. A session HUD — its plan status + flow, its worktree's changed files, and
-- a bottom-right action box whose rows exist ONLY when their target does (devenv/
-- app only for a registered cockpit context, plan only with a plan, ticket only
-- with a ticket id). Reused across sessions; unnamed so lualine shows no filename.
-- Cockpit masthead banner — theme-aware PNG (light/dark electric) rendered inline
-- via snacks.image (kitty graphics). Wrapped so a missing file or a terminal
-- without image support never breaks the resting view.
local COCKPIT_BANNER_DIR = fn.expand("~/personal/ai-cockpit/assets")
local COCKPIT_BANNER_W = 22 -- minimum banner width in cells
-- The banner scales with the WINDOW: a fixed cell count renders physically
-- smaller on denser screens (the private instance's masthead looked half the
-- work one's size). ~26% of the pane, clamped sane.
local function banner_w(win)
  local ww = (win and api.nvim_win_is_valid(win)) and api.nvim_win_get_width(win) or 80
  return math.max(COCKPIT_BANNER_W, math.min(44, math.floor(ww * 0.26)))
end
-- Rows from the asset aspect (790x184 = 4.29) and the REAL cell pixel size
-- (snacks queries the terminal): an assumed cell aspect made the float box a
-- wrong shape at most window widths and the image squished to fit it.
local BANNER_ASPECT = 790 / 184
local function banner_h(w)
  local ok, term = pcall(require, "snacks.image.terminal")
  if ok and term.size then
    local oks, sz = pcall(term.size)
    if oks and sz and sz.cell_width and sz.cell_height and sz.cell_height > 0 then
      -- +2 slack rows on top of ceil: under Cockpit's device-pixel renderer
      -- snacks spans MORE rows than the reported cell size predicts (#73), so
      -- an exact box still clipped glyph bottoms. The image draws from the
      -- float's top; extra rows are an invisible gap, clipping is not.
      return math.max(3, math.ceil(w * sz.cell_width / BANNER_ASPECT / sz.cell_height)) + 2
    end
  end
  return math.max(3, math.ceil(w / 8.6)) + 2
end
-- 790×184 scaled to 22 cells ≈ 3 text rows. Declared before place_banner so its
-- float config captures the local (a later declaration resolved to a nil global →
-- height=nil → open_win threw under pcall → the banner never rendered).
local COCKPIT_BANNER_ROWS = 3
-- The banner lives in its OWN floating window over the dashboard's reserved top
-- rows — NOT inline in the card buffer. An inline image shares the card's buffer, so
-- every set_lines re-render wiped + re-placed it and its virtual columns offset the
-- content rows (the recurring jagged-border bug, unfixable while it's inline). In a
-- float the image is physically isolated: the card's set_lines can't touch it, and it
-- can't shift a single content column. `win` = the editor window showing the dashboard.
local function place_banner(_buf, win)
  if not (win and api.nvim_win_is_valid(win)) then hide_banner(); return end
  -- The banner draws ONLY over the dashboard. If the target window isn't currently
  -- showing the scratch buffer (a file is open — including a stray re-place from a
  -- ColorScheme/User autocmd), never draw it over code.
  if not (S.scratchbuf and api.nvim_win_get_buf(win) == S.scratchbuf) then hide_banner(); return end
  local ok, Placement = pcall(require, "snacks.image.placement")
  if not ok then return end
  local variant = vim.o.background == "light" and "light" or "dark"
  -- Per-scope identity: work flies the LOVABLE masthead, the private cockpit
  -- flies David's own mark + "cockpit"; missing files fall back to HEIÐR.
  local ident = (scope == "lovable") and "lovable" or "cockpit"
  local src = COCKPIT_BANNER_DIR .. "/" .. ident .. "-" .. variant .. ".png"
  if fn.filereadable(src) == 0 then src = COCKPIT_BANNER_DIR .. "/cockpit-" .. variant .. ".png" end
  if fn.filereadable(src) == 0 then hide_banner(); return end
  if not (S.banner_buf and api.nvim_buf_is_valid(S.banner_buf)) then
    S.banner_buf = api.nvim_create_buf(false, true)
    vim.bo[S.banner_buf].bufhidden = "hide"; vim.bo[S.banner_buf].swapfile = false
  end
  local bw = banner_w(win)
  local col = math.max(0, math.floor((api.nvim_win_get_width(win) - bw) / 2))
  local cfg = {
    relative = "win", win = win, anchor = "NW", row = 0, col = col,
    width = bw, height = banner_h(bw),
    -- border=none EXPLICITLY: a global `winborder` (e.g. "rounded") otherwise leaks a box
    -- onto this float, framing the banner in an ugly outline over the card.
    focusable = false, style = "minimal", zindex = 45, border = "none",
    -- NO noautocmd: snacks.image hooks window autocmds to draw the inline image, so
    -- suppressing them left the float empty (the "no header" bug).
  }
  if S.banner_win and api.nvim_win_is_valid(S.banner_win) then
    pcall(api.nvim_win_set_config, S.banner_win, cfg)
  else
    S.banner_win = api.nvim_open_win(S.banner_buf, false, cfg)
    pcall(function() vim.wo[S.banner_win].winhighlight = "Normal:Normal,NormalFloat:Normal" end)
  end
  pcall(Placement.clean, S.banner_buf)
  pcall(Placement.new, S.banner_buf, src, { pos = { 1, 0 }, inline = true, width = bw, auto_resize = false })
end

hide_banner = function()
  if S.banner_win and api.nvim_win_is_valid(S.banner_win) then pcall(api.nvim_win_close, S.banner_win, true) end
  S.banner_win = nil
end

-- 0 when the banner won't render (no snacks / missing PNG), so the reserved top
-- rows collapse and the layout stays exact in a plain terminal too.
local function banner_rows(win)
  if not pcall(require, "snacks.image.placement") then return 0 end
  local variant = vim.o.background == "light" and "light" or "dark"
  local ident = (scope == "lovable") and "lovable" or "cockpit"
  if fn.filereadable(COCKPIT_BANNER_DIR .. "/" .. ident .. "-" .. variant .. ".png") == 0
     and fn.filereadable(COCKPIT_BANNER_DIR .. "/cockpit-" .. variant .. ".png") == 0 then return 0 end
  return banner_h(banner_w(win))
end

local function show_scratch(win, cwd)
  local _d = vim.g.cockpit_debug_switch and { vim.loop.hrtime() } or nil -- switch-timing marks
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
  -- Centered card matching the rail's box(): surface fill + hairpin border + titled
  -- top, drawn in a centered content column of width CW at left margin LM. Reuses
  -- box() verbatim (same glyphs/colours as the rail) via a thin adapter: box writes
  -- {line,fg,bg,cs,ce} decor with group-name attrs → we replay it as add_highlight
  -- offset by LM, so the surface fills only the card columns, not the whole row.
  local CW = math.max(40, math.min(W - 8, 96))
  local LM = math.max(0, math.floor((W - CW) / 2))
  local LMS = string.rep(" ", LM)
  local function card(ic, title, bodyfn)
    local bd, first = {}, nil
    local function bpush(line) local ln = push(LMS .. line); first = first or ln; return ln end -- nav is the caller's job (via add's return)
    box(bpush, bd, CW, ic, title, bodyfn, "CockpitBox", false, true, true) -- nofill: outline-only, no surface fill (cleaner, esp. light mode)
    for _, d in ipairs(bd) do
      if d.bg then hl(d.line, d.bg, LM, -1) end
      if d.fg then hl(d.line, d.fg, (d.cs or 0) + LM, d.ce and (d.ce + LM) or -1) end
    end
    return first -- the top-border line, so callers can overlay accents on the title
  end
  local CARD_INNER = CW - 6 -- box()'s content width (W minus "│  " + "  │")
  local nm = short_name(S.selected) or fn.fnamemodify(cwd, ":t")
  -- the worktree name carries the ticket too, which is what keeps the identity (and the
  -- `l` linear action) when an external driver renders a session this nvim never selected
  local tik = (S.selected or ""):match("%a+%-%d+") or fn.fnamemodify(cwd or "", ":t"):match("%a+%-%d+")
  local ctx = cockpit_ctx_registered(cwd)
  local private_root = scope == "personal" and cwd == scope_root()
  local root = ctx == "main" or private_root -- the scope's main checkout → a fleet dashboard

  -- masthead: the inline Cockpit banner IS the header — reserve its rows, nothing else.
  -- The session identity lives in the PLAN card title (Electric); no path, no id line.
  local br = banner_rows(win)
  local topN = math.max(2, br) -- banner-reserved rows preserved across re-renders (no image re-place)
  for _ = 1, topN do push("") end
  for _ = 1, 3 do push("") end -- breathing room between the banner image and the HUD card

  -- PLAN + CHANGES share one tabbed HUD card, rendered in the non-root branch below
  -- (after the action box is sized so the file list can be capped). pl is loaded here
  -- because the action row needs it too.
  local pl = load_plan(cwd)
  if _d then _d[#_d + 1] = vim.loop.hrtime() end -- [2]: after banner_rows + load_plan (git)

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
  end
  -- a: open the session's dev preview. cockpit-app takes the SESSION name, asks agentd for
  -- its webPort and routes accordingly — local sessions via the wt-proxy, remote ones get
  -- an ssh -L first. NOT gated on a registered cockpit context like devenv above: a VM
  -- ticket's mirror is never cockpit-add'ed, so that gate hid the action on exactly the
  -- sessions whose app you cannot reach any other way.
  -- The session's name, derived without a roster: this nvim's roster only spans its own
  -- scope, so a VM session (work scope) is invisible here — but ticket sessions are NAMED
  -- their ticket id and review sessions review-pr-<n>, and cockpit-app searches every agentd
  -- socket by name. A live roster hit still wins (covers ad-hoc session names).
  local apr = (cwd or ""):match("lovable%.review%-(%d+)") or (S.selected or ""):match("^review%-pr%-(%d+)")
  local target = apr and ("review-pr-" .. apr) or (tik and tik:lower()) or (ctx and ctx ~= "main" and ctx or nil)
  for _, a in ipairs(S.roster) do if a.id == S.selected then target = a.name; break end end
  if target then
    act("a", "app", function()
      fn.jobstart({ home .. "/.config/niri/scripts/cockpit-app", target }, {
        detach = true,
        -- cockpit-app fails fast when the session isn't live or has no devenv port; a
        -- detached silent exit read as "the button does nothing".
        on_exit = function(_, code)
          if code ~= 0 then
            vim.schedule(function() vim.notify("app: no live session/port for " .. target) end)
          end
        end,
      })
    end)
  end
  if root then
    act("n", "session", function() if open_picker then open_picker() end end) -- start/pick a session
  end
  -- l: the session's external link. A review worktree (review/pr-<n>) opens the PR;
  -- a ticket session opens Linear. Reviews have no Linear ticket, so never try one.
  -- review worktree cwd is ~/work/lovable.review-<n>-<slug>; session name is review-pr-<n>.
  -- Match either (the old `review-pr-` cwd pattern never hit → reviews wrongly said "linear").
  local pr = (cwd or ""):match("lovable%.review%-(%d+)") or (S.selected or ""):match("^review%-pr%-(%d+)")
  if pr then
    act("l", "open PR", function()
      fn.jobstart({ "gh", "pr", "view", pr, "--web" }, { cwd = cwd, detach = true })
    end)
    -- r: reopen the review-pr artifact (the skill writes ~/…/reviews/pr-<n>.md). Set it as
    -- the session's editor file so reflect_context restores it on every switch back — the
    -- review IS a review session's deliverable, so it should stick, not vanish to the dash.
    local rv = (os.getenv("HOME") or "") .. "/personal/notes/storage/reviews/pr-" .. pr .. ".md"
    if fn.filereadable(rv) == 1 then
      act("r", "review", function()
        S.editor = S.editor or {}
        if S.selected then S.editor[S.selected] = rv end
        open_in_editor(cwd, rv, nil)
      end)
    end
  elseif tik then
    act("l", "linear", function()
      local u = "https://linear.app/lovable/issue/" .. tik:upper()
      if vim.ui.open then vim.ui.open(u) else fn.jobstart({ "xdg-open", u }, { detach = true }) end
    end)
  end
  -- (no `c`/`r`: <Tab> swaps to the CHANGES view in the card, and the resize
  -- autocmd re-renders automatically — so a manual changes/refresh hint is dead weight.)
  local FOOTER_H = 1 -- the horizontal hint row pinned to the bottom

  local openmap, expand_ln, sessmap, ticketmap, planmap, teardownmap = {}, nil, {}, {}, {}, {} -- file/toggle/session/ticket/plan/teardown rows
  local dash_views -- the HUD card's tab order (non-root), exposed to <Tab> via S.dash
  if root then
    -- ORCHESTRATOR dashboard — the cycle's tickets in the same centered bordered cards
    -- as the worktree HUD (card()/box()), so both dashboards read as one system. Live
    -- sessions are NOT listed here (the rail roster shows them permanently); a ticket
    -- being worked on is flagged "in progress" in the list below instead.

    if scope == "personal" then
      local inv = S.plan_inventory or { needs = {}, implementing = {}, reconciled = {} }
      local slugw = 0
      for _, group in ipairs({ inv.needs, inv.implementing, inv.reconciled }) do
        for _, row in ipairs(group or {}) do slugw = math.max(slugw, #row.slug) end
      end
      slugw = math.min(slugw, math.max(12, CARD_INNER - 22))
      card(nil, "PLANS", function(add)
        local summary = #inv.needs .. " need you · " .. #inv.implementing .. " implementing"
        add(summary, { { 0, #summary, "CockpitMuted" } })
        local function add_group(label, rows, color)
          if #rows == 0 then return end
          add("")
          add(label, { { 0, #label, color } })
          for _, row in ipairs(rows) do
            local session = row.session and (row.session.name or short_name(row.session.id)) or "unbound"
            local slug = row.slug
            if #slug > slugw then slug = slug:sub(1, slugw - 1) .. "…" end
            local mark = "●"
            local left = mark .. " " .. slug .. string.rep(" ", slugw - #slug)
              .. "   ◆ " .. row.done .. "/" .. row.total
            local suffix = " · " .. session
            local text = left .. suffix
            local basehl = label == "RECENTLY RECONCILED" and "CockpitMuted" or "CockpitFile"
            planmap[add(text, {
              { 0, #text, basehl },
              { 0, #mark, color },
              { #left, #text, "CockpitMuted" },
            })] = row
          end
        end
        add_group("NEEDS YOU", inv.needs, "CockpitErr")
        add_group("IMPLEMENTING", inv.implementing, "CockpitElectric")
        add_group("RECENTLY RECONCILED", inv.reconciled, "CockpitMuted")
        if #inv.needs + #inv.implementing + #inv.reconciled == 0 then
          add("")
          local empty = "No plan artifacts"
          add(empty, { { 0, #empty, "CockpitMuted" } })
        end
      end)
    else
      -- CYCLE + TICKETS from the agent-cached cycle.json, in the same card chrome. Tickets
      -- in priority order; <CR>/o confirms + cockpit-adds a session. Live ones flagged.
      local cyc = read_cycle()
      if cyc and cyc.cycle then
      local cy = cyc.cycle
      local span = (cy.starts and cy.ends) and (" · " .. cy.starts .. "–" .. cy.ends) or ""
      local cprog = (cy.progress and cy.progress.total and cy.progress.total > 0)
        and ("  ◆ " .. (cy.progress.done or 0) .. "/" .. cy.progress.total) or ""
      -- split OPEN (actionable) from DONE — a finished ticket isn't something you kick
      -- off, so it goes in a dim group below, not mixed into the priority list.
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
      local have = {} -- ticket id → its live roster session entry (●-marker + teardown)
      for _, a in ipairs(S.roster) do
        local t = (a.name or ""):match("%a+%-%d+"); if t then have[t:upper()] = a end
      end
      local prigrp = { [1] = "CockpitErr", [2] = "CockpitElectric", [3] = "CockpitFile", [4] = "CockpitMuted" }
      local idw = 0
      for _, t in ipairs(open) do idw = math.max(idw, #(t.id or "")) end
      -- cap the open list to the room left, reserving for this card's head+tail chrome
      -- and the DONE card below (each card adds borders/pad the flat layout didn't).
      local reserve = 7 + ((#done > 0) and (4 + math.min(#done, 5)) or 0)
      local fit = math.max(1, math.min(#open, H - #lines - FOOTER_H - br - reserve))
      local cap = S.dash_expand and #open or fit
      card(nil, "TICKETS", function(add)
        local cd = (cy.name or "current") .. span .. cprog
        add(cd, { { 0, #cd, "CockpitMuted" } })
        local od = #open .. " open · ⏎ starts a session"
        add(od, { { 0, #od, "CockpitMuted" } })
        add("")
        for i = 1, cap do
          local t = open[i]
          local id = t.id or "?"
          local live = have[id:upper()]
          local mark = live and "●" or "○" -- ● = a session already exists for it
          local badge = live and "  · in progress" or "" -- a worktree/session is open for it
          local avail = math.max(10, CARD_INNER - (#mark + 1 + idw + 3) - #badge)
          local title = t.title or ""
          if #title > avail then title = title:sub(1, avail - 1) .. "…" end
          local text = mark .. " " .. id .. string.rep(" ", idw - #id) .. "   " .. title .. badge
          local segs = {
            { 0, #text, "CockpitFile" },                         -- id + title, neutral
            { 0, #mark, prigrp[t.priority] or "CockpitMuted" },  -- priority-coloured marker
          }
          if live then segs[#segs + 1] = { #text - #badge, #text, "CockpitElectric" } end -- in-progress flag
          ticketmap[add(text, segs)] = { id = id, slug = t.slug, live = live, title = t.title }
        end
        if #open > fit then
          local more = S.dash_expand and "⏶ show less   ⏎" or ("… " .. (#open - fit) .. " more   ⏎")
          expand_ln = add(more, { { 0, #more, "CockpitMuted" } })
        end
      end)

      -- DONE — dim. A done ticket that STILL has a session/worktree is offered for
      -- teardown (⊘ + ⏎); the rest are just ✓. Teardown-able ones sort first.
      if #done > 0 then
        push("")
        table.sort(done, function(x, y)
          local hx = have[(x.id or ""):upper()] and 0 or 1
          local hy = have[(y.id or ""):upper()] and 0 or 1
          if hx ~= hy then return hx < hy end
          return (x.id or "") < (y.id or "")
        end)
        card(nil, "DONE", function(add)
          for i = 1, math.min(#done, 5) do
            local t = done[i]
            local sess = have[(t.id or ""):upper()]
            local mark = sess and "⊘" or ICON.check
            local suffix = sess and "   ⏎ teardown" or ""
            local text = mark .. " " .. (t.id or "?") .. "  " .. (t.title or "") .. suffix
            local segs = { { 0, #text, "CockpitMuted" } }
            if sess then segs[#segs + 1] = { 0, #mark, "CockpitErr" } end -- ⊘ = lingering session
            local ln = add(text, segs)
            if sess then teardownmap[ln] = { id = sess.id, cwd = sess.cwd, ticket = t.id } end
          end
          if #done > 5 then local m = "… " .. (#done - 5) .. " more"; add(m, { { 0, #m, "CockpitMuted" } }) end
        end)
      end
    end
    end
  else
    -- Unified HUD card: PLAN and CHANGES in ONE card; <Tab> swaps the active view.
    -- Only the views that exist become tabs (a plan-less session shows just CHANGES).
    local ch = git_changes(cwd)
    -- manual (MT#) checks from review.json = the tests YOU run by hand (no `command`).
    local tests = {}
    if pl and pl.review and type(pl.review.verification) == "table" then
      for _, v in ipairs(pl.review.verification) do
        if not (v.command and v.command ~= "") then tests[#tests + 1] = v end
      end
    end
    local pending_tests = 0
    for _, v in ipairs(tests) do if (v.result or "pending") ~= "pass" then pending_tests = pending_tests + 1 end end
    local has_plan = pl and pl.progress
    local has_tests = #tests > 0
    local has_changes = ctx or #ch > 0
    local views = {}
    if has_plan then views[#views + 1] = "plan" end
    if has_tests then views[#views + 1] = "tests" end
    if has_changes then views[#views + 1] = "changes" end
    dash_views = views
    if #views > 0 then
      -- auto-switch to TESTS the moment manual tests first appear (the testing stage),
      -- once per session so you can still Tab away afterward.
      S.dash_tests_seen = S.dash_tests_seen or {}
      local sid = S.selected
      if sid and pending_tests > 0 and not S.dash_tests_seen[sid] then
        S.dash_view = "tests"; S.dash_tests_seen[sid] = true
      elseif sid and pending_tests == 0 then
        S.dash_tests_seen[sid] = nil
      end
      local view = S.dash_view
      if not vim.tbl_contains(views, view) then view = views[1] end
      S.dash_view = view
      -- title layout: PLAN · TESTS · CHANGES (white, box() titles them) with a ` ⇥ `
      -- keycap so it's obvious Tab swaps them; the ticket key is spliced to the
      -- RIGHTMOST edge of the border (Electric) as the session's identity.
      local parts = {}
      if has_plan then parts[#parts + 1] = ICON.plan .. " PLAN" end
      if has_tests then parts[#parts + 1] = ICON.tests .. " TESTS" end
      if has_changes then parts[#parts + 1] = ICON.changes .. " CHANGES" end
      local title = table.concat(parts, "    ")
      if #views >= 2 then title = title .. "    ⇥ " end -- Tab-swap hint (keycap-styled below)
      local topln = card(nil, title, function(add)
        if view == "plan" then
          local pg = pl.progress
          local done, total = 0, 0
          for _, s in ipairs(pg.flow or {}) do total = total + 1; if s.status == "done" then done = done + 1 end end
          add(pg.phase or "?", { { 0, #(pg.phase or "?"), "CockpitMuted" } }) -- key is in the border now
          if total > 0 then
            local label = done .. "/" .. total .. " "
            local barw = math.max(8, math.min(CARD_INNER - #label, 48))
            local btext, bsegs = progress_bar(done, total, barw, "CockpitElectric", "CockpitDivider")
            local segs = { { 0, #label, "CockpitMuted" } }
            for _, sg in ipairs(bsegs) do segs[#segs + 1] = { sg[1] + #label, sg[2] + #label, sg[3] } end
            add(label .. btext, segs)
            add("") -- margin between the gauge and the step list
          end
          local savail = math.max(12, CARD_INNER - 3)
          for _, s in ipairs(pg.flow or {}) do
            local g = s.status == "done" and ICON.step_done or (s.status == "active" and ICON.step_active or ICON.step_todo)
            local grp = s.status == "done" and "CockpitStream" or (s.status == "active" and "CockpitTitle" or "CockpitIdle")
            local step = s.step or ""
            if #step > savail then step = step:sub(1, savail - 1) .. "…" end
            local row = g .. " " .. step
            add(row, { { 0, #row, "CockpitFile" }, { 0, #g, grp } })
          end
        elseif view == "tests" then
          local detail = pending_tests .. " to run"
            .. (#tests > pending_tests and ("  ·  " .. (#tests - pending_tests) .. " done") or "")
          add(detail, { { 0, #detail, "CockpitMuted" } })
          add("")
          local savail = math.max(12, CARD_INNER - 3)
          for _, v in ipairs(tests) do
            local res = v.result or "pending"
            local g = res == "pass" and ICON.step_done or (res == "fail" and ICON.xmark or ICON.step_todo)
            local grp = res == "pass" and "CockpitStream" or (res == "fail" and "CockpitErr" or "CockpitIdle")
            local txt = v.check or v.name or "(test)"
            if #txt > savail then txt = txt:sub(1, savail - 1) .. "…" end
            local row = g .. " " .. txt
            add(row, { { 0, #row, "CockpitFile" }, { 0, #g, grp } })
          end
        else
          if #ch == 0 then
            add("working tree clean", { { 0, 18, "CockpitMuted" } })
          else
            local ta, td = 0, 0
            for _, c in ipairs(ch) do ta = ta + c.add; td = td + c.del end
            local detail = #ch .. (#ch == 1 and " file  ·  +" or " files  ·  +") .. ta .. " -" .. td
            add(detail, { { 0, #detail, "CockpitMuted" } })
            local aw, dw = 0, 0
            for _, c in ipairs(ch) do aw = math.max(aw, #("+" .. c.add)); dw = math.max(dw, #("-" .. c.del)) end
            local fitcap = math.max(1, math.min(#ch, H - FOOTER_H - br - #lines - 4)) -- rows left above the footer
            local cap = S.dash_expand and #ch or fitcap
            for i = 1, cap do
              local c = ch[i]
              local acol = string.rep(" ", aw - #("+" .. c.add)) .. "+" .. c.add
              local dcol = string.rep(" ", dw - #("-" .. c.del)) .. "-" .. c.del
              local line = file_row(CARD_INNER, "• ", c.path, acol, dcol)
              local segs = { { 0, #line, "CockpitFile" }, { 0, 3, "CockpitMuted" } } -- • bullet muted
              local ps, pe = line:find("%+%d+"); if ps then segs[#segs + 1] = { ps - 1, pe, "CockpitStream" } end
              local ms, me = line:find("%-%d+", (pe or 0) + 1); if ms then segs[#segs + 1] = { ms - 1, me, "CockpitErr" } end
              openmap[add(line, segs)] = c.path -- <CR>/o opens it
            end
            if #ch > fitcap then
              local more = S.dash_expand and "⏶ show less   ⏎" or ("… " .. (#ch - fitcap) .. " more   ⏎")
              expand_ln = add(more, { { 0, #more, "CockpitMuted" } })
            end
          end
        end
      end)
      if topln then
        -- active tab reads as an Electric pill; the others dim, so the selected view is
        -- obvious. Located by plain-find on the top-border line (robust to the LM/prefix
        -- offset), overriding box()'s uniform CockpitTitle for each tab's span.
        local tabmap = {}
        if has_plan then tabmap.plan = ICON.plan .. " PLAN" end
        if has_tests then tabmap.tests = ICON.tests .. " TESTS" end
        if has_changes then tabmap.changes = ICON.changes .. " CHANGES" end
        local tbl = lines[topln + 1] or ""
        for v, lbl in pairs(tabmap) do
          local s, e = tbl:find(lbl, 1, true)
          if s then
            -- active tab gets a padded pill (extend the bg one space each side, into the
            -- separator/border spaces); inactive tabs just dim, no bg.
            if v == view then hl(topln, "CockpitTabActive", s - 2, e + 1)
            else hl(topln, "CockpitMuted", s - 1, e) end
          end
        end
        -- splice the ticket key onto the RIGHT edge of the top border (replace the
        -- trailing dashes with " KEY ─┐"), coloured Electric. Same display width in,
        -- same out, so the border stays a perfect rectangle.
        if has_plan and pl.key then
          local ln, key = lines[topln + 1] or "", pl.key
          local strip = 3 + (#key + 3) * 3 -- ┐ (3B) + (kw+3) dashes (3B each)
          if #ln > strip + 30 then
            local base = ln:sub(1, #ln - strip)
            lines[topln + 1] = base .. " " .. key .. " ─┐"
            hl(topln, "CockpitElectric", #base + 1, #base + 1 + #key)
          end
        end
        -- the ` ⇥ ` Tab-swap hint reads as a keycap pill (shown when there's >1 tab).
        if #views >= 2 then
          local hs, he = (lines[topln + 1] or ""):find(" ⇥ ", 1, true)
          if hs then hl(topln, "CockpitKeyCap", hs - 1, he) end
        end
      end
    end
  end

  -- horizontal hint footer, pinned to the bottom row so a long changes list fills the
  -- space above without ever shoving the hints. Roster-style: ` k ` CockpitKeyCap pill +
  -- muted label, laid out left-to-right and centered.
  local ftext, fsegs = "", {}
  for i, a in ipairs(acts) do
    if i > 1 then ftext = ftext .. "      " end
    local cap = " " .. a.key .. " "
    local cs = #ftext; ftext = ftext .. cap; fsegs[#fsegs + 1] = { cs, #ftext, "CockpitKeyCap" }
    ftext = ftext .. " "
    local ls = #ftext; ftext = ftext .. a.label; fsegs[#fsegs + 1] = { ls, #ftext, "CockpitMuted" }
  end
  local fpad = math.max(0, math.floor((W - fn.strdisplaywidth(ftext)) / 2))
  -- pin to one row above the bottom edge (matching the composer's 1-row bottom pad). The
  -- old `- br` wrongly subtracted the TOP banner reservation here, floating it rows high.
  local target = math.max(#lines + 1, H - FOOTER_H - 1)
  while #lines < target do push("") end
  local fln = push(string.rep(" ", fpad) .. ftext)
  for _, s in ipairs(fsegs) do hl(fln, s[3], fpad + s[1], fpad + s[2]) end

  -- Full render every time + re-place the banner. (An earlier optimization preserved
  -- the top banner rows on same-width re-renders to avoid a Tab-swap flicker, but a
  -- STALE inline-image placement offset the rows below and left the card border
  -- jagged — "tab away and back" fixed it because that forced a full re-place. A
  -- correct card beats dodging a tiny flicker.)
  if _d then _d[#_d + 1] = vim.loop.hrtime() end -- [3]: after the dashboard body build
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, S.ns, 0, -1)
  for _, d in ipairs(decor) do pcall(api.nvim_buf_add_highlight, buf, S.ns, d.grp, d.ln, d.cs, d.ce) end
  S.dash = { open = openmap, sessions = sessmap, tickets = ticketmap, plans = planmap, teardown = teardownmap, expand_ln = expand_ln, cwd = cwd, win = win, views = dash_views } -- <CR>/o targets; views = the card's tab order
  dash_keys(buf, acts)
  pcall(api.nvim_win_set_buf, win, buf)
  editor_gutter(win, false) -- clean resting view: no number/sign/fold columns
  if _d then _d[#_d + 1] = vim.loop.hrtime() end -- [4]: before place_banner
  pcall(place_banner, buf, win)
  if _d then
    local ms = function(a, b) return (_d[b] - _d[a]) / 1e6 end
    pcall(fn.writefile, { string.format("  show_scratch(%s): pre+loadplan=%.1fms body=%.1fms commit=%.1fms place_banner=%.1fms",
      root and "root" or "worktree", ms(1, 2), ms(2, 3), ms(3, 4), (vim.loop.hrtime() - _d[4]) / 1e6) },
      "/tmp/cockpit-switch-timing.log", "a")
  end
  S.dash_w = (win and api.nvim_win_is_valid(win)) and api.nvim_win_get_width(win) or nil -- for the resize guard
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

-- Bind the dashboard's action keys buffer-locally. Clear the full known set first
-- so a row that vanished (e.g. devenv when the session isn't a cockpit context)
-- can't leave a stale keymap behind. <CR>/o are context-sensitive: open the file
-- row under the cursor, toggle the …more/less line, else run the first action.
dash_keys = function(buf, acts)
  for _, k in ipairs({ "p", "d", "a", "l", "n", "c", "r", "i", "<CR>", "o", "<Tab>" }) do pcall(vim.keymap.del, "n", k, { buffer = buf }) end
  local function map(lhs, f) vim.keymap.set("n", lhs, f, { buffer = buf, nowait = true, silent = true }) end
  for _, a in ipairs(acts) do map(a.key, a.fn) end
  -- `i` on the read-only dash means "talk to the agent": focus the rail composer.
  map("i", function()
    vim.fn.jobstart({ vim.fn.expand("~/.config/niri/scripts/cockpit-ipc"), "focusComposer" },
      { env = { COCKPIT_NVIM_SOCK = vim.env.NVIM_LISTEN_ADDRESS or "", HEIDR_NVIM_SOCK = vim.env.NVIM_LISTEN_ADDRESS or "" }, detach = true })
  end)
  -- <Tab> cycles the HUD card through its available views (PLAN · TESTS · CHANGES).
  map("<Tab>", function()
    local d = S.dash or {}
    local vs = d.views or {}
    if #vs > 1 then
      local i = 1
      for k, v in ipairs(vs) do if v == S.dash_view then i = k; break end end
      S.dash_view = vs[(i % #vs) + 1]
      if d.win and api.nvim_win_is_valid(d.win) then show_scratch(d.win, d.cwd) end
    end
  end)
  local function enter()
    local d = S.dash or {}
    local ln0 = api.nvim_win_get_cursor(0)[1] - 1
    if d.teardown and d.teardown[ln0] then
      local t = d.teardown[ln0]
      teardown_session(t.id, t.cwd)
      if d.win and api.nvim_win_is_valid(d.win) then vim.defer_fn(function() show_scratch(d.win, d.cwd) end, 500) end
    elseif d.plans and d.plans[ln0] then
      local p = d.plans[ln0]
      if p.session then
        view_session(p.session.id, p.session.cwd)
      else
        vim.notify("unbound — P in the rail binds it")
      end
      pcall(function() require("plan-nvim").open(p.slug) end)
    elseif d.tickets and d.tickets[ln0] then
      local t = d.tickets[ln0]
      if t.live then
        vim.notify("agent: " .. t.id .. " already has a session")
      elseif t.id and t.id ~= "" then
        -- name the worktree JUST the ticket id (lowercase, e.g. "every-2662") — no
        -- title slug. Linear still auto-links (it matches the identifier in the branch
        -- daphen/every-2662, case-insensitive) and GitHub closes from the PR body.
        -- cockpit-spawn = the full kickoff: worktree + devenv + nvim tab + seeded agent.
        local name = t.id:lower()
        local seed = "Work " .. t.id .. (t.title and t.title ~= "" and (": " .. t.title) or "")
          .. "\n\nStart with /plan-ticket " .. t.id .. " to scope it, then implement."
        if vim.fn.confirm("Spawn a session for " .. t.id .. "?", "&Yes\n&No", 2) == 1 then
          local home = os.getenv("HOME") or ""
          fn.jobstart({ home .. "/.local/bin/cockpit-spawn", name, seed }, { detach = true })
          vim.notify("agent: spawning session · " .. name)
        end
      else
        vim.notify("agent: ticket has no id in cycle.json")
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
function M.follow_remote(cwd, path, force, line)
  local ed = target_editor_win()
  if not ed then return "" end
  if force then
    -- A forced follow is the rail SWITCHING to a streaming session: adopt it
    -- (capturing the outgoing session's file first). Without this the viewed
    -- session changed while S.selected didn't, and the next capture filed the
    -- new session's buffer under the old session's memory.
    if cwd and cwd ~= "" then
      local want = fn.fnamemodify(cwd, ":t")
      for _, a in ipairs(S.roster or {}) do
        if a.cwd and fn.fnamemodify(a.cwd, ":t") == want then
          if S.selected and S.selected ~= a.id then capture_editor(S.selected) end
          S.selected = a.id
          break
        end
      end
    end
    S._follow_paused = nil; follow_edit(cwd, path, line, true, true); return ""
  end
  local bn = api.nvim_buf_get_name(api.nvim_win_get_buf(ed))
  -- Follow only while the editor rests on session context — never yank the user out
  -- of their own unrelated file. Session context is: the dashboard (unnamed scratch),
  -- the session's worktree, a PLAN buffer (watching the plan of a working session is
  -- the follow use-case, not a detour), or whatever file the follow itself opened
  -- last (a multi-repo plan otherwise self-blocks after its first out-of-repo edit).
  local plans = fn.expand("~/personal/notes/storage/plans/")
  local ours = S._follow and S._follow:gsub(":%d+$", "")
  if bn ~= "" and not (cwd and cwd ~= "" and bn:sub(1, #cwd) == cwd)
     and bn:sub(1, #plans) ~= plans and not bn:find("/%.plans/")
     and bn ~= ours then return "" end
  follow_edit(cwd, path, line, true)
  return ""
end

function M.dashboard(cwd)
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
  if cwd and cwd ~= "" then
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
-- context switch — reaches sessions with NO cockpit tab too (agent-spawned agents,
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
    -- Match EVERY identity form `want` can arrive as: the full session id/name
    -- (lovable.daphen-<slug>), the collapsed ticket (short_name → every-2662), the
    -- cockpit CONTEXT name (the <slug> a notification's cockpit-context hint carries),
    -- and the bare prefix-stripped name. The notification path sends the context slug,
    -- which matched NONE of the old two forms — the long-standing Super+i miss.
    local nm = a.name or a.id or ""
    local ctxname = (a.cwd and a.cwd ~= "") and cockpit_context(a.cwd) or nil
    local bare = nm:gsub("^lovable%.daphen%-", ""):gsub("^lovable%.", "")
    if a.id == want or nm == want or short_name(nm) == want or ctxname == want or bare == want then
      if a.id ~= S.selected then view_session(a.id, a.cwd) end
      -- land in the COMPOSER (like <CR> on the roster): ready to reply, and it doesn't
      -- yank you into the read-only chat pane while you were typing.
      if focus_composer then focus_composer() end
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
    elseif filename == "agent-jump" or filename == "agent-jump.tmp" then
      -- Match BOTH forms like `active` above: the writer does temp+rename
      -- (agent-jump.tmp → agent-jump), and libuv's fs_event frequently reports the
      -- TEMP name for the rename — so watching only "agent-jump" missed the event
      -- and Super+i (notification jump) never selected the roster item.
      vim.schedule(on_agent_jump)
    end
  end)
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

refresh_git_changes = function(cwd, path)
  if not cwd or fn.isdirectory(cwd) ~= 1 then return end
  if path and not S.gitdiff[cwd] then path = nil end
  local ok, signs = pcall(require, "hunk-nvim.signs")
  local base = ok and signs.base_for and signs.base_for(cwd) or "HEAD"
  if not base or base == "" then base = "HEAD" end
  -- A repo with no commits has no HEAD: diff against the empty tree so a brand-new
  -- project shows everything as added instead of an empty CHANGES view.
  if base == "HEAD" and fn.systemlist({ "git", "-C", cwd, "rev-parse", "-q", "--verify", "HEAD" })[1] == nil then
    base = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  end
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
      -- git diff never lists untracked paths — synthesize them so a fresh project
      -- shows its files as added instead of an empty CHANGES view.
      local unt = fn.systemlist({ "git", "-C", cwd, "ls-files", "--others", "--exclude-standard" })
      for _, f in ipairs(unt or {}) do
        if f ~= "" and not f:match("^%.heidr%-pastes/") then
          local n = tonumber(fn.system({ "wc", "-l", cwd .. "/" .. f }):match("%d+") or "0") or 0
          n = math.min(n, 500)
          output[#output + 1] = "diff --git a/" .. f .. " b/" .. f
          output[#output + 1] = "+++ b/" .. f
          -- the parser counts adds only inside @@ hunks — synthesize a real one
          output[#output + 1] = "@@ -0,0 +1," .. n .. " @@"
          for _ = 1, n do output[#output + 1] = "+x" end
        end
      end
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
        -- the DASHBOARD's CHANGES card is gated on git_changes; without this it renders
        -- once with a cold (empty) cache and never updates when the async diff lands —
        -- why a freshly-opened session showed an empty dash despite a real diff. Keyed on
        -- the dash's OWN cwd, not the selection: the cockpit rail renders dashboards for
        -- sessions this nvim has never selected, and gating on S.selected skipped them all.
        if refresh_dashboard and S.dash and S.dash.cwd == cwd then refresh_dashboard() end
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
            vim.schedule(function() if render_roster then render_roster() end end)
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
      vim.schedule(function() if render_roster then render_roster() end end)
      done_one()
    end,
  })
  if not ok then done_one() end
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
    decor[#decor + 1] = { line = push("  press <CR> to open a session"), fg = "CockpitMuted" }
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
          segs = { { 0, #text, "CockpitFile" }, { 0, #r.dot, r.grp } }
        else
          local as, ds = "+" .. r.add, "-" .. r.del
          local acol = string.rep(" ", aw - #as) .. as
          local dcol = string.rep(" ", dw - #ds) .. ds
          text = file_row(inner, indent, r.path, acol, dcol)
          segs = { { 0, #text, "CockpitFile" }, { 0, #r.dot, r.grp } }
          local ps, pe = text:find("%+%d+")
          if ps then segs[#segs + 1] = { ps - 1, pe, "CockpitStream" } end
          local ms, me = text:find("%-%d+", (pe or 0) + 1)
          if ms then segs[#segs + 1] = { ms - 1, me, "CockpitErr" } end
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
      local segs = { { 0, #s, "CockpitMuted" } }
      local ps, pe = s:find("%+%d+")
      if ps then segs[#segs + 1] = { ps - 1, pe, "CockpitStream" } end
      local ms, me = s:find("%-%d+", (pe or 0) + 1)
      if ms then segs[#segs + 1] = { ms - 1, me, "CockpitErr" } end
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
          local btext, bsegs = progress_bar(done, #flow, math.max(8, inner - #label - 1), "CockpitElectric", "CockpitDivider")
          local text = label .. btext
          local segs = { { 0, #label, "CockpitMuted" } }
          for _, sg in ipairs(bsegs) do segs[#segs + 1] = { sg[1] + #label, sg[2] + #label, sg[3] } end
          add(text, segs)
        end
        for _, step in ipairs(flow) do
          local g = step.status == "done" and "●" or (step.status == "active" and "◐" or "○")
          local grp = step.status == "done" and "CockpitStream" or (step.status == "active" and "CockpitAccent" or "CockpitIdle")
          local t = g .. " " .. (step.step or "")
          -- status colour on the DOT only; the step text stays neutral (not a green wash)
          add(t, { { 0, #g, grp }, { #g, #t, "CockpitFile" } })
        end
      end, nil, false, false, true, true)
      local rows = {}
      for _, pf in ipairs(pg.planned or {}) do
        local c = bypath[pf.file]
        rows[#rows + 1] = {
          dot = pf.status == "done" and "●" or (pf.status == "touched" and "◐" or "○"),
          grp = pf.status == "done" and "CockpitStream" or (pf.status == "touched" and "CockpitAccent" or "CockpitIdle"),
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
            box_files(add, { { dot = "⚠", grp = "CockpitAttn", path = c.path, add = c.add, del = c.del, hunks = c.hunks } })
          end
        end, nil, false, false, true, true)
      end
    else
      box(push, decor, W, ICON.changes, "CHANGES · " .. base(cwd), function(add)
        local ds, dsegs = diffstat(); if ds then add(ds, dsegs) end
        if #changes == 0 then
          add("no changes on this branch", { { 0, #"no changes on this branch", "CockpitMuted" } })
        else
          local rows = {}
          for _, c in ipairs(changes) do
            rows[#rows + 1] = { dot = ICON.file_change, grp = "CockpitIdle", path = c.path, add = c.add, del = c.del, hunks = c.hunks }
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
          add(t, { { 0, #t, "CockpitIdle" } })
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
  vim.wo[win].winhighlight = "Normal:Normal,FloatBorder:CockpitMuted"
  vim.wo[win].conceallevel = 2
  vim.wo[win].wrap = true
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = b, nowait = true })
  vim.keymap.set("n", "<Esc>", "<cmd>close<CR>", { buffer = b, nowait = true })
  -- floats are read-only navigation surfaces — hide the cursor here too. One fixed
  -- group (cleared each open) — floats are modal, so per-buffer named groups just
  -- leaked one augroup per float opened.
  local grp = api.nvim_create_augroup("CockpitFloatCursor", { clear = true })
  api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = grp, buffer = b,
    callback = function()
      if not S.saved_gcr then S.saved_gcr = vim.o.guicursor end
      vim.o.guicursor = "a:CockpitCursorFloat"
    end,
  })
  api.nvim_create_autocmd({ "BufLeave", "WinLeave", "BufWipeout" }, {
    group = grp, buffer = b,
    callback = function() if S.saved_gcr then vim.o.guicursor = S.saved_gcr end end,
  })
  if not S.saved_gcr then S.saved_gcr = vim.o.guicursor end
  vim.o.guicursor = "a:CockpitCursorFloat"
  return win
end

function M.help()
  float({
    " roster   attention queue · z show all · / filter by name · s search all transcripts",
    "          j/k move · <CR> open · ]a/[a next needing you · n new · . cwd",
    "          x stop · a abort · <C-r> restart pi (reload MCP) · p peek · <Esc> clear filter",
    " chat     <Tab> changes · ]m/[m message · za/zM/zR fold · yr reply · yc convo",
    "          gf open ref · gx open url/link · yl yank link url · i compose",
    " changes  <CR> open file · ]f/[f next file · <Tab> back to chat · r refresh",
    " composer <CR> send · <C-s> send(insert) · <C-f> attach · <C-↑/↓> scroll chat",
    "          <C-x> drop attachments · q roster · / commands",
    "",
    " anywhere R focus roster · <leader>a toggle · <leader>A quick-message active session",
    "          <leader>as (visual) send selection · :CockpitSend / File / Diff / Diagnostics",
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
  -- ft=markdown so markview attaches and renders the structure (headings / bold / inline
  -- code / fenced-block backgrounds) off its OWN parser. We don't start nvim's treesitter
  -- highlighter on the chat, but markview STILL syntax-highlights code fences itself (chat
  -- AND plans) via get_visual_text, which lazily loads a parser per fence language on first
  -- render — the ~230ms first-focus hitch.
  vim.bo[S.chatbuf].filetype = "markdown"
  -- Pre-warm markview's WHOLE pipeline during idle startup: its first render in a process
  -- costs ~340ms (module + query + per-fence-language parser loads), which is the lag you
  -- feel the first time you focus the chat. Run one full render on a throwaway sample (with
  -- fences in every language the chat/plans use) so that cost is paid once, off the
  -- interaction — the first real chat/plan render is then ~30ms.
  vim.defer_fn(function()
    local ok, cmd = pcall(require, "markview.commands")
    if not ok then return end
    local sample = { "# h", "`inline` **bold** _it_ [x](http://y)" }
    for _, l in ipairs({ "ts", "typescript", "tsx", "javascript", "json", "jsonc", "toml",
      "yaml", "rust", "bash", "sh", "python", "lua", "go", "diff", "html", "css" }) do
      sample[#sample + 1] = "```" .. l; sample[#sample + 1] = "const x = 1"; sample[#sample + 1] = "```"
    end
    local b = api.nvim_create_buf(false, true)
    vim.bo[b].filetype = "markdown" -- markview attaches on FileType
    api.nvim_buf_set_lines(b, 0, -1, false, sample)
    pcall(cmd.render, b)
    pcall(api.nvim_buf_delete, b, { force = true })
  end, 500)

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
  -- no auto-formatting: wrapmargin/textwidth insert REAL newlines into the typed
  -- text (they leak into the sent+stored message as hard breaks). Visual wrapping
  -- is the window's `wrap=true` — display-only, never mutates the buffer text.
  vim.bo[S.composerbuf].textwidth = 0
  vim.bo[S.composerbuf].wrapmargin = 0

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
  cmap("zo", function() -- load the full (uncapped) history for this session
    if not S.selected then return end
    S.chat_full = S.chat_full or {}
    S.chat_full[S.selected] = true
    send({ type = "get_entries", session = S.selected })
  end)
  cmap("Y", function() chat_yank_code() end)
  cmap("yy", function() chat_yank_line() end)  -- yank the single line you see (skips ``` fences)
  cmap("yr", function() chat_yank_reply() end) -- yank (copy) the last agent reply
  cmap("yc", function() chat_yank_convo() end) -- yank the whole conversation as md
  cmap("gf", function() chat_open() end)
  cmap("gx", function() chat_open_url() end) -- open the URL/link under the cursor
  cmap("yl", function() chat_yank_url() end) -- yank the URL of the link under the cursor
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

  -- Copying from the chat: markview CONCEALS markdown delimiters, but they stay in the
  -- buffer — so a plain yank grabs raw `backticks`/**bold**. Strip the common inline
  -- markers from the yanked register (and the clipboard, when unnamed(plus) is in effect)
  -- so what you paste matches what you saw. setreg doesn't re-fire TextYankPost → no loop.
  api.nvim_create_autocmd("TextYankPost", {
    buffer = S.chatbuf,
    callback = function()
      local ev = vim.v.event
      if ev.operator ~= "y" or type(ev.regcontents) ~= "table" then return end
      local out, changed = {}, false
      for _, l in ipairs(ev.regcontents) do
        local s = l:gsub("`", ""):gsub("%*%*(.-)%*%*", "%1"):gsub("~~(.-)~~", "%1")
        if s ~= l then changed = true end
        out[#out + 1] = s
      end
      if not changed then return end
      local reg = (ev.regname == nil or ev.regname == "") and '"' or ev.regname
      pcall(vim.fn.setreg, reg, out, ev.regtype)
      if reg == '"' then
        local cb = vim.o.clipboard or ""
        if cb:find("unnamedplus", 1, true) then pcall(vim.fn.setreg, "+", out, ev.regtype) end
        if cb:find("unnamed", 1, true) then pcall(vim.fn.setreg, "*", out, ev.regtype) end
      end
    end,
  })

  -- The chat gutter tracks focus: 2 blank cols when unfocused (text tight to the
  -- left, aligned with the composer input), and 3 cols when focused — the RELATIVE
  -- line number (for count-motions like 12j) plus a trailing space so the number
  -- never butts against the text. So focusing the chat grows the left text margin by
  -- one col (numbers get their own gutter with a gap), and blurring it shrinks back.
  -- Width is uniform within each focus state, so text doesn't jitter row-to-row.
  -- relnum for a VISIBLE line ≤ window height, so 2 digits always fit; the cursor
  -- line (relnum 0) stays blank but keeps the focused width so it aligns.
  _G.__CockpitChatStc = function()
    -- focused = the chat window is the actually-current window. (Don't use
    -- g:statusline_winid — it isn't set during 'statuscolumn' eval, only statusline/
    -- winbar, so the old check always failed and the gutter was permanently blank.)
    if not (S.chatwin and api.nvim_get_current_win() == S.chatwin) then return "  " end
    local r = vim.v.relnum
    if r == 0 then return "   " end
    if r > 99 then return "99 " end
    return string.format("%2d ", r)
  end
  local CHAT_STC = "%!v:lua.__CockpitChatStc()"
  local chatnum = api.nvim_create_augroup("CockpitChatNum", { clear = true })
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
    local sid = S.selected
    -- 1) a QUEUED message (sent mid-turn, NOT yet delivered / worked on) → pull it BACK
    --    into the composer to edit or resend, Claude-style. The running turn is untouched.
    local q = sid and S.queued and S.queued[sid]
    if q and q ~= "" then
      S.queued[sid] = nil
      api.nvim_buf_set_lines(S.composerbuf, 0, -1, false, vim.split(q, "\n", { plain = true }))
      render_chips(); composer_placeholder(); render_chat(false) -- drop the queued indicator
      if S.composerwin and api.nvim_win_is_valid(S.composerwin) then
        api.nvim_set_current_win(S.composerwin)
        pcall(api.nvim_win_set_cursor, S.composerwin, { api.nvim_buf_line_count(S.composerbuf), 0 })
        vim.cmd("startinsert!")
      end
      vim.notify("queued message returned to the composer")
      return true
    end
    -- 2) the agent is working, nothing queued → interrupt the turn.
    if is_working() then
      send({ type = "abort", session = sid })
      S.stream[sid] = nil
      if S.turn_active then S.turn_active[sid] = nil end
      vim.notify("agent: interrupted")
      render_chat(false)
      return true
    end
    -- idle → TRUE rewind: agentd truncates the session to before the last user
    -- turn and respawns pi; the "rewound" event brings the removed message back
    -- into the composer (see handle). Falls back to a local restore if offline.
    if S.selected and S.connected then
      -- Guard: a session whose ONLY user turn is the seed prompt would be wiped
      -- entirely by a rewind (truncateLastUserTurn drops the last user turn + all
      -- after it) — that's the "empty chat after rewind" data loss. Refuse when we
      -- can see there's ≤1 user turn; if the transcript isn't loaded, defer to
      -- agentd's own refuse-to-empty guard.
      local c = S.chat[S.selected]
      if c and c.msgs then
        local users = 0
        for _, m in ipairs(c.msgs) do if m.role == "user" then users = users + 1 end end
        if users <= 1 then
          vim.notify("Cockpit: nothing to rewind — only the opening turn", vim.log.levels.WARN)
          return true
        end
      end
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

  -- ↑/↓ recall sent-message history (shell / Claude-style). ↑ on the FIRST line loads the
  -- previous sent message (older each press); ↓ steps back toward your live draft. Off the
  -- first line ↑ is a normal cursor move, so multi-line editing still works. A live slash
  -- picker takes the arrows first.
  local function _set_composer(text)
    api.nvim_buf_set_lines(S.composerbuf, 0, -1, false, vim.split(text or "", "\n", { plain = true }))
    render_chips(); composer_placeholder()
    local n = api.nvim_buf_line_count(S.composerbuf)
    pcall(api.nvim_win_set_cursor, 0, { n, #(api.nvim_buf_get_lines(S.composerbuf, n - 1, n, false)[1] or "") })
  end
  local function hist_recall(dir)
    local sid = S.selected
    local h = sid and S.history and S.history[sid]
    if not (h and #h > 0) then return false end
    S.histpos = S.histpos or {}
    local b = S.histpos[sid]
    if dir < 0 then -- older
      if not b then
        b = { idx = #h + 1, draft = table.concat(api.nvim_buf_get_lines(S.composerbuf, 0, -1, false), "\n") }
        S.histpos[sid] = b
      end
      if b.idx <= 1 then return true end -- already at the oldest; swallow the key
      b.idx = b.idx - 1
      _set_composer(h[b.idx])
    else -- newer
      if not b then return false end
      b.idx = b.idx + 1
      if b.idx > #h then S.histpos[sid] = nil; _set_composer(b.draft) else _set_composer(h[b.idx]) end
    end
    return true
  end
  vim.keymap.set({ "n", "i" }, "<Up>", function()
    if sl_move(-1) then return end -- slash picker open → navigate it
    -- recall only when the input is BLANK (else ↑ is a normal cursor move), or when you're
    -- already stepping through history (so repeated ↑ keeps going older).
    local blank = table.concat(api.nvim_buf_get_lines(S.composerbuf, 0, -1, false), ""):match("%S") == nil
    local browsing = S.histpos and S.histpos[S.selected]
    if (blank or browsing) and hist_recall(-1) then return end
    passthru("<Up>")
  end, { buffer = S.composerbuf, nowait = true })
  vim.keymap.set({ "n", "i" }, "<Down>", function()
    if sl_move(1) then return end
    if S.histpos and S.histpos[S.selected] and hist_recall(1) then return end
    passthru("<Down>")
  end, { buffer = S.composerbuf, nowait = true })

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
  map("x", function() -- stop the session + tear down its devenv slice; KEEP the worktree on disk
    local a = S.displayed[S.focus]
    if not a then return end
    send({ type = "stop", session = a.id })
    if S.selected == a.id then S.selected = nil end
    -- Also tear down the worktree's devenv slice so `x` doesn't leave an orphan
    -- devenv behind. slice-down kills only the .devenv procs + that worktree's
    -- process-compose (targeted by exe path) — it never removes the worktree files.
    -- Lovable scope only (where devenv exists); `X` remains the full teardown (wt rm).
    if scope == "lovable" and a.cwd and a.cwd ~= "" then
      pcall(fn.jobstart, { (os.getenv("HOME") or "") .. "/.local/bin/slice-down", a.cwd }, { detach = true })
    end
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
    if #q == 0 then vim.notify("Cockpit: nothing needs you"); return end
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
  local grp = api.nvim_create_augroup("CockpitRailCursor", { clear = true })
  -- ONE coalesced, deferred roster render per focus change. Both enter and leave
  -- fire on TWO events each (Buf* + Win*); rendering per-event set the buffer twice
  -- and flashed the wrong expand/highlight state mid-transition. Deferring lets focus
  -- settle first (render_roster self-computes roster_active from the current window),
  -- and the pending-guard collapses a burst of events into a single repaint.
  local roster_refresh_pending = false
  local function refresh_roster_soon()
    if roster_refresh_pending or not S.built then return end
    roster_refresh_pending = true
    vim.schedule(function()
      roster_refresh_pending = false
      if S.built and render_roster then render_roster() end
    end)
  end
  api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = grp, buffer = S.buf,
    callback = function()
      if not S.saved_gcr then S.saved_gcr = vim.o.guicursor end
      vim.o.guicursor = "a:CockpitCursorRoster"
      -- focusing the roster to switch sessions → show them all (collapses on leave).
      -- Gated on S.built inside refresh_roster_soon: nvim_win_set_buf during M.open
      -- fires BufEnter here before the chat/composer windows exist — an early render
      -- would shrink the roster and the next split dies E36 "not enough room".
      if S.built and not S.roster_pinned_open then S.show_all = true end -- pinned already shows all
      refresh_roster_soon()
    end,
  })
  api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = grp, buffer = S.buf,
    callback = function()
      if S.saved_gcr then vim.o.guicursor = S.saved_gcr end
      if S.built and not S.roster_pinned_open then S.show_all = false end -- collapse on blur UNLESS pinned
      refresh_roster_soon()
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

  -- Chat + composer own custom statuscolumns (chat = focus-aware relnum gutter;
  -- composer = the › prompt + input margin). They're reasserted from these constants
  -- by the gutter autocmd, so a transient clear (file-open, husk cleanup, layout
  -- event) self-heals on the next window event instead of stripping them for good.
  local CHATWIN_STC = "%!v:lua.__CockpitChatStc()"
  local COMPOSER_STC = "%#CockpitAccent#%{v:lnum==1&&v:virtnum==0?'  ›  ':'     '}"
  local ROSTER_STC = "  " -- roster's 2-col left margin; reasserted alongside the other two

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
  vim.wo[S.win].winhighlight = "WinSeparator:CockpitDivider"
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
  vim.wo[S.chatwin].statuscolumn = CHATWIN_STC -- 2-col gutter; relnum on focus, blank off (see __CockpitChatStc)
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
  vim.wo[S.composerwin].statuscolumn = COMPOSER_STC
  vim.wo[S.composerwin].fillchars = "eob: " -- blank bottom pad row (no hairline)
  vim.wo[S.composerwin].winhighlight = "Normal:Normal,WinSeparator:CockpitDivider"
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
    vim.wo[edwin].winhighlight = (S.editor_wh ~= "" and (S.editor_wh .. ",") or "") .. "WinSeparator:CockpitDivider"
  end

  if not S.saved_gcr then S.saved_gcr = vim.o.guicursor end
  vim.o.guicursor = "a:CockpitCursorRoster"
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
  local fgrp = api.nvim_create_augroup("CockpitRailFocus", { clear = true })
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
  vim.defer_fn(function()
    refresh_plans()
    if S.win and api.nvim_win_is_valid(S.win) then render_roster() end
    refresh_dashboard()
  end, 300)
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
    local ours = S._follow and S._follow:gsub(":%d+$", "")
    -- Plan buffers are spectating, not working — they must never pause follow
    -- (watching the plan of a working session is follow's main use-case).
    if name:find("/notes/storage/plans/", 1, true) or name:find("/%.plans/") then return end
    if name ~= ours then S._follow_paused = true end
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
    S._follow_paused = true
  end,
})

function M.setup(opts)
  opts = opts or {}
  load_qsicons()
  target_editor_win()
  -- Embedded cockpit (TermView env): the QML chin renders the statusline; feed it.
  if cockpit_env("COCKPIT") == "1" then pcall(function() require("cockpit.chin").setup() end) end
  if opts.scope then scope = opts.scope end
  if opts.scopes then ROOTS = opts.scopes end
  S.ns = api.nvim_create_namespace("agent_nvim")
  S.composer_ns = api.nvim_create_namespace("agent_nvim_composer")
  S.chip_ns = api.nvim_create_namespace("agent_nvim_chips")
  S.pad_ns = api.nvim_create_namespace("agent_nvim_chatpad")
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
      S.follow_pending = { cwd = cwd, path = path, sid = S.selected }
      if not S.follow_cd then
        local function fire()
          local p = S.follow_pending; S.follow_pending = nil
          if not p or p.sid ~= S.selected then return end -- switched sessions → drop
          local abs = edit_abs(p.cwd, p.path)
          -- Attribution gate (bulletproof for shared-cwd multi-agent): only follow a
          -- file THIS session's own tool-calls edited, recorded live from
          -- message_update. Excludes a co-located agent's writes in a shared cwd, plus
          -- history/state/log files nothing edited via a tool. inotify has no agent
          -- info; agentd's per-session stream is the only ground truth for authorship.
          local ed = S.edited[p.sid]
          if not (abs and ed and ed[abs]) then return end
          -- And only when it's a real tracked hunk to reveal (skips untracked scratch).
          local rel = abs:sub(1, #p.cwd + 1) == p.cwd .. "/" and abs:sub(#p.cwd + 2) or abs
          local g = S.gitdiff[p.cwd]
          if not (g and g.bypath[rel]) then return end
          follow_edit(p.cwd, abs, nil)
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

  api.nvim_create_user_command("CockpitRail", function() M.toggle() end, {})
  api.nvim_create_user_command("CockpitReconnect", function()
    S.connected = false
    pcall(function() if S.pipe then S.pipe:close() end end)
    S.pipe, S.readbuf, S.connecting = nil, "", false
    render_roster()
    connect(function() send({ type = "list_sources" }) end)
  end, {})
  api.nvim_create_user_command("CockpitReroot", function(o) reroot(o.args) end, { nargs = 1 })
  api.nvim_create_user_command("CockpitDash", to_dashboard, {}) -- editor back to the session dashboard
  -- Swap the masthead banner light/dark when the theme flips, if it's showing.
  api.nvim_create_autocmd("ColorScheme", {
    callback = function()
      if S.scratchbuf and api.nvim_buf_is_valid(S.scratchbuf) then
        pcall(place_banner, S.scratchbuf, S.dash and S.dash.win)
      end
    end,
  })
  -- global: jump the editor to the active session's dashboard from ANY buffer
  -- (no-ops when there's no session, so it's a safe always-on binding). <leader>D
  -- rather than gd — bare gd is LSP go-to-definition.
  vim.keymap.set("n", "<leader>D", to_dashboard, { desc = "Cockpit: session dashboard" })
  api.nvim_create_user_command("CockpitFollow", function()
    S.follow_edits = not (S.follow_edits ~= false)
    vim.notify("Cockpit: live-follow edits " .. (S.follow_edits and "on" or "off"))
  end, {})
  api.nvim_create_user_command("CockpitSend", function() M.send_range() end, { range = true })
  api.nvim_create_user_command("CockpitSendFile", function() M.send_file() end, {})
  api.nvim_create_user_command("CockpitSendDiff", function() M.send_diff() end, {})
  api.nvim_create_user_command("CockpitSendDiagnostics", function() M.send_diagnostics() end, {})
  api.nvim_create_user_command("CockpitMsg", function() M.send_message() end, {})
  -- Open a file in a real editor window, NEVER a rail buffer: open_in_editor skips
  -- every agent-* window and makes a fresh vsplit if only the rail is up. The
  -- review-pr skill calls this (`:CockpitEdit <path>`) so the review .md can't land in
  -- the composer/chat even when a rail pane is focused.
  api.nvim_create_user_command("CockpitEdit", function(o) open_in_editor(nil, o.args, nil) end,
    { nargs = 1, complete = "file" })
  -- preview the approval card without a real agent: :CockpitMockApproval [confirm|select|input]
  api.nvim_create_user_command("CockpitMockApproval", function(o)
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
  for _, suffix in ipairs({ "Rail", "Reconnect", "Reroot", "Dash", "Follow", "Send", "SendFile",
                              "SendDiff", "SendDiagnostics", "Msg", "Edit", "MockApproval" }) do
    api.nvim_create_user_command("Heidr" .. suffix, function(o)
      local prefix = o.range > 0 and (o.line1 .. "," .. o.line2) or ""
      local args = o.args ~= "" and (" " .. o.args) or ""
      vim.cmd(prefix .. "Cockpit" .. suffix .. args)
    end, { nargs = "*", range = true })
  end

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
  -- opts OUT. Rail panes are separate windows that stay gutterless via their own setup, and
  -- floats manage themselves, so we touch only normal, non-rail windows here.
  api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinEnter" }, {
    callback = function()
      local rs = rail_set()
      for _, w in ipairs(api.nvim_list_wins()) do
        local cfg = api.nvim_win_get_config(w)
        if cfg.relative == nil or cfg.relative == "" then
          if rs[w] then
            -- Cockpit rail pane → hide the gutter (the opt-out). The chat AND composer own
            -- custom statuscolumns; REASSERT them here (don't just skip) so a transient
            -- clear from a file-open/layout event self-heals on the next window event
            -- instead of leaving the composer without its › prompt + margin.
            vim.wo[w].number = false; vim.wo[w].relativenumber = false
            vim.wo[w].signcolumn = "no"; vim.wo[w].foldcolumn = "0"
            if w == S.chatwin then
              vim.wo[w].statuscolumn = CHATWIN_STC
            elseif w == S.composerwin then
              vim.wo[w].statuscolumn = COMPOSER_STC
            elseif w == S.win then
              vim.wo[w].statuscolumn = ROSTER_STC
            else
              vim.wo[w].statuscolumn = ""
            end
          else
            editor_gutter(w, api.nvim_win_get_buf(w) ~= S.scratchbuf)
          end
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
            else
              -- Height-only resize: re-place the banner without re-rendering the card.
              pcall(place_banner, S.scratchbuf, w)
            end
          end
        end
      end)
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
  -- In Cockpit the standalone rail isn't used; keymaps.lua owns <C-l>
  -- (cross into the Quickshell rail) and <C-h>, so don't override them here.
  if cockpit_env("COCKPIT") ~= "1" then
    for _, d in ipairs({ "h", "l" }) do
      vim.keymap.set("n", "<C-" .. d .. ">", function() wincmd_rail_aware(d) end,
        { desc = "Window " .. d .. " (rail-aware)" })
      vim.keymap.set("n", "<C-w>" .. d, function() wincmd_rail_aware(d) end,
        { desc = "Window " .. d .. " (rail-aware)" })
    end
  end
  vim.keymap.set("n", "<leader>a", function() M.toggle() end, { desc = "Toggle agent rail" })
  vim.keymap.set("n", "<leader>A", function() M.send_message() end, { desc = "Quick-message the active agent" })
  vim.keymap.set("x", "<leader>as", ":<C-u>lua require('cockpit').send_range()<CR>", { silent = true, desc = "Send selection to agent" })

  -- Autostart only when launched via `cockpit-rail` (legacy `heidr` also sets the alias).
  -- or the cockpit nvim leg. A plain `nvim` stays dormant — quicknotes, config edits,
  -- etc. get a clean editor with no rail. `nvim` vs `cockpit-rail` are the two explicit
  -- entry points; the rail no longer hijacks every nvim (which also stopped N stray
  -- nvims each polling devenv). The rail is still one keypress away: <leader>a.
  -- Scope is auto-detected independently (COCKPIT_SCOPE / niri workspace).
  -- Force either way with setup({ autostart = true|false }).
  local autostart = opts.autostart
  if autostart == nil then autostart = cockpit_env("OPEN") ~= nil end
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
