import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { isolatedProofLaunchArguments } from "../src/proof-launch-arguments.mjs";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const proofRoot = path.dirname(scriptDirectory);
const artifactRoot = path.join(proofRoot, ".proof");
const manifestPath = path.join(artifactRoot, "proof-app-manifest.json");
const defaultAppPath = fs.existsSync(manifestPath)
  ? JSON.parse(fs.readFileSync(manifestPath, "utf8")).outputApp
  : path.join(artifactRoot, "HITW Codex Proof.app");
const appPath = process.argv[2] ?? defaultAppPath;
const executable = path.join(appPath, "Contents", "MacOS", "ChatGPT");
if (!fs.existsSync(executable)) throw new Error(`Missing proof app: ${appPath}`);

fs.mkdirSync(artifactRoot, { recursive: true });
const profile = fs.mkdtempSync(path.join(artifactRoot, "smoke-profile-"));
const logPath = path.join(artifactRoot, "proof-app-smoke.log");
const log = fs.openSync(logPath, "w");
const child = spawn(executable, isolatedProofLaunchArguments({
  profile,
  remoteDebuggingPort: 49_798,
}), {
  detached: false,
  env: { ...process.env, ELECTRON_ENABLE_LOGGING: "1" },
  stdio: ["ignore", log, log],
});

const wait = (milliseconds) =>
  new Promise((resolve) => setTimeout(resolve, milliseconds));
await wait(12_000);
const exitedEarly = child.exitCode !== null;
if (!exitedEarly) {
  child.kill("SIGTERM");
  await Promise.race([
    new Promise((resolve) => child.once("exit", resolve)),
    wait(5_000),
  ]);
  if (child.exitCode === null) child.kill("SIGKILL");
}
fs.closeSync(log);

const output = fs.readFileSync(logPath, "utf8");
const integrityFailure = /integrity check failed|asar.*integrity/i.test(output);
const result = {
  ok: !exitedEarly && !integrityFailure,
  appPath,
  stayedAliveForSeconds: exitedEarly ? 0 : 12,
  exitedEarly,
  integrityFailure,
  logPath,
  isolatedProfile: profile,
};
console.log(JSON.stringify(result, null, 2));
if (!result.ok) process.exitCode = 1;
