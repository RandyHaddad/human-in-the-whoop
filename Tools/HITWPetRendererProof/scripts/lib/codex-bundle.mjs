import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import {
  createPackageFromStreams,
  extractAll,
  extractFile,
  getRawHeader,
  listPackage,
} from "@electron/asar";

export const DEFAULT_CODEX_APP = "/Applications/ChatGPT.app";
export const NATIVE_FRAME_PATTERN =
  /^\/webview\/assets\/avatar-overlay-native-frame-[^/]+\.js$/;
export const MASCOT_BUTTON_PATTERN =
  /^\/webview\/assets\/avatar-mascot-button-[^/]+\.js$/;
export const CODEX_AVATAR_PATTERN =
  /^\/webview\/assets\/codex-avatar-[^/]+\.js$/;

export function appAsarPath(appPath) {
  return path.join(appPath, "Contents", "Resources", "app.asar");
}

export function appInfoPlistPath(appPath) {
  return path.join(appPath, "Contents", "Info.plist");
}

export function plistValue(appPath, key) {
  return execFileSync("/usr/bin/plutil", [
    "-extract",
    key,
    "raw",
    "-o",
    "-",
    appInfoPlistPath(appPath),
  ], { encoding: "utf8" }).trim();
}

export function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

export function archiveHeaderHash(archivePath) {
  return sha256(getRawHeader(archivePath).headerString);
}

export function uniqueArchiveEntry(entries, pattern, label) {
  const matches = entries.filter((entry) => pattern.test(entry));
  if (matches.length !== 1) {
    throw new Error(`Expected one ${label}; found ${matches.length}`);
  }
  return matches[0].slice(1);
}

export function uniqueAsset(entries, prefix) {
  const pattern = new RegExp(
    `^/webview/assets/${prefix}-spritesheet-[^/]+\\.webp$`,
  );
  return path.basename(uniqueArchiveEntry(entries, pattern, `${prefix} asset`));
}

export function inspectCurrentRenderer(appPath = DEFAULT_CODEX_APP) {
  const archivePath = appAsarPath(appPath);
  const entries = listPackage(archivePath, { isPack: false });
  const nativeFrame = uniqueArchiveEntry(
    entries,
    NATIVE_FRAME_PATTERN,
    "native avatar frame",
  );
  const mascotButton = uniqueArchiveEntry(
    entries,
    MASCOT_BUTTON_PATTERN,
    "avatar mascot button",
  );
  const codexAvatar = uniqueArchiveEntry(
    entries,
    CODEX_AVATAR_PATTERN,
    "Codex avatar renderer",
  );

  return {
    appPath,
    archivePath,
    version: plistValue(appPath, "CFBundleShortVersionString"),
    build: plistValue(appPath, "CFBundleVersion"),
    entries,
    nativeFrame,
    mascotButton,
    codexAvatar,
    sources: {
      nativeFrame: extractFile(archivePath, nativeFrame).toString("utf8"),
      mascotButton: extractFile(archivePath, mascotButton).toString("utf8"),
      codexAvatar: extractFile(archivePath, codexAvatar).toString("utf8"),
    },
    assets: {
      energetic: uniqueAsset(entries, "codex"),
      normal: uniqueAsset(entries, "dewey"),
      tired: uniqueAsset(entries, "seedy"),
      exhausted: uniqueAsset(entries, "rocky"),
    },
  };
}

export function rendererConfiguration(inspection) {
  return {
    endpoint: "http://127.0.0.1:49797/v1/pet",
    assets: {
      battery: inspection.assets,
      "whoop-sensor-b": inspection.assets,
    },
  };
}

export function extractArchive(archivePath, destination) {
  extractAll(archivePath, destination);
}

function collectStreams(headerNode, extractedRoot, relativeParent = "") {
  const streams = [];
  for (const [name, entry] of Object.entries(headerNode.files ?? {})) {
    const relativePath = path.join(relativeParent, name);
    const diskPath = path.join(extractedRoot, relativePath);
    const unpacked = entry.unpacked === true;

    if (entry.files != null) {
      streams.push({ type: "directory", path: relativePath, unpacked });
      streams.push(...collectStreams(entry, extractedRoot, relativePath));
      continue;
    }

    const stat = fs.lstatSync(diskPath);
    if (entry.link != null) {
      streams.push({
        type: "link",
        path: relativePath,
        unpacked,
        stat,
        symlink: entry.link,
        streamGenerator: () => fs.createReadStream(diskPath),
      });
      continue;
    }

    streams.push({
      type: "file",
      path: relativePath,
      unpacked,
      stat,
      streamGenerator: () => fs.createReadStream(diskPath),
    });
  }
  return streams;
}

export async function repackPreservingUnpackedLayout(
  originalArchivePath,
  extractedRoot,
  destinationArchivePath,
  additionalRelativePaths = [],
) {
  const { header } = getRawHeader(originalArchivePath);
  const streams = collectStreams(header, extractedRoot);
  const existingPaths = new Set(streams.map((stream) => stream.path));
  for (const relativePath of additionalRelativePaths) {
    const normalized = path.normalize(relativePath);
    if (
      normalized !== relativePath ||
      path.isAbsolute(relativePath) ||
      normalized.startsWith(`..${path.sep}`) ||
      existingPaths.has(normalized)
    ) {
      throw new Error(`Refusing unsafe or duplicate ASAR addition: ${relativePath}`);
    }
    const diskPath = path.join(extractedRoot, normalized);
    const stat = fs.lstatSync(diskPath);
    if (!stat.isFile()) {
      throw new Error(`ASAR addition must be a regular file: ${relativePath}`);
    }
    streams.push({
      type: "file",
      path: normalized,
      unpacked: false,
      stat,
      streamGenerator: () => fs.createReadStream(diskPath),
    });
    existingPaths.add(normalized);
  }
  await createPackageFromStreams(destinationArchivePath, streams);
}

export function extractAssetBuffer(inspection, assetName) {
  return extractFile(
    inspection.archivePath,
    `webview/assets/${inspection.assets[assetName]}`,
  );
}
