import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";
import { isolatedProofLaunchArguments } from "../src/proof-launch-arguments.mjs";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const proofRoot = path.dirname(scriptDirectory);
const artifactRoot = path.join(proofRoot, ".proof");
const manifest = JSON.parse(
  fs.readFileSync(path.join(artifactRoot, "proof-app-manifest.json"), "utf8"),
);
const executable = path.join(
  manifest.outputApp,
  "Contents",
  "MacOS",
  "ChatGPT",
);
const remoteDebuggingPort = 49799;
const delay = (milliseconds) =>
  new Promise((resolve) => setTimeout(resolve, milliseconds));

const serverLogPath = path.join(artifactRoot, "copy-transport-server.log");
const appLogPath = path.join(artifactRoot, "copy-transport-app.log");
const serverLog = fs.openSync(serverLogPath, "w");
const appLog = fs.openSync(appLogPath, "w");
const profile = fs.mkdtempSync(path.join(artifactRoot, "transport-profile-"));

const server = spawn(
  process.execPath,
  [path.join(scriptDirectory, "proof-server.mjs")],
  {
    cwd: proofRoot,
    stdio: ["ignore", serverLog, serverLog],
  },
);
const app = spawn(
  executable,
  isolatedProofLaunchArguments({ profile, remoteDebuggingPort }),
  {
    env: { ...process.env, ELECTRON_ENABLE_LOGGING: "1" },
    stdio: ["ignore", appLog, appLog],
  },
);

async function waitForUrl(url, attempts = 100) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      const response = await fetch(url);
      if (response.ok) return response;
    } catch {}
    await delay(100);
  }
  throw new Error(`Timed out waiting for ${url}`);
}

let browser;
try {
  await waitForUrl("http://127.0.0.1:49797/v1/pet");
  await waitForUrl(`http://127.0.0.1:${remoteDebuggingPort}/json/version`);
  browser = await chromium.connectOverCDP(
    `http://127.0.0.1:${remoteDebuggingPort}`,
  );

  let success = null;
  for (let attempt = 0; attempt < 50 && success == null; attempt += 1) {
    for (const context of browser.contexts()) {
      for (const page of context.pages()) {
        try {
          const value = await page.evaluate(async () => {
            const response = await fetch("http://127.0.0.1:49797/v1/pet", {
              cache: "no-store",
            });
            return {
              ok: response.ok,
              status: response.status,
              body: await response.json(),
              origin: window.location.origin,
            };
          });
          if (value.ok) {
            success = value;
            break;
          }
        } catch {}
      }
      if (success != null) break;
    }
    if (success == null) await delay(200);
  }
  if (success == null) {
    throw new Error(
      "No copied Codex renderer could fetch the HITW loopback snapshot",
    );
  }

  const result = {
    ok: true,
    copiedApp: manifest.outputApp,
    installedCodexModified: false,
    rendererOrigin: success.origin,
    responseStatus: success.status,
    responseBody: success.body,
    isolatedProfile: profile,
    appLogPath,
    serverLogPath,
  };
  const resultPath = path.join(artifactRoot, "copy-transport-proof.json");
  fs.writeFileSync(resultPath, `${JSON.stringify(result, null, 2)}\n`);
  console.log(JSON.stringify({ ...result, resultPath }, null, 2));
} finally {
  await browser?.close();
  app.kill("SIGTERM");
  server.kill("SIGTERM");
  await Promise.race([
    Promise.all([
      new Promise((resolve) => app.once("exit", resolve)),
      new Promise((resolve) => server.once("exit", resolve)),
    ]),
    delay(3000),
  ]);
  if (app.exitCode === null) app.kill("SIGKILL");
  if (server.exitCode === null) server.kill("SIGKILL");
  fs.closeSync(appLog);
  fs.closeSync(serverLog);
}
