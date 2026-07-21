import test from "node:test";
import assert from "node:assert/strict";
import { patchNativeFrameSource } from "../src/patch-native-frame.mjs";
import { MARKER } from "../src/renderer-runtime-source.mjs";

const fixture = [
  "const before=1;",
  "function rt({activityCopies:e}){",
  "let ve=ae(v[0]),[ye,be]=Q.useState(null);",
  "const mascot={spriteVersionNumber:i.spriteVersionNumber,spritesheetUrl:i.spritesheetUrl,state:ve.mascotState,style:p,transientState:f};",
  'const main={"data-avatar-overlay-debug-window-border":o||void 0,children:mascot};',
  "return main}",
].join("");

const configuration = {
  endpoint: "http://127.0.0.1:49797/v1/pet",
  assets: {
    battery: {
      energetic: "battery-energetic.webp",
      normal: "battery-normal.webp",
      tired: "battery-tired.webp",
      exhausted: "battery-exhausted.webp",
    },
    "whoop-sensor-b": {
      energetic: "sensor-energetic.webp",
      normal: "sensor-normal.webp",
      tired: "sensor-tired.webp",
      exhausted: "sensor-exhausted.webp",
    },
  },
};

test("patch injects one feature-gated presentation seam", () => {
  const patched = patchNativeFrameSource(fixture, configuration);
  assert.match(patched, new RegExp(MARKER));
  assert.match(patched, /__hitwUsePresentation\(ve\.mascotState/);
  assert.match(patched, /ve\.mascotState===`review`/);
  assert.match(patched, /transientState:f\?\?/);
  assert.match(patched, /Q\.useEffect\(\(\)=>\{if\(o!=="jumping"\)/);
  assert.match(patched, /data-hitw-tier-revision/);
  assert.match(patched, /data-hitw-identity/);
  assert.match(patched, /whoop-sensor-b/);
});

test("patch refuses already-patched or structurally unknown bundles", () => {
  const patched = patchNativeFrameSource(fixture, configuration);
  assert.throws(() => patchNativeFrameSource(patched, configuration), /already patched/);
  assert.throws(() => patchNativeFrameSource("function rt({}){}", configuration), /hook anchor/);
});
