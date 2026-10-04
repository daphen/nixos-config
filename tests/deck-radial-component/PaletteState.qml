pragma Singleton
import QtQuick

QtObject {
    property bool open: false
    property var tabs: []
    property var quickmarks: []
    property var currentTabId: null
    property string lastActivated: ""
    property var activationHistory: []
    signal radialRequested(string action, int value)
    function hide() { open = false }
    function activateTab(tabId, windowId) {
        lastActivated = String(tabId)
        activationHistory = activationHistory.concat(lastActivated)
    }
    function gotoUrl(url, newTab) { open = false }
    function closeTab(tabId) {}
}
