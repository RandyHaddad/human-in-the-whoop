import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  DEFAULT_CODEX_APP,
  appAsarPath,
  appInfoPlistPath,
  archiveHeaderHash,
  extractArchive,
  inspectCurrentRenderer,
  repackPreservingUnpackedLayout,
  sha256,
} from "./lib/codex-bundle.mjs";
import { patchNativeFrameSource } from "../src/patch-native-frame.mjs";
import { patchLoopbackConnectSource } from "../src/patch-csp.mjs";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const proofRoot = path.dirname(scriptDirectory);
const projectRoot = path.resolve(proofRoot, "../..");
const artifactRoot = path.join(proofRoot, ".proof");
const sourceApp = process.argv[2] ?? DEFAULT_CODEX_APP;
const inspection = inspectCurrentRenderer(sourceApp);
const outputApp = process.argv[3] ?? path.join(
  os.tmpdir(),
  `hitw-codex-proof-${inspection.build}`,
  "HITW Codex Proof.app",
);

if (!path.isAbsolute(sourceApp) || !path.isAbsolute(outputApp)) {
  throw new Error("Source and output app paths must be absolute");
}
if (fs.existsSync(outputApp)) {
  throw new Error(`Refusing to overwrite existing proof app: ${outputApp}`);
}

const petAssetRoot = path.join(projectRoot, "Assets", "HITWPets");
const familyContract = JSON.parse(
  fs.readFileSync(path.join(petAssetRoot, "family-contract.json"), "utf8"),
);
const requestedIdentityIds = new Set(
  (process.env.HITW_PET_IDENTITIES ?? familyContract.identities.map(({ id }) => id).join(","))
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean),
);
const customAssets = [];
const configuredAssets = {};
for (const identity of familyContract.identities) {
  if (!requestedIdentityIds.has(identity.id)) continue;
  configuredAssets[identity.id] = {};
  for (const [tier, relativeSource] of Object.entries(identity.tiers)) {
    const source = path.join(petAssetRoot, relativeSource);
    if (!fs.existsSync(source)) {
      throw new Error(`Missing validated HITW atlas: ${source}`);
    }
    const filename = `hitw-${identity.id}-${tier}.webp`;
    configuredAssets[identity.id][tier] = filename;
    customAssets.push({ identity: identity.id, tier, source, filename });
  }
}

const patchedSource = patchNativeFrameSource(
  inspection.sources.nativeFrame,
  {
    endpoint: "http://127.0.0.1:49797/v1/pet",
    assets: configuredAssets,
  },
);

fs.mkdirSync(artifactRoot, { recursive: true });
fs.mkdirSync(path.dirname(outputApp), { recursive: true });
execFileSync("/bin/cp", ["-cR", sourceApp, outputApp], { stdio: "inherit" });

const buildDirectory = fs.mkdtempSync(
  path.join(artifactRoot, `bundle-${inspection.build}-`),
);
let completed = false;
try {
  const copiedArchive = appAsarPath(outputApp);
  const extractedRoot = path.join(buildDirectory, "extracted");
  const repackedArchive = path.join(buildDirectory, "app.asar");
  extractArchive(copiedArchive, extractedRoot);

  const nativeFramePath = path.join(extractedRoot, inspection.nativeFrame);
  fs.writeFileSync(nativeFramePath, patchedSource);
  for (const asset of customAssets) {
    fs.copyFileSync(
      asset.source,
      path.join(extractedRoot, "webview", "assets", asset.filename),
    );
  }
  const patchedHtmlFiles = [
    "webview/index.html",
    "webview/avatar-overlay-composition-surface.html",
  ];
  for (const relativePath of patchedHtmlFiles) {
    const filePath = path.join(extractedRoot, relativePath);
    fs.writeFileSync(
      filePath,
      patchLoopbackConnectSource(fs.readFileSync(filePath, "utf8")),
    );
  }
  await repackPreservingUnpackedLayout(
    copiedArchive,
    extractedRoot,
    repackedArchive,
    customAssets.map(({ filename }) => path.join("webview", "assets", filename)),
  );

  const originalArchiveBackup = `${copiedArchive}.stock-before-hitw`;
  fs.renameSync(copiedArchive, originalArchiveBackup);
  fs.copyFileSync(repackedArchive, copiedArchive);

  const headerHash = archiveHeaderHash(copiedArchive);
  const integrity = JSON.stringify({
    "Resources/app.asar": { algorithm: "SHA256", hash: headerHash },
  });
  const plistPath = appInfoPlistPath(outputApp);
  execFileSync("/usr/bin/plutil", [
    "-replace",
    "ElectronAsarIntegrity",
    "-json",
    integrity,
    plistPath,
  ]);
  execFileSync("/usr/bin/plutil", [
    "-replace",
    "CFBundleIdentifier",
    "-string",
    "com.openai.codex.hitwproof",
    plistPath,
  ]);
  execFileSync("/usr/bin/plutil", [
    "-replace",
    "CFBundleName",
    "-string",
    "HITW Codex Proof",
    plistPath,
  ]);

  execFileSync("/usr/bin/xattr", ["-cr", outputApp]);
  for (const attribute of ["com.apple.FinderInfo", "com.apple.ResourceFork"]) {
    spawnSync("/usr/bin/xattr", ["-dr", attribute, outputApp], {
      stdio: "ignore",
    });
  }
  execFileSync("/usr/bin/codesign", [
    "--force",
    "--deep",
    "--sign",
    "-",
    "--entitlements",
    path.join(proofRoot, "resources", "proof-entitlements.plist"),
    outputApp,
  ], { stdio: "inherit" });
  execFileSync("/usr/bin/codesign", [
    "--verify",
    "--deep",
    "--strict",
    outputApp,
  ], { stdio: "inherit" });

  const manifest = {
    ok: true,
    builtAt: new Date().toISOString(),
    sourceApp,
    outputApp,
    sourceVersion: inspection.version,
    sourceBuild: inspection.build,
    requestedIdentityIds: [...requestedIdentityIds],
    nativeFrame: inspection.nativeFrame,
    patchedHtmlFiles,
    stockAssets: inspection.assets,
    customAssets: customAssets.map((asset) => ({
      identity: asset.identity,
      tier: asset.tier,
      filename: asset.filename,
      source: asset.source,
      sha256: sha256(fs.readFileSync(asset.source)),
    })),
    patchedNativeFrameSha256: sha256(patchedSource),
    appAsarHeaderHash: headerHash,
    originalArchiveBackup,
    installedCodexModified: false,
    adHocSigned: true,
  };
  const manifestPath = path.join(artifactRoot, "proof-app-manifest.json");
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  completed = true;
  console.log(JSON.stringify({ ...manifest, manifestPath }, null, 2));
} finally {
  if (completed) fs.rmSync(buildDirectory, { recursive: true, force: true });
  else console.error(`Build artifacts retained for diagnosis: ${buildDirectory}`);
}
