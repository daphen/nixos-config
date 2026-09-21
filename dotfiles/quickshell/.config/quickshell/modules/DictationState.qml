pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: state

    property string lifecycle: "idle"
    readonly property bool active: lifecycle !== "idle"
    readonly property bool recording: lifecycle === "preparing" || lifecycle === "recording"
    readonly property bool processing: lifecycle === "processing"

    function apply(value) {
        const next = (value || "").trim()
        lifecycle = ["preparing", "recording", "processing"].indexOf(next) >= 0
            ? next
            : "idle"
    }

    FileView {
        path: Quickshell.env("XDG_RUNTIME_DIR") + "/openwhispr-dictation-state"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: state.apply(text())
        onLoadFailed: state.lifecycle = "idle"
    }
}
