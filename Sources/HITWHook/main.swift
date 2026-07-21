import Darwin
import Foundation

import HumanInTheWhoopCore

private let maximumInputBytes = 1_048_576
private let inputChunkBytes = 64 * 1_024

private struct InputTooLarge: Error {}

private func readBoundedInput(from fileHandle: FileHandle) throws -> Data {
    var input = Data()
    input.reserveCapacity(maximumInputBytes)

    while input.count <= maximumInputBytes {
        let remainingThroughLimit = maximumInputBytes - input.count + 1
        let chunk = try fileHandle.read(
            upToCount: min(inputChunkBytes, remainingThroughLimit)
        ) ?? Data()
        guard !chunk.isEmpty else {
            return input
        }

        input.append(chunk)
        guard input.count <= maximumInputBytes else {
            throw InputTooLarge()
        }
    }

    throw InputTooLarge()
}

private func runHook() throws {
    let inputData = try readBoundedInput(from: .standardInput)
    let input = try JSONDecoder().decode(HookInput.self, from: inputData)

    guard input.hookEventName == "UserPromptSubmit" else {
        return
    }

    let paths = AppPaths()
    let store = try SQLiteStateStore(databaseURL: paths.database)
    let engine = ChargeEngine(store: store)
    try engine.withPromptDecision(for: input) { decision in
        let output = try HookDecisionService().render(decision, now: Date())
        if let output {
            try FileHandle.standardOutput.write(contentsOf: output)
        }
    }
}

_ = signal(SIGPIPE, SIG_IGN)

do {
    try runHook()
} catch {
    // Hooks must always fail open without exposing prompt, storage, or rendering errors.
}
