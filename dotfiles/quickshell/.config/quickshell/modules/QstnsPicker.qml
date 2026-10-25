import QtQuick
import Qstns as Qstns
import "."

Picker {
    id: root
    open: Qstns.State.open
    Connections { target: Qstns.State; function onResetPickerRequested() { root.tab = 0 } }
    tabs: ["New chat", "Image", "Search"]
    placeholder: tab === 0 ? "What do you want to talk about?"
                 : tab === 1 ? "What do you want to make?" : "Search chats…"
    freeText: tab !== 2
    filterItemsWithQuery: tab === 2
    listVisible: tab === 2 || (tab === 1 && Qstns.State.imageReferenceItems.length > 0)
                 || (tab === 0 && Qstns.State.contextItems.length > 0)
    tabsBottomPadding: 14
    animateHeight: true
    animatePlaceholder: true
    items: tab === 0 ? Qstns.State.contextItems : (tab === 1 ? Qstns.State.imageReferenceItems : Qstns.State.pickerItems)
    onItemsChanged: resetList()
    subtitleField: "searchText"
    subtitleFn: item => item.preview
    detailField: "detail"
    previewField: "image"
    thumbSize: 56
    detailRowHeight: 220
    trailingField: "when"
    emptyText: tab === 2 ? "no chats found" : "type a prompt and press Enter"
    enterLabel: tab === 2 ? "open" : (tab === 1 ? "create" : "start")
    navHint: tab === 2
    altLabel: tab === 2 ? "Ctrl+W: delete"
              : tab === 1 ? (Qstns.State.imageReferences.length ? "Ctrl+V: reference · Ctrl+W: remove" : "Ctrl+V: reference") : ""
    onDelete: item => {
        if (tab === 2 && item && item.id) Qstns.State.agentd.stopSession(item.id)
        else if (tab === 1 && item) Qstns.State.removeImageReference(item.referenceIndex)
    }
    onPaste: tab === 1 ? function() { Qstns.State.pasteImageReference() } : null
    onEnterText: text => tab === 1 ? Qstns.State.startImage(text) : Qstns.State.startConversation(text)
    onEnter: item => Qstns.State.openConversation(item.id)
    onCloseRequested: {
        Qstns.State.open = false
        Qstns.State.pendingContext = ""
        Qstns.State.imageReferences = []
    }
}
