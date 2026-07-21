import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const proofRoot = path.dirname(scriptDirectory);
const artifactRoot = path.join(proofRoot, ".proof");
fs.mkdirSync(artifactRoot, { recursive: true });

const serverLogPath = path.join(artifactRoot, "proof-server.log");
const serverLog = fs.openSync(serverLogPath, "w");
const server = spawn(process.execPath, [path.join(scriptDirectory, "proof-server.mjs")], {
  cwd: proofRoot,
  stdio: ["ignore", serverLog, serverLog],
});

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
async function waitForServer() {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    try {
      const response = await fetch("http://127.0.0.1:49797/v1/pet");
      if (response.ok) return;
    } catch {}
    await delay(100);
  }
  throw new Error("Proof server did not start");
}

let browser;
try {
  await waitForServer();
  browser = await chromium.launch({
    executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    headless: true,
  });
  const page = await browser.newPage({ viewport: { width: 1100, height: 900 } });
  await page.goto("http://127.0.0.1:49797/", { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => document.body.dataset.hitwEnabled != null);

  await page.click('button[data-snapshot*="72"]');
  await page.waitForFunction(() => document.body.dataset.hitwTier === "energetic");
  const firstRevision = await page.getAttribute("body", "data-hitw-tier-revision");

  await page.evaluate(async () => {
    await fetch("/v1/test/snapshot", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ enabled: true, charge: 70 }),
    });
  });
  await delay(250);
  const sameTierRevision = await page.getAttribute("body", "data-hitw-tier-revision");
  if (sameTierRevision !== firstRevision) {
    throw new Error("Body revision changed without crossing a tier boundary");
  }

  await page.selectOption("#lifecycle-select", "running");
  await page.waitForFunction(() => document.body.dataset.hitwLifecycle === "running");
  await page.click('button[data-snapshot*="33"]');
  await page.click("#refill");
  await page.waitForFunction(() => document.body.dataset.hitwPendingJump === "true");
  const runningEffectiveState = await page.getAttribute(
    "body",
    "data-hitw-effective-state",
  );
  if (runningEffectiveState !== "running") {
    throw new Error(
      `Refill jump obscured the Running lifecycle: ${runningEffectiveState}`,
    );
  }

  await page.selectOption("#lifecycle-select", "review");
  await page.waitForFunction(() => document.body.dataset.hitwEffectiveState === "jumping");
  const jumpScreenshot = path.join(artifactRoot, "queued-refill-jump.png");
  await page.screenshot({ path: jumpScreenshot, fullPage: true });
  await page.waitForFunction(() => document.body.dataset.hitwEffectiveState === "review", null, { timeout: 2500 });

  await page.click("#off");
  await page.waitForFunction(() => document.body.dataset.hitwEnabled === "false");
  const offScreenshot = path.join(artifactRoot, "off-stock-fallback.png");
  await page.screenshot({ path: offScreenshot, fullPage: true });

  const result = {
    ok: true,
    firstRevision,
    sameTierRevision,
    queuedWhileRunning: true,
    firedAtReady: true,
    returnedToReview: true,
    offRestoredNativePresentation: true,
    jumpScreenshot,
    offScreenshot,
    serverLogPath,
  };
  const resultPath = path.join(artifactRoot, "browser-proof.json");
  fs.writeFileSync(resultPath, `${JSON.stringify(result, null, 2)}\n`);
  console.log(JSON.stringify({ ...result, resultPath }, null, 2));
} finally {
  await browser?.close();
  server.kill("SIGTERM");
  await Promise.race([new Promise((resolve) => server.once("exit", resolve)), delay(2000)]);
  if (server.exitCode === null) server.kill("SIGKILL");
  fs.closeSync(serverLog);
}
