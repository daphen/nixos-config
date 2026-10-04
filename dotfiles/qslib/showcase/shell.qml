import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import QsLib
import "IconNames.js" as IconNames

ShellRoot {
  FloatingWindow {
    id: win
    title: "QsLib Presentation"
    implicitWidth: 1100
    implicitHeight: 820
    color: Theme.bg

    property string iconFilter: ""
    function copy(s) { Quickshell.execDetached(["wl-copy", "--", String(s)]) }
    function feedback(message) { toast.text = message; toast.active = true; toastReset.restart() }

    component SectionLabel: Text {
      color: Theme.fg_muted; font.family: Theme.fontFamily
      font.pixelSize: Theme.fontSize - 1; font.bold: true; font.letterSpacing: 1.2
    }
    component Tag: Text {
      color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
    }
    component AttachmentBadge: ButtonSurface {
      property string text: ""
      property bool file: false
      inverted: Theme.mode === "dark"
      readonly property color accent: file ? (inverted ? "#9A6500" : "#F2C572") : (inverted ? "#3F8C69" : "#86D7B0")
      implicitWidth: badgeContent.implicitWidth + 16
      implicitHeight: 26
      radius: height / 2
      Row {
        id: badgeContent
        anchors.centerIn: parent; spacing: 6
        Icon { name: file ? "file-content" : "image"; width: 12; height: 12; color: accent; anchors.verticalCenter: parent.verticalCenter }
        Text { text: parent.parent.text; color: parent.parent.contentColor; font.family: file ? Theme.fontFamily : "Inter"; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
      }
    }
    component Swatch: Rectangle {
      Layout.fillWidth: true
      implicitHeight: sc.implicitHeight + 32
      radius: Theme.radius; color: Theme.surface
      border.color: Theme.hairline; border.width: 1
      default property alias data: sc.data
      RowLayout {
        id: sc
        anchors { fill: parent; leftMargin: 18; rightMargin: 18 }
        spacing: 18
      }
    }

    Flickable {
      id: flick
      anchors.fill: parent
      contentWidth: width
      contentHeight: col.implicitHeight + 48
      clip: true
      ScrollFeel { flick: flick }

      ColumnLayout {
        id: col
        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 28; rightMargin: 28; topMargin: 24 }
        spacing: 26

        // ── header ────────────────────────────────────────────────
        ColumnLayout {
          spacing: 4
          Text { text: "QsLib"; color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize + 12; font.bold: true }
          Text {
            text: "Live orbs, cards, controls, motion, and " + IconNames.names.length + " icons. Click an icon to copy its name."
            color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
          }
        }

        // ── components ────────────────────────────────────────────
        RowLayout {
          SectionLabel { text: "COMPONENTS" }
          Item { Layout.fillWidth: true }
          PrimaryButton {
            Layout.preferredWidth: 150; Layout.preferredHeight: 34
            text: Theme.mode === "dark" ? "Preview light" : "Preview dark"
            onClicked: Theme.mode = Theme.mode === "dark" ? "light" : "dark"
          }
        }

        Swatch {
          Tag { text: "ThinkingOrb"; Layout.preferredWidth: 130 }
          Repeater {
            model: [Theme.sky, Theme.green, Theme.orange, Theme.electric]
            ThinkingOrb {
              required property color modelData
              required property int index
              Layout.preferredWidth: 48; Layout.preferredHeight: 48
              glow: modelData; seedKey: "presentation-" + index
            }
          }
          ThinkingOrb {
            Layout.preferredWidth: 24; Layout.preferredHeight: 24
            glow: Theme.orange; seedKey: "presentation-small"
          }
          ThinkingOrb {
            Layout.preferredWidth: 48; Layout.preferredHeight: 48
            activityColors: [Theme.sky, Theme.green, Theme.orange]
            seedKey: "presentation-combined"
          }
          Item { Layout.fillWidth: true }
        }
        Swatch {
          Tag { text: "ContrastCard"; Layout.preferredWidth: 130 }
          ContrastCard {
            Layout.fillWidth: true; Layout.preferredHeight: 130
            Column {
              anchors.fill: parent; anchors.margins: 20; spacing: 12
              Text { text: "Canonical card"; color: Theme.fg; font.family: "Inter"; font.pixelSize: 20; font.weight: 600 }
              Text { text: "Live theme-aware face, bevel, outline, and shadows"; color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: 12 }
              Row {
                spacing: 10
                AttachmentBadge { text: "Image 1" }
                AttachmentBadge { text: "shell.qml"; file: true }
                CapLabel { text: "DETAILS"; anchors.verticalCenter: parent.verticalCenter }
              }
            }
          }
          ContrastCard {
            elevated: false
            Layout.preferredWidth: 220; Layout.preferredHeight: 130
            Text { anchors.centerIn: parent; text: "Nested · no shadow"; color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: 12 }
          }
        }
        Swatch {
          Tag { text: "PrimaryButton"; Layout.preferredWidth: 130 }
          PrimaryButton {
            Layout.preferredWidth: 180; Layout.preferredHeight: 42
            text: "Primary action"; iconName: "chevron-right"
            onClicked: win.feedback("Primary action clicked")
          }
          PrimaryButton {
            Layout.preferredWidth: 140; Layout.preferredHeight: 42
            primary: false; text: "Secondary"
            onClicked: win.feedback("Secondary action clicked")
          }
          PrimaryButton {
            Layout.preferredWidth: 42; Layout.preferredHeight: 42
            radius: Theme.radiusSm; iconName: "paper-plane-2"
            onClicked: win.feedback("Send clicked")
          }
          PrimaryButton {
            Layout.preferredWidth: 120; Layout.preferredHeight: 42
            text: "Disabled"; enabled: false
          }
          Item { Layout.fillWidth: true }
        }
        Swatch {
          Tag { text: "Crossfade"; Layout.preferredWidth: 130 }
          Crossfade {
            id: swapper
            Layout.fillWidth: true; Layout.preferredHeight: 50
            first: Text { anchors.verticalCenter: parent.verticalCenter; text: "First state"; color: Theme.fg; font.family: "Inter"; font.pixelSize: 20 }
            second: Text { anchors.verticalCenter: parent.verticalCenter; text: "Second state"; color: Theme.sky; font.family: "Inter"; font.pixelSize: 20 }
          }
          PrimaryButton {
            Layout.preferredWidth: 120; Layout.preferredHeight: 36
            text: "Swap state"; onClicked: swapper.showSecond = !swapper.showSecond
          }
        }
        Swatch {
          Tag { text: "KeyCap"; Layout.preferredWidth: 130 }
          KeyCap { text: "⏎" }
          KeyCap { text: "⌃t" }
          KeyCap { small: true; text: "j" }
          KeyCap { ghost: true; text: "esc" }
          Item { Layout.fillWidth: true }
        }
        Swatch {
          Tag { text: "CapLabel"; Layout.preferredWidth: 130 }
          KeyCap { small: true; text: "y" }
          CapLabel { text: "copy" }
          KeyCap { small: true; text: "i" }
          CapLabel { text: "type" }
          Item { Layout.fillWidth: true }
        }
        Swatch {
          Tag { text: "Spinner"; Layout.preferredWidth: 130 }
          Spinner { running: true; color: Theme.fg }
          Spinner { running: true; color: Theme.green }
          Spinner { running: true; color: Theme.electric; dotSize: 3 }
          Item { Layout.fillWidth: true }
        }
        Swatch {
          Tag { text: "FeedbackPill"; Layout.preferredWidth: 130 }
          FeedbackPill { text: "Copied"; active: true }
          FeedbackPill { text: "Saved ✓"; active: true }
          Item { Layout.fillWidth: true }
        }
        Swatch {
          Tag { text: "Card"; Layout.preferredWidth: 130 }
          Card {
            implicitWidth: 200; implicitHeight: 56; color: Theme.surface0
            Text { anchors.centerIn: parent; text: "a Card surface"; color: Theme.fg; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize }
          }
          Item { Layout.fillWidth: true }
        }
        Swatch {
          Tag { text: "Theme swatches"; Layout.preferredWidth: 130 }
          Repeater {
            model: [ {c: Theme.fg, n: "fg"}, {c: Theme.fg_muted, n: "muted"}, {c: Theme.electric, n: "electric"},
                     {c: Theme.green, n: "green"}, {c: Theme.orange, n: "orange"}, {c: Theme.red, n: "red"},
                     {c: Theme.surface, n: "surface"} ]
            ColumnLayout {
              spacing: 4
              Rectangle { width: 40; height: 40; radius: 8; color: modelData.c; border.color: Theme.hairline; border.width: 1 }
              Text { text: modelData.n; color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2; horizontalAlignment: Text.AlignHCenter; Layout.preferredWidth: 40 }
            }
          }
          Item { Layout.fillWidth: true }
        }

        // ── icons ─────────────────────────────────────────────────
        RowLayout {
          Layout.topMargin: 8
          SectionLabel { text: "ICONS" }
          Item { Layout.fillWidth: true }
          Rectangle {
            implicitWidth: 260; implicitHeight: 34; radius: 17
            color: Theme.surface0; border.color: search.activeFocus ? Theme.electric : Theme.hairline; border.width: 1
            RowLayout {
              anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
              spacing: 8
              Icon { name: "magnifier"; width: 14; height: 14; color: Theme.fg_muted }
              TextInput {
                id: search; Layout.fillWidth: true; color: Theme.fg
                font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize; clip: true
                verticalAlignment: TextInput.AlignVCenter
                onTextChanged: win.iconFilter = text.toLowerCase()
                Text { anchors.fill: parent; verticalAlignment: Text.AlignVCenter; visible: !search.text
                  text: "filter icons…"; color: Theme.fg_muted; font: search.font }
              }
            }
          }
        }

        GridView {
          id: grid
          Layout.fillWidth: true
          readonly property int cols: Math.max(1, Math.floor(width / cellWidth))
          Layout.preferredHeight: Math.max(cellHeight, Math.ceil(count / cols) * cellHeight)
          interactive: false
          cellWidth: 118; cellHeight: 92
          model: win.iconFilter === "" ? IconNames.names : IconNames.names.filter(n => n.indexOf(win.iconFilter) !== -1)
          delegate: Item {
            width: grid.cellWidth; height: grid.cellHeight
            Rectangle {
              anchors { fill: parent; margins: 4 }
              radius: Theme.radius
              color: cellHov.hovered ? Theme.surface : "transparent"
              border.color: cellHov.hovered ? Theme.hairline : "transparent"; border.width: 1
              ColumnLayout {
                anchors.centerIn: parent; spacing: 8; width: parent.width - 12
                Icon { name: modelData; width: 22; height: 22; color: Theme.fg; Layout.alignment: Qt.AlignHCenter }
                Text {
                  text: modelData; color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3
                  elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
                  Layout.fillWidth: true; Layout.alignment: Qt.AlignHCenter
                }
              }
              HoverHandler { id: cellHov }
              TapHandler { onTapped: { win.copy(modelData); toast.text = "copied \"" + modelData + "\""; toast.active = true; toastReset.restart() } }
            }
          }
        }
      }
    }

    // copy confirmation
    FeedbackPill {
      id: toast; text: ""; active: false
      anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: 24 }
    }
    Timer { id: toastReset; interval: 1400; onTriggered: toast.active = false }
  }
}
