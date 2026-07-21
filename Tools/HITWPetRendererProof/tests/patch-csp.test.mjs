import test from "node:test";
import assert from "node:assert/strict";
import {
  LOOPBACK_ORIGIN,
  patchLoopbackConnectSource,
} from "../src/patch-csp.mjs";

const fixture =
  '<meta http-equiv="Content-Security-Policy" content="default-src &#39;none&#39;; connect-src &#39;self&#39; https://example.com;">';

test("CSP patch adds only the fixed loopback proof origin", () => {
  const patched = patchLoopbackConnectSource(fixture);
  assert.match(patched, new RegExp(`connect-src &#39;self&#39; ${LOOPBACK_ORIGIN}`));
  assert.match(patched, /https:\/\/example\.com/);
});

test("CSP patch refuses missing, ambiguous, or already-patched policies", () => {
  assert.throws(() => patchLoopbackConnectSource("<html></html>"), /Missing/);
  assert.throws(
    () => patchLoopbackConnectSource(`${fixture}${fixture}`),
    /Ambiguous/,
  );
  assert.throws(
    () => patchLoopbackConnectSource(patchLoopbackConnectSource(fixture)),
    /already allows/,
  );
});
