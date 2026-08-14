import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import QsLib
import "IconNames.js" as IconNames

ShellRoot {
  FloatingWindow {
    id: win
    title: "QsLib Gallery"
    implicitWidth: 1100
    implicitHeight: 820
    color: Theme.bg

    property string iconFilter: ""
    function copy(s) { Quickshell.execDetached(["wl-copy", "--", String(s)]) }

    component SectionLabel: Text {
      color: Theme.fg_muted; font.family: Theme.fontFamily
      font.pixelSize: Theme.fontSize - 1; font.bold: true; font.letterSpacing: 1.2
    }
    component Tag: Text {
      color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 1
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
            text: "Quickshell design system — components + " + IconNames.names.length + " Nucleo icons. Click an icon to copy its name."
            color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize
          }
        }

        // ── components ────────────────────────────────────────────
        SectionLabel { text: "COMPONENTS" }

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
