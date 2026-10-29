import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

// Anthropic keeps a stalled stream alive with pings, so the HTTP idle timeout never fires.
// Prefill finishes before headers, so a silent body after them is a stall (pi#10019).
const STALL_MS = Number(process.env.PI_STALL_GUARD_MS) || 90_000;
const AFTER_HEADERS_MS = 45_000;
const MAX_RESTARTS = 3;

export default function (pi: ExtensionAPI) {
  let inTurn = false;
  let waitingSince = 0;
  let limit = STALL_MS;
  let stalled = false;
  let restarts = 0;
  let stallLimit = STALL_MS;
  let ctxRef: ExtensionContext | undefined;

  const timer = setInterval(() => {
    if (!waitingSince || stalled || !ctxRef) return;
    if (Date.now() - waitingSince < limit) return;
    try {
      if (ctxRef.isIdle()) return;
      stalled = true;
      stallLimit = limit;
      waitingSince = 0;
      ctxRef.abort();
    } catch {
      // ctx goes stale after reload, /new or session switch.
      ctxRef = undefined;
      waitingSince = 0;
    }
  }, 5_000);
  timer.unref?.();

  pi.on("turn_start", (_e, ctx) => { inTurn = true; ctxRef = ctx; });
  pi.on("turn_end", () => { inTurn = false; waitingSince = 0; });
  pi.on("before_provider_request", (_e, ctx) => {
    if (!inTurn) return;
    ctxRef = ctx;
    waitingSince = Date.now();
    limit = STALL_MS;
  });
  pi.on("after_provider_response", () => {
    if (!waitingSince) return;
    waitingSince = Date.now();
    limit = AFTER_HEADERS_MS;
  });
  pi.on("provider_stream_event", () => { if (waitingSince) { waitingSince = Date.now(); limit = STALL_MS; } });
  pi.on("message_end", (e) => {
    if (e.message.role !== "assistant") return;
    waitingSince = 0;
    if (!stalled && e.message.stopReason !== "aborted") restarts = 0;
  });
  pi.on("input", () => { restarts = 0; });
  const resume = (ctx: ExtensionContext) => {
    try {
      if (!ctx.isIdle()) { setTimeout(() => resume(ctx), 100); return; }
    } catch {
      return;
    }
    pi.sendMessage(
      {
        customType: "stall-guard",
        content: `The model stream went silent for ${Math.round(stallLimit / 1000)}s and was restarted automatically (attempt ${restarts}/${MAX_RESTARTS}). Continue exactly where you left off.`,
        display: true,
      },
      { triggerTurn: true },
    );
  };
  pi.on("agent_end", (_e, ctx) => {
    inTurn = false;
    waitingSince = 0;
    if (!stalled) return;
    stalled = false;
    if (++restarts > MAX_RESTARTS) return;
    resume(ctx);
  });
}
