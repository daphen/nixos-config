import QtQuick
import Quickshell
import Quickshell.Io
import "."
import "../QsLib" as Lib

Item {
    id: root

    property string kind: "disconnected"
    property string label: "Disconnected"
    property string device: ""
    property int strength: 0
    property real latencyMs: -1
    property real linkMegabitsPerSecond: 0
    property real downloadBytesPerSecond: 0
    property real uploadBytesPerSecond: 0
    property double previousRxBytes: -1
    property double previousTxBytes: -1
    property double previousSampleMs: 0

    function formatRate(bytesPerSecond) {
        if (bytesPerSecond >= 1000000) return (bytesPerSecond / 1000000).toFixed(1) + " MB/s"
        if (bytesPerSecond >= 1000) return Math.round(bytesPerSecond / 1000) + " KB/s"
        return Math.round(bytesPerSecond) + " B/s"
    }

    readonly property var tooltipRows: {
        if (kind === "disconnected") return [{ label: label, detail: "", icon: "wifi-2" }]
        const rows = [{ label: label, detail: kind === "wifi" ? strength + "%" : "Ethernet",
                        icon: kind === "wifi" ? "wifi-2" : "link" }]
        if (linkMegabitsPerSecond > 0)
            rows.push({ label: "Link", detail: Math.round(linkMegabitsPerSecond) + " Mb/s", icon: "signal-2" })
        rows.push({ label: "Ping", detail: latencyMs >= 0 ? latencyMs.toFixed(0) + " ms" : "—", icon: "clock" })
        rows.push({ label: "Download", detail: formatRate(downloadBytesPerSecond), icon: "arrow-door-in" })
        rows.push({ label: "Upload", detail: formatRate(uploadBytesPerSecond), icon: "arrow-door-out-3" })
        return rows
    }

    implicitWidth: indicator.implicitWidth + Theme.modulePadH * 2
    implicitHeight: parent ? parent.height : Theme.barHeight

    Process {
        id: proc
        running: true
        command: ["sh", "-c",
            "dev=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}'); " +
            "type=$(nmcli -g GENERAL.TYPE device show \"$dev\" 2>/dev/null); " +
            "if [ \"$type\" = wifi ]; then " +
            "  line=$(nmcli -t -f ACTIVE,SIGNAL,SSID dev wifi 2>/dev/null | awk -F: '/^yes:/ {sig=$2; ssid=$3; for(i=4;i<=NF;i++) ssid=ssid \":\" $i; print sig \"\\n\" ssid; exit}'); " +
            "  sig=$(printf '%s\\n' \"$line\" | head -n1); label=$(printf '%s\\n' \"$line\" | tail -n +2); kind=wifi; " +
            "elif [ \"$type\" = ethernet ]; then kind=eth; sig=100; label=$dev; " +
            "else kind=none; sig=0; label=Disconnected; fi; " +
            "rx=$(cat /sys/class/net/\"$dev\"/statistics/rx_bytes 2>/dev/null || echo 0); " +
            "tx=$(cat /sys/class/net/\"$dev\"/statistics/tx_bytes 2>/dev/null || echo 0); " +
            "path=$(nmcli -g GENERAL.DBUS-PATH device show \"$dev\" 2>/dev/null); " +
            "bitrate=$(busctl --system get-property org.freedesktop.NetworkManager \"$path\" org.freedesktop.NetworkManager.Device.Wireless Bitrate 2>/dev/null | awk '{print $2}'); " +
            "latency=$(ping -n -c3 -i0.2 -W1 1.1.1.1 2>/dev/null | awk -F= '/^rtt/ {split($2, value, \"/\"); print value[2]}'); " +
            "printf 'kind=%s\\ndevice=%s\\nstrength=%s\\nlabel=%s\\nrx=%s\\ntx=%s\\nlatency=%s\\nbitrate=%s\\n' \"$kind\" \"$dev\" \"$sig\" \"$label\" \"$rx\" \"$tx\" \"$latency\" \"$bitrate\""
        ]
        stdout: StdioCollector {
            onStreamFinished: {
                const values = {}
                for (const line of this.text.trim().split("\n")) {
                    const split = line.indexOf("=")
                    if (split >= 0) values[line.substring(0, split)] = line.substring(split + 1)
                }
                const nextDevice = values.device || ""
                const now = Date.now()
                const rx = Number(values.rx || 0)
                const tx = Number(values.tx || 0)
                if (nextDevice === root.device && root.previousSampleMs > 0 && now > root.previousSampleMs) {
                    const seconds = (now - root.previousSampleMs) / 1000
                    root.downloadBytesPerSecond = Math.max(0, (rx - root.previousRxBytes) / seconds)
                    root.uploadBytesPerSecond = Math.max(0, (tx - root.previousTxBytes) / seconds)
                } else {
                    root.downloadBytesPerSecond = 0
                    root.uploadBytesPerSecond = 0
                }
                root.kind = values.kind === "wifi" ? "wifi" : values.kind === "eth" ? "eth" : "disconnected"
                root.device = nextDevice
                root.strength = Number(values.strength || 0)
                root.label = values.label || (root.kind === "disconnected" ? "Disconnected" : nextDevice)
                root.latencyMs = values.latency ? Number(values.latency) : -1
                root.linkMegabitsPerSecond = Number(values.bitrate || 0) / 1000
                root.previousRxBytes = rx
                root.previousTxBytes = tx
                root.previousSampleMs = now
            }
        }
    }

    Timer {
        interval: 5000
        repeat: true
        running: true
        onTriggered: proc.running = true
    }

    ProgressRingIcon {
        id: indicator
        anchors.centerIn: parent
        progress: root.kind === "eth" ? 1 : root.kind === "wifi" ? root.strength / 100 : 0
        iconName: root.kind === "eth" ? "plug-2"
                : root.strength > 66 ? "wifi-3"
                : root.strength > 33 ? "wifi-2" : "wifi-1"
        iconSize: 16
    }

}
