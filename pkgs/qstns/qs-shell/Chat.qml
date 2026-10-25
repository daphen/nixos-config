import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import QsLib

Rectangle {
    id: root

    required property var agentd
    property string activeId: ""
    property int selected: 0
    property bool opensExternally: false
    property bool closeOnBack: false
    property bool pickerChrome: false
    readonly property string uiFont: Theme.fontFamily
    readonly property var sessionRows: agentd.filtered(search.text)
    readonly property var active: activeId ? agentd.conversation(activeId) : null
    readonly property var messages: active ? active.messages : []
    readonly property bool imageMode: reading && agentd.sessionProfile(activeId) === "phtqs"
    readonly property var galleryImages: imageMode ? sessionImages(messages) : []
    readonly property bool reading: activeId.length > 0
    readonly property var pendingAsk: reading ? (agentd.asks[activeId] || null) : null
    property bool insertMode: true
    property int cursorIndex: Math.max(0, messages.length - 1)
    property string cursorKey: ""
    property bool hinting: false
    property bool yankMode: false
    property var hintLabels: []
    property var hintTargets: []
    property int hintIndex: -1
    property var pastedImages: []
    property string feedback: ""
    readonly property string hintChars: "asdfghjklqwertyuiopzxcvbnm"
    readonly property string inputMode: insertMode ? "insert" : (hinting ? (yankMode ? "yank" : "hint") : "normal")
    readonly property string pasteDir: Quickshell.env("HOME") + "/.local/share/agentd/chat/" + (imageMode ? ".phtqs-pastes" : ".qstns-pastes")
    readonly property color panelBorder: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b,
                                                  Theme.mode === "light" ? 0.15 : 0.10)
    // Typography, surfaces and chin colors mirror the cockpit rail (ai-cockpit qs-shell/Rail.qml) value for value.
    readonly property bool lightMode: Theme.mode === "light"
    readonly property int fsName: Theme.fontSize + 4
    readonly property int fsBody: Theme.fontSize + 3
    readonly property int fsMeta: Theme.fontSize + 2
    readonly property string fontDir: "file://" + Quickshell.env("HOME") + "/.local/share/fonts/Timeless-1.094/"
    FontLoader { id: messageFont; source: root.fontDir + "TimelessSans-SansRegular.ttf" }
    FontLoader { id: labelFont; source: root.fontDir + "TimelessSans-GroteskRegular.ttf" }
    FontLoader { source: root.fontDir + "TimelessSans-GroteskSemibold.ttf" }
    readonly property string messageFontFamily: messageFont.status === FontLoader.Ready ? "Timeless Sans Sans" : "Geist"
    readonly property string labelFontFamily: labelFont.status === FontLoader.Ready ? labelFont.name : Theme.fontFamily
    readonly property string labelSemibold: labelFont.status === FontLoader.Ready ? "Grotesk Semibold" : ""
    readonly property color userCardTop: lightMode ? "#FFFFFF" : Qt.lighter(Theme.surface0, 1.25)
    readonly property color userCardBottom: lightMode ? "#FDFDFD" : Qt.lighter(Theme.surface0, 1.2)
    readonly property color lavenderAccent: lightMode ? "#7C68C9" : "#C4B5FD"
    readonly property color activeRing: lightMode ? "#242424" : "#FAFAFA"
    readonly property color cardContentColor: lightMode ? "#23272B" : "#FAFAFA"
    readonly property color cardBodyColor: lightMode ? "#343A3F" : "#EDEDED"
    readonly property color cardMutedColor: lightMode ? "#747D84" : "#909090"
    readonly property color chinFg: lightMode ? "#23272B" : "#FAFAFA"
    readonly property color chinMuted: lightMode ? "#747D84" : "#858585"
    readonly property color chinCardSurface: lightMode ? "#F4F6F8" : "#141414"
    readonly property color chinHairline: lightMode ? Qt.rgba(0.14, 0.14, 0.13, 0.16) : Qt.rgba(1, 1, 1, 0.14)
    readonly property color decisionOrange: lightMode ? "#D75A13" : "#FF570D"
    component ChinKeyCap: KeyCap {
        color: root.lightMode ? "#F7F9FA" : "#2D2D2D"
        border.color: root.lightMode ? "#C9D1D8" : "#4A4A4A"
        textColor: root.lightMode ? "#4F5961" : "#B5B9BB"
    }
    signal closeRequested()
    signal sessionRequested(string session)

    focus: true
    onPendingAskChanged: {
        if (pendingAsk) insertMode = false
        if (reading && !insertMode) forceActiveFocus()
    }
    onMessagesChanged: {
        if (!messages.length) {
            cursorIndex = 0
            cursorKey = ""
        } else if (insertMode) {
            cursorIndex = messages.length - 1
            cursorKey = messageKey(cursorIndex)
        } else {
            var restored = indexForKey(cursorKey)
            cursorIndex = restored >= 0 ? restored
                                      : Math.max(0, Math.min(cursorIndex, messages.length - 1))
            cursorKey = messageKey(cursorIndex)
        }
        Qt.callLater(function() { feedScroll.synced() })
    }
    Keys.onPressed: event => {
        if (insertMode) return
        if (pendingAsk && handleAskKey(event)) { event.accepted = true; return }
        if (hinting && handleHintKey(event)) { event.accepted = true; return }
        if (handleNormalKey(event)) event.accepted = true
    }

    radius: pickerChrome ? 24 : 0
    color: reading ? Theme.canvas : Theme.bg
    border.color: pickerChrome ? panelBorder : "transparent"
    border.width: pickerChrome ? 1 : 0
    clip: true

    Canvas {
        id: dotGrid
        anchors.fill: parent
        visible: root.reading
        readonly property color dotColor: root.lightMode ? Qt.rgba(0.14, 0.14, 0.13, 0.07) : Qt.rgba(1, 1, 1, 0.08)
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onVisibleChanged: if (visible) requestPaint()
        onDotColorChanged: if (visible) requestPaint()
        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            ctx.fillStyle = dotColor
            for (var y = 16; y < height; y += 32)
                for (var x = 16; x < width; x += 32) {
                    ctx.beginPath()
                    ctx.arc(x, y, 1.2, 0, Math.PI * 2)
                    ctx.fill()
                }
        }
    }

    FeedScroll {
        id: feedScroll
        view: messageList
        chatVisible: root.reading
        onWantCursorAtEnd: force => {
            if (!root.messages.length) return
            root.cursorIndex = root.messages.length - 1
            root.cursorKey = root.messageKey(root.cursorIndex)
        }
    }

    function activate() {
        if (reading) enterInsert()
        else search.forceActiveFocus()
    }

    function step(dir) {
        if (!sessionRows.length) return
        selected = Math.max(0, Math.min(sessionRows.length - 1, selected + dir))
        sessionList.positionViewAtIndex(selected, ListView.Contain)
    }

    function showSession(id) {
        agentd.openSession(id)
        if (opensExternally) sessionRequested(id)
        else {
            activeId = id
            Qt.callLater(function() { composer.forceActiveFocus() })
        }
    }

    function openSelected() {
        var row = sessionRows[Math.max(0, Math.min(selected, sessionRows.length - 1))]
        if (row) showSession(row.id)
    }

    function newMessage() {
        search.text = ""
        showSession(agentd.createSession())
    }

    function submit(queued) {
        var text = attachRefs(composer.text.trim())
        if (!text) return
        if (!activeId) activeId = agentd.createSession()
        var sent = queued ? agentd.enqueue(activeId, text) : agentd.prompt(activeId, text)
        if (!sent) return
        composer.text = ""
        pastedImages = []
        showFeedback(queued && agentd.sessionBusy(activeId) ? "queued" : (agentd.sessionBusy(activeId) ? "steered" : "sent"))
        Qt.callLater(function() { feedScroll.toEnd() })
    }

    function back() {
        composer.text = ""
        if (closeOnBack) {
            closeRequested()
            return
        }
        activeId = ""
        Qt.callLater(function() { search.forceActiveFocus() })
    }

    function relTime(value) {
        var elapsed = Date.now() - Date.parse(value)
        if (!isFinite(elapsed)) return ""
        if (elapsed < 60000) return "now"
        if (elapsed < 3600000) return Math.floor(elapsed / 60000) + "m"
        if (elapsed < 86400000) return Math.floor(elapsed / 3600000) + "h"
        return Math.floor(elapsed / 86400000) + "d"
    }

    function messageKey(index) {
        var message = messages[index]
        return message ? String(message.key || (message.role + ":" + index)) : ""
    }

    function indexForKey(key) {
        if (!key) return -1
        for (var i = 0; i < messages.length; i++)
            if (messageKey(i) === key) return i
        return -1
    }

    function setCursor(index) {
        if (!messages.length) return
        cancelHints()
        cursorIndex = Math.max(0, Math.min(messages.length - 1, index))
        cursorKey = messageKey(cursorIndex)
        feedScroll.cursorMoved(cursorIndex, cursorIndex === messages.length - 1)
    }

    function enterInsert() {
        cancelHints()
        insertMode = true
        if (messages.length) {
            cursorIndex = messages.length - 1
            cursorKey = messageKey(cursorIndex)
        }
        feedScroll.toEnd()
        Qt.callLater(function() { composer.forceActiveFocus() })
    }

    function exitInsert() {
        insertMode = false
        setCursor(Math.max(0, messages.length - 1))
        forceActiveFocus()
    }

    function moveCursor(delta) {
        setCursor(cursorIndex + delta)
    }

    function selectedText() {
        var message = messages[cursorIndex]
        return message ? String(message.content || "") : ""
    }

    function generatedImages(text) {
        var matches = String(text || "").match(/(?:~|\/[^\s<>"'`()]+)?\/Pictures\/phtqs\/[^\s<>"'`()]+\.png/gi) || []
        var home = Quickshell.env("HOME"), seen = {}, paths = []
        for (var i = 0; i < matches.length; i++) {
            var value = matches[i].replace(/[.,;:!?]+$/, "")
            var absolute = value.indexOf("~/") === 0 ? home + value.slice(1) : value
            if (absolute.indexOf(home + "/Pictures/phtqs/") !== 0 || seen[absolute]) continue
            seen[absolute] = true
            paths.push(absolute)
        }
        return paths
    }

    function sessionImages(rows) {
        var seen = {}, paths = []
        for (var i = 0; i < rows.length; i++) {
            var found = generatedImages(rows[i].content)
            for (var j = 0; j < found.length; j++) {
                if (seen[found[j]]) continue
                seen[found[j]] = true
                paths.push(found[j])
            }
        }
        return paths
    }

    function imageSource(file) {
        return "file://" + encodeURI(file)
    }

    function linkPattern() {
        return /\[[^\]]*\]\((https?:\/\/[^\s)]+)\)|(https?:\/\/[^\s<>")\]]+)/g
    }

    function yankPattern() {
        return /```[a-zA-Z]*\n([\s\S]*?)```|`([^`\n]+)`|\[[^\]]*\]\((https?:\/\/[^\s)]+)\)|(https?:\/\/[^\s<>")\]]+)/g
    }

    function startHints() {
        var pattern = linkPattern(), match, targets = [], text = selectedText()
        while ((match = pattern.exec(text)) !== null) targets.push(match[1] || match[2])
        if (!targets.length) { showFeedback("no links in this message"); return }
        var labels = []
        for (var i = 0; i < targets.length; i++) labels.push(hintChars.charAt(i % hintChars.length))
        hintTargets = targets
        hintLabels = labels
        hintIndex = cursorIndex
        hinting = true
        yankMode = false
    }

    function startYank() {
        var pattern = yankPattern(), match, targets = [], text = selectedText()
        while ((match = pattern.exec(text)) !== null)
            targets.push(match[1] || match[2] || match[3] || match[4] || match[0])
        var labels = [], chars = hintChars.replace("y", "")
        for (var i = 0; i < targets.length; i++) labels.push(chars.charAt(i % chars.length))
        hintTargets = targets
        hintLabels = labels
        hintIndex = cursorIndex
        hinting = true
        yankMode = true
        showFeedback(targets.length ? "yank mode · yellow letter · yy for all" : "yank mode · yy for all")
    }

    function cancelHints() {
        hinting = false
        yankMode = false
        hintLabels = []
        hintTargets = []
        hintIndex = -1
    }

    function chooseHint(character) {
        if (yankMode && character === "y") {
            copyText(selectedText())
            cancelHints()
            return
        }
        var index = hintLabels.indexOf(character)
        if (index < 0) return
        var target = hintTargets[index]
        var copy = yankMode
        cancelHints()
        if (copy) copyText(target)
        else Quickshell.execDetached(["xdg-open", target])
    }

    function colorHex(color) {
        function channel(value) {
            var hex = Math.round(value * 255).toString(16)
            return hex.length < 2 ? "0" + hex : hex
        }
        return "#" + channel(color.r) + channel(color.g) + channel(color.b)
    }

    function hintBadge(label) {
        return "<font color=\"" + colorHex(Theme.yellow) + "\"><b>[" + label + "]</b></font>&#8201;"
    }

    function displayText(text, rowIndex) {
        var value = String(text || "")
        value = value.replace(/@?\.(?:qstns|phtqs)-pastes\/\S+/g,
            "<font color=\"" + colorHex(Theme.orange) + "\"><b>📎 image</b></font>")
        if (!hinting || rowIndex !== hintIndex) return value
        var labels = hintLabels, n = 0
        return value.replace(yankMode ? yankPattern() : linkPattern(), function(all) {
            var label = labels[n++]
            if (!label) return all
            if (yankMode && all.slice(0, 3) === "```") return hintBadge(label) + "\n\n" + all
            return hintBadge(label) + all
        })
    }

    function copyText(text) {
        if (!text) return
        Quickshell.execDetached(["wl-copy", "--", String(text)])
        showFeedback("copied")
    }

    function showFeedback(text) {
        feedback = text
        feedbackTimer.restart()
    }

    function handleHintKey(event) {
        if (event.key === Qt.Key_Escape) { cancelHints(); return true }
        if (event.text && /^[a-z]$/.test(event.text)) { chooseHint(event.text); return true }
        if (event.key === Qt.Key_Control || event.key === Qt.Key_Shift || event.key === Qt.Key_Alt || event.key === Qt.Key_Meta) return true
        cancelHints()
        return false
    }

    function handleAskKey(event) {
        if (event.key === Qt.Key_Escape) { agentd.answer(activeId, { cancelled: true }); return true }
        if (event.key === Qt.Key_T) { agentd.answer(activeId, { cancelled: true }); enterInsert(); return true }
        if (pendingAsk.method === "confirm" && event.key === Qt.Key_Y) { agentd.answer(activeId, { confirmed: true }); return true }
        if (pendingAsk.method === "confirm" && event.key === Qt.Key_N) { agentd.answer(activeId, { confirmed: false }); return true }
        if (pendingAsk.method === "select") {
            var choice = event.key - Qt.Key_0
            if (choice >= 1 && choice <= Math.min(9, (pendingAsk.options || []).length)) {
                agentd.answer(activeId, { value: pendingAsk.options[choice - 1] })
                return true
            }
        }
        if ((pendingAsk.method === "input" || pendingAsk.method === "editor") && event.key === Qt.Key_I) {
            askInput.forceActiveFocus()
            return true
        }
        return false
    }

    function handleNormalKey(event) {
        var shift = event.modifiers & Qt.ShiftModifier
        if (event.key === Qt.Key_I) { enterInsert(); return true }
        if (event.key === Qt.Key_J) { moveCursor(1); return true }
        if (event.key === Qt.Key_K) { moveCursor(-1); return true }
        if (event.key === Qt.Key_G) {
            setCursor(shift ? Math.max(0, messages.length - 1) : 0)
            return true
        }
        if (event.key === Qt.Key_F) { startHints(); return true }
        if (event.key === Qt.Key_Y) {
            if (shift) copyText(selectedText())
            else startYank()
            return true
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { enterInsert(); return true }
        if (event.key === Qt.Key_Escape) {
            if (agentd.sessionBusy(activeId)) agentd.abort(activeId)
            else closeRequested()
            return true
        }
        if (event.key === Qt.Key_H) { closeRequested(); return true }
        return false
    }

    function attachRefs(text) {
        return String(text || "").replace(/\[image (\d+)\]/g, function(all, number) {
            var file = pastedImages[parseInt(number) - 1]
            return file ? "@" + (imageMode ? ".phtqs-pastes/" : ".qstns-pastes/") + file : all
        })
    }

    Timer {
        id: feedbackTimer
        interval: 1800
        onTriggered: root.feedback = ""
    }

    Process {
        id: pasteProcess
        stdout: StdioCollector {
            onStreamFinished: {
                var file = String(text || "").trim()
                if (!file || file === "NOIMAGE") {
                    composer.paste()
                    return
                }
                root.pastedImages = root.pastedImages.concat([file])
                composer.insert(composer.cursorPosition, "[image " + root.pastedImages.length + "] ")
            }
        }
    }

    function pasteImage() {
        pasteProcess.running = false
        pasteProcess.command = ["sh", "-c",
            "d=" + JSON.stringify(pasteDir) + "; mkdir -p \"$d\" || exit 0; "
            + "t=$(wl-paste --list-types 2>/dev/null | grep -m1 '^image/'); "
            + "[ -n \"$t\" ] || { echo NOIMAGE; exit 0; }; "
            + "e=${t#image/}; [ \"$e\" = jpeg ] && e=jpg; [ \"$e\" = svg+xml ] && e=svg; "
            + "n=$(find \"$d\" -maxdepth 1 -type f -name 'img*' | wc -l); n=$((n+1)); "
            + "f=img$n.$e; wl-paste --type \"$t\" > \"$d/$f\" 2>/dev/null && echo \"$f\" || echo NOIMAGE"]
        pasteProcess.running = true
    }

    component Hint: Row {
        required property string cap
        required property string label
        spacing: 6
        ChinKeyCap { small: true; px: 11; text: parent.cap; anchors.verticalCenter: parent.verticalCenter }
        CapLabel {
            anchors.verticalCenter: parent.verticalCenter
            px: 12
            text: parent.label
            color: root.lightMode ? "#747D84" : "#9AA2A7"
        }
    }

    Column {
        anchors.fill: parent

        Item {
            id: inputWrap
            visible: !root.reading
            width: parent.width
            height: visible ? 68 : 0

            Rectangle {
                id: topField
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
                anchors.left: topField.left
                anchors.leftMargin: 14
                anchors.verticalCenter: topField.verticalCenter
                text: root.reading ? "‹" : "\uf002"
                color: Theme.fg_muted
                font.family: root.uiFont
                font.pixelSize: root.reading ? 24 : 15
                TapHandler { onTapped: if (root.reading) root.back() }
            }

            TextField {
                id: search
                visible: !root.reading
                anchors.left: topField.left
                anchors.leftMargin: 42
                anchors.right: escCap.left
                anchors.rightMargin: 12
                anchors.verticalCenter: topField.verticalCenter
                placeholderText: "Search chats"
                color: Theme.fg
                placeholderTextColor: Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.5)
                font.family: root.uiFont
                font.pixelSize: 18
                background: null
                padding: 8
                onTextChanged: root.selected = 0
                Keys.onPressed: event => {
                    var ctrl = event.modifiers & Qt.ControlModifier
                    if (event.key === Qt.Key_Escape) {
                        root.closeRequested(); event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.openSelected(); event.accepted = true
                    } else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_J)) {
                        root.step(1); event.accepted = true
                    } else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K)) {
                        root.step(-1); event.accepted = true
                    } else if (ctrl && event.key === Qt.Key_N) {
                        root.newMessage(); event.accepted = true
                    }
                }
            }

            Text {
                visible: root.reading
                anchors.left: topField.left
                anchors.leftMargin: 42
                anchors.right: escCap.left
                anchors.rightMargin: 12
                anchors.verticalCenter: topField.verticalCenter
                text: root.active ? root.active.title : "New chat"
                color: Theme.fg
                elide: Text.ElideRight
                font.family: root.uiFont
                font.pixelSize: 15
                font.weight: 500
            }

            KeyCap {
                id: escCap
                anchors.right: topField.right
                anchors.rightMargin: 12
                anchors.verticalCenter: topField.verticalCenter
                text: "esc"
                TapHandler { onTapped: root.reading ? root.back() : root.closeRequested() }
            }
        }

        Item {
            visible: !root.reading
            width: parent.width
            height: visible ? root.height - inputWrap.height - footer.height : 0

            ListView {
                id: sessionList
                anchors.fill: parent
                clip: true
                spacing: 2
                model: root.sessionRows
                currentIndex: root.selected
                header: Item { width: 1; height: 14 }
                footer: Item { width: 1; height: 14 }

                delegate: Item {
                    id: row
                    required property var modelData
                    required property int index
                    width: ListView.view.width
                    height: 44

                    Rectangle {
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14
                        radius: 13
                        color: row.index === root.selected ? Theme.selection
                             : rowHover.hovered ? Theme.surface : "transparent"
                        border.width: 1
                        border.color: row.index === root.selected ? Theme.hairline : "transparent"
                    }
                    HoverHandler { id: rowHover }
                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 28
                        anchors.right: rowTime.left
                        anchors.rightMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.modelData.title
                        color: Theme.fg
                        elide: Text.ElideRight
                        font.family: root.uiFont
                        font.pixelSize: 15
                        font.weight: 500
                    }
                    Text {
                        id: rowTime
                        anchors.right: parent.right
                        anchors.rightMargin: 28
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.relTime(row.modelData.updatedAt)
                        color: Theme.fg_muted
                        font.family: root.uiFont
                        font.pixelSize: 12
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.selected = row.index; root.openSelected() }
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                visible: root.sessionRows.length === 0
                text: root.agentd.connected ? "no conversations yet" : "connecting to chat…"
                color: Theme.fg_muted
                font.family: root.uiFont
                font.pixelSize: 12
            }
        }

        Item {
            visible: root.reading
            width: parent.width
            height: visible ? root.height - chin.height : 0

            Rectangle {
                id: gallery
                visible: root.imageMode && root.galleryImages.length > 0
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: visible ? 118 : 0
                color: Theme.surface0
                border.width: visible ? 1 : 0
                border.color: Theme.hairline

                Text {
                    anchors { left: parent.left; top: parent.top; leftMargin: 20; topMargin: 10 }
                    text: "gallery"
                    color: Theme.fg_muted
                    font.family: root.uiFont
                    font.pixelSize: 11
                    font.bold: true
                }

                ListView {
                    anchors { left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom
                              leftMargin: 20; rightMargin: 20; topMargin: 30; bottomMargin: 10 }
                    orientation: ListView.Horizontal
                    spacing: 10
                    clip: true
                    model: root.galleryImages
                    delegate: Rectangle {
                        id: galleryCard
                        required property string modelData
                        width: 104
                        height: ListView.view.height
                        radius: 10
                        color: Theme.surface
                        border.width: 1
                        border.color: Theme.hairline
                        clip: true
                        Image {
                            anchors.fill: parent
                            anchors.margins: 1
                            source: root.imageSource(galleryCard.modelData)
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            sourceSize.width: 320
                        }
                        TapHandler { onTapped: Quickshell.execDetached(["xdg-open", galleryCard.modelData]) }
                    }
                }
            }

            ListView {
                id: messageList
                anchors { left: parent.left; right: parent.right; top: gallery.bottom; bottom: parent.bottom }
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                clip: true
                spacing: 24
                model: root.messages
                currentIndex: root.cursorIndex
                header: Item { width: 1; height: 24 }
                footer: Item { width: 1; height: 72 }
                boundsBehavior: Flickable.StopAtBounds
                cacheBuffer: 1000000
                ScrollBar.vertical: ScrollBar { width: 6; policy: ScrollBar.AsNeeded }
                ScrollFeel {
                    flick: messageList
                    onScrolled: up => feedScroll.userScrolled(up)
                }
                onCountChanged: feedScroll.contentChanged()
                onDraggingChanged: dragging ? feedScroll.gestureStarted() : feedScroll.gestureEnded()
                onFlickingChanged: if (!flicking) feedScroll.gestureEnded()

                delegate: Item {
                    id: messageRow
                    required property var modelData
                    required property int index
                    readonly property bool cursor: !root.insertMode && root.cursorIndex === index
                    readonly property bool isUser: modelData.role === "user"
                    readonly property color accent: isUser ? Theme.orange : root.lavenderAccent
                    // Assistant replies sit flush (8 above and below); user cards carry their own 16.
                    readonly property int padY: isUser ? 16 : 8
                    width: ListView.view.width
                    implicitHeight: cardColumn.implicitHeight + 2 * padY

                    Item {
                        id: card
                        anchors.right: parent.right
                        anchors.rightMargin: messageRow.isUser ? 12 : 0
                        width: messageRow.isUser ? (parent.width - 24) * 0.9 : parent.width
                        height: parent.height

                        ContrastCard {
                            visible: messageRow.isUser
                            anchors.fill: parent
                            cardRadius: 18
                            elevated: true
                            bevelWidth: 2
                            faceTop: root.userCardTop
                            faceUpper: faceTop
                            faceMid: root.userCardBottom
                            faceBottom: faceMid
                            rimTop: cardHover.hovered ? (root.lightMode ? "#FFFFFF" : "#34313A") : (root.lightMode ? "#FFFFFF" : "#2B2B2B")
                            rimBottom: root.lightMode ? "#FFFFFF" : "#222222"
                            outlineColor: cardHover.hovered
                                ? Qt.rgba(messageRow.accent.r, messageRow.accent.g, messageRow.accent.b, 0.42)
                                : (root.lightMode ? "#FFFFFF" : "#282828")
                            Behavior on rimTop { ColorAnimation { duration: 150; easing.type: Easing.OutCubic } }
                            Behavior on outlineColor { ColorAnimation { duration: 150; easing.type: Easing.OutCubic } }
                        }
                        Rectangle {
                            anchors.fill: parent
                            radius: 18
                            color: messageRow.isUser ? Qt.rgba(messageRow.accent.r, messageRow.accent.g, messageRow.accent.b, 0.05) : "transparent"
                            border.width: 1
                            border.color: Qt.rgba(messageRow.accent.r, messageRow.accent.g, messageRow.accent.b, 0.36)
                            opacity: cardHover.hovered && !messageRow.cursor ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                        }
                        Rectangle {
                            anchors.fill: parent
                            radius: 18
                            color: "transparent"
                            border.width: messageRow.isUser ? 2 : 1
                            border.color: Qt.rgba(messageRow.accent.r, messageRow.accent.g, messageRow.accent.b, messageRow.isUser ? 0.92 : 0.65)
                            opacity: messageRow.cursor ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                        }
                        HoverHandler { id: cardHover }
                        TapHandler {
                            onTapped: {
                                root.insertMode = false
                                root.setCursor(messageRow.index)
                                root.forceActiveFocus()
                            }
                        }

                        Column {
                            id: cardColumn
                            anchors { left: parent.left; right: parent.right; top: parent.top
                                      leftMargin: 24; rightMargin: 24; topMargin: messageRow.padY }
                            spacing: 16

                            Row {
                                spacing: 8
                                visible: messageRow.isUser
                                Icon {
                                    name: "paper-plane-2"
                                    variantSize: 12
                                    width: 16; height: 16
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: messageRow.accent
                                }
                                Text {
                                    text: "You"
                                    color: root.cardContentColor
                                    font.family: root.labelFontFamily
                                    font.styleName: root.labelSemibold
                                    font.pixelSize: root.fsName
                                    font.weight: 600
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Text {
                                width: cardColumn.width
                                visible: text.length > 0
                                text: root.displayText(messageRow.modelData.content, messageRow.index)
                                textFormat: Text.MarkdownText
                                wrapMode: Text.Wrap
                                color: root.cardBodyColor
                                font.family: root.messageFontFamily
                                font.pixelSize: root.fsBody
                                font.weight: 400
                                lineHeightMode: Text.FixedHeight
                                lineHeight: root.fsBody * 1.5
                                onLinkActivated: link => Quickshell.execDetached(["xdg-open", link])
                            }

                            Repeater {
                                model: root.imageMode ? root.generatedImages(messageRow.modelData.content) : []
                                Rectangle {
                                    id: generatedCard
                                    required property string modelData
                                    width: cardColumn.width
                                    height: Math.min(width * 0.75, 420)
                                    radius: 12
                                    color: Theme.surface0
                                    border.width: 1
                                    border.color: Theme.hairline
                                    clip: true
                                    Image {
                                        anchors.fill: parent
                                        anchors.margins: 1
                                        source: root.imageSource(generatedCard.modelData)
                                        fillMode: Image.PreserveAspectFit
                                        asynchronous: true
                                        cache: true
                                        sourceSize.width: 1200
                                    }
                                    TapHandler { onTapped: Quickshell.execDetached(["xdg-open", generatedCard.modelData]) }
                                }
                            }
                        }
                    }
                }
            }
        }

        Item {
            id: chin
            visible: root.reading
            width: parent.width
            height: visible ? chinCol.implicitHeight + 26 : 0

            ContrastCard {
                anchors { fill: parent; leftMargin: 18; rightMargin: 18; bottomMargin: -cardRadius }
                cardRadius: 28
                faceTop: root.lightMode ? root.userCardBottom : root.userCardTop
                faceUpper: faceTop
                faceMid: root.userCardBottom
                faceBottom: faceMid
            }

            ColumnLayout {
                id: chinCol
                anchors { left: parent.left; right: parent.right; top: parent.top
                          leftMargin: 38; rightMargin: 38; topMargin: 14 }
                spacing: 10

                Rectangle {
                    id: askCard
                    visible: root.pendingAsk !== null
                    Layout.fillWidth: true
                    implicitHeight: askColumn.implicitHeight + 28
                    radius: 14
                    color: root.chinCardSurface
                    border.width: 1
                    border.color: root.decisionOrange

                    Rectangle {
                        anchors { left: parent.left; top: parent.top; bottom: parent.bottom
                                  topMargin: 12; bottomMargin: 12 }
                        width: 2; radius: 1; color: root.decisionOrange
                    }

                    Column {
                        id: askColumn
                        anchors { left: parent.left; right: parent.right; top: parent.top
                                  leftMargin: 18; rightMargin: 16; topMargin: 14 }
                        spacing: 9
                        Text {
                            text: "needs your input"
                            color: root.decisionOrange
                            font.family: Theme.fontFamily
                            font.pixelSize: root.fsMeta
                            font.bold: true
                        }
                        Text {
                            width: parent.width
                            visible: text.length > 0
                            text: root.pendingAsk ? (root.pendingAsk.title || root.pendingAsk.message || "Your input") : ""
                            wrapMode: Text.Wrap
                            color: root.chinFg
                            font.family: Theme.fontFamily
                            font.pixelSize: root.fsBody
                        }
                        Text {
                            width: parent.width
                            visible: text.length > 0
                            text: root.pendingAsk && root.pendingAsk.title ? String(root.pendingAsk.message || "") : ""
                            textFormat: Text.MarkdownText
                            wrapMode: Text.Wrap
                            color: root.chinMuted
                            font.family: Theme.fontFamily
                            font.pixelSize: root.fsMeta
                            onLinkActivated: url => Quickshell.execDetached(["xdg-open", url])
                        }
                        Column {
                            visible: root.pendingAsk && root.pendingAsk.method === "select"
                            width: parent.width
                            spacing: 6
                            Repeater {
                                model: root.pendingAsk && root.pendingAsk.method === "select" ? root.pendingAsk.options : []
                                Row {
                                    required property var modelData
                                    required property int index
                                    spacing: 9
                                    ChinKeyCap { small: true; px: 11; text: String(parent.index + 1); anchors.verticalCenter: parent.verticalCenter }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: String(parent.modelData)
                                        color: root.chinFg
                                        font.family: Theme.fontFamily
                                        font.pixelSize: root.fsBody
                                    }
                                }
                            }
                        }
                        TextField {
                            id: askInput
                            visible: root.pendingAsk && (root.pendingAsk.method === "input" || root.pendingAsk.method === "editor")
                            width: parent.width
                            placeholderText: "Answer…"
                            placeholderTextColor: root.chinMuted
                            color: root.chinFg
                            font.family: Theme.fontFamily
                            font.pixelSize: root.fsBody
                            cursorDelegate: Rectangle {
                                width: 2
                                radius: 1
                                color: Theme.cursor
                                opacity: askInput.cursorVisible ? 1 : 0
                            }
                            background: Rectangle {
                                radius: 10
                                color: "transparent"
                                border.width: askInput.activeFocus ? 2 : 1
                                border.color: askInput.activeFocus ? root.activeRing : Theme.hairline
                            }
                            onAccepted: {
                                if (text.trim()) root.agentd.answer(root.activeId, { value: text })
                                text = ""
                            }
                        }
                    }
                }

                Rectangle {
                    id: composerBox
                    visible: root.pendingAsk === null
                    Layout.fillWidth: true
                    implicitHeight: Math.max(52, Math.min(composer.implicitHeight + 30, 94))
                    radius: Math.min(height / 2, 26)
                    color: "transparent"
                    ContrastCard {
                        anchors.fill: parent
                        cardRadius: parent.radius
                        elevated: false
                        faceTop: root.lightMode ? root.userCardBottom : root.userCardTop
                        faceUpper: faceTop
                        faceMid: root.userCardBottom
                        faceBottom: faceMid
                    }
                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: "transparent"
                        border.color: root.insertMode ? root.activeRing : Theme.hairline
                        border.width: root.insertMode ? 2 : 1
                        Behavior on border.color { ColorAnimation { duration: 650; easing.type: Easing.InOutQuad } }
                    }

                    Icon {
                        id: composeChevron
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        y: composerFlick.y + Math.max(0, (composer.cursorRectangle.height - height) / 2)
                        name: "chevron-right"
                        width: 14; height: 14
                        color: root.insertMode ? root.activeRing : root.chinHairline
                        Behavior on color { ColorAnimation { duration: 650; easing.type: Easing.InOutQuad } }
                    }

                    Flickable {
                        id: composerFlick
                        anchors { left: composeChevron.right; right: parent.right; top: parent.top; bottom: parent.bottom
                                  leftMargin: 8; rightMargin: 12; topMargin: 15; bottomMargin: 15 }
                        contentHeight: composer.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        function ensureVisible(rect) {
                            if (contentY >= rect.y) contentY = rect.y
                            else if (contentY + height <= rect.y + rect.height) contentY = rect.y + rect.height - height
                        }

                        TextArea {
                            id: composer
                            width: composerFlick.width
                            padding: 0
                            background: null
                            wrapMode: TextArea.Wrap
                            color: root.chinFg
                            selectionColor: Theme.selection
                            font.family: Theme.fontFamily
                            font.pixelSize: root.fsBody
                            onCursorRectangleChanged: composerFlick.ensureVisible(cursorRectangle)
                            cursorDelegate: Rectangle {
                                width: 2
                                radius: 1
                                color: Theme.cursor
                                opacity: composer.cursorVisible ? 1 : 0
                            }
                            Keys.onPressed: event => {
                                var control = event.modifiers & Qt.ControlModifier
                                if (control && event.key === Qt.Key_V && !(event.modifiers & Qt.ShiftModifier)) {
                                    root.pasteImage()
                                    event.accepted = true
                                } else if (control && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                                    root.submit(true)
                                    event.accepted = true
                                } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                           && !(event.modifiers & Qt.ShiftModifier)) {
                                    root.submit(false)
                                    event.accepted = true
                                } else if (event.key === Qt.Key_Escape) {
                                    if (root.agentd.sessionBusy(root.activeId)) root.agentd.abort(root.activeId)
                                    else root.exitInsert()
                                    event.accepted = true
                                }
                            }
                            Text {
                                visible: !composer.text.length && !composer.activeFocus
                                anchors.fill: parent
                                verticalAlignment: Text.AlignVCenter
                                text: "Message…"
                                color: root.chinMuted
                                font: composer.font
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Row {
                        spacing: 5
                        Icon {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 16; height: 16
                            name: "msg-bubble-user"
                            color: Theme.orange
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.feedback || (root.imageMode ? "phtqs" : "qstns")
                            color: root.feedback ? Theme.orange : root.chinMuted
                            font { family: Theme.fontFamily; pixelSize: root.fsMeta - 2; weight: 650 }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.agentd.queuedFor(root.activeId) > 0
                            leftPadding: 8
                            text: root.agentd.queuedFor(root.activeId) + " queued"
                            color: Theme.orange
                            font { family: Theme.fontFamily; pixelSize: root.fsMeta - 2; weight: 650 }
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Repeater {
                        model: root.pendingAsk
                            ? (root.pendingAsk.method === "confirm"
                               ? [{ cap: "y", label: "yes" }, { cap: "n", label: "no" }, { cap: "t", label: "talk" }, { cap: "esc", label: "cancel" }]
                               : root.pendingAsk.method === "select"
                                 ? [{ cap: "1-9", label: "pick" }, { cap: "t", label: "talk" }, { cap: "esc", label: "cancel" }]
                                 : [{ cap: "i", label: "answer" }, { cap: "t", label: "talk" }, { cap: "esc", label: "cancel" }])
                            : root.insertMode
                            ? (root.agentd.sessionBusy(root.activeId)
                               ? [{ cap: "⏎", label: "steer" }, { cap: "C-⏎", label: "queue" },
                                  { cap: "esc", label: "interrupt" }, { cap: "C-v", label: "paste" }]
                               : [{ cap: "⏎", label: "send" }, { cap: "S-⏎", label: "newline" },
                                  { cap: "esc", label: "normal" }, { cap: "C-v", label: "paste" }])
                            : (root.hinting
                               ? [{ cap: "a-z", label: root.yankMode ? "copy" : "open" },
                                  { cap: "esc", label: "cancel" }]
                               : [{ cap: "j/k", label: "move" }, { cap: "i", label: "type" },
                                  { cap: "f", label: "links" }, { cap: "y/Y", label: "yank" },
                                  { cap: "esc", label: "close" }])
                        RowLayout {
                            required property var modelData
                            spacing: 6
                            ChinKeyCap { small: true; px: 11; text: parent.modelData.cap }
                            CapLabel { px: 12; text: parent.modelData.label; color: root.lightMode ? "#747D84" : "#9AA2A7" }
                            Item { width: 6 }
                        }
                    }
                }
            }
        }

        Item {
            id: footer
            visible: !root.reading
            width: parent.width
            height: visible ? 52 : 0
            Rectangle {
                anchors.fill: parent
                color: Theme.surface0
                bottomLeftRadius: root.pickerChrome ? 23 : 0
                bottomRightRadius: root.pickerChrome ? 23 : 0
            }
            Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.hairline }
            Row {
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                spacing: 14
                Hint { cap: "⌃j"; label: "move" }
                Hint { cap: "↵"; label: "open" }
            }
            Row {
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                spacing: 14
                Hint { cap: "⌃n"; label: "new" }
                Hint { cap: "esc"; label: "close" }
                Text {
                    visible: root.agentd.error.length > 0
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.agentd.error
                    color: Theme.red
                    font.family: root.uiFont
                    font.pixelSize: 11
                }
            }
        }
    }

    Rectangle {
        id: thinkingPill
        opacity: root.reading && root.pendingAsk === null && root.agentd.sessionBusy(root.activeId) ? 1 : 0
        visible: opacity > 0.01
        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: chin.height + 10 }
        implicitWidth: thinkingRow.implicitWidth + 32
        height: 56
        radius: height / 2
        color: root.chinCardSurface
        border.width: 1
        border.color: root.chinHairline
        z: 20
        Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }

        Row {
            id: thinkingRow
            anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
            spacing: 12
            ThinkingOrb {
                width: 38; height: 38
                anchors.verticalCenter: parent.verticalCenter
                running: thinkingPill.visible
                glow: Theme.orange
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "thinking…"
                rightPadding: 6
                color: root.chinMuted
                font.family: Theme.fontFamily
                font.pixelSize: root.fsBody
                SequentialAnimation on opacity {
                    running: thinkingPill.visible
                    loops: Animation.Infinite
                    NumberAnimation { from: 0.5; to: 1; duration: 900; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 1; to: 0.5; duration: 900; easing.type: Easing.InOutSine }
                }
            }
        }
    }
}
