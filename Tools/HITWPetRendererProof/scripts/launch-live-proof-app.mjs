import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { isolatedProofLaunchArguments } from "../src/proof-launch-arguments.mjs";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const proofRoot = path.dirname(scriptDirectory);
const artifactRoot = path.join(proofRoot, ".proof");
const manifest = JSON.parse(
  fs.readFileSync(path.join(artifactRoot, "proof-app-manifest.json"), "utf8"),
);
const executable = path.join(manifest.outputApp, "Contents", "MacOS", "ChatGPT");
if (!fs.existsSync(executable)) throw new Error(`Missing proof app: ${manifest.outputApp}`);

const profile = path.join(artifactRoot, "live-whoop-profile");
const logPath = path.join(artifactRoot, "live-whoop-app.log");
const pidPath = path.join(artifactRoot, "live-whoop-app.pid");
fs.mkdirSync(profile, { recursive: true });

if (fs.existsSync(pidPath)) {
  const priorPid = Number.parseInt(fs.readFileSync(pidPath, "utf8").trim(), 10);
  if (Number.isSafeInteger(priorPid) && priorPid > 1) {
    try {
      process.kill(priorPid, 0);
      console.log(JSON.stringify({ ok: true, alreadyRunning: true, pid: priorPid, profile, logPath }, null, 2));
      process.exit(0);
    } catch {}
  }
}

const log = fs.openSync(logPath, "a");
const child = spawn(
  executable,
  isolatedProofLaunchArguments({ profile, remoteDebuggingPort: 49_801 }),
  {
    detached: true,
    env: { ...process.env, ELECTRON_ENABLE_LOGGING: "1" },
    stdio: ["ignore", log, log],
  },
);
child.unref();
fs.closeSync(log);
fs.writeFileSync(pidPath, `${child.pid}\n`);

console.log(JSON.stringify({
  ok: true,
  alreadyRunning: false,
  pid: child.pid,
  appPath: manifest.outputApp,
  profile,
  logPath,
  remoteDebuggingPort: 49_801,
  usesMockKeychain: true,
}, null, 2));
