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
      '      if (phase === "cancel") {\n        this.sendCancelActiveDictation();\n        return;\n      }\n' +
      "      if (this.isDictationProcessing()) {\n        return;\n      }\n\n      const activationMode = this.getActivationMode();",
  },
];

for (const { file, from, to } of edits) {
  const target = path.join(work, file);
  const source = fs.readFileSync(target, "utf8");
  if (source.split(from).length !== 2) throw new Error(`${file}: anchor not found exactly once: ${from.slice(0, 60)}`);
  fs.writeFileSync(target, source.replace(from, to));
}
