import test from "node:test";
import assert from "node:assert/strict";
import { isolatedProofLaunchArguments } from "../src/proof-launch-arguments.mjs";

test("isolated copied-app launches cannot access the user's Keychain", () => {
  assert.deepEqual(
    isolatedProofLaunchArguments({
      profile: "/private/tmp/hitw-proof-profile",
      remoteDebuggingPort: 49_799,
    }),
    [
      "--user-data-dir=/private/tmp/hitw-proof-profile",
      "--remote-debugging-port=49799",
      "--use-mock-keychain",
    ],
  );
});

test("isolated copied-app launch arguments reject invalid inputs", () => {
  assert.throws(
    () =>
      isolatedProofLaunchArguments({
        profile: "",
        remoteDebuggingPort: 49_799,
      }),
    /profile/,
  );
  assert.throws(
    () =>
      isolatedProofLaunchArguments({
        profile: "/tmp/a",
        remoteDebuggingPort: 0,
      }),
    /port/,
  );
});
