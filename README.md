# Human in the Whoop

![WHOOP band around the Codex logo](docs/media/hero.png)

Human in the Whoop connects WHOOP to Codex.

- WHOOP recovery sets Charge
- Every Codex prompt uses 1 Charge
- Scored WHOOP workouts add Charge
- At 0, Codex redirects the user to move
- The menu-bar app shows Charge and refreshes WHOOP data
- Turning it off restores normal Codex

## Demo flow

1. Enable Human in the Whoop.
2. Refresh WHOOP to set Charge from the latest Recovery.
3. Send Codex prompts and watch Charge decrease.
4. Complete and score a WHOOP workout.
5. Refresh WHOOP and watch Charge refill from Workout Strain.

## What is in this repository

- Swift and SwiftUI macOS menu-bar companion
- WHOOP OAuth and read-only API client
- Shared SQLite Charge ledger
- Codex `UserPromptSubmit` hook
- Workout refill and prompt accounting logic
- Isolated Codex pet-renderer proof
- Four validated WHOOP sensor animation tiers
- Unit and integration tests

![WHOOP sensor pet](docs/media/whoop-sensor-pet.png)

## Build

Requirements: macOS 15+, Swift 6.1+, and a WHOOP developer application.

```bash
swift test
./scripts/package-app.sh
./scripts/install-local.sh
```

Installation leaves the feature off. Enable it from the menu-bar app after the required WHOOP credentials are stored in macOS Keychain.

## Privacy and isolation

- WHOOP access is read-only.
- Credentials and OAuth tokens stay in macOS Keychain.
- Local state stays in the user's Application Support directory.
- Prompt text is not stored.
- The hook fails open.
- Disabling the feature restores normal Codex behavior.
- Native-pet work runs against an isolated Codex copy, not the everyday app.

No WHOOP token, health record, device identifier, local database, or copied Codex binary is included in this repository.

## Technical notes

Workout awards use a capped nonlinear curve based on WHOOP Workout Strain. The ledger deduplicates workout UUIDs, handles token rotation, and keeps all Codex windows on one local Charge balance.

The main implementation work was prompt accounting, OAuth refresh, workout deduplication, safe hook installation, and keeping the demo build separate from the regular Codex app.
