import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import "."
import "../QsLib" as Lib

// Command palette (Super+F) — THE palette UI; the old in-browser popup
// (chromium-palette App.tsx) is retired, the extension is bridge-only.
// Data + actions come from PaletteState (palette-daemon over the UI
// socket). Visuals: centered responsive panel, strong fg-tinted outer border,
// full-width hairline section separators, borderless 17px input,
// sans-serif type.
PanelWindow {
    id: root

    screen: {
        const _ = NiriState.version
        const output = NiriState.focusedOutput()
        const screens = Quickshell.screens
        for (let i = 0; i < screens.length; i++)
            if (screens[i].name === output) return screens[i]
        return screens.length ? screens[0] : null
    }

    property bool active: false
    property real slideProgress: 0
    visible: active
    readonly property bool open: PaletteState.open

    NumberAnimation {
        id: openSlide
        target: root
        property: "slideProgress"
        from: 0
        to: 1
        duration: 280
        easing.type: Easing.BezierSpline
        easing.bezierCurve: [0.16, 1, 0.3, 1, 1, 1]
    }
    NumberAnimation {
        id: closeSlide
        target: root
        property: "slideProgress"
        to: 0
        duration: 220
        easing.type: Easing.InCubic
    }

    onOpenChanged: {
        if (open) {
            closeDelay.stop()
            closeSlide.stop()
            reassert.stop()
            active = true
            slideProgress = 0
            openSlide.restart()
            resetTransient()
            PaletteState.refresh()
            search.forceActiveFocus()
            Qt.callLater(() => {
                search.forceActiveFocus()
                list.positionViewAtBeginning()
                Qt.callLater(() => list.positionViewAtBeginning())
            })
        } else {
            openSlide.stop()
            closeSlide.from = slideProgress
            closeSlide.restart()
            closeDelay.restart()
            if (restoreTabOnClose) {
                const original = sessionTabs.find(t => t.id === sessionCurrentTabId)
                if (original && previewTabId !== original.id)
                    PaletteState.activateTab(original.id, original.windowId)
                ignoreRecencyUntil = Date.now() + 500
                reconcileTabOrder(PaletteState.tabs || [], sessionCurrentTabId)
            } else if (committedTabId != null) {
                ignoreRecencyUntil = Date.now() + 500
                reconcileTabOrder(PaletteState.tabs || [], committedTabId)
            } else {
                ignoreRecencyUntil = 0
            }
            // Window switches made while cycling the chin happen UNDER this
            // layer; when the layer drops, niri returns keyboard focus to the
            // pre-palette window, silently undoing them. Re-assert the user's
            // pick once the layer is gone so the final activation wins.
            if (scopedWindowId != null && scopedWindowProfile) reassert.restart()
        }
    }
    Timer { id: closeDelay; interval: 240; onTriggered: root.active = false }
    Timer { id: closeScrollTimeout; interval: 1000; onTriggered: root.preservingCloseScroll = false }
    Timer {
        id: reassert
        interval: 420   // past closeDelay + unmap, before it reads as a second hop
        onTriggered: {
            if (root.scopedWindowId != null && root.scopedWindowProfile)
                PaletteState.activateWindow(root.scopedWindowProfile, root.scopedWindowId)
        }
    }

    function resetTransient() {
        search.text = ""
        searchMode = null
        filterTab = 0
        filterNavFocused = false
        filmFocused = true
        scopedWindowId = null
        scopedWindowProfile = null
        previewTabId = PaletteState.currentTabId
        restoreTabOnClose = true
        committedTabId = null
        captureTabOrder()
        selectedIndex = firstSelectable()
        list.positionViewAtBeginning()
        Qt.callLater(() => { syncFilmIndex(); filmPos = filmIndex })
    }

    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-picker"
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // The old palette rendered in the system sans stack, not the
    // desktop's mono — part of what made it feel cleaner. Keep that.
    readonly property string sans: Theme.fontFamily
    // Outer border: --app-container-border-color (fg @ .5 light / .1 dark).
    readonly property color panelBorder:
        Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, Theme.mode === "light" ? 0.15 : 0.10)

    // ── ranking / grouping ────────────────────────────────────────────
    readonly property var filterTabs: ["All", "Tabs", "Pinned items", "Quickmarks", "History", "Web", "?"]
    property int filterTab: 0
    property string query: search ? search.text : ""
    property var scopedWindowId: null
    property var scopedWindowProfile: null
    property int selectedIndex: 0
    property bool preservingCloseScroll: false
    property real closeScrollY: 0
    property var tabOrder: []
    property var previewTabId: null
    property bool restoreTabOnClose: true
    property var committedTabId: null
    property double ignoreRecencyUntil: 0
    property var pinnedItems: []
    property var sessionTabs: []
    property string sessionTabsKey: ""
    property var sessionCurrentTabId: null
    property var sessionQuickmarks: []
    property string sessionQuickmarksKey: ""
    property int filmIndex: 0
    property real filmPos: 0
    property bool filmFocused: true
    property bool filterNavFocused: false

    readonly property var dockQuickmarks: open ? sessionQuickmarks : (PaletteState.quickmarks || [])
    readonly property bool showQuickmarkDock: !searchMode
        && (filterTab === 0 || filterTabs[filterTab] === "Tabs")
    readonly property var filmTabs: {
        const tabs = (open ? sessionTabs : (PaletteState.tabs || [])).slice()
        tabs.sort((a, b) => {
            const ai = tabOrder.indexOf(a.id)
            const bi = tabOrder.indexOf(b.id)
            if (ai >= 0 && bi >= 0) return ai - bi
            if (ai >= 0) return -1
            if (bi >= 0) return 1
            return (b.lastAccessed || 0) - (a.lastAccessed || 0)
        })
        return scopedWindowId == null ? tabs : tabs.filter(t => t.windowId === scopedWindowId)
    }
    readonly property bool showFilmstrip: !searchMode
        && (filterTab === 0 || filterTabs[filterTab] === "Tabs") && filmTabs.length > 0

    onFilmTabsChanged: Qt.callLater(syncFilmIndex)

    FrameAnimation {
        running: root.active && Math.abs(root.filmPos - root.filmIndex) > 0.001
        onTriggered: {
            const k = 1 - Math.exp(-frameTime / 0.07)
            const next = root.filmPos + (root.filmIndex - root.filmPos) * k
            root.filmPos = Math.abs(next - root.filmIndex) < 0.001 ? root.filmIndex : next
        }
    }

    function filmEntry(index) {
        const tab = filmTabs[index]
        if (!tab) return null
        return {
            kind: "tab", title: tab.title || "Untitled", url: tab.url || "",
            subtitle: niceUrl(tab.url || ""), faviconPath: tab.faviconPath || "",
            previewPath: tab.previewPath || "", tabId: tab.id, windowId: tab.windowId,
        }
    }

    function syncFilmIndex() {
        if (filmTabs.length === 0) { filmIndex = 0; filmPos = 0; return }
        const wanted = previewTabId == null ? sessionCurrentTabId : previewTabId
        const index = filmTabs.findIndex(tab => tab.id === wanted)
        filmIndex = index >= 0 ? index : Math.min(filmIndex, filmTabs.length - 1)
        if (!open || Math.abs(filmPos - filmIndex) > filmTabs.length) filmPos = filmIndex
    }

    function moveFilm(delta) {
        if (filmTabs.length === 0) return
        filmFocused = true
        filmIndex = Math.max(0, Math.min(filmTabs.length - 1, filmIndex + delta))
        previewTab(filmEntry(filmIndex))
    }

    function focusFilmMatch() {
        if (!showFilmstrip) return
        const q = query.trim().toLowerCase()
        if (!q) { filmFocused = true; return }
        let bestTabIndex = -1
        let bestTabScore = 0
        for (let i = 0; i < filmTabs.length; i++) {
            const tab = filmTabs[i]
            const value = String(tab.title || "") + " " + String(tab.url || "")
            const score = scoreMatch(q, value.toLowerCase())
            if (score > bestTabScore) { bestTabScore = score; bestTabIndex = i }
        }
        let bestResultIndex = -1
        let bestResultScore = 0
        for (let i = 0; i < entries.length; i++) {
            const entry = entries[i]
            if (!entry || entry.divider) continue
            const value = String(entry.title || "") + " "
                + String(entry.subtitle || "") + " " + String(entry.url || "")
            const score = scoreMatch(q, value.toLowerCase())
            if (score > bestResultScore) {
                bestResultScore = score
                bestResultIndex = i
            }
        }
        if (bestResultIndex >= 0) selectedIndex = bestResultIndex
        filmFocused = bestTabIndex >= 0 && bestTabScore > bestResultScore
        if (!filmFocused) return
        filmIndex = bestTabIndex
        const entry = filmEntry(bestTabIndex)
        if (entry && entry.tabId !== previewTabId) previewTab(entry)
    }

    function tabContentKey(tabs) {
        return JSON.stringify(tabs.map(t => [
            t.id, t.windowId, t.title, t.url, t.faviconPath
        ]))
    }

    function reconcileTabOrder(tabs, curId) {
        const liveIds = ({})
        for (const tab of tabs) liveIds[tab.id] = true
        if (tabOrder.length === 0) {
            const sorted = tabs.slice()
                .sort((a, b) => (b.lastAccessed || 0) - (a.lastAccessed || 0))
            tabOrder = sorted.filter(t => t.id === curId)
                .concat(sorted.filter(t => t.id !== curId))
                .map(t => t.id)
            return
        }
        const previous = tabOrder.filter(id => liveIds[id] && id !== curId)
        const knownIds = ({})
        for (const id of previous) knownIds[id] = true
        const newcomers = tabs.filter(t => t.id !== curId && !knownIds[t.id])
            .sort((a, b) => (b.lastAccessed || 0) - (a.lastAccessed || 0))
            .map(t => t.id)
        const current = liveIds[curId] ? [curId] : []
        tabOrder = current.concat(newcomers, previous)
    }

    function captureTabOrder() {
        const tabs = (PaletteState.tabs || []).slice()
        sessionTabs = tabs
        sessionTabsKey = tabContentKey(tabs)
        sessionCurrentTabId = PaletteState.currentTabId
        sessionQuickmarks = (PaletteState.quickmarks || []).slice()
        sessionQuickmarksKey = JSON.stringify(sessionQuickmarks)
        reconcileTabOrder(tabs, PaletteState.currentTabId)
    }

    function previewTab(entry) {
        if (!open || !entry || entry.divider || entry.kind !== "tab") return
        if (entry.tabId === previewTabId) return
        previewTabId = entry.tabId
        PaletteState.activateTab(entry.tabId, entry.windowId)
    }

    function togglePinned(entry) {
        if (!entry || entry.divider || !entry.url) return
        const index = pinnedItems.findIndex(item => item.url === entry.url)
        if (index >= 0) {
            pinnedItems = pinnedItems.filter((_, i) => i !== index)
            markToast.show("unpinned")
            return
        }
        pinnedItems = pinnedItems.concat([{
            kind: "pinned",
            title: entry.title || entry.url,
            url: entry.url,
            subtitle: entry.subtitle || niceUrl(entry.url),
            faviconPath: entry.faviconPath || "",
        }])
        markToast.show("pinned")
    }

    // History feeds the History tab always, and the All tab under a query
    // (empty-query All stays calm — recents live in the History tab).
    function historyWanted() {
        const ft = filterTabs[filterTab]
        return ft === "History" || (ft === "All" && query.trim().length > 0)
    }
    onQueryChanged: {
        selectedIndex = firstSelectable(); list.positionViewAtBeginning()
        Qt.callLater(focusFilmMatch)
        if (historyWanted()) histDebounce.restart()
    }
    onFilterTabChanged: {
        selectedIndex = firstSelectable()
        // entering a tab fetches immediately; typing goes through the debounce
        if (historyWanted()) PaletteState.searchHistory(query.trim())
    }
    Timer { id: histDebounce; interval: 150; onTriggered: PaletteState.searchHistory(root.query.trim()) }

    function relTime(ms) {
        if (!ms) return ""
        const s = (Date.now() - ms) / 1000
        if (s < 60) return "just now"
        if (s < 3600) return Math.floor(s / 60) + "m ago"
        if (s < 86400) return Math.floor(s / 3600) + "h ago"
        return Math.floor(s / 86400) + "d ago"
    }

    function niceUrl(u) {
        if (!u) return ""
        return u.length <= 80 ? u : u.slice(0, 40) + "..." + u.slice(-37)
    }

    function isRootUrlForQuery(url, rawQuery) {
        const queryMatch = String(rawQuery || "").trim().match(
            /^(?:https?:\/\/)?(?:www\.)?([^/?#]+\.[^/?#]+)\/?$/i)
        const urlMatch = String(url || "").match(
            /^https?:\/\/(?:www\.)?([^/?#]+)(\/[^?#]*)?(?:[?#].*)?$/i)
        if (!queryMatch || !urlMatch) return false
        const path = urlMatch[2] || "/"
        return queryMatch[1].toLowerCase() === urlMatch[1].toLowerCase()
            && path === "/"
    }

    // Token-prefix 10000 > substring ~1000 (boundary/position bonus) >
    // fuzzy subsequence 1 (last-resort tiebreak).
    // The fuzzy tier only counts when the matched letters sit in a tight
    // window (span ≤ 2× query) — "twtr" finds twitter, but a query
    // scattered letter-by-letter across a long title is noise, not a match.
    function scoreMatch(qLower, matchText) {
        if (!qLower) return 1
        const v = matchText
        const tokens = v.split(/\W+/).filter(t => t.length > 0)
        for (let i = 0; i < tokens.length; i++)
            if (tokens[i].startsWith(qLower)) return 10000
        const idx = v.indexOf(qLower)
        if (idx >= 0) {
            const atBoundary = idx === 0 || /[\s/\-_.]/.test(v[idx - 1])
            return 1000 - Math.min(idx, 500) + (atBoundary ? 200 : 0)
        }
        let best = -1
        for (let start = 0; start < v.length; start++) {
            if (v[start] !== qLower[0]) continue
            let qi = 1, vi = start + 1
            while (vi < v.length && qi < qLower.length) {
                if (v[vi] === qLower[qi]) qi++
                vi++
            }
            if (qi < qLower.length) break // can't complete from here → nor from any later start
            const span = vi - start
            if (best < 0 || span < best) best = span
        }
        return (best > 0 && best <= qLower.length * 2) ? 1 : 0
    }

    function looksLikeUrl(t) {
        if (!t || /\s/.test(t)) return false
        if (/^[a-z][\w-]*:(\/\/)?/i.test(t)) return true
        if (/^[\w-]+(\.[\w-]+)+([:/?#].*)?$/i.test(t)) return true
        if (/^localhost([:/?#].*)?$/i.test(t)) return true
        return false
    }

    function matchText(e) {
        let s = (e.title || "")
        if (e.url) {
            const m = e.url.match(/^[a-z][\w+.-]*:\/\/([^/]+)(\/[^?#]*)?/i)
            if (m) s += " " + m[1] + (m[2] || "")
        }
        return s.toLowerCase()
    }

    // Fixed order — DuckDuckGo is THE default search; the group is never
    // rank-shuffled (every template contains the query, so scoring them
    // is position noise).
    // key + Tab enters that engine's search mode (chip before the input;
    // Enter searches in a NEW tab; Backspace on empty input exits).
    readonly property var webTemplates: [
        { key: "d", name: "DuckDuckGo", origin: "https://duckduckgo.com",   mk: q => "https://duckduckgo.com/?q=" + encodeURIComponent(q) },
        { key: "m", name: "Google Maps", origin: "https://maps.google.com", mk: q => "https://www.google.com/maps/search/" + encodeURIComponent(q) },
        { key: "y", name: "Youtube", origin: "https://www.youtube.com",     mk: q => "https://www.youtube.com/results?search_query=" + encodeURIComponent(q) },
    ]
    property var searchMode: null

    // Flattened [divider, entry, entry, divider, ...] list, rebuilt on
    // every state push / keystroke. Groups: Open URL → Tabs → Quickmarks →
    // Web Search, ranked + reordered by best score under a query,
    // cross-group URL dedupe, chin scope filter.
    readonly property var entries: {
        if (searchMode) {
            const qq = query.trim()
            return [
                { divider: true, label: searchMode.name },
                { kind: "web", forceNewTab: true,
                  title: qq.length ? ("Search " + searchMode.name + ": " + qq) : ("Search " + searchMode.name + "…"),
                  url: searchMode.mk(qq), subtitle: "", faviconPath: "" },
            ]
        }
        const q = query.trim().toLowerCase()
        const ftab = filterTabs[filterTab]
        const scope = scopedWindowId

        if (ftab === "?") {
            // keys as the title, action as the muted subtitle — no prose
            const help = [
                ["\u23ce   \u2303\u23ce", "open \u00b7 open in new tab"],
                ["\u2303h   \u2303l", "move open-tab focus"],
                ["tab, then h/l", "focus / move filters"],
                ["\u2303\u21e7h   \u2303\u21e7l", "window scope"],
                ["\u2303w", "close tab"],
                ["\u2303m", "quickmark tab"],
                ["\u2303p", "pin / unpin item"],
                ["tab", "web-search mode"],
                ["\u2303/", "toggle this sheet"],
            ]
            const out = [{ divider: true, label: "Keybinds" }]
            for (const [keys, what] of help)
                out.push({ kind: "help", title: keys, subtitle: what,
                           url: "", faviconPath: "" })
            return out
        }

        if (ftab === "History") {
            // The tab is a timeline: recency order, always (Chrome's text
            // queries return relevance order — resort). The daemon query IS
            // the filter, no local re-rank.
            const _h = PaletteState.historyGen
            const items = (PaletteState.historyEntries || []).slice()
                .sort((a, b) => Number(isRootUrlForQuery(b.url, query))
                    - Number(isRootUrlForQuery(a.url, query))
                    || (b.lastVisitTime || 0) - (a.lastVisitTime || 0))
                .map(h => ({
                    kind: "history",
                    title: h.title || h.url || "Untitled",
                    url: h.url || "",
                    subtitle: (relTime(h.lastVisitTime) ? relTime(h.lastVisitTime) + "  ·  " : "")
                              + niceUrl(h.url || ""),
                    faviconPath: h.faviconPath || "",
                }))
            if (items.length === 0) return []
            const out = [{ divider: true, label: "History" }]
            for (const it of items) out.push(it)
            return out
        }

        const tabs = (open ? sessionTabs : (PaletteState.tabs || [])).slice()
        tabs.sort((a, b) => {
            const ai = tabOrder.indexOf(a.id)
            const bi = tabOrder.indexOf(b.id)
            if (ai >= 0 && bi >= 0) return ai - bi
            if (ai >= 0) return -1
            if (bi >= 0) return 1
            return (b.lastAccessed || 0) - (a.lastAccessed || 0)
        })
        const curId = open ? sessionCurrentTabId : PaletteState.currentTabId
        const scoped = scope == null ? tabs : tabs.filter(t => t.windowId === scope)

        const tabEntry = t => ({
            kind: "tab", title: t.title || "Untitled", url: t.url || "",
            subtitle: niceUrl(t.url || ""), faviconPath: t.faviconPath || "",
            tabId: t.id, windowId: t.windowId,
        })
        const cur = scoped.find(t => t.id === curId)
        const tabItems = scoped.map(tabEntry)

        const quickmarks = open ? sessionQuickmarks : (PaletteState.quickmarks || [])
        const qmItems = quickmarks.map(m => ({
            kind: "quickmark", title: m.name || "", url: m.url || "",
            subtitle: niceUrl(m.url || ""), faviconPath: m.faviconPath || "",
        }))

        const webItems = webTemplates.map(t => ({
            kind: "web",
            title: q ? ("Search " + t.name + ": " + query.trim()) : ("Search " + t.name),
            url: t.mk(query.trim()), subtitle: "", faviconPath: "",
        }))

        // Address-bar default: a URL-shaped query gets a "Go to" row that
        // wins unless a tab/quickmark hits; plain words fall through to the
        // Web Search group (DDG on Enter) — same split as a browser bar.
        const qt = query.trim()
        const gotoUrl = /^[a-z][\w-]*:/i.test(qt) ? qt : "https://" + qt
        const urlItems = looksLikeUrl(qt)
            ? [{ kind: "url", title: "Go to " + gotoUrl, url: gotoUrl,
                 subtitle: "", faviconPath: "" }]
            : []

        const rank = items => {
            if (!q) return { items: items, maxScore: 0 }
            const scored = items
                .map(e => ({ e: e, s: scoreMatch(q, matchText(e)) }))
                .filter(x => x.s > 0)
            scored.sort((a, b) => b.s - a.s)
            return { items: scored.map(x => x.e), maxScore: scored.length ? scored[0].s : 0 }
        }

        const rt = rank(tabItems)
        const rq = rank(qmItems)
        const rp = rank(pinnedItems)
        // Address-bar Enter semantics: a URL-looking query navigates by
        // default — unless a tab/quickmark actually hits (substring or
        // better), in which case the hit stays on top. Weak fuzzy noise
        // (score 1) doesn't count as a hit.
        const hasHit = Math.max(rt.maxScore, rq.maxScore) >= 1000

        // History in All: only under a query (recents live in the History
        // tab). Chrome did the matching; the local score filter just drops
        // stale entries from the previous keystroke instantly. Order:
        // visit count, then recency. Capped so it can't drown the list.
        let histItems = []
        if (q) {
            const _h = PaletteState.historyGen
            histItems = (PaletteState.historyEntries || [])
                .filter(h => scoreMatch(q, matchText({ title: h.title || "", url: h.url || "" })) > 0)
                .sort((a, b) => Number(isRootUrlForQuery(b.url, query))
                             - Number(isRootUrlForQuery(a.url, query))
                             || (b.visitCount || 0) - (a.visitCount || 0)
                             || (b.lastVisitTime || 0) - (a.lastVisitTime || 0))
                .slice(0, 8)
                .map(h => ({
                    kind: "history",
                    title: h.title || h.url || "Untitled",
                    url: h.url || "",
                    subtitle: (relTime(h.lastVisitTime) ? relTime(h.lastVisitTime) + "  ·  " : "")
                              + niceUrl(h.url || ""),
                    faviconPath: h.faviconPath || "",
                }))
        }

        // Fixed hierarchy — groups never rank-shuffle past each other:
        // Open URL (unless a tab/quickmark hit beats it) → Tabs →
        // Quickmarks → History → Web Search → Actions.
        // Array order doubles as cross-group dedupe priority.
        let groups = []
        if (urlItems.length && !hasHit) groups.push({ id: "url", heading: "Open URL", items: urlItems })
        if (ftab === "Pinned items")
            groups.push({ id: "pinned", heading: "Pinned items", items: rp.items })
        else if (!showFilmstrip)
            groups.push({ id: "tabs", heading: "Tabs", items: rt.items })
        if (q.length > 0 || !showQuickmarkDock)
            groups.push({ id: "quickmarks", heading: "Quickmarks", items: rq.items })
        if (urlItems.length && hasHit) groups.push({ id: "url", heading: "Open URL", items: urlItems })
        if (q.length > 0 || ftab === "History")
            groups.push({ id: "history", heading: "History", items: histItems })
        if (ftab === "Web")
            groups.push({ id: "websites", heading: "Web Search", items: webItems })
        // Actions on the current tab. Rankable like everything else
        // ("add"/"quickmark"/"mark", "save"/"sync"/"synced"). Quickmark hides
        // once the tab's already marked; save-to-Synced always offered.
        if (cur && q.length > 0) {
            const actionItems = []
            if (!quickmarks.some(m => m.url === cur.url)) {
                actionItems.push({
                    kind: "addqm", qmName: cur.title || cur.url, qmUrl: cur.url || "",
                    title: "Add current tab to quickmarks",
                    subtitle: niceUrl(cur.url || ""), faviconPath: cur.faviconPath || "",
                })
            }
            actionItems.push({
                kind: "savesync",
                title: "Save current tab to Synced",
                subtitle: niceUrl(cur.url || ""), faviconPath: cur.faviconPath || "",
            })
            const ra = rank(actionItems)
            groups.push({ id: "actions", heading: "Actions", items: q ? ra.items : actionItems })
        }

        // Cross-group URL dedupe in hierarchy order — a URL that's already
        // an open tab renders as its tab row, not a history/quickmark echo.
        const seen = ({})
        for (let gi = 0; gi < groups.length; gi++) {
            groups[gi].items = groups[gi].items.filter(e => {
                if (!e.url) return true
                if (e.kind === "tab") {
                    seen[e.url] = true
                    return true
                }
                if (seen[e.url]) return false
                seen[e.url] = true
                return true
            })
        }

        let nonEmpty = groups.filter(g => g.items.length > 0)

        if (ftab === "Tabs") nonEmpty = nonEmpty.filter(g => g.id === "tabs")
        else if (ftab === "Pinned items") nonEmpty = nonEmpty.filter(g => g.id === "pinned")
        else if (ftab === "Quickmarks") nonEmpty = nonEmpty.filter(g => g.id === "quickmarks")
        else if (ftab === "History") nonEmpty = nonEmpty.filter(g => g.id === "history")
        else if (ftab === "Web") nonEmpty = nonEmpty.filter(g => g.id === "websites")

        const out = []
        for (let gi = 0; gi < nonEmpty.length; gi++) {
            out.push({ divider: true, label: nonEmpty[gi].heading })
            for (let ii = 0; ii < nonEmpty[gi].items.length; ii++)
                out.push(nonEmpty[gi].items[ii])
        }
        return out
    }

    onEntriesChanged: {
        if (selectedIndex >= entries.length) selectedIndex = firstSelectable()
        Qt.callLater(focusFilmMatch)
        if (preservingCloseScroll) {
            Qt.callLater(() => Qt.callLater(() => {
                const minY = list.originY
                const maxY = Math.max(minY, list.originY + list.contentHeight - list.height)
                list.contentY = Math.max(minY, Math.min(maxY, closeScrollY))
                preservingCloseScroll = false
                closeScrollTimeout.stop()
            }))
        } else if (entries.length > 0) {
            ensureSelectedVisible(selectedIndex)
        }
    }

    function adjustSelectedMargin(index) {
        const item = list.itemAtIndex(index)
        if (!item) return false
        const margin = list.navigationMargin
        const viewTop = list.contentY
        const viewBottom = viewTop + list.height
        let target = viewTop
        if (item.y < viewTop + margin)
            target = item.y - margin
        else if (item.y + item.height > viewBottom - margin)
            target = item.y + item.height + margin - list.height
        const minY = list.originY
        const maxY = Math.max(minY, list.originY + list.contentHeight - list.height)
        list.contentY = Math.max(minY, Math.min(maxY, target))
        return true
    }

    function ensureSelectedVisible(index) {
        if (adjustSelectedMargin(index)) return
        list.positionViewAtIndex(index, ListView.Contain)
        Qt.callLater(() => adjustSelectedMargin(index))
    }

    function firstSelectable() {
        for (let i = 0; i < entries.length; i++)
            if (!entries[i] || !entries[i].divider) return i
        return 0
    }

    function step(dir) {
        const n = entries.length
        if (n === 0) return
        if (filmFocused) {
            filmFocused = false
            ensureSelectedVisible(selectedIndex)
            return
        }
        let i = selectedIndex + dir
        while (i >= 0 && i < n && entries[i] && entries[i].divider) i += dir
        if (i >= 0 && i < n) {
            selectedIndex = i
            previewTab(entries[i])
            ensureSelectedVisible(i)
        } else if (dir < 0 && showFilmstrip) {
            filmFocused = true
        }
    }

    // Enter = run: tab rows always activate the existing tab; URL rows
    // navigate the current tab (Ctrl+Enter = new tab). Shift+Enter = DDG
    // the raw query.
    function runEntry(e, inNewTab) {
        if (!e || e.divider || e.kind === "help") return
        if (e.kind === "addqm") {
            if (e.qmUrl) PaletteState.quickmarkAdd(e.qmName, e.qmUrl)
        } else if (e.kind === "savesync") {
            PaletteState.saveSynced()
            markToast.show("saving…")
            return // keep the palette open so the result toast is visible
        } else if (e.kind === "tab") {
            restoreTabOnClose = false
            committedTabId = e.tabId
            if (e.tabId !== previewTabId) PaletteState.activateTab(e.tabId, e.windowId)
        } else if (e.url) {
            restoreTabOnClose = false
            PaletteState.gotoUrl(e.url, inNewTab || !!e.forceNewTab)
        }
        PaletteState.hide()
    }

    function runSelected(inNewTab) {
        if (showFilmstrip && (filmFocused || entries.length === 0)) {
            runEntry(filmEntry(filmIndex), inNewTab)
            return
        }
        if (entries.length === 0) return
        const idx = Math.max(0, Math.min(selectedIndex, entries.length - 1))
        runEntry(entries[idx], inNewTab)
    }

    function actionEntry() {
        if (showFilmstrip && (filmFocused || entries.length === 0)) return filmEntry(filmIndex)
        const idx = Math.max(0, Math.min(selectedIndex, entries.length - 1))
        return entries[idx]
    }

    // Drop a stale chin scope when the daemon reports a different
    // focused window (external focus changes).
    Connections {
        target: PaletteState
        function onGenChanged() {
            const tabs = PaletteState.tabs || []
            if (root.open) {
                const tabsKey = root.tabContentKey(tabs)
                if (tabsKey !== root.sessionTabsKey) {
                    root.sessionTabs = tabs.slice()
                    root.sessionTabsKey = tabsKey
                }
                const quickmarks = PaletteState.quickmarks || []
                const quickmarksKey = JSON.stringify(quickmarks)
                if (quickmarksKey !== root.sessionQuickmarksKey) {
                    root.sessionQuickmarks = quickmarks.slice()
                    root.sessionQuickmarksKey = quickmarksKey
                }
                if (root.tabOrder.length === 0 && tabs.length > 0) root.captureTabOrder()
            } else if (Date.now() >= root.ignoreRecencyUntil) {
                root.reconcileTabOrder(tabs, PaletteState.currentTabId)
            }
            const sid = root.scopedWindowId
            if (sid == null) return
            const focused = (PaletteState.chin || []).find(w => w.focused)
            if (focused && focused.id !== sid) root.scopedWindowId = null
        }
        function onSaveResult(result) {
            markToast.show(result === "ok" ? "saved to Synced ✓"
                : result === "dupe" ? "already in Synced"
                : "save failed")
        }
    }

    function selectChinWindow(w) {
        scopedWindowId = w.id
        scopedWindowProfile = w.profile
        PaletteState.activateWindow(w.profile, w.id)
    }

    function cycleChin(dir) {
        const wins = PaletteState.chin || []
        if (wins.length === 0) return
        const sid = scopedWindowId
        let idx = wins.findIndex(w => w.id === sid)
        if (idx < 0) idx = wins.findIndex(w => w.focused)
        const next = ((idx < 0 ? 0 : idx) + dir + wins.length) % wins.length
        selectChinWindow(wins[next])
    }

    function handleKeys(event) {
        const ctrl = event.modifiers & Qt.ControlModifier
        const shift = event.modifiers & Qt.ShiftModifier
        if (event.key === Qt.Key_Escape) {
            if (root.filterNavFocused) root.filterNavFocused = false
            else PaletteState.hide()
            event.accepted = true
        } else if (event.key === Qt.Key_Tab && !root.searchMode) {
            const kw = root.query.trim().toLowerCase()
            const t = root.webTemplates.find(t => t.key === kw)
            if (t && kw.length > 0) { root.searchMode = t; search.text = "" }
            else if (kw.length === 0) root.filterNavFocused = !root.filterNavFocused
            event.accepted = true
        } else if (root.filterNavFocused && !ctrl
                   && (event.key === Qt.Key_H || event.key === Qt.Key_Left
                       || event.key === Qt.Key_L || event.key === Qt.Key_Right)) {
            const dir = (event.key === Qt.Key_L || event.key === Qt.Key_Right) ? 1 : -1
            const n = root.filterTabs.length - 1
            root.filterTab = (root.filterTab + dir + n) % n
            event.accepted = true
        } else if (root.filterNavFocused
                   && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
            root.filterNavFocused = false
            event.accepted = true
        } else if (event.key === Qt.Key_Backspace && root.searchMode && search.text.length === 0) {
            root.searchMode = null
            event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (shift) {
                const q = root.query.trim()
                if (q.length > 0) {
                    root.restoreTabOnClose = false
                    PaletteState.gotoUrl("https://duckduckgo.com/?q=" + encodeURIComponent(q), false)
                    PaletteState.hide()
                }
            } else {
                root.runSelected(!!ctrl)
            }
            event.accepted = true
        } else if (root.showFilmstrip && ctrl && !shift && event.key === Qt.Key_H) {
            root.moveFilm(-1); event.accepted = true
        } else if (root.showFilmstrip && ctrl && !shift && event.key === Qt.Key_L) {
            root.moveFilm(1); event.accepted = true
        } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_J && ctrl)) {
            root.step(1); event.accepted = true
        } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_K && ctrl)) {
            root.step(-1); event.accepted = true
        } else if ((event.key === Qt.Key_H || event.key === Qt.Key_L) && ctrl && shift) {
            root.cycleChin(event.key === Qt.Key_L ? 1 : -1); event.accepted = true
        } else if ((event.key === Qt.Key_H || event.key === Qt.Key_L) && ctrl) {
            const dir = event.key === Qt.Key_L ? 1 : -1
            const n = root.filterTabs.length - 1   // "?" lives behind the badge, not in the cycle
            root.filterTab = (root.filterTab + dir + n) % n
            event.accepted = true
        } else if ((event.key === Qt.Key_D || event.key === Qt.Key_W) && ctrl) {
            // ⌃w matches browser muscle memory; ⌃d kept as the original bind
            const e = root.actionEntry()
            if (e && !e.divider && e.kind === "tab") {
                root.closeScrollY = list.contentY
                root.preservingCloseScroll = true
                closeScrollTimeout.restart()
                PaletteState.closeTab(e.tabId)
            }
            event.accepted = true
        } else if (event.key === Qt.Key_Slash && ctrl) {
            const helpIdx = root.filterTabs.length - 1
            root.filterTab = root.filterTab === helpIdx ? 0 : helpIdx
            event.accepted = true
        } else if (event.key === Qt.Key_P && ctrl) {
            root.togglePinned(root.actionEntry())
            event.accepted = true
        } else if (event.key === Qt.Key_M && ctrl) {
            const e = root.actionEntry()
            if (e && !e.divider && e.kind === "tab" && e.url) {
                const already = (PaletteState.quickmarks || []).some(q => q.url === e.url)
                if (already) {
                    markToast.show("already quickmarked")
                } else {
                    // name from the title, trimmed to something quickmark-shaped
                    const name = (e.title || e.url).trim().slice(0, 48)
                    PaletteState.quickmarkAdd(name, e.url)
                    markToast.show("quickmarked: " + name)
                }
            }
            event.accepted = true
        }
    }

    // transient confirmation for silent actions (quickmark, …)
    Lib.FeedbackPill {
        id: markToast
        z: 300
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 90
    }

    // ── visuals ───────────────────────────────────────────────────────
    Rectangle {
        id: dim
        anchors.fill: parent
        color: "#000000"
        opacity: root.open ? 0.30 : 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        MouseArea { anchors.fill: parent; onClicked: PaletteState.hide() }
    }

    Rectangle {
        id: panel
        readonly property real targetWidth: Math.min(1120, parent.width - 96)
        readonly property real resultHeight: {
            if (root.entries.length === 0) return 0
            let total = 48
            for (let i = 0; i < root.entries.length; i++) {
                const entry = root.entries[i]
                total += entry && entry.divider ? 36
                    : String(entry && entry.subtitle || "").length > 0 ? 64 : 44
            }
            return Math.min(300, total)
        }
        readonly property real fixedHeight: 68
            + (root.showFilmstrip ? 178 : 0)
            + (root.showQuickmarkDock && root.dockQuickmarks.length > 0 ? 85 : 0)
            + (PaletteState.chin.length > 0 ? 54 : 0)
        readonly property real targetHeight: Math.min(620,
            Math.min(parent.height - 96, fixedHeight + resultHeight))
        readonly property real targetX: (parent.width - targetWidth) / 2
        readonly property real targetBottom: Math.min(parent.height - 48,
            parent.height * 0.70 + 310)
        readonly property real settledY: Math.max(48, targetBottom - height)
        readonly property real startY: parent.height + 24
        x: targetX
        y: startY + (settledY - startY) * root.slideProgress
        width: targetWidth
        height: targetHeight
        Behavior on height {
            enabled: root.open && root.slideProgress > 0.99
            NumberAnimation {
                duration: 200
                easing.type: Easing.BezierSpline
                easing.bezierCurve: [0.165, 0.84, 0.44, 1.0, 1.0, 1.0]
            }
        }

        color: Theme.bg
        // Radii measured off the reference palette: panel 24, field 15,
        // cards 13, tiles 10, keycaps 7.
        radius: 24
        border.color: root.panelBorder
        border.width: 1
        clip: true

        Column {
            anchors.fill: parent

            // ── input_wrap: icon + borderless input + ESC badge ──────
            Item {
                id: inputWrap
                width: parent.width
                height: 68

                Rectangle {
                    id: searchField
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    anchors.topMargin: 14
                    anchors.bottomMargin: 6
                    radius: 15
                    color: Theme.surface1
                    border.width: 1
                    border.color: Theme.hairline
                }

                Text {
                    id: searchIcon
                    anchors.left: searchField.left
                    anchors.leftMargin: 14
                    anchors.verticalCenter: searchField.verticalCenter
                    text: ""
                    color: Theme.fg_muted
                    opacity: 0.85
                    font.family: Theme.fontFamily
                    font.pixelSize: 16
                }

                Rectangle {
                    id: modeChip
                    visible: root.searchMode !== null
                    anchors.left: searchIcon.right
                    anchors.leftMargin: 12
                    anchors.verticalCenter: searchField.verticalCenter
                    width: visible ? chipText.implicitWidth + 16 : 0
                    height: chipText.implicitHeight + 8
                    radius: 6
                    color: Theme.selection
                    Text {
                        id: chipText
                        anchors.centerIn: parent
                        text: root.searchMode ? root.searchMode.name : ""
                        color: Theme.fg
                        font.family: root.sans
                        font.pixelSize: 12
                        font.weight: 600
                    }
                }

                TextInput {
                    id: search
                    focus: root.open
                    anchors.left: modeChip.visible ? modeChip.right : searchIcon.right
                    anchors.leftMargin: 12
                    anchors.right: escBadge.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: searchField.verticalCenter
                    color: Theme.fg
                    font.family: root.sans
                    font.pixelSize: 18
                    clip: true
                    Keys.onPressed: event => root.handleKeys(event)
                    onTextChanged: if (text.length > 0) root.filterNavFocused = false
                    Text {
                        visible: !search.text
                        text: PaletteState.daemonConnected ? "Type to search..." : "palette-daemon offline…"
                        color: Theme.fg_muted
                        font: search.font
                    }
                }

                Rectangle {
                    id: escBadge
                    anchors.right: searchField.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: searchField.verticalCenter
                    width: escText.implicitWidth + 16
                    height: 24
                    radius: 7
                    color: Theme.mode === "light" ? Theme.bg : Theme.surface2
                    border.color: Theme.hairline
                    border.width: 1
                    Text {
                        id: escText
                        anchors.centerIn: parent
                        text: "ESC"
                        color: Theme.fg_muted
                        font.family: root.sans
                        font.pixelSize: 11
                        font.weight: 500
                        font.letterSpacing: 0.5
                    }
                }
            }

            Item {
                id: filmWrap
                width: parent.width
                height: root.showFilmstrip ? 178 : 0
                visible: height > 0
                clip: true
                transform: Translate { y: list.height }

                property real wheelAccumulator: 0
                readonly property real cardStride: 256
                readonly property real contentWidth: root.filmTabs.length * cardStride - 16
                readonly property real baseX: contentWidth <= width - 32
                    ? (width - contentWidth) / 2 : 16
                readonly property real scrollX: contentWidth <= width - 32 ? 0 : Math.max(0,
                    (root.filmPos + 1) * cardStride - (width - 32))
                readonly property var slotLight: [1, 0.62, 0.44, 0.30, 0.20]

                function lerp(values, distance) {
                    if (distance >= values.length - 1) return values[values.length - 1]
                    const index = Math.floor(distance)
                    const amount = distance - index
                    return values[index] + (values[index + 1] - values[index]) * amount
                }

                Repeater {
                    model: root.filmTabs
                    delegate: Item {
                        id: filmCard
                        required property int index
                        required property var modelData
                        readonly property real offset: index - root.filmPos
                        readonly property real distance: Math.abs(offset)
                        readonly property bool focused: index === root.filmIndex
                        readonly property real light: filmWrap.lerp(filmWrap.slotLight, distance)
                        width: 240
                        height: 135
                        x: filmWrap.baseX + index * filmWrap.cardStride - filmWrap.scrollX
                        y: (filmWrap.height - height) / 2
                        z: 10 - distance
                        visible: x + width > -16 && x < filmWrap.width + 16
                        opacity: distance <= 4 ? 1 : Math.max(0, 5 - distance)

                        Rectangle {
                            anchors.fill: parent
                            radius: 16
                            color: Theme.surface1
                            border.width: 1
                            border.color: Theme.hairline
                            clip: true
                            layer.enabled: filmCard.focused
                            layer.effect: MultiEffect {
                                shadowEnabled: true
                                shadowColor: Qt.rgba(0, 0, 0, 0.45)
                                shadowBlur: 0.7
                                shadowVerticalOffset: 5
                            }

                            Image {
                                anchors.fill: parent
                                source: filmCard.modelData.previewPath
                                    ? "file://" + filmCard.modelData.previewPath : ""
                                sourceSize.width: 960
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: false
                            }

                            Rectangle {
                                anchors.fill: parent
                                visible: !filmCard.modelData.previewPath
                                color: Theme.surface2
                                Image {
                                    anchors.centerIn: parent
                                    width: 24
                                    height: width
                                    source: filmCard.modelData.faviconPath
                                        ? "file://" + filmCard.modelData.faviconPath : ""
                                    sourceSize.width: 72
                                    sourceSize.height: 72
                                }
                            }

                            Rectangle {
                                anchors.fill: parent
                                color: "#000000"
                                opacity: 1 - filmCard.light
                            }

                            Rectangle {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                height: 32
                                color: Qt.rgba(0, 0, 0, 0.68)
                                Text {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.leftMargin: 12
                                    anchors.rightMargin: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: String(filmCard.modelData.title || "Untitled")
                                    color: "#ffffff"
                                    elide: Text.ElideRight
                                    font.family: root.sans
                                    font.pixelSize: 12
                                    font.weight: 500
                                }
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: 16
                            color: Theme.fg
                            opacity: filmHover.hovered ? 0.08 : 0
                            Behavior on opacity {
                                NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: -3
                            radius: 16
                            color: "transparent"
                            border.width: 2
                            border.color: Theme.cursor
                            visible: filmCard.focused && root.filmFocused
                        }

                        HoverHandler { id: filmHover; cursorShape: Qt.PointingHandCursor }

                        TapHandler {
                            onTapped: {
                                root.filmFocused = true
                                if (filmCard.focused) root.runEntry(root.filmEntry(filmCard.index), false)
                                else {
                                    root.filmIndex = filmCard.index
                                    root.previewTab(root.filmEntry(filmCard.index))
                                }
                            }
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    onWheel: event => {
                        const x = event.angleDelta.x
                        const y = event.angleDelta.y
                        const delta = Math.abs(x) > Math.abs(y) ? x : y
                        filmWrap.wheelAccumulator += delta
                        const steps = Math.trunc(filmWrap.wheelAccumulator / 120)
                        if (steps !== 0) {
                            root.moveFilm(-steps)
                            filmWrap.wheelAccumulator -= steps * 120
                        }
                        event.accepted = true
                    }
                }

                Rectangle {
                    anchors.top: parent.top
                    width: parent.width
                    height: 1
                    color: Theme.hairline
                    visible: root.entries.length > 0
                }
            }

            // ── list ─────────────────────────────────────────────────
            ListView {
                id: list
                width: parent.width
                height: parent.height - inputWrap.height - filmWrap.height - chinWrap.height
                    - (root.showQuickmarkDock && root.dockQuickmarks.length > 0 ? 85 : 0)
                clip: true
                model: root.entries
                readonly property int navigationMargin: 24
                header: Item { width: 1; height: list.navigationMargin }
                footer: Item { width: 1; height: list.navigationMargin }
                boundsBehavior: Flickable.StopAtBounds
                transform: Translate { y: -filmWrap.height }

                Text {
                    visible: root.entries.length === 0 && !root.showFilmstrip
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: 24
                    text: "No results."
                    color: Theme.fg_muted
                    font.family: root.sans
                    font.pixelSize: 13
                }

                delegate: Item {
                    id: rowItem
                    required property var modelData
                    required property int index
                    property bool isDivider: !!(modelData && modelData.divider)
                    readonly property bool hasSubtitle: !isDivider && String(modelData.subtitle || "").length > 0
                    readonly property bool isPreviewedTab: !isDivider && modelData.kind === "tab"
                        && modelData.tabId === root.previewTabId
                    width: list.width
                    height: isDivider ? 36 : (hasSubtitle ? 64 : 44)

                    // Group heading: 11px uppercase, padding 12 18 6.
                    Text {
                        visible: rowItem.isDivider
                        anchors.left: parent.left
                        anchors.leftMargin: 28
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 10
                        text: rowItem.modelData ? String(rowItem.modelData.label || "") : ""
                        color: Theme.fg_muted
                        font.family: root.sans
                        font.pixelSize: 11
                        font.weight: 600
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 1.2
                    }
                    Text {
                        visible: rowItem.isDivider
                        anchors.right: parent.right
                        anchors.rightMargin: 28
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 10
                        text: {
                            let c = 0
                            for (let j = rowItem.index + 1; j < root.entries.length; j++) {
                                if (root.entries[j] && root.entries[j].divider) break
                                c++
                            }
                            return c
                        }
                        color: Theme.fg_muted
                        opacity: 0.7
                        font.family: root.sans
                        font.pixelSize: 11
                    }

                    // Entry: inset 6px, radius 8, padding 8 12.
                    Rectangle {
                        visible: !rowItem.isDivider
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14
                        radius: 13
                        color: rowItem.index === root.selectedIndex && !root.filmFocused
                            ? Theme.selection
                            : rowItem.isPreviewedTab ? Theme.surface2
                            : rowHover.hovered ? Theme.surface : "transparent"
                        border.width: 1
                        border.color: (rowItem.index === root.selectedIndex && !root.filmFocused)
                            || rowItem.isPreviewedTab ? Theme.hairline : "transparent"

                        Rectangle {
                            id: iconBox
                            anchors.left: parent.left
                            anchors.leftMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            width: rowItem.hasSubtitle ? 34 : 24
                            height: width
                            radius: rowItem.hasSubtitle ? 10 : 7
                            color: Theme.surface2
                            Image {
                                id: fav
                                anchors.centerIn: parent
                                width: rowItem.hasSubtitle ? 22 : 16
                                height: width
                                source: (!rowItem.isDivider && rowItem.modelData.faviconPath)
                                    ? "file://" + rowItem.modelData.faviconPath : ""
                                visible: status === Image.Ready
                                sourceSize.width: 44; sourceSize.height: 44
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: fav.status !== Image.Ready
                                text: {
                                    if (rowItem.isDivider) return ""
                                    const t = String(rowItem.modelData.title || "?")
                                    return t.length ? t[0].toUpperCase() : "?"
                                }
                                color: Theme.fg_muted
                                font.family: root.sans
                                font.pixelSize: rowItem.hasSubtitle ? 13 : 10
                                font.weight: 600
                            }
                        }

                        Column {
                            anchors.left: iconBox.right
                            anchors.leftMargin: 14
                            anchors.right: parent.right
                            anchors.rightMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            Text {
                                width: parent.width
                                text: rowItem.isDivider ? "" : String(rowItem.modelData.title || "")
                                color: Theme.fg
                                elide: Text.ElideRight
                                font.family: root.sans
                                font.pixelSize: 15
                                font.weight: 500
                            }
                            Text {
                                width: parent.width
                                visible: text.length > 0
                                text: rowItem.isDivider ? "" : String(rowItem.modelData.subtitle || "")
                                color: Theme.fg_muted
                                elide: Text.ElideRight
                                font.family: root.sans
                                font.pixelSize: 12
                            }
                        }

                        HoverHandler {
                            id: rowHover
                            onPointChanged: {
                                if (!hovered || rowItem.isDivider) return
                                root.filmFocused = false
                                root.selectedIndex = rowItem.index
                                root.previewTab(rowItem.modelData)
                            }
                        }
                        TapHandler {
                            onTapped: {
                                root.filmFocused = false
                                root.selectedIndex = rowItem.index
                                root.runSelected(false)
                            }
                        }
                    }
                }
            }

            Item {
                id: quickmarkDockWrap
                width: parent.width
                height: root.showQuickmarkDock && root.dockQuickmarks.length > 0 ? 85 : 0
                visible: height > 0

                Rectangle {
                    anchors.top: parent.top
                    anchors.topMargin: 7
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: dockRow.implicitWidth + 14
                    height: 50
                    radius: 16
                    color: Theme.surface1
                    border.width: 1
                    border.color: root.panelBorder

                    Row {
                        id: dockRow
                        anchors.centerIn: parent
                        spacing: 4

                        Repeater {
                            model: root.dockQuickmarks
                            Item {
                                id: dockSlot
                                required property var modelData
                                width: 36
                                height: 36

                                Rectangle {
                                    anchors.fill: parent
                                    radius: 9
                                    color: dockHover.hovered ? Theme.selection : "transparent"

                                    Image {
                                        id: dockIcon
                                        anchors.centerIn: parent
                                        width: 22
                                        height: 22
                                        source: dockSlot.modelData.faviconPath
                                            ? "file://" + dockSlot.modelData.faviconPath : ""
                                        sourceSize.width: 44
                                        sourceSize.height: 44
                                        visible: status === Image.Ready
                                    }

                                    Text {
                                        anchors.centerIn: parent
                                        visible: dockIcon.status !== Image.Ready
                                        text: String(dockSlot.modelData.name || "?").slice(0, 1).toUpperCase()
                                        color: Theme.fg_muted
                                        font.family: root.sans
                                        font.pixelSize: 13
                                        font.weight: 600
                                    }
                                }

                                HoverHandler { id: dockHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler {
                                    onTapped: root.runEntry({
                                        kind: "quickmark",
                                        title: dockSlot.modelData.name || "",
                                        url: dockSlot.modelData.url || "",
                                        faviconPath: dockSlot.modelData.faviconPath || ""
                                    }, false)
                                }
                            }
                        }
                    }
                }
            }

            // ── chin: surface0 band + top border + pills ─────────────
            Item {
                id: chinWrap
                width: parent.width
                height: PaletteState.chin.length > 0 ? 54 : 0
                visible: height > 0

                Rectangle {
                    // whisper band, inset inside the panel's 1px border
                    anchors.fill: parent
                    anchors.leftMargin: 1
                    anchors.rightMargin: 1
                    anchors.bottomMargin: 1
                    color: Theme.surface0
                    bottomLeftRadius: 23
                    bottomRightRadius: 23
                }
                Rectangle {
                    anchors.top: parent.top
                    width: parent.width
                    height: 1
                    color: root.panelBorder
                }

                Row {
                    id: chinTabsRow
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    Repeater {
                        model: root.filterTabs.filter(t => t !== "?")
                        Rectangle {
                            required property var modelData
                            required property int index
                            readonly property bool isActive: index === root.filterTab
                            width: chinTabLabel.implicitWidth + 16
                            height: 26
                            radius: 10
                            color: isActive ? Theme.selection
                                 : chinTabHover.hovered ? Theme.surface : "transparent"
                            border.width: root.filterNavFocused && isActive ? 2 : 0
                            border.color: Theme.cursor
                            Text {
                                id: chinTabLabel
                                anchors.centerIn: parent
                                text: String(parent.modelData)
                                color: parent.isActive ? Theme.fg : Theme.fg_muted
                                font.family: root.sans
                                font.pixelSize: 12
                                font.weight: 500
                            }
                            HoverHandler { id: chinTabHover }
                            TapHandler { onTapped: root.filterTab = parent.index }
                        }
                    }

                    Item {
                        width: 26
                        height: 26
                        Lib.KeyCap {
                            readonly property bool helpActive: root.filterTab === root.filterTabs.length - 1
                            anchors.fill: parent
                            text: "?"
                            textColor: helpActive ? Theme.fg
                                : Qt.tint(Theme.fg_muted,
                                    Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.55))
                            border.color: helpActive ? Theme.fg_muted : Theme.hairline
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            TapHandler {
                                onTapped: root.filterTab = parent.helpActive
                                    ? 0 : root.filterTabs.length - 1
                            }
                        }
                    }
                }

                Row {
                    id: chinRow
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    readonly property int availableWidth: Math.max(0, chinTabsRow.x - 28)
                    readonly property int maxPill: Math.max(60, Math.floor(
                        (availableWidth - spacing * Math.max(0, PaletteState.chin.length - 1))
                        / Math.max(1, PaletteState.chin.length)))
                    Repeater {
                        model: PaletteState.chin
                        Rectangle {
                            id: pill
                            required property var modelData
                            readonly property bool isActive: root.scopedWindowId != null
                                ? modelData.id === root.scopedWindowId
                                : !!modelData.focused
                            height: 26
                            width: Math.min(pillRow.implicitWidth + 16, Math.min(220, chinRow.maxPill))
                            radius: 10
                            color: isActive ? Theme.selection
                                 : pillHover.hovered ? Theme.surface : "transparent"
                            border.color: isActive ? root.panelBorder : "transparent"
                            border.width: 1
                            Row {
                                id: pillRow
                                anchors.centerIn: parent
                                spacing: 6
                                Image {
                                    width: 14; height: 14
                                    anchors.verticalCenter: parent.verticalCenter
                                    source: pill.modelData.faviconPath ? "file://" + pill.modelData.faviconPath : ""
                                    visible: status === Image.Ready
                                    sourceSize.width: 28; sourceSize.height: 28
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: String(pill.modelData.activeTabTitle || ("Window " + pill.modelData.id))
                                    color: pill.isActive ? Theme.fg : Theme.fg_muted
                                    elide: Text.ElideRight
                                    width: Math.min(implicitWidth, Math.min(150, chinRow.maxPill - 66))
                                    font.family: root.sans
                                    font.pixelSize: 12
                                }
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: profileText.implicitWidth + 10
                                    height: profileText.implicitHeight + 4
                                    radius: 4
                                    color: Theme.surface
                                    Text {
                                        id: profileText
                                        anchors.centerIn: parent
                                        text: pill.modelData.profile === "personal" ? "P"
                                            : pill.modelData.profile === "work" ? "W" : "?"
                                        color: Theme.fg_muted
                                        font.family: root.sans
                                        font.pixelSize: 10
                                        font.weight: 600
                                        font.letterSpacing: 0.5
                                    }
                                }
                            }
                            HoverHandler { id: pillHover }
                            TapHandler { onTapped: root.selectChinWindow(pill.modelData) }
                        }
                    }
                }
            }

        }
    }
}
