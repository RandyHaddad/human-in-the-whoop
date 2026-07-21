# Native Codex pet renderer feasibility proof

This local tool proves the narrow renderer mechanics needed to present Human in the Whoop state through the native Codex pet. It operates only on an isolated copy of the current Codex application. It never modifies `/Applications/ChatGPT.app`, the Human in the Whoop Charge ledger, WHOOP data, or Codex prompt state.

This is a feasibility proof, not the finished pet integration. Its tier bodies deliberately reuse complete native Codex v2 atlases so every lifecycle row remains valid while renderer behavior is tested. The final energetic, normal, tired, and exhausted artwork—especially the readable collapsed body—remains a separate asset and visual-QA deliverable.

## Preserved boundaries

- Codex owns lifecycle state. WHOOP health presentation never replaces Running, Needs input, Ready, or Blocked.
- The presentation adapter is read-only. It cannot spend or refill Charge and cannot write WHOOP or prompt state.
- Body selection changes only when Charge crosses a health-tier boundary: `67–100` energetic, `34–66` normal, `1–33` tired, and `0` exhausted.
- A positive workout award is a separate transient event. It becomes one pending jump and fires when Codex reaches Ready (`review` in the current renderer).
- A native Codex transient has priority over the WHOOP jump.
- Feature Off or unavailable passes the original spritesheet, sprite version, lifecycle, and native transient through unchanged.
- The renderer fails soft after three bridge failures and returns to the stock presentation.

If multiple positive awards arrive before Ready, the current proof coalesces them into one pending jump. An award that applies zero Charge at the cap does not jump. These are explicit proof semantics, not accidental renderer behavior.

## Proof shape

The state machine in `src/pet-presentation-state.mjs` combines an immutable presentation snapshot with Codex lifecycle state. The renderer patch in `src/patch-native-frame.mjs` injects that state machine at one exact seam and refuses unknown or already-patched bundles. The patch also adds a fixed loopback origin to the two exact renderer Content Security Policies.

The loopback bridge binds only to `127.0.0.1:49797` and exposes presentation fields: availability, enabled state, Charge, an opaque award sequence, and applied Charge. The proof server is a test double; the Swift companion does not yet expose this endpoint.

`scripts/build-proof-app.mjs` clone-copies the installed app, patches the copied ASAR, updates Electron ASAR integrity, assigns a distinct bundle identifier, and ad-hoc signs the copy. It retains the stock ASAR inside that copy for inspection. The installed app remains untouched.

Every supported copied-app launcher supplies Chromium's `--use-mock-keychain` switch in addition to an isolated profile. The proof must never request access to the installed Codex application's `Codex Storage Key`. Do not open the generated `.app` directly from Finder; use the proof scripts below.

## Run the proof

From this directory:

```bash
npm ci
npm test
npm run verify-current
npm run build-copy
npm run browser-proof
npm run copy-transport-proof
npm run smoke-copy
```

`build-copy` refuses to overwrite an existing proof app. Its manifest in `.proof/proof-app-manifest.json` records the generated temporary app path. All generated apps, browser profiles, logs, reports, and screenshots stay under the ignored `.proof` directory or the macOS temporary directory.

## What is proven on Codex build 5591

- The current native renderer exposes complete v2 sprite atlases and maps Ready to the `review` sprite row.
- Health-tier body swaps preserve the independent lifecycle row.
- Same-tier Charge changes do not change the body revision.
- A positive refill can queue while busy, fire once at Ready, and return to Ready after the jump.
- Important lifecycle changes preempt the jump; native Codex transients retain priority.
- Off and unavailable restore the stock presentation.
- The copied app accepts the fixed loopback bridge from its real `app://-` renderer origin.
- The copied app passes strict code-sign verification and starts under an isolated profile without an ASAR-integrity failure.

## What remains

- Author and validate four complete 8-by-11 v2 health atlases for the chosen native pet. The exhausted body must visibly collapse without making lifecycle actions unreadable.
- Add the read-only presentation endpoint and monotonic workout-award sequence to the Swift companion.
- Replace proof polling with the production bridge lifecycle and threat model while keeping Off and unavailable stock-identical.
- Package installation, restoration, update detection, and renderer-version refusal as a reversible feature-gated workflow.
- Visually exercise the final atlases in the native overlay. The isolated copied-app check deliberately does not reuse the user’s signed-in Codex profile.

The detailed run evidence is recorded in [the native-pet feasibility verification](../../docs/verification/2026-07-20-native-pet-feasibility.md).
