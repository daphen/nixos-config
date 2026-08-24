import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

// A blocking question the agent raises at a decision point. In RPC mode (the
// agent rail) ctx.ui.* emits an extension_ui_request the rail renders as an
// approval card + "needs input" roster flag; in the TUI it's a native dialog.
const say = (s: string) => ({ content: [{ type: "text" as const, text: s }], details: undefined });

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "ask_user",
    label: "Ask user",
    description:
      "Ask the user a blocking question that surfaces as an approval card in the agent rail, " +
      "instead of asking in prose. kind='confirm' → yes/no (returns 'approved'/'declined'); " +
      "kind='choice' → pick one of `options` (returns the chosen string); " +
      "kind='input' → free text (returns the entry). Set `title` to the decision's heading " +
      "exactly as written in the plan (e.g. 'D1: cursor start position') so the plan buffer scrolls to it.",
    promptSnippet: "ask_user: raise a blocking decision as an approval card (use at plan decision points)",
    parameters: Type.Object({
      kind: Type.Union([Type.Literal("confirm"), Type.Literal("choice"), Type.Literal("input")]),
      title: Type.String(),
      message: Type.Optional(Type.String()),
      options: Type.Optional(Type.Array(Type.String())),
    }),
    async execute(_id: string, params: any, _signal: unknown, _onUpdate: unknown, ctx: ExtensionContext) {
      if (!ctx.hasUI) return say("No interactive UI available — ask the user in plain text instead.");
      const { kind, title, message, options } = params;
      // A question the user cannot act on is worse than no question: an input/confirm
      // card with only a terse title ("reconnect linear") renders as an inexplicable
      // blank box. Bounce it back to the agent instead of surfacing it.
      if (kind !== "choice" && (!message || message.trim().length < 20)) {
        return say(
          "ask_user rejected: `message` is required and must explain what you need — " +
          "what happened, what the user should do, and (for input) what to type. " +
          "Re-ask with a complete message, or if the user cannot act on it (e.g. an MCP " +
          "re-auth that needs a desktop pi session), report it in prose and continue without."
        );
      }
      if (kind === "confirm") {
        return say((await ctx.ui.confirm(title, message ?? title)) ? "approved" : "declined");
      }
      if (kind === "choice") {
        const opts: string[] = options ?? [];
        if (opts.length === 0) return say("No options provided.");
        const choice = await ctx.ui.select(title, opts);
        return say(choice ?? "cancelled");
      }
      const val = await ctx.ui.input(title, message);
      return say(val ?? "cancelled");
    },
  });
}
