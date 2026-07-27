pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Reads the current WPM written by wpm-daemon to ~/.local/state/wpm.
// The daemon rewrites the file atomically every 500ms; FileView re-reads
// on every change.
Singleton {
    id: state

    // Live WPM for the bar pill (0 when idle).
    property int value: 0

    // Peak WPM of the last completed burst, written by the daemon only once
    // typing has actually paused. burstNonce ticks per burst so a repeated
    // peak still registers. The badge shows on this, never mid-sentence.
    property int burstPeak: 0
    property int burstNonce: 0

    FileView {
        path: Quickshell.env("HOME") + "/.local/state/wpm"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: state.value = parseInt((text() || "0").trim()) || 0
    }

    FileView {
        path: Quickshell.env("HOME") + "/.local/state/wpm-burst"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            const parts = (text() || "").trim().split(/\s+/)
            state.burstPeak = parseInt(parts[0]) || 0
            state.burstNonce = parseInt(parts[1]) || 0
        }
    }
}
