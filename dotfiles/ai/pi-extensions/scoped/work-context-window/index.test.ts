import { describe, expect, test } from "bun:test";
import workContextWindow from "./index";

function registeredExtension() {
  const handlers: Record<string, (event: any, ctx: any) => Promise<void>> = {};
  const selected: Record<string, unknown>[] = [];
  const pi = {
    on(name: string, handler: (event: any, ctx: any) => Promise<void>) { handlers[name] = handler; },
    async setModel(model: Record<string, unknown>) {
      selected.push(model);
      await handlers.model_select?.({ type: "model_select", model, source: "set" }, {});
      return true;
    },
  };
  workContextWindow(pi as never);
  return { handlers, selected };
}

const astra = {
  provider: "openai",
  id: "gpt-6-astra",
  reasoning: true,
  contextWindow: 1_050_000,
  maxTokens: 128_000,
};

describe("Work context window", () => {
  test("reselects the startup model with only its context window changed", async () => {
    const { handlers, selected } = registeredExtension();
    await handlers.session_start({ type: "session_start", reason: "resume" }, { model: astra });
    expect(selected).toEqual([{ ...astra, contextWindow: 200_000 }]);
  });

  test("reapplies the scope after model restore without recursion", async () => {
    const { handlers, selected } = registeredExtension();
    await handlers.model_select({ type: "model_select", model: astra, source: "restore" }, {});
    expect(selected).toEqual([{ ...astra, contextWindow: 200_000 }]);
  });

  test("does nothing without a model or when already scoped", async () => {
    const { handlers, selected } = registeredExtension();
    await handlers.session_start({ type: "session_start", reason: "resume" }, { model: undefined });
    await handlers.model_select({ type: "model_select", model: { ...astra, contextWindow: 200_000 }, source: "set" }, {});
    expect(selected).toEqual([]);
  });
});
