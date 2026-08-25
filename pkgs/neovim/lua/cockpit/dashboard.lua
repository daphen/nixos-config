local M = {}

local function row(text, fields)
  local out = { text = text or "" }
  for key, value in pairs(fields or {}) do out[key] = value end
  return out
end

local function card(model, title)
  local out = { title = title, rows = {} }
  model.cards[#model.cards + 1] = out
  return out.rows
end

local function add(rows, text, fields)
  rows[#rows + 1] = row(text, fields)
end

local function action(id, prefix)
  if not id or id == "" then return nil end
  return prefix .. id
end

local function personal_home(model, spec)
  local rows = card(model, "PLANS")
  local inventory = spec.inventory or {}
  local needs = inventory.needs or {}
  local implementing = inventory.implementing or {}
  local reconciled = inventory.reconciled or {}
  local summary = #needs .. " need you · " .. #implementing .. " implementing"
  add(rows, summary, { icon = "clipboard-check", label = summary, iconTone = "muted", tone = "muted" })

  local function group(label, plans, tone, icon)
    if #plans == 0 then return end
    add(rows, label, { tone = tone })
    for _, plan in ipairs(plans) do
      local session = plan.session and (plan.session.name or plan.session.id) or "unbound"
      add(rows, plan.slug, {
        icon = icon,
        label = plan.slug,
        detail = (plan.done or 0) .. "/" .. (plan.total or 0) .. " · " .. session,
        action = action(plan.slug, "plan:"),
        iconTone = tone,
        tone = label == "RECENTLY RECONCILED" and "muted" or "normal",
      })
    end
  end

  group("NEEDS YOU", needs, "error", "triangle-warning")
  group("IMPLEMENTING", implementing, "accent", "loader")
  group("RECENTLY RECONCILED", reconciled, "muted", "check")
  if #needs + #implementing + #reconciled == 0 then
    add(rows, "No plan artifacts", { tone = "muted" })
  end
end

local function lovable_home(model, spec)
  local cycle = spec.cycle
  if not (cycle and cycle.cycle) then return end
  local meta = cycle.cycle
  local open, done = {}, {}
  for _, ticket in ipairs(cycle.tickets or {}) do
    if ticket.done then done[#done + 1] = ticket else open[#open + 1] = ticket end
  end
  table.sort(open, function(a, b)
    local ap = (a.priority == nil or a.priority == 0) and 99 or a.priority
    local bp = (b.priority == nil or b.priority == 0) and 99 or b.priority
    return ap == bp and (a.id or "") < (b.id or "") or ap < bp
  end)
  table.sort(done, function(a, b)
    local alive = spec.live_tickets or {}
    local aa = alive[(a.id or ""):upper()] and 0 or 1
    local bb = alive[(b.id or ""):upper()] and 0 or 1
    return aa == bb and (a.id or "") < (b.id or "") or aa < bb
  end)

  local rows = card(model, "TICKETS")
  local span = meta.starts and meta.ends and (" · " .. meta.starts .. "–" .. meta.ends) or ""
  local progress = meta.progress and meta.progress.total and meta.progress.total > 0
    and ((meta.progress.done or 0) .. "/" .. meta.progress.total) or nil
  add(rows, (meta.name or "current") .. span, {
    icon = "calendar-days", label = (meta.name or "current") .. span,
    detail = progress, iconTone = "muted", tone = "muted",
  })
  add(rows, #open .. " open · starts a session", {
    icon = "arrow-door-in", label = #open .. " open · starts a session", iconTone = "muted", tone = "muted",
  })
  local limit = spec.expanded and #open or math.min(#open, spec.ticket_limit or #open)
  for index = 1, limit do
    local ticket = open[index]
    local id = ticket.id or "?"
    local live = (spec.live_tickets or {})[id:upper()]
    local suffix = live and " · in progress" or ""
    add(rows, id .. "  " .. (ticket.title or "") .. suffix, {
      icon = live and "half-dotted-circle-play" or "circle-hashtag",
      label = id .. "   " .. (ticket.title or "") .. suffix,
      action = action(id, "ticket:"),
      iconTone = ({ [1] = "error", [2] = "accent", [3] = "normal", [4] = "muted" })[ticket.priority] or "muted",
    })
  end
  if #open > limit then
    add(rows, "… " .. (#open - limit) .. " more", { tone = "muted", action = "expand" })
  elseif spec.expanded and #open > (spec.ticket_limit or #open) then
    add(rows, "show less", { tone = "muted", action = "expand" })
  end

  if #done > 0 then
    local done_rows = card(model, "DONE")
    for index = 1, math.min(#done, 5) do
      local ticket = done[index]
      local id = ticket.id or "?"
      local live = (spec.live_tickets or {})[id:upper()]
      add(done_rows, id .. "  " .. (ticket.title or ""), {
        icon = live and "triangle-warning" or "check",
        label = id .. "  " .. (ticket.title or ""),
        detail = live and "teardown" or nil,
        iconTone = live and "error" or "muted",
        tone = "muted",
        action = live and action(live.id, "teardown:") or nil,
      })
    end
    if #done > 5 then add(done_rows, "… " .. (#done - 5) .. " more", { tone = "muted" }) end
  end
end

local function plan_rows(rows, plan)
  local progress = plan.progress
  add(rows, progress.phase or "?", { tone = "muted" })
  local done, total = 0, 0
  for _, step in ipairs(progress.flow or {}) do
    total = total + 1
    if step.status == "done" then done = done + 1 end
  end
  if total > 0 then add(rows, done .. "/" .. total .. " steps", { tone = "muted" }) end
  for _, step in ipairs(progress.flow or {}) do
    local status = step.status or "todo"
    add(rows, step.step or "", {
      icon = status == "done" and "check" or (status == "active" and "loader" or "minus"),
      label = step.step or "", markerTone = status == "done" and "success" or (status == "active" and "accent" or "muted"),
    })
  end
end

local function test_rows(rows, tests)
  local pending = 0
  for _, test in ipairs(tests) do if (test.result or "pending") ~= "pass" then pending = pending + 1 end end
  add(rows, pending .. " to run" .. (#tests > pending and (" · " .. (#tests - pending) .. " done") or ""), { tone = "muted" })
  for _, test in ipairs(tests) do
    local result = test.result or "pending"
    local label = test.check or test.name or "(test)"
    add(rows, label, {
      icon = result == "pass" and "check" or (result == "fail" and "triangle-warning" or "minus"),
      label = label, markerTone = result == "pass" and "success" or (result == "fail" and "error" or "muted"),
    })
  end
end

local function change_rows(rows, changes, expanded, limit)
  if #changes == 0 then add(rows, "working tree clean", { tone = "muted" }); return end
  local additions, removals = 0, 0
  for _, change in ipairs(changes) do
    additions = additions + (change.add or 0)
    removals = removals + (change.del or 0)
  end
  add(rows, #changes .. (#changes == 1 and " file" or " files"), {
    label = #changes .. (#changes == 1 and " file" or " files"),
    additions = "+" .. additions, removals = "-" .. removals, tone = "muted",
  })
  local cap = expanded and #changes or math.min(#changes, limit or #changes)
  for index = 1, cap do
    local change = changes[index]
    add(rows, change.path, {
      icon = "file-content", label = change.path,
      additions = "+" .. (change.add or 0), removals = "-" .. (change.del or 0),
      action = "file:" .. index,
    })
  end
  if #changes > cap then add(rows, "… " .. (#changes - cap) .. " more", { tone = "muted", action = "expand" })
  elseif expanded and #changes > (limit or #changes) then add(rows, "show less", { tone = "muted", action = "expand" }) end
end

local function session(model, spec)
  model.tabs = spec.tabs or {}
  model.activeTab = spec.active_tab
  if #model.tabs == 0 then return end
  local rows = card(model, spec.active_tab and spec.active_tab:upper() or "SESSION")
  if spec.active_tab == "plan" then plan_rows(rows, spec.plan)
  elseif spec.active_tab == "tests" then test_rows(rows, spec.tests or {})
  else change_rows(rows, spec.changes or {}, spec.expanded, spec.change_limit) end
end

function M.build(spec)
  local model = {
    active = true,
    scope = spec.scope,
    kind = spec.kind,
    identity = spec.identity,
    masthead = spec.scope == "lovable" and "lovable" or "cockpit",
    cwd = spec.cwd,
    cards = {},
    actions = spec.actions or {},
    tabs = {},
  }
  if spec.kind == "home" then
    if spec.scope == "personal" then personal_home(model, spec) else lovable_home(model, spec) end
  else
    session(model, spec)
  end
  return model
end

function M.text(model, width)
  width = math.max(32, width or 80)
  local lines, actions = {}, {}
  local function push(text, action_id)
    text = tostring(text or "")
    if #text > width then text = text:sub(1, width - 1) .. "…" end
    lines[#lines + 1] = text
    if action_id then actions[#lines - 1] = action_id end
  end
  push((model.identity or "COCKPIT") .. (model.activeTab and (" · " .. model.activeTab:upper()) or ""))
  push("")
  for _, section in ipairs(model.cards or {}) do
    push(section.title or "")
    for _, item in ipairs(section.rows or {}) do
      local text = item.label or item.text or ""
      if item.detail then text = text .. " · " .. item.detail end
      if item.additions then text = text .. "  " .. item.additions .. " " .. (item.removals or "") end
      push("  " .. text, item.action)
    end
    push("")
  end
  local hints = {}
  for _, item in ipairs(model.actions or {}) do hints[#hints + 1] = item.key .. " " .. item.label end
  push(table.concat(hints, "   "))
  return lines, actions
end

return M
