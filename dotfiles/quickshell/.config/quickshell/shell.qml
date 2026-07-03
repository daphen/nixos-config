import Quickshell
import QtQml
import "modules"

ShellRoot {
    id: root

    // Per-screen surfaces — Variants reconciles when monitors come and
    // go, so undocking doesn't leave an orphan layer-shell window from
    // the disconnected screen (which niri then framed as a regular
    // toplevel with an empty transparent body).
    Variants {
        model: Quickshell.screens
        Bar { required property var modelData; screen: modelData }
    }

    // Single overlay that follows the focused monitor (its `screen` binds to
    // the focused output). One window avoids the per-screen duplicate toasts
    // and the focus-driven window flipping that crashed quickshell 0.2.1.
    NotificationOverlay {}

    Launcher {}
    WorktreePicker {}
    WorktreeCreatePicker {}
    ReviewCreatePicker {}
    WorktreeNameInputPicker {}
    LovboxPicker {}
    BluetoothPicker {}
    NetworkPicker {}
    AsusProfilePicker {}
    EmojiPicker {}
    ClaudeRenamePicker {}
    ColorFormatPicker {}
    NotesPicker {}
    TodoListPicker {}
    NotificationJumpPicker {}
}
