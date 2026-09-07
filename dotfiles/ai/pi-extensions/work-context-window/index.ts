import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const WORK_CONTEXT_WINDOW = 200_000;

export default function workContextWindow(pi: ExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => {
    if (!ctx.model || ctx.model.contextWindow === WORK_CONTEXT_WINDOW) return;

    const accepted = await pi.setModel({
      ...ctx.model,
      contextWindow: WORK_CONTEXT_WINDOW,
    });
    if (!accepted) throw new Error("failed to apply the Work context window");
  });
}
