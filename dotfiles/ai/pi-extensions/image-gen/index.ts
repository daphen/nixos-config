import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { mkdir, open, readFile, rm, writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import os from "node:os";
import path from "node:path";

const imageGenSchema = {
  type: "object",
  properties: {
    prompt: { type: "string", minLength: 1, description: "Describe the image to generate or the edit to apply." },
    ref_images: {
      type: "array",
      items: { type: "string" },
      minItems: 1,
      maxItems: 16,
      description: "Local image paths to edit or use as references. Pass the previous generated path when iterating.",
    },
    size: { type: "string", enum: ["auto", "1024x1024", "1536x1024", "1024x1536"] },
    quality: { type: "string", enum: ["auto", "low", "medium", "high"] },
    background: { type: "string", enum: ["auto", "opaque", "transparent"] },
  },
  required: ["prompt"],
  additionalProperties: false,
} as const;

export type ImageGenInput = {
  prompt: string;
  ref_images?: string[];
  size?: "auto" | "1024x1024" | "1536x1024" | "1024x1536";
  quality?: "auto" | "low" | "medium" | "high";
  background?: "auto" | "opaque" | "transparent";
};

type ApiImage = { b64_json?: string };
type FetchLike = typeof fetch;
type RequestOptions = {
  apiKey: string;
  baseUrl?: string;
  headers?: Record<string, string | null>;
  fetchImpl?: FetchLike;
  home?: string;
  now?: Date;
};

type CommandRunner = (command: string, args: string[], signal?: AbortSignal) => Promise<void>;

function expandPath(value: string, home: string): string {
  const clean = value.replace(/^@/, "");
  if (clean === "~") return home;
  if (clean.startsWith("~/")) return path.join(home, clean.slice(2));
  return path.resolve(clean);
}

function slug(prompt: string): string {
  const value = prompt.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 48);
  return value || "image";
}

function endpoint(baseUrl: string | undefined, edit: boolean): string {
  const base = (baseUrl || "https://api.openai.com/v1").replace(/\/$/, "");
  return `${base}/images/${edit ? "edits" : "generations"}`;
}

function requestHeaders(apiKey: string, configured?: Record<string, string | null>): Record<string, string> {
  const headers: Record<string, string> = { Authorization: `Bearer ${apiKey}` };
  for (const [key, value] of Object.entries(configured || {})) {
    if (value !== null && key.toLowerCase() !== "content-type") headers[key] = value;
  }
  return headers;
}

export async function generateImages(input: ImageGenInput, options: RequestOptions): Promise<string[]> {
  const home = options.home || os.homedir();
  const refs = (input.ref_images || []).map(value => expandPath(value, home));
  const headers = requestHeaders(options.apiKey, options.headers);
  const model = input.background === "transparent" ? "gpt-image-1.5" : "gpt-image-2";
  let body: BodyInit;

  if (refs.length) {
    const form = new FormData();
    form.set("model", model);
    form.set("prompt", input.prompt);
    form.set("size", input.size || "auto");
    form.set("quality", input.quality || "auto");
    form.set("output_format", "png");
    if (input.background) form.set("background", input.background);
    for (const ref of refs) {
      const bytes = await readFile(ref);
      form.append("image[]", new Blob([bytes], { type: "image/png" }), path.basename(ref));
    }
    body = form;
  } else {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify({
      model,
      prompt: input.prompt,
      size: input.size || "auto",
      quality: input.quality || "auto",
      output_format: "png",
      ...(input.background ? { background: input.background } : {}),
    });
  }

  const response = await (options.fetchImpl || fetch)(endpoint(options.baseUrl, refs.length > 0), {
    method: "POST",
    headers,
    body,
  });
  if (!response.ok) {
    const message = (await response.text()).slice(0, 1000);
    throw new Error(`OpenAI Images failed (${response.status}): ${message}`);
  }

  const payload = await response.json() as { data?: ApiImage[] };
  const images = (payload.data || []).map(item => item.b64_json).filter((value): value is string => Boolean(value));
  if (!images.length) throw new Error("OpenAI Images returned no image data");

  const now = options.now || new Date();
  const date = now.toISOString().slice(0, 10);
  const dir = path.join(home, "Pictures", "phtqs", date);
  await mkdir(dir, { recursive: true });
  const stem = slug(input.prompt);
  const paths: string[] = [];
  for (const image of images) {
    let number = 1;
    while (true) {
      const output = path.join(dir, `${stem}-${number}.png`);
      try {
        await writeFile(output, Buffer.from(image, "base64"), { flag: "wx" });
        paths.push(output);
        break;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
        number++;
      }
    }
  }
  return paths;
}

