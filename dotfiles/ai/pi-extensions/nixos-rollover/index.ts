import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import os from "node:os";
import path from "node:path";
import checkpoint from "../scoped/no-summary-rollover/index.ts";
import contextWindow from "../scoped/work-context-window/index.ts";

export default function nixosRollover(pi: ExtensionAPI) {
  if (process.cwd() !== path.join(os.homedir(), "nixos")) return;
  checkpoint(pi);
  contextWindow(pi);
}
