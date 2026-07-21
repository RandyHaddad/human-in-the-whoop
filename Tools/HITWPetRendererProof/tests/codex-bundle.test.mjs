import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { createPackage, extractFile, listPackage } from "@electron/asar";
import {
  extractArchive,
  repackPreservingUnpackedLayout,
} from "../scripts/lib/codex-bundle.mjs";

test("repacker includes explicit new renderer assets without dropping existing files", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "hitw-asar-test-"));
  try {
    const source = path.join(root, "source");
    const extracted = path.join(root, "extracted");
    const original = path.join(root, "original.asar");
    const repacked = path.join(root, "repacked.asar");
    const assetDirectory = path.join(source, "webview", "assets");
    fs.mkdirSync(assetDirectory, { recursive: true });
    fs.writeFileSync(path.join(assetDirectory, "existing.txt"), "existing");
    await createPackage(source, original);

    extractArchive(original, extracted);
    fs.writeFileSync(
      path.join(extracted, "webview", "assets", "hitw-new.txt"),
      "custom",
    );
    await repackPreservingUnpackedLayout(original, extracted, repacked, [
      path.join("webview", "assets", "hitw-new.txt"),
    ]);

    const entries = listPackage(repacked, { isPack: false });
    assert.ok(entries.includes("/webview/assets/existing.txt"));
    assert.ok(entries.includes("/webview/assets/hitw-new.txt"));
    assert.equal(
      extractFile(repacked, "webview/assets/existing.txt").toString("utf8"),
      "existing",
    );
    assert.equal(
      extractFile(repacked, "webview/assets/hitw-new.txt").toString("utf8"),
      "custom",
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
