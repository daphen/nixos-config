import QtQuick
import "."

Picker {
    id: root

    open: AgentAskState.inputOpen
    onCloseRequested: AgentAskState.closeInput()

    placeholder: AgentAskState.inputAsk
        ? (AgentAskState.inputAsk.title || AgentAskState.inputAsk.message || "answer")
        : "answer"
    freeText: true

    onEnterText: text => {
        const value = text.trim()
        if (!value || !AgentAskState.inputAsk) return
        AgentAskState.answer(AgentAskState.inputAsk, { value: value })
    }
}
