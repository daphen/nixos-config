pragma Singleton

import QtQuick

QtObject {
  function classify(tool, args) {
    const name = String(tool || "").toLowerCase()
    if (name !== "bash" && name !== "shell") return name
    const command = String((args || {}).command || (args || {}).cmd || "")
    return /(?:<<-?\s*'?[A-Z]{2,})|(?:\bsed\s+-i)|(?:\btee\s)|(?:>>?\s*['"]?[\w~.\/-]+\.[A-Za-z]{1,4})/.test(command)
      ? "bash-write" : name
  }

  function colorFor(activity) {
    const name = String(activity || "").toLowerCase()
    if (["edit", "write", "create", "str_replace", "bash-write"].includes(name)) return Theme.green
    if (["bash", "shell"].includes(name)) return Theme.orange
    if (["read", "grep", "glob", "find", "ls", "ripgrep", "search_files"].includes(name)) return Theme.sky
    return Qt.color("#3aa0ff")
  }

  function colorsFor(activities) {
    return (activities || []).map(activity => colorFor(activity))
  }
}
