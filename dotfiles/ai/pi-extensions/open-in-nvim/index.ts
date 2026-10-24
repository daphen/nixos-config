import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "open_in_nvim",
    label: "Open in Neovim",
    description:
      "Open and focus a file in the Cockpit Neovim showing this agent session. " +
      "Use when the user asks to see, show, or open a file or a change you discussed. " +
      "Resolve the relevant path and changed line from the conversation yourself; the user does not need to provide them. " +
      "Accepts repository-relative, absolute, mirrored remote, and notes-vault paths. " +
      "The Cockpit editor has three tabs, each with its own per-session state: " +
      "Code live-follows your edits (and keeps the last edited file while the user is elsewhere); " +
      "Dashboard is the session overview and never changes on its own; " +
      "Vault is the user's notes vault, static, remembering the note they last had open (first visit opens the session plan). " +
      "This tool switches to the right tab itself: vault paths open in Vault, everything else in Code. " +
      "Edits to vault files never move any tab, so open a plan or note explicitly when the user should see it.",
    promptSnippet: "open_in_nvim: show a requested file or change in this session's Cockpit Neovim",
    parameters: Type.Object({
      path: Type.String({ description: "File to open, relative to this session's cwd or absolute" }),
      line: Type.Optional(Type.Integer({ minimum: 1, description: "One-based line to reveal" })),
      column: Type.Optional(Type.Integer({ minimum: 1, description: "One-based column to reveal" })),
    }),
    async execute(_id: string, params: any) {
      const path = String(params.path || "").trim();
      if (!path) throw new Error("path is required");
      const line = Number.isInteger(params.line) && params.line > 0 ? params.line : 1;
      const column = Number.isInteger(params.column) && params.column > 0 ? params.column : 1;
      return {
        content: [{ type: "text" as const, text: `Requested ${path}:${line}:${column} in this session's Neovim` }],
        details: { path, line, column },
      };
    },
  });
}
