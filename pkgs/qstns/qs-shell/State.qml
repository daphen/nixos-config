pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import QsLib

Singleton {
    id: shell
    property bool open: false
    signal resetPickerRequested()
    property alias agentd: agentdModel
    property string activeChatId: ""
    property string pendingContext: ""
    property var imageReferences: []
    readonly property string imagePasteDir: Quickshell.env("HOME") + "/.local/share/agentd/chat/.phtqs-pastes"
    readonly property var imageReferenceItems: {
        var out = []
        for (var i = 0; i < imageReferences.length; i++) out.push({
            id: "reference:" + i, referenceIndex: i,
            label: "Image " + (i + 1) + " · reference", preview: imageReferences[i],
            searchText: imageReferences[i], image: "file://" + encodeURI(imagePasteDir + "/" + imageReferences[i]), when: ""
        })
        return out
    }
    readonly property var contextItems: pendingContext
        ? [{ id: "context", label: "Attached context", preview: pendingContext,
             detail: pendingContext, searchText: pendingContext, when: "" }]
        : []
    function summaryLine(value, fallback) {
        var text = String(value || "").replace(/\s+/g, " ").trim()
        return text || fallback
    }

    readonly property var pickerItems: {
        agentd.revision
        var out = []
        var chats = agentd.filtered("")
        for (var i = 0; i < chats.length; i++) {
            var chat = chats[i]
            var parts = []
            for (var j = 0; j < chat.messages.length; j++)
                if (chat.messages[j].content) parts.push(chat.messages[j].content)
            out.push({
                id: chat.id,
                label: summaryLine(chat.title, "New chat"),
                preview: parts.length ? summaryLine(parts[parts.length - 1], "Empty conversation") : "Empty conversation",
                searchText: (chat.title || "") + "\n" + parts.join("\n"),
                when: relativeTime(chat.updatedAt)
            })
        }
        return out
    }

    function relativeTime(value) {
        var elapsed = Date.now() - Date.parse(value)
        if (!isFinite(elapsed)) return ""
        if (elapsed < 60000) return "now"
        if (elapsed < 3600000) return Math.floor(elapsed / 60000) + "m"
        if (elapsed < 86400000) return Math.floor(elapsed / 3600000) + "h"
        return Math.floor(elapsed / 86400000) + "d"
    }

    onOpenChanged: {
        if (!open) { pendingContext = ""; imageReferences = [] }
    }

    function toggle() {
        if (open) { open = false; return "closed" }
        return openPicker()
    }

    function openPicker() {
        if (activeChatId) return "conversation-open"
        // A restart (bar reload, crash) closes the window without the user leaving the chat; resume it.
        if (lastChatId && agentd.sessions.some(s => (s.id || s.name) === lastChatId)) {
            openConversation(lastChatId)
            return "conversation-open"
        }
        pendingContext = ""
        imageReferences = []
        resetPickerRequested()
        open = true
        return "open"
    }

    function openWithContext(context) {
        var value = String(context || "").trim()
        if (!value) return openPicker()
        activeChatId = ""
        pendingContext = value
        resetPickerRequested()
        open = true
        return "open"
    }

    function openConversation(id) {
        open = false
        pendingContext = ""
        activeChatId = id
        lastChatFile.setText(id)
        Qt.callLater(function() { conversation.activate() })
    }

    function startConversation(text) {
        var prompt = pendingContext
            ? text.trim() + "\n\nContext from another app:\n" + pendingContext
            : text.trim()
        openConversation(agentd.createSession(prompt))
    }

    function startImage(text) {
        var prompt = String(text || "").trim()
        if (!prompt) return
        if (imageReferences.length) {
            prompt += "\n\nAttached reference images in order:"
            for (var i = 0; i < imageReferences.length; i++)
                prompt += "\nImage " + (i + 1) + ": @.phtqs-pastes/" + imageReferences[i]
        }
        imageReferences = []
        openConversation(agentd.createSession(prompt, "phtqs"))
    }

    function pasteImageReference() {
        imagePasteProcess.running = false
        imagePasteProcess.command = ["sh", "-c",
            "d=" + JSON.stringify(imagePasteDir) + "; mkdir -p \"$d\" || exit 0; "
            + "t=$(wl-paste --list-types 2>/dev/null | grep -m1 '^image/'); "
            + "[ -n \"$t\" ] || { echo NOIMAGE; exit 0; }; "
            + "e=${t#image/}; [ \"$e\" = jpeg ] && e=jpg; [ \"$e\" = svg+xml ] && e=svg; "
            + "f=ref$(date +%s%N).$e; wl-paste --type \"$t\" > \"$d/$f\" 2>/dev/null && echo \"$f\" || echo NOIMAGE"]
        imagePasteProcess.running = true
    }

    function removeImageReference(index) {
        var next = imageReferences.slice()
        next.splice(index, 1)
        imageReferences = next
    }

    Process {
        id: imagePasteProcess
        stdout: StdioCollector {
            onStreamFinished: {
                var file = String(text || "").trim()
                if (file && file !== "NOIMAGE") shell.imageReferences = shell.imageReferences.concat([file])
            }
        }
    }

    AgentdState { id: agentdModel }

    // The chat the user is in, kept across restarts; cleared only when they close the window themselves.
    readonly property string lastChatId: lastChatFile.loaded ? lastChatFile.text().trim() : ""
    FileView {
        id: lastChatFile
        path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/qstns-active-chat"
        printErrors: false
        property bool loaded: false
        onLoaded: loaded = true
        onLoadFailed: loaded = true
    }
    function leaveConversation() {
        activeChatId = ""
        lastChatFile.setText("")
    }

    IpcHandler {
        target: "qstns"
        function toggle(): string { return shell.toggle() }
        function openWithContext(context: string): string { return shell.openWithContext(context) }
    }

    FloatingWindow {
        id: conversationWindow
        title: agentd.sessionProfile(shell.activeChatId) === "phtqs" ? "phtqs" : "qstns"
        visible: shell.activeChatId.length > 0
        implicitWidth: 920
        implicitHeight: 900
        minimumSize: Qt.size(640, 480)
        color: Theme.bg
        onClosed: shell.leaveConversation()

        Chat {
            id: conversation
            anchors.fill: parent
            agentd: shell.agentd
            activeId: shell.activeChatId
            closeOnBack: true
            opensExternally: true
            onSessionRequested: session => shell.openConversation(session)
            onCloseRequested: shell.leaveConversation()
        }
    }
}
