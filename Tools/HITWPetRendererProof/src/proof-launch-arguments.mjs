export function isolatedProofLaunchArguments({
  profile,
  remoteDebuggingPort,
}) {
  if (typeof profile !== "string" || profile.length === 0) {
    throw new TypeError("profile must be a non-empty string");
  }
  if (
    !Number.isInteger(remoteDebuggingPort) ||
    remoteDebuggingPort < 1 ||
    remoteDebuggingPort > 65_535
  ) {
    throw new TypeError("remoteDebuggingPort must be a valid port");
  }

  return Object.freeze([
    `--user-data-dir=${profile}`,
    `--remote-debugging-port=${remoteDebuggingPort}`,
    // The proof app is ad-hoc signed and must never request access to the
    // installed Codex application's "Codex Storage Key" Keychain item.
    "--use-mock-keychain",
  ]);
}
