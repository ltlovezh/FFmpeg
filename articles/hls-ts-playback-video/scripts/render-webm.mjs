import { access, mkdir } from "node:fs/promises";
import { createWriteStream } from "node:fs";
import { once } from "node:events";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(here, "..");
const input = resolve(projectRoot, "index.html");
const output = resolve(projectRoot, "renders", "hls-ts-playback.webm");
const require = createRequire(import.meta.url);
const { chromium } = require("/Users/leon/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright");

await mkdir(dirname(output), { recursive: true });

async function firstExisting(paths) {
  for (const candidate of paths) {
    if (!candidate)
      continue;
    try {
      await access(candidate);
      return candidate;
    } catch {
      // Try the next browser path.
    }
  }
  return undefined;
}

const executablePath = await firstExisting([
  process.env.CHROME_PATH,
  "/Users/leon/.cache/puppeteer/chrome-headless-shell/mac_arm-131.0.6778.204/chrome-headless-shell-mac-arm64/chrome-headless-shell",
  "/Users/leon/.cache/puppeteer/chrome-headless-shell/mac_arm-126.0.6478.126/chrome-headless-shell-mac-arm64/chrome-headless-shell",
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
]);

const browser = await chromium.launch({
  headless: true,
  executablePath,
  args: [
    "--autoplay-policy=no-user-gesture-required",
    "--disable-background-timer-throttling",
    "--disable-renderer-backgrounding",
    "--disable-backgrounding-occluded-windows"
  ]
});

try {
  const page = await browser.newPage({
    viewport: { width: 1920, height: 1080 },
    deviceScaleFactor: 1
  });
  await page.goto(pathToFileURL(input).href, { waitUntil: "load" });
  await page.waitForFunction(() => typeof window.__recordTeachingVideo === "function");
  const duration = await page.evaluate(() => window.__HLS_TS_VIDEO_DURATION);
  console.log(`Rendering ${duration}s WebM from ${input}`);

  const outputStream = createWriteStream(output);
  let bytesWritten = 0;
  await page.exposeFunction("__writeVideoChunk", async (base64) => {
    const chunk = Buffer.from(base64, "base64");
    bytesWritten += chunk.length;
    if (!outputStream.write(chunk))
      await once(outputStream, "drain");
  });

  await page.evaluate(async () => {
    const canvas = document.getElementById("stage");
    const duration = window.__HLS_TS_VIDEO_DURATION;
    const fps = 24;
    window.__renderFrame(0);
    const mimeTypes = [
      "video/webm;codecs=vp9",
      "video/webm;codecs=vp8",
      "video/webm"
    ];
    const mimeType = mimeTypes.find((m) => MediaRecorder.isTypeSupported(m)) || "";
    const stream = canvas.captureStream(fps);
    const recorder = new MediaRecorder(stream, mimeType ? {
      mimeType,
      videoBitsPerSecond: 4000000
    } : {
      videoBitsPerSecond: 4000000
    });

    function toBase64(bytes) {
      let binary = "";
      const step = 0x8000;
      for (let i = 0; i < bytes.length; i += step) {
        binary += String.fromCharCode(...bytes.subarray(i, i + step));
      }
      return btoa(binary);
    }

    let writeChain = Promise.resolve();
    recorder.ondataavailable = (event) => {
      if (!event.data || !event.data.size)
        return;
      writeChain = writeChain.then(async () => {
        const bytes = new Uint8Array(await event.data.arrayBuffer());
        await window.__writeVideoChunk(toBase64(bytes));
      });
    };

    const done = new Promise((resolve) => {
      recorder.onstop = async () => {
        await writeChain;
        resolve();
      };
    });
    const start = performance.now();
    const timer = setInterval(() => {
      const elapsed = (performance.now() - start) / 1000;
      window.__renderFrame(Math.min(elapsed, duration));
      if (elapsed >= duration) {
        clearInterval(timer);
        window.__renderFrame(duration);
        recorder.stop();
        stream.getTracks().forEach((track) => track.stop());
      }
    }, 1000 / fps);
    recorder.start(1000);
    await done;
  });

  await new Promise((resolve, reject) => {
    outputStream.once("error", reject);
    outputStream.end(resolve);
  });
  console.log(`Wrote ${output} (${bytesWritten} bytes)`);
} finally {
  await browser.close();
}
