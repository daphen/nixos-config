import QtQuick
import "."

// Countdown timers on the house Picker. Type a duration + enter to start
// ("5 tea" · "25m" · "1h10 focus" · "90s" · "1:30"); running timers list
// with live countdowns (subtitleFn ticks off TimerState.now); Ctrl+W
// cancels the selected timer.
Picker {
    open: TimerState.open
    onCloseRequested: TimerState.open = false

    placeholder: "duration + label — try “25m”, “90s”, or “5 tea”"
    freeText: true
    enterLabel: "start"
    altLabel: "Ctrl+W: cancel"
    emptyText: "no timers running"

    items: TimerState.items.map((t, i) => ({
        label: t.label || "timer", end: t.end, idx: i,
    }))
    subtitleFn: t => (t && t.end) ? TimerState.fmt(t.end - TimerState.now) : ""

    onEnterText: text => {
        const p = TimerState.parseSpec(text)
        if (p) TimerState.add(p.ms, p.label)
    }
    onDelete: item => {
        if (item && item.idx !== undefined) TimerState.cancel(item.idx)
    }
}
