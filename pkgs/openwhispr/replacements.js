// Exact-once source edits for files a unified diff can't carry well (minified bundles) or that
// need to change in step with them. The build fails if any anchor is missing or duplicated.
const fs = require("fs");
const path = require("path");

const work = process.argv[2];

const edits = [
  {
    // The renderer only reports the mic level while the assistant panel is open; the orb needs it during dictation.
    file: "src/dist/assets/index-ByWBFLRu.js",
    from: "!l&&z?.current&&window.electronAPI?.dictationAudioLevelChanged?.(e)",
    to: "!l&&window.electronAPI?.dictationAudioLevelChanged?.(e)",
  },
  {
    // External-hotkey mode: our Hyprland config owns the binds, so the app must not edit hyprland.lua.
    file: "src/helpers/hyprlandShortcut.js",
    from: "  _ensureSourceInMainConfig(config) {\n",
    to: '  _ensureSourceInMainConfig(config) {\n    if (process.env.OPENWHISPR_EXTERNAL_HOTKEY === "1") return true;\n',
  },
  {
    file: "src/helpers/hyprlandShortcut.js",
    from: '          PttUp: () => {\n            if (this.callback) {\n              this.callback(undefined, "up");\n            }\n          },\n',
    to:
      '          PttUp: () => {\n            if (this.callback) {\n              this.callback(undefined, "up");\n            }\n          },\n' +
      '          Cancel: () => {\n            if (this.callback) {\n              this.callback(undefined, "cancel");\n            }\n          },\n',
  },
  {
    file: "src/helpers/hyprlandShortcut.js",
    from: '            PttUp: ["", ""],\n',
    to: '            PttUp: ["", ""],\n            Cancel: ["", ""],\n',
  },
  {
    // Cancel discards a recording or a transcript still processing, like the app's own pill cancel.
    file: "src/helpers/windowManager.js",
    from: "      if (this.isDictationProcessing()) {\n        return;\n      }\n\n      const activationMode = this.getActivationMode();",
    to:
      '      if (phase === "cancel") {\n' +
      "        if (this.winPushState?.safetyTimeoutId) clearTimeout(this.winPushState.safetyTimeoutId);\n" +
      "        this.winPushState = null;\n" +
      "        this.sendCancelActiveDictation();\n        return;\n      }\n" +
      "      if (this.isDictationProcessing()) {\n        return;\n      }\n\n      const activationMode = this.getActivationMode();",
  },
  {
    // Hyprland's toggle is the key press itself; the push-to-talk hold debounce only delays the mic.
    file: "src/helpers/windowManager.js",
    from: "    const MIN_HOLD_DURATION_MS = 150;\n    const MAX_PUSH_DURATION_MS = 300000;\n    const downTime = Date.now();\n\n    this.showDictationPanel({ reposition: true });",
    to: '    const MIN_HOLD_DURATION_MS = process.env.OPENWHISPR_EXTERNAL_HOTKEY === "1" ? 0 : 150;\n    const MAX_PUSH_DURATION_MS = 300000;\n    const downTime = Date.now();\n\n    this.showDictationPanel({ reposition: true });',
  },
  {
    // The renderer starts sending audio before it asks main to connect; keep those first frames instead of dropping them.
    file: "src/helpers/ipcHandlers.js",
    from: '    ipcMain.on("dictation-realtime-send", (_event, buffer) => {\n      this._dictationStreaming?.sendAudio(Buffer.from(buffer));\n    });',
    to:
      '    ipcMain.on("dictation-realtime-send", (_event, buffer) => {\n' +
      "      if (this._dictationStreaming) {\n        this._dictationStreaming.sendAudio(Buffer.from(buffer));\n        return;\n      }\n" +
      "      const early = (this._dictationEarlyAudio ||= []);\n" +
      "      if (early.reduce((sum, frame) => sum + frame.data.length, 0) < 96000) early.push({ at: Date.now(), data: Buffer.from(buffer) });\n" +
      "    });",
  },
  {
    file: "src/helpers/ipcHandlers.js",
    from: "        streaming.beginConnecting();\n        this._dictationStreaming = streaming;",
    to:
      "        streaming.beginConnecting();\n" +
      "        for (const frame of this._dictationEarlyAudio || []) {\n" +
      "          if (Date.now() - frame.at < 1500) streaming.sendAudio(frame.data);\n" +
      "        }\n" +
      "        this._dictationEarlyAudio = [];\n" +
      "        this._dictationStreaming = streaming;",
  },
  {
    file: "src/helpers/ipcHandlers.js",
    from: '    ipcMain.handle("dictation-realtime-stop", async () => {\n      clearDictationIdleTimer();',
    to: '    ipcMain.handle("dictation-realtime-stop", async () => {\n      this._dictationEarlyAudio = [];\n      clearDictationIdleTimer();',
  },
];

for (const { file, from, to } of edits) {
  const target = path.join(work, file);
  const source = fs.readFileSync(target, "utf8");
  if (source.split(from).length !== 2) throw new Error(`${file}: anchor not found exactly once: ${from.slice(0, 60)}`);
  fs.writeFileSync(target, source.replace(from, to));
}
