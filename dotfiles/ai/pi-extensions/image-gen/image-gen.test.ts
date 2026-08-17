import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { generateImages, removeImageBackground, upscaleImage } from "./index.ts";

const homes: string[] = [];
const png = Buffer.from("png bytes");

async function tempHome(): Promise<string> {
  const home = await mkdtemp(path.join(os.tmpdir(), "image-gen-"));
  homes.push(home);
  return home;
}

afterEach(async () => {
  await Promise.all(homes.splice(0).map(home => rm(home, { recursive: true, force: true })));
});

describe("generateImages", () => {
  test("shapes a generation request and saves only the decoded PNG path", async () => {
    const home = await tempHome();
    let url = "";
    let init: RequestInit | undefined;
    const fetchImpl = (async (value: string | URL | Request, request?: RequestInit) => {
      url = String(value);
      init = request;
      return new Response(JSON.stringify({ data: [{ b64_json: png.toString("base64") }] }), { status: 200 });
    }) as typeof fetch;

    const paths = await generateImages(
      { prompt: "Teal aurora gradient!", size: "1024x1024", quality: "high" },
      { apiKey: "secret-key", fetchImpl, home, now: new Date("2026-08-17T12:00:00Z") },
    );

    expect(url).toBe("https://api.openai.com/v1/images/generations");
    expect(JSON.parse(String(init?.body))).toEqual({
      model: "gpt-image-2",
      prompt: "Teal aurora gradient!",
      size: "1024x1024",
      quality: "high",
      output_format: "png",
    });
    expect(paths).toEqual([path.join(home, "Pictures/phtqs/2026-08-17/teal-aurora-gradient-1.png")]);
    expect(await readFile(paths[0])).toEqual(png);
    expect(JSON.stringify({ paths, body: init?.body })).not.toContain("secret-key");
  });

  test("keeps best-of calls as distinct files when prompts match", async () => {
    const home = await tempHome();
    const fetchImpl = (async () => new Response(
      JSON.stringify({ data: [{ b64_json: png.toString("base64") }] }),
      { status: 200 },
    )) as typeof fetch;
    const options = { apiKey: "secret-key", fetchImpl, home, now: new Date("2026-08-17T12:00:00Z") };

    const results = await Promise.all([
      generateImages({ prompt: "Same brief", quality: "high" }, options),
      generateImages({ prompt: "Same brief", quality: "high" }, options),
    ]);

    expect(results.flat().sort()).toEqual([
      path.join(home, "Pictures/phtqs/2026-08-17/same-brief-1.png"),
      path.join(home, "Pictures/phtqs/2026-08-17/same-brief-2.png"),
    ]);
  });

  test("uses multipart edits when reference images are provided", async () => {
    const home = await tempHome();
    const references = Array.from({ length: 16 }, (_, index) => path.join(home, `reference-${index + 1}.png`));
    await Promise.all(references.map(reference => writeFile(reference, png)));
    let url = "";
    let form: FormData | undefined;
    const fetchImpl = (async (value: string | URL | Request, request?: RequestInit) => {
      url = String(value);
      form = request?.body as FormData;
      return new Response(JSON.stringify({ data: [{ b64_json: png.toString("base64") }] }), { status: 200 });
    }) as typeof fetch;

    await generateImages(
      {
        prompt: "Apply the style of image 1 to the subject of image 2",
        ref_images: references,
      },
      { apiKey: "secret-key", baseUrl: "https://api.openai.com/v1/", fetchImpl, home },
    );

    expect(url).toBe("https://api.openai.com/v1/images/edits");
    expect(form?.get("model")).toBe("gpt-image-2");
    expect(form?.get("prompt")).toBe("Apply the style of image 1 to the subject of image 2");
    expect(form?.getAll("image[]")).toHaveLength(16);
    expect(form?.has("input_fidelity")).toBe(false);
  });

  test("requests real PNG transparency for image edits", async () => {
    const home = await tempHome();
    const reference = path.join(home, "mascot.png");
    await writeFile(reference, png);
    let form: FormData | undefined;
    const fetchImpl = (async (_value: string | URL | Request, request?: RequestInit) => {
      form = request?.body as FormData;
      return new Response(JSON.stringify({ data: [{ b64_json: png.toString("base64") }] }), { status: 200 });
    }) as typeof fetch;

    await generateImages(
      {
        prompt: "Preserve the mascot exactly and remove the background",
        ref_images: [reference],
        size: "1024x1024",
        quality: "high",
        background: "transparent",
      },
      { apiKey: "secret-key", fetchImpl, home },
    );

    expect(form?.get("model")).toBe("gpt-image-1.5");
    expect(form?.get("size")).toBe("1024x1024");
    expect(form?.get("quality")).toBe("high");
    expect(form?.get("background")).toBe("transparent");
    expect(form?.get("output_format")).toBe("png");
  });

  test("shapes deterministic upscale and background-removal commands", async () => {
    const home = await tempHome();
    const input = path.join(home, "mascot.png");
    await writeFile(input, png);
    const calls: Array<{ command: string; args: string[] }> = [];
    const runner = async (command: string, args: string[]) => { calls.push({ command, args }); };

    const upscaled = await upscaleImage(input, { home, runner });
    const alpha = await removeImageBackground(upscaled, { home, runner });

    expect(upscaled).toBe(path.join(home, "mascot-upscaled-4x-1.png"));
    expect(alpha).toBe(path.join(home, "mascot-upscaled-4x-1-alpha-1.png"));
    expect(calls).toEqual([
      { command: "nix", args: ["run", "nixpkgs#realesrgan-ncnn-vulkan", "--", "-i", input, "-o", upscaled, "-s", "4", "-n", "realesrgan-x4plus"] },
      { command: "nix", args: ["run", "nixpkgs#rembg", "--", "i", upscaled, alpha] },
    ]);
  });

  test("throws a bounded API error without writing a result", async () => {
    const home = await tempHome();
    const fetchImpl = (async () => new Response("bad request", { status: 400 })) as typeof fetch;
    await expect(generateImages(
      { prompt: "broken" },
      { apiKey: "secret-key", fetchImpl, home },
    )).rejects.toThrow("OpenAI Images failed (400): bad request");
  });
});