async function reserveSibling(input: string, suffix: string): Promise<string> {
  const parsed = path.parse(input);
  let number = 1;
  while (true) {
    const output = path.join(parsed.dir, `${parsed.name}-${suffix}-${number}.png`);
    try {
      await (await open(output, "wx")).close();
      return output;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      number++;
    }
  }
}

const runCommand: CommandRunner = (command, args, signal) => new Promise((resolve, reject) => {
  const child = spawn(command, args, { signal, stdio: ["ignore", "ignore", "pipe"] });
  let error = "";
  child.stderr.on("data", chunk => { error = (error + chunk).slice(-4000); });
  child.on("error", reject);
  child.on("close", code => code === 0 ? resolve() : reject(new Error(`${command} failed (${code}): ${error.trim()}`)));
});

export async function upscaleImage(value: string, options: { home?: string; signal?: AbortSignal; runner?: CommandRunner } = {}): Promise<string> {
  const input = expandPath(value, options.home || os.homedir());
  const output = await reserveSibling(input, "upscaled-4x");
  try {
    await (options.runner || runCommand)("nix", ["run", "nixpkgs#realesrgan-ncnn-vulkan", "--", "-i", input, "-o", output, "-s", "4", "-n", "realesrgan-x4plus"], options.signal);
    return output;
  } catch (error) {
    await rm(output, { force: true });
    throw error;
  }
}

export async function removeImageBackground(value: string, options: { home?: string; signal?: AbortSignal; runner?: CommandRunner } = {}): Promise<string> {
  const input = expandPath(value, options.home || os.homedir());
  const output = await reserveSibling(input, "alpha");
  try {
    await (options.runner || runCommand)("nix", ["run", "nixpkgs#rembg", "--", "i", input, output], options.signal);
    return output;
  } catch (error) {
    await rm(output, { force: true });
    throw error;
  }
}

export default function imageGenExtension(pi: ExtensionAPI): void {
  pi.registerTool({
    name: "image_gen",
    label: "Generate image",
    description: "Generate or edit PNG images with OpenAI gpt-image-2, using gpt-image-1.5 when true transparent output is requested because gpt-image-2 rejects transparent backgrounds. Returns local saved paths only; edits accept up to 16 ordered ref_images. input_fidelity is intentionally unsupported.",
    promptSnippet: "Generate or edit images and save them under ~/Pictures/phtqs",
    promptGuidelines: [
      "Use image_gen when the user asks to create or modify an image, and include every returned path verbatim in the final response so qstns can render it.",
    ],
    parameters: imageGenSchema as any,
    async execute(_id, input, signal, _onUpdate, ctx: ExtensionContext) {
      if (signal?.aborted) throw new Error("Image generation cancelled");
      const auth = await ctx.modelRegistry.getProviderAuth("openai");
      const apiKey = auth?.auth.apiKey;
      if (!apiKey) throw new Error("OpenAI credential is not configured in pi");
      const paths = await generateImages(input, {
        apiKey,
        baseUrl: auth.auth.baseUrl,
        headers: auth.auth.headers,
      });
      return {
        content: [{ type: "text", text: `Saved image${paths.length === 1 ? "" : "s"}:\n${paths.join("\n")}` }],
        details: { paths },
      };
    },
  });

  pi.registerTool({
    name: "image_upscale",
    label: "Upscale image",
    description: "Deterministically upscale a chosen PNG 4× with Real-ESRGAN. Use only after the user asks to polish a selected draft.",
    parameters: {
      type: "object",
      properties: { path: { type: "string", description: "Local path of the polished image to upscale." } },
      required: ["path"],
      additionalProperties: false,
    } as any,
    async execute(_id, input: { path: string }, signal) {
      const output = await upscaleImage(input.path, { signal });
      return { content: [{ type: "text", text: `Saved upscaled image:\n${output}` }], details: { paths: [output] } };
    },
  });

  pi.registerTool({
    name: "image_remove_background",
    label: "Remove image background",
    description: "Deterministically remove the background from a finished image and save a true-alpha PNG. Use only when the user explicitly asks for a cutout.",
    parameters: {
      type: "object",
      properties: { path: { type: "string", description: "Local path of the finished image to cut out." } },
      required: ["path"],
      additionalProperties: false,
    } as any,
    async execute(_id, input: { path: string }, signal) {
      const output = await removeImageBackground(input.path, { signal });
      return { content: [{ type: "text", text: `Saved transparent image:\n${output}` }], details: { paths: [output] } };
    },
  });
}
