import QtQuick
import Quickshell
import Quickshell.Wayland
import "."

// Command palette — quickshell port of the chromium-palette popup.
// Data + actions come from PaletteState (palette-daemon over the UI
// socket); ranking, grouping and keybinds are ported 1:1 from the
// Solid app (App.tsx). Visuals are a faithful clone of the original
// SCSS (App.scss/Entry.scss/index.scss): 600×480, radius 14, strong
// fg-tinted outer border, full-width hairline section separators,
// borderless 17px input, sans-serif type.
PanelWindow {
    id: root

    property bool active: false
    visible: active
    readonly property bool open: PaletteState.open

    onOpenChanged: {
        if (open) {
            closeDelay.stop()
            reassert.stop()
            active = true
            resetTransient()
            PaletteState.refresh()
            search.forceActiveFocus()
        } else {
            closeDelay.restart()
            // Window switches made while cycling the chin happen UNDER this
            // layer; when the layer drops, niri returns keyboard focus to the
            // pre-palette window, silently undoing them. Re-assert the user's
            // pick once the layer is gone so the final activation wins.
            if (scopedWindowId != null && scopedWindowProfile) reassert.restart()
        }
    }
    Timer { id: closeDelay; interval: 300; onTriggered: root.active = false }
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
        scopedWindowId = null
        scopedWindowProfile = null
        selectedIndex = 0
        list.positionViewAtBeginning()
    }

    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-picker"
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // The old palette rendered in the system sans stack, not the
    // desktop's mono — part of what made it feel cleaner. Keep that.
    readonly property string sans: "Geist"
    // Outer border: --app-container-border-color (fg @ .5 light / .1 dark).
    readonly property color panelBorder:
        Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, Theme.mode === "light" ? 0.15 : 0.10)

    // ── ranking / grouping (ported from App.tsx) ──────────────────────
    readonly property var filterTabs: ["All", "Tabs", "Quickmarks", "Web"]
    property int filterTab: 0
    property string query: search ? search.text : ""
    property var scopedWindowId: null
    property var scopedWindowProfile: null
    property int selectedIndex: 0

    onQueryChanged: { selectedIndex = firstSelectable(); list.positionViewAtBeginning() }
    onFilterTabChanged: selectedIndex = firstSelectable()

    function niceUrl(u) {
        if (!u) return ""
        return u.length <= 80 ? u : u.slice(0, 40) + "..." + u.slice(-37)
    }

    // Token-prefix 10000 > substring ~1000 (boundary/position bonus) >
    // fuzzy subsequence 1 (last-resort tiebreak). Same tiers as App.tsx.
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
        let qi = 0
        for (let vi = 0; vi < v.length && qi < qLower.length; vi++)
            if (v[vi] === qLower[qi]) qi++
        return qi === qLower.length ? 1 : 0
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
    // every state push / keystroke. Groups: Open URL → Current Tab →
    // Open Tabs → Quickmarks → Web Search, ranked + reordered by best
    // score under a query, cross-group URL dedupe, chin scope filter.
    readonly property var entries: {
        const _ = PaletteState.gen
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

        const tabs = (PaletteState.tabs || []).slice()
        tabs.sort((a, b) => (b.lastAccessed || 0) - (a.lastAccessed || 0))
        const curId = PaletteState.currentTabId
        const scoped = scope == null ? tabs : tabs.filter(t => t.windowId === scope)

        const tabEntry = t => ({
            kind: "tab", title: t.title || "Untitled", url: t.url || "",
            subtitle: niceUrl(t.url || ""), faviconPath: t.faviconPath || "",
            tabId: t.id, windowId: t.windowId,
        })
        let currentItems = []
        const cur = scoped.find(t => t.id === curId)
        if (cur) { const e = tabEntry(cur); e.isCurrent = true; currentItems = [e] }
        const tabItems = scoped.filter(t => t.id !== curId).map(tabEntry)

        const qmItems = (PaletteState.quickmarks || []).map(m => ({
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

        let groups = []
        const rt = rank(q ? tabItems.concat(currentItems) : tabItems)
        const rq = rank(qmItems)
        // Address-bar Enter semantics: a URL-looking query navigates by
        // default — unless a tab/quickmark actually hits (substring or
        // better), in which case the hit stays on top. Weak fuzzy noise
        // (score 1) doesn't count as a hit.
        const hasHit = Math.max(rt.maxScore, rq.maxScore) >= 1000
        if (urlItems.length) groups.push({ id: "url", heading: "Open URL", items: urlItems, maxScore: hasHit ? 999 : 99999 })
        if (currentItems.length && !q) groups.push({ id: "tabs", heading: "Current Tab", items: currentItems, maxScore: 0 })
        groups.push({ id: "tabs", heading: "Open Tabs", items: rt.items, maxScore: rt.maxScore })
        groups.push({ id: "quickmarks", heading: "Quickmarks", items: rq.items, maxScore: rq.maxScore })
        // Web templates keep insertion order; modest score keeps the group
        // below real hits and the Go-to row, but on top when nothing hits.
        groups.push({ id: "websites", heading: "Web Search", items: webItems, maxScore: q ? 500 : 0 })
        // Actions: quickmark the current tab. Rankable like everything else
        // ("add", "quickmark", "mark" all hit it); hidden if already marked.
        if (cur && !(PaletteState.quickmarks || []).some(m => m.url === cur.url)) {
            const addItem = {
                kind: "addqm", qmName: cur.title || cur.url, qmUrl: cur.url || "",
                title: "Add current tab to quickmarks",
                subtitle: niceUrl(cur.url || ""), faviconPath: cur.faviconPath || "",
            }
            const ra = rank([addItem])
            groups.push({ id: "actions", heading: "Actions", items: q ? ra.items : [addItem],
                          maxScore: ra.maxScore })
        }

        // Cross-group URL dedupe (tabs > quickmarks > websites).
        const seen = ({})
        for (let gi = 0; gi < groups.length; gi++) {
            groups[gi].items = groups[gi].items.filter(e => {
                if (!e.url) return true
                if (seen[e.url]) return false
                seen[e.url] = true
                return true
            })
        }

        let nonEmpty = groups.filter(g => g.items.length > 0)
        if (q) nonEmpty.sort((a, b) => b.maxScore - a.maxScore)

        if (ftab === "Tabs") nonEmpty = nonEmpty.filter(g => g.id === "tabs")
        else if (ftab === "Quickmarks") nonEmpty = nonEmpty.filter(g => g.id === "quickmarks")
        else if (ftab === "Web") nonEmpty = nonEmpty.filter(g => g.id === "websites")

        const out = []
        for (let gi = 0; gi < nonEmpty.length; gi++) {
            out.push({ divider: true, label: nonEmpty[gi].heading })
            for (let ii = 0; ii < nonEmpty[gi].items.length; ii++)
                out.push(nonEmpty[gi].items[ii])
        }
        return out
    }

    onEntriesChanged: if (selectedIndex >= entries.length) selectedIndex = firstSelectable()

    function firstSelectable() {
        for (let i = 0; i < entries.length; i++)
            if (!entries[i] || !entries[i].divider) return i
        return 0
    }

    function step(dir) {
        const n = entries.length
        if (n === 0) return
        let i = selectedIndex + dir
        while (i >= 0 && i < n && entries[i] && entries[i].divider) i += dir
        if (i >= 0 && i < n) {
            selectedIndex = i
            list.positionViewAtIndex(i, ListView.Contain)
            // Contain stops at the row edge; at the ends, include the spacers
            if (i <= firstSelectable()) list.positionViewAtBeginning()
            else if (i === n - 1) list.positionViewAtEnd()
        }
    }

    // Enter = run: tab row activates the tab; URL rows navigate the
    // current tab (Ctrl+Enter = new tab; on a tab row an intentional
    // duplicate). Shift+Enter = DDG the raw query.
    function runSelected(inNewTab) {
        if (entries.length === 0) return
        const idx = Math.max(0, Math.min(selectedIndex, entries.length - 1))
        const e = entries[idx]
        if (!e || e.divider) return
        if (e.kind === "addqm") {
            if (e.qmUrl) PaletteState.quickmarkAdd(e.qmName, e.qmUrl)
        } else if (e.kind === "tab" && !inNewTab) {
            if (!e.isCurrent) PaletteState.activateTab(e.tabId, e.windowId)
        } else if (e.url) {
            PaletteState.gotoUrl(e.url, inNewTab || !!e.forceNewTab)
        }
        PaletteState.hide()
    }

    // Drop a stale chin scope when the daemon reports a different
    // focused window (external focus changes) — port of App.tsx logic.
    Connections {
        target: PaletteState
        function onGenChanged() {
            const sid = root.scopedWindowId
            if (sid == null) return
            const focused = (PaletteState.chin || []).find(w => w.focused)
            if (focused && focused.id !== sid) root.scopedWindowId = null
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
            PaletteState.hide(); event.accepted = true
        } else if (event.key === Qt.Key_Tab && !root.searchMode) {
            const kw = root.query.trim().toLowerCase()
            const t = root.webTemplates.find(t => t.key === kw)
            if (t) { root.searchMode = t; search.text = "" }
            event.accepted = true
        } else if (event.key === Qt.Key_Backspace && root.searchMode && search.text.length === 0) {
            root.searchMode = null
            event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (shift) {
                const q = root.query.trim()
                if (q.length > 0) {
                    PaletteState.gotoUrl("https://duckduckgo.com/?q=" + encodeURIComponent(q), false)
                    PaletteState.hide()
                }
            } else {
                root.runSelected(!!ctrl)
            }
            event.accepted = true
        } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_J && ctrl)) {
            root.step(1); event.accepted = true
        } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_K && ctrl)) {
            root.step(-1); event.accepted = true
        } else if ((event.key === Qt.Key_H || event.key === Qt.Key_L) && ctrl && shift) {
            root.cycleChin(event.key === Qt.Key_L ? 1 : -1); event.accepted = true
        } else if ((event.key === Qt.Key_H || event.key === Qt.Key_L) && ctrl) {
            const dir = event.key === Qt.Key_L ? 1 : -1
            root.filterTab = (root.filterTab + dir + root.filterTabs.length) % root.filterTabs.length
            event.accepted = true
        } else if (event.key === Qt.Key_D && ctrl) {
            const idx = Math.max(0, Math.min(root.selectedIndex, root.entries.length - 1))
            const e = root.entries[idx]
            if (e && !e.divider && e.kind === "tab") PaletteState.closeTab(e.tabId)
            event.accepted = true
        }
    }

    // ── visuals: faithful clone of the original popup ─────────────────
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
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round((parent.height - height) / 2)
        width: 660
        height: 560

        color: Theme.bg
        // Radii measured off the reference palette: panel 24, field 15,
        // cards 13, tiles 10, keycaps 7.
        radius: 24
        border.color: root.panelBorder
        border.width: 1
        clip: true

        scale: root.open ? 1.0 : 0.97
        opacity: root.open ? 1.0 : 0.0
        Behavior on scale {
            NumberAnimation { duration: 170; easing.type: Easing.BezierSpline
                              easing.bezierCurve: [0.26, 0.08, 0.25, 1.0, 1.0, 1.0] }
        }
        Behavior on opacity {
            NumberAnimation { duration: 170; easing.type: Easing.BezierSpline
                              easing.bezierCurve: [0.26, 0.08, 0.25, 1.0, 1.0, 1.0] }
        }

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
                    color: Theme.surface2
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
                    renderType: Text.NativeRendering
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
                        renderType: Text.NativeRendering
                    }
                }

                TextInput {
                    id: search
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
                    Text {
                        visible: !search.text
                        text: PaletteState.daemonConnected ? "Type to search..." : "palette-daemon offline…"
                        color: Theme.fg_muted
                        font: search.font
                        renderType: Text.NativeRendering
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
                        renderType: Text.NativeRendering
                    }
                }
            }

            // ── filter_tabs: pill buttons + hairline ─────────────────
            Item {
                id: tabsWrap
                width: parent.width
                height: 42

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Repeater {
                        model: root.filterTabs
                        Rectangle {
                            required property var modelData
                            required property int index
                            readonly property bool isActive: index === root.filterTab
                            width: tabLabel.implicitWidth + 16
                            height: 26
                            radius: 10
                            color: isActive ? Theme.selection
                                 : tabHover.hovered ? Theme.surface : "transparent"
                            Text {
                                id: tabLabel
                                anchors.centerIn: parent
                                text: String(parent.modelData)
                                color: parent.isActive ? Theme.fg : Theme.fg_muted
                                font.family: root.sans
                                font.pixelSize: 12
                                font.weight: 500
                                renderType: Text.NativeRendering
                            }
                            HoverHandler { id: tabHover }
                            TapHandler { onTapped: root.filterTab = parent.index }
                        }
                    }
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 1
                    color: Theme.hairline
                }
            }

            // ── list ─────────────────────────────────────────────────
            ListView {
                id: list
                width: parent.width
                height: parent.height - inputWrap.height - tabsWrap.height - chinWrap.height
                clip: true
                model: root.entries
                currentIndex: root.selectedIndex
                // structural padding: header/footer are part of the content, so
                // model resets and positionViewAt* respect them natively
                header: Item { width: 1; height: 10 }
                footer: Item { width: 1; height: 10 }
                boundsBehavior: Flickable.StopAtBounds

                Text {
                    visible: root.entries.length === 0
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: 24
                    text: "No results."
                    color: Theme.fg_muted
                    font.family: root.sans
                    font.pixelSize: 13
                    renderType: Text.NativeRendering
                }

                delegate: Item {
                    id: rowItem
                    required property var modelData
                    required property int index
                    property bool isDivider: !!(modelData && modelData.divider)
                    readonly property bool hasSubtitle: !isDivider && String(modelData.subtitle || "").length > 0
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
                        renderType: Text.NativeRendering
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
                        renderType: Text.NativeRendering
                    }

                    // Entry: inset 6px, radius 8, padding 8 12.
                    Rectangle {
                        visible: !rowItem.isDivider
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14
                        radius: 13
                        color: rowItem.index === root.selectedIndex ? Theme.selection
                             : rowHover.hovered ? Theme.surface : "transparent"
                        border.width: 1
                        border.color: rowItem.index === root.selectedIndex ? Theme.hairline : "transparent"
                        opacity: (!rowItem.isDivider && rowItem.modelData.isCurrent) ? 0.6 : 1

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
                                renderType: Text.NativeRendering
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
                                renderType: Text.NativeRendering
                            }
                            Text {
                                width: parent.width
                                visible: text.length > 0
                                text: rowItem.isDivider ? "" : String(rowItem.modelData.subtitle || "")
                                color: Theme.fg_muted
                                elide: Text.ElideRight
                                font.family: root.sans
                                font.pixelSize: 12
                                renderType: Text.NativeRendering
                            }
                        }

                        HoverHandler { id: rowHover }
                        TapHandler {
                            onTapped: { root.selectedIndex = rowItem.index; root.runSelected(false) }
                        }
                    }
                }
            }

            // ── chin: strong top border + pills ──────────────────────
            Item {
                id: chinWrap
                width: parent.width
                height: PaletteState.chin.length > 0 ? 54 : 0
                visible: height > 0

                Rectangle {
                    anchors.top: parent.top
                    width: parent.width
                    height: 1
                    color: root.panelBorder
                }

                Row {
                    id: chinRow
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    // chips share the panel width — three fixed 220px pills overflowed
                    readonly property int maxPill: Math.floor(
                        (chinWrap.width - 28 - spacing * Math.max(0, PaletteState.chin.length - 1))
                        / Math.max(1, PaletteState.chin.length))
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
                                    renderType: Text.NativeRendering
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
                                        renderType: Text.NativeRendering
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
