import { describe, expect, test } from "bun:test";
import workContextWindow from "./index";

describe("Work context window", () => {
  test("reselects the current model with only its context window changed", async () => {
    let start: ((event: unknown, ctx: unknown) => Promise<void>) | undefined;
    let selected: Record<string, unknown> | undefined;
    const pi = {
      on(name: string, handler: typeof start) {
        expect(name).toBe("session_start");
        start = handler;
      },
      async setModel(model: Record<string, unknown>) {
        selected = model;
        return true;
      },
    };

    workContextWindow(pi as never);
    await start?.(
      { type: "session_start", reason: "resume" },
      {
        model: {
          provider: "openai",
          id: "gpt-6-astra",
          reasoning: true,
          contextWindow: 1_050_000,
          maxTokens: 128_000,
        },
      },
    );

    expect(selected).toEqual({
      provider: "openai",
      id: "gpt-6-astra",
      reasoning: true,
      contextWindow: 200_000,
      maxTokens: 128_000,
    });
  });

  test("does nothing without a model or when already scoped", async () => {
    let start: ((event: unknown, ctx: unknown) => Promise<void>) | undefined;
    let calls = 0;
    const pi = {
      on(_name: string, handler: typeof start) { start = handler; },
      async setModel() { calls++; return true; },
    };

    workContextWindow(pi as never);
    await start?.({ type: "session_start", reason: "resume" }, { model: undefined });
    await start?.({ type: "session_start", reason: "resume" }, { model: { contextWindow: 200_000 } });
    expect(calls).toBe(0);
  });
});
