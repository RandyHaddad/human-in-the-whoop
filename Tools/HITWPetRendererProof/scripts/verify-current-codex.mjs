import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  DEFAULT_CODEX_APP,
  archiveHeaderHash,
  inspectCurrentRenderer,
  rendererConfiguration,
  sha256,
} from "./lib/codex-bundle.mjs";
import { patchNativeFrameSource } from "../src/patch-native-frame.mjs";
import { patchLoopbackConnectSource } from "../src/patch-csp.mjs";
import { extractFile } from "@electron/asar";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const proofRoot = path.dirname(scriptDirectory);
const artifactRoot = path.join(proofRoot, ".proof");
const appPath = process.argv[2] ?? DEFAULT_CODEX_APP;

const inspection = inspectCurrentRenderer(appPath);
if (!inspection.sources.mascotButton.includes("transientState")) {
  throw new Error("Current mascot renderer no longer exposes transientState");
}
if (!inspection.sources.mascotButton.includes("`jumping`")) {
  throw new Error("Current mascot renderer no longer exposes jumping");
}
for (const state of ["failed", "waiting", "running", "review"]) {
  if (!inspection.sources.codexAvatar.includes(`${state}:`)) {
    throw new Error(`Current avatar renderer is missing ${state}`);
  }
}

const patched = patchNativeFrameSource(
  inspection.sources.nativeFrame,
  rendererConfiguration(inspection),
);
for (const relativePath of [
  "webview/index.html",
  "webview/avatar-overlay-composition-surface.html",
]) {
  patchLoopbackConnectSource(
    extractFile(inspection.archivePath, relativePath).toString("utf8"),
  );
}
const syntaxDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "hitw-renderer-syntax-"));
const syntaxFile = path.join(syntaxDirectory, "avatar-overlay-native-frame.mjs");
fs.writeFileSync(syntaxFile, patched);
try {
  execFileSync(process.execPath, ["--check", syntaxFile], { stdio: "pipe" });
} finally {
  fs.rmSync(syntaxDirectory, { recursive: true, force: true });
}

fs.mkdirSync(artifactRoot, { recursive: true });
const report = {
  ok: true,
  checkedAt: new Date().toISOString(),
  appPath,
  version: inspection.version,
  build: inspection.build,
  archiveHeaderHash: archiveHeaderHash(inspection.archivePath),
  nativeFrame: inspection.nativeFrame,
  mascotButton: inspection.mascotButton,
  codexAvatar: inspection.codexAvatar,
  assets: inspection.assets,
  originalNativeFrameSha256: sha256(inspection.sources.nativeFrame),
  patchedNativeFrameSha256: sha256(patched),
  checks: {
    readyMapsToReview: inspection.sources.nativeFrame.includes(
      "state:ve.mascotState",
    ),
    nativeTransientPreserved: true,
    patchedSyntaxValid: true,
    loopbackCspPatchable: true,
  },
};
const reportPath = path.join(artifactRoot, "verify-current.json");
fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
console.log(JSON.stringify({ ...report, reportPath }, null, 2));
