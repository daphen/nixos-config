import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const WORK_CONTEXT_WINDOW = 200_000;

export default function workContextWindow(pi: ExtensionAPI) {
  let applying = false;

  async function scopeModel(model: Parameters<typeof pi.setModel>[0] | undefined) {
    if (!model || model.contextWindow === WORK_CONTEXT_WINDOW || applying) return;
    applying = true;
    try {
      const accepted = await pi.setModel({ ...model, contextWindow: WORK_CONTEXT_WINDOW });
      if (!accepted) throw new Error("failed to apply the Work context window");
    } finally {
      applying = false;
    }
  }

  pi.on("session_start", async (_event, ctx) => scopeModel(ctx.model));
  pi.on("model_select", async (event) => scopeModel(event.model));
}
