import { describe, expect, mock, test } from "bun:test";

mock.module("typebox", () => ({
  Type: {
    Object: (value: unknown) => value,
    String: () => ({}),
    Integer: () => ({}),
    Optional: (value: unknown) => value,
  },
}));
const { default: openInNvimExtension } = await import("./index.ts");

describe("open_in_nvim", () => {
  test("registers through the default extension entrypoint and returns the requested location", async () => {
    let tool: any;
    openInNvimExtension({ registerTool: (value: any) => { tool = value; } } as any);

    expect(tool.name).toBe("open_in_nvim");
    const result = await tool.execute("call", { path: "src/hash.ts", line: 42, column: 7 });
    expect(result.details).toEqual({ path: "src/hash.ts", line: 42, column: 7 });
  });

  test("rejects an empty path", async () => {
    let tool: any;
    openInNvimExtension({ registerTool: (value: any) => { tool = value; } } as any);
    await expect(tool.execute("call", { path: "  " })).rejects.toThrow("path is required");
  });
});
