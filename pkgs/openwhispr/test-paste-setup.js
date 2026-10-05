const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

async function check(source, isWlroots, hasWtype, expectedDialogs, expectedYdotoolChecks) {
  let dialogs = 0;
  let ydotoolChecks = 0;
  const module = { exports: {} };
  vm.runInNewContext(source, {
    module,
    process: { platform: "linux", env: { XDG_SESSION_TYPE: "wayland" } },
    require(name) {
      switch (name) {
        case "fs": return { constants: { W_OK: 2 }, existsSync: () => false, accessSync() { throw Error("not accessible"); } };
        case "os": return { homedir: () => "/home/test" };
        case "electron": return { dialog: { showMessageBox() { dialogs++; } } };
        case "./linuxSession": return { getLinuxSessionInfo: () => ({ isWlroots }) };
        case "./debugLogger": return { debug() {}, info() {}, warn() {} };
        case "child_process": return { spawnSync(command, args) {
          if (command === "which" && args[0] === "wtype") return { status: hasWtype ? 0 : 1 };
          if (command === "which" && args[0] === "ydotool") ydotoolChecks++;
          return { status: 1, stdout: Buffer.from("") };
        } };
        default: throw Error(`Unexpected dependency: ${name}`);
      }
    },
  });
  await module.exports.ensureYdotool();
  assert.equal(dialogs, expectedDialogs);
  assert.equal(ydotoolChecks, expectedYdotoolChecks);
}

(async () => {
  const source = fs.readFileSync(process.argv[2], "utf8");
  await check(source, true, true, 0, 0);
  await check(source, true, false, 1, 1);
  await check(source, false, true, 1, 1);
  console.log("Paste setup: wtype path quiet; missing-tool and non-wlroots warnings preserved");
})().catch(error => { console.error(error); process.exitCode = 1; });
