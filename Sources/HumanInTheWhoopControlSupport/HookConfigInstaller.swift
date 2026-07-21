import Darwin
import Foundation

public struct HookConfigMutationResult: Equatable, Sendable {
    public let changed: Bool
    public let backup: URL?
    /// False means the atomic replacement committed, but the final parent-directory
    /// fsync could not be confirmed. Reporting failure after rename would falsely
    /// imply that callers can safely retry or compensate an uncommitted mutation.
    public let durabilityConfirmed: Bool
    let undo: HookConfigUndo?

    public init(changed: Bool, backup: URL?, durabilityConfirmed: Bool = true) {
        self.changed = changed
        self.backup = backup
        self.durabilityConfirmed = durabilityConfirmed
        self.undo = nil
    }

    init(changed: Bool, backup: URL?, durabilityConfirmed: Bool, undo: HookConfigUndo?) {
        self.changed = changed
        self.backup = backup
        self.durabilityConfirmed = durabilityConfirmed
        self.undo = undo
    }
}

struct HookConfigUndo: Equatable, Sendable {
    let priorData: Data?
    let committedData: Data
}

public enum HookConfigInstallerError: LocalizedError, Equatable, Sendable {
    case invalidPath(String)
    case unsafeSymbolicLink(String)
    case invalidConfiguration(String)
    case concurrentModification
    case fileOperation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            "Refusing unsafe hook path: \(path)"
        case .unsafeSymbolicLink(let path):
            "Refusing symbolic-link hook configuration: \(path)"
        case .invalidConfiguration(let message):
            "Invalid Codex hook configuration: \(message)"
        case .concurrentModification:
            "Codex hooks changed concurrently; no Human in the Whoop update was committed."
        case .fileOperation(let message):
            "Could not update Codex hook configuration: \(message)"
        }
    }
}

enum HookConfigInstallerTestPoint: Equatable, Sendable {
    case beforeCompareAndSwap
    case beforeRename
    case afterRenameBeforeDirectorySync
}

struct HookConfigInstallerTestHooks: Sendable {
    let callback: @Sendable (HookConfigInstallerTestPoint) throws -> Void

    init(_ callback: @escaping @Sendable (HookConfigInstallerTestPoint) throws -> Void) {
        self.callback = callback
    }
}

/// Owns only Human in the Whoop's direct UserPromptSubmit command handler.
/// Other hook entries and unknown JSON fields remain semantically untouched.
///
/// Cooperating HITW writers serialize on a stable sibling lock. All target,
/// backup, temporary, and replacement operations are relative to a pinned
/// parent directory descriptor, and an observed target-content mismatch aborts
/// instead of overwriting a non-cooperating editor.
public struct HookConfigInstaller: Sendable {
    public static let statusMessage = "Checking Human in the Whoop Charge"

    public let hooksFile: URL
    public let hookBinary: URL
    private let testHooks: HookConfigInstallerTestHooks?

    public init(hooksFile: URL, hookBinary: URL) throws {
        try self.init(hooksFile: hooksFile, hookBinary: hookBinary, testHooks: nil)
    }

    init(
        hooksFile: URL,
        hookBinary: URL,
        testHooks: HookConfigInstallerTestHooks?
    ) throws {
        self.hooksFile = try Self.validateFileURL(hooksFile, role: "hooks file")
        self.hookBinary = try Self.validateFileURL(hookBinary, role: "hook binary")
        self.testHooks = testHooks
        guard self.hooksFile.lastPathComponent == "hooks.json" else {
            throw HookConfigInstallerError.invalidPath(self.hooksFile.path)
        }
        guard self.hookBinary.lastPathComponent == "hitw-hook" else {
            throw HookConfigInstallerError.invalidPath(self.hookBinary.path)
        }
        try Self.rejectExistingSymbolicLinkComponents(self.hookBinary.path)
    }

    public var installedCommand: String {
        "\"\(hookBinary.path)\""
    }

    @discardableResult
    public func install() throws -> HookConfigMutationResult {
        try withLockedParent { parent in
            let document = try readDocument(parent: parent)
            var root = document.root
            var hooks = try hooksObject(from: root)
            let groups = try promptGroups(from: hooks)
            let canonicalHandler: [String: Any] = [
                "type": "command",
                "command": installedCommand,
                "timeout": 2,
                "statusMessage": Self.statusMessage,
            ]

            var keptDirectHandler = false
            var updatedGroups: [[String: Any]] = []
            updatedGroups.reserveCapacity(groups.count + 1)

            for var group in groups {
                let originalHandlers = try handlers(from: group)
                let isDirectGroup = group["matcher"] == nil
                var updatedHandlers: [[String: Any]] = []
                var removedOwnedHandler = false

                for var handler in originalHandlers {
                    guard isOwnedHandler(handler) else {
                        updatedHandlers.append(handler)
                        continue
                    }
                    if isDirectGroup, !keptDirectHandler {
                        for (key, value) in canonicalHandler { handler[key] = value }
                        updatedHandlers.append(handler)
                        keptDirectHandler = true
                    } else {
                        removedOwnedHandler = true
                    }
                }

                group["hooks"] = updatedHandlers
                if updatedHandlers.isEmpty, removedOwnedHandler { continue }
                updatedGroups.append(group)
            }

            if !keptDirectHandler {
                updatedGroups.append(["hooks": [canonicalHandler]])
            }
            hooks["UserPromptSubmit"] = updatedGroups
            root["hooks"] = hooks

            guard !Self.jsonObjectsEqual(document.root, root) else {
                guard let committedData = document.originalData else {
                    throw HookConfigInstallerError.fileOperation(
                        "could not retain a confirmation token for hooks.json"
                    )
                }
                return HookConfigMutationResult(
                    changed: false,
                    backup: nil,
                    durabilityConfirmed: true,
                    undo: HookConfigUndo(
                        priorData: committedData,
                        committedData: committedData
                    )
                )
            }
            return try write(root: root, replacing: document, parent: parent)
        }
    }

    @discardableResult
    public func uninstall() throws -> HookConfigMutationResult {
        try withLockedParent { parent in
            let document = try readDocument(parent: parent)
            var root = document.root
            var hooks = try hooksObject(from: root)
            guard hooks["UserPromptSubmit"] != nil else {
                return HookConfigMutationResult(changed: false, backup: nil)
            }
            let groups = try promptGroups(from: hooks)
            var updatedGroups: [[String: Any]] = []
            updatedGroups.reserveCapacity(groups.count)

            for var group in groups {
                let originalHandlers = try handlers(from: group)
                let remaining = originalHandlers.filter { !isOwnedHandler($0) }
                if originalHandlers.isEmpty {
                    updatedGroups.append(group)
                    continue
                }
                guard !remaining.isEmpty else { continue }
                group["hooks"] = remaining
                updatedGroups.append(group)
            }

            if updatedGroups.isEmpty {
                hooks.removeValue(forKey: "UserPromptSubmit")
            } else {
                hooks["UserPromptSubmit"] = updatedGroups
            }
            root["hooks"] = hooks

            guard !Self.jsonObjectsEqual(document.root, root) else {
                return HookConfigMutationResult(changed: false, backup: nil)
            }
            return try write(root: root, replacing: document, parent: parent)
        }
    }

    /// Compensates a mutation made by this installer, but only if the target is
    /// still byte-for-byte the value this operation committed. It never
    /// overwrites a later editor or another HITW mutation.
    func rollback(_ result: HookConfigMutationResult) throws {
        guard result.changed, let undo = result.undo else { return }
        try withLockedParent { parent in
            try Self.requireUnchangedTarget(expected: undo.committedData, parent: parent.descriptor)
            try Self.revalidate(parent: parent, path: hooksFile.deletingLastPathComponent().path)
            if let priorData = undo.priorData {
                let temporaryName = ".hooks.json.rollback.\(UUID().uuidString)"
                var temporaryExists = false
                defer {
                    if temporaryExists { unlinkat(parent.descriptor, temporaryName, 0) }
                }
                try Self.writeNewPrivateFile(priorData, parent: parent.descriptor, name: temporaryName)
                temporaryExists = true
                guard renameat(parent.descriptor, temporaryName, parent.descriptor, "hooks.json") == 0 else {
                    throw HookConfigInstallerError.fileOperation("could not restore hooks.json")
                }
                temporaryExists = false
            } else {
                guard unlinkat(parent.descriptor, "hooks.json", 0) == 0 else {
                    throw HookConfigInstallerError.fileOperation("could not remove newly installed hooks.json")
                }
            }
            guard fsync(parent.descriptor) == 0 else {
                throw HookConfigInstallerError.fileOperation("could not synchronize restored hooks.json")
            }
        }
    }

    /// Confirms, without changing hooks.json, that it is still byte-for-byte
    /// the value returned by this install operation. A byte mismatch is an
    /// expected concurrent edit and returns false; unsafe filesystem state or
    /// read failures still throw.
    public func confirmCommitted(_ result: HookConfigMutationResult) throws -> Bool {
        guard let undo = result.undo else { return false }
        return try withLockedParent(
            createMissingParent: false,
            createMissingLock: false,
            secureLockPermissions: false
        ) { parent in
            do {
                try Self.requireUnchangedTarget(
                    expected: undo.committedData,
                    parent: parent.descriptor
                )
                return true
            } catch HookConfigInstallerError.concurrentModification {
                return false
            }
        }
    }

    private struct Document {
        let root: [String: Any]
        let originalData: Data?
    }

    private struct PinnedParent {
        let descriptor: Int32
        let device: dev_t
        let inode: ino_t
    }

    private func withLockedParent<T>(
        createMissingParent: Bool = true,
        createMissingLock: Bool = true,
        secureLockPermissions: Bool = true,
        _ body: (PinnedParent) throws -> T
    ) throws -> T {
        let parent = try Self.openParentDirectory(
            hooksFile.deletingLastPathComponent().path,
            createMissing: createMissingParent
        )
        defer { close(parent.descriptor) }

        let lockName = ".hooks.json.human-in-the-whoop.lock"
        var lockDescriptor = openat(
            parent.descriptor,
            lockName,
            O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        if lockDescriptor < 0, errno == ENOENT, createMissingLock {
            lockDescriptor = openat(
                parent.descriptor,
                lockName,
                O_RDWR | O_NONBLOCK | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            if lockDescriptor < 0, errno == EEXIST {
                lockDescriptor = openat(
                    parent.descriptor,
                    lockName,
                    O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
        }
        guard lockDescriptor >= 0 else {
            if errno == ELOOP { throw HookConfigInstallerError.unsafeSymbolicLink(lockName) }
            throw HookConfigInstallerError.fileOperation("could not open the hooks writer lock")
        }
        defer { close(lockDescriptor) }
        var lockStatus = stat()
        guard fstat(lockDescriptor, &lockStatus) == 0,
              lockStatus.st_mode & S_IFMT == S_IFREG
        else {
            throw HookConfigInstallerError.invalidPath(lockName)
        }
        if secureLockPermissions {
            guard fchmod(lockDescriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw HookConfigInstallerError.fileOperation("could not secure the hooks writer lock")
            }
        } else {
            guard lockStatus.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO) == S_IRUSR | S_IWUSR else {
                throw HookConfigInstallerError.invalidPath(lockName)
            }
        }
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw HookConfigInstallerError.fileOperation("could not lock hooks.json")
        }
        defer { flock(lockDescriptor, LOCK_UN) }
        try Self.revalidate(parent: parent, path: hooksFile.deletingLastPathComponent().path)
        return try body(parent)
    }

    private func readDocument(parent: PinnedParent) throws -> Document {
        let data = try Self.readOptionalRegularFile(parent: parent.descriptor, name: "hooks.json")
        guard let data else { return Document(root: [:], originalData: nil) }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HookConfigInstallerError.invalidConfiguration("hooks.json is not valid JSON")
        }
        guard let root = object as? [String: Any] else {
            throw HookConfigInstallerError.invalidConfiguration("the root must be an object")
        }
        _ = try hooksObject(from: root)
        return Document(root: root, originalData: data)
    }

    private func hooksObject(from root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else {
            throw HookConfigInstallerError.invalidConfiguration("hooks must be an object")
        }
        return hooks
    }

    private func promptGroups(from hooks: [String: Any]) throws -> [[String: Any]] {
        guard let value = hooks["UserPromptSubmit"] else { return [] }
        guard let rawGroups = value as? [Any] else {
            throw HookConfigInstallerError.invalidConfiguration("hooks.UserPromptSubmit must be an array")
        }
        return try rawGroups.map { value in
            guard let group = value as? [String: Any] else {
                throw HookConfigInstallerError.invalidConfiguration("each UserPromptSubmit matcher group must be an object")
            }
            _ = try handlers(from: group)
            return group
        }
    }

    private func handlers(from group: [String: Any]) throws -> [[String: Any]] {
        guard let value = group["hooks"] else {
            throw HookConfigInstallerError.invalidConfiguration("each UserPromptSubmit matcher group must contain hooks")
        }
        guard let rawHandlers = value as? [Any] else {
            throw HookConfigInstallerError.invalidConfiguration("matcher-group hooks must be an array")
        }
        return try rawHandlers.map { value in
            guard let handler = value as? [String: Any] else {
                throw HookConfigInstallerError.invalidConfiguration("each UserPromptSubmit handler must be an object")
            }
            return handler
        }
    }

    /// Ownership is intentionally independent of handler type or metadata.
    /// An old/corrupt entry that still invokes our exact binary is ours to repair
    /// on install and ours to remove on uninstall.
    private func isOwnedHandler(_ handler: [String: Any]) -> Bool {
        guard let command = handler["command"] as? String,
              let path = Self.normalizedDirectCommandPath(command)
        else { return false }
        return path == hookBinary.path
    }

    private func write(
        root: [String: Any],
        replacing document: Document,
        parent: PinnedParent
    ) throws -> HookConfigMutationResult {
        let data: Data
        do {
            var encoded = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            encoded.append(0x0A)
            data = encoded
        } catch {
            throw HookConfigInstallerError.invalidConfiguration("configuration could not be encoded")
        }

        let temporaryName = ".hooks.json.temporary.\(UUID().uuidString)"
        var temporaryExists = false
        defer {
            if temporaryExists { unlinkat(parent.descriptor, temporaryName, 0) }
        }
        try Self.writeNewPrivateFile(data, parent: parent.descriptor, name: temporaryName)
        temporaryExists = true

        try testHooks?.callback(.beforeCompareAndSwap)
        try Self.revalidate(parent: parent, path: hooksFile.deletingLastPathComponent().path)
        try Self.requireUnchangedTarget(
            expected: document.originalData,
            parent: parent.descriptor
        )

        var backupURL: URL?
        if let originalData = document.originalData {
            let backupName = "hooks.json.backup.\(Self.backupTimestamp()).\(UUID().uuidString)"
            try Self.writeNewPrivateFile(originalData, parent: parent.descriptor, name: backupName)
            guard fsync(parent.descriptor) == 0 else {
                throw HookConfigInstallerError.fileOperation("could not synchronize the hook backup entry")
            }
            backupURL = hooksFile.deletingLastPathComponent().appendingPathComponent(backupName)
            // A non-cooperating editor may have changed the target while the
            // durable backup was created. Validate again immediately before rename.
            try Self.requireUnchangedTarget(expected: document.originalData, parent: parent.descriptor)
        }

        try testHooks?.callback(.beforeRename)
        try Self.revalidate(parent: parent, path: hooksFile.deletingLastPathComponent().path)
        try Self.requireUnchangedTarget(expected: document.originalData, parent: parent.descriptor)
        guard renameat(parent.descriptor, temporaryName, parent.descriptor, "hooks.json") == 0 else {
            throw HookConfigInstallerError.fileOperation("atomic hooks.json replacement failed")
        }
        temporaryExists = false

        // From here onward the semantic mutation is committed. A post-rename
        // directory-fsync failure is reported as committed with uncertain crash
        // durability, never as an uncommitted throwing failure.
        var durabilityConfirmed = true
        do {
            try testHooks?.callback(.afterRenameBeforeDirectorySync)
            if fsync(parent.descriptor) != 0 { durabilityConfirmed = false }
        } catch {
            durabilityConfirmed = false
        }
        return HookConfigMutationResult(
            changed: true,
            backup: backupURL,
            durabilityConfirmed: durabilityConfirmed,
            undo: HookConfigUndo(priorData: document.originalData, committedData: data)
        )
    }

    private static func requireUnchangedTarget(expected: Data?, parent: Int32) throws {
        let current = try readOptionalRegularFile(parent: parent, name: "hooks.json")
        guard current == expected else { throw HookConfigInstallerError.concurrentModification }
    }

    private static func readOptionalRegularFile(parent: Int32, name: String) throws -> Data? {
        let descriptor = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw HookConfigInstallerError.unsafeSymbolicLink(name) }
            throw HookConfigInstallerError.fileOperation("could not open hooks.json")
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw HookConfigInstallerError.invalidPath(name)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { return data }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw HookConfigInstallerError.fileOperation("could not read hooks.json")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func writeNewPrivateFile(_ data: Data, parent: Int32, name: String) throws {
        let descriptor = openat(
            parent,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw HookConfigInstallerError.fileOperation("could not create hook configuration artifact")
        }
        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded { unlinkat(parent, name, 0) }
        }
        try data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                guard count > 0 else {
                    if errno == EINTR { continue }
                    throw HookConfigInstallerError.fileOperation("could not write hook configuration artifact")
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw HookConfigInstallerError.fileOperation("could not synchronize hook configuration artifact")
        }
        succeeded = true
    }

    private static func openParentDirectory(_ path: String, createMissing: Bool) throws -> PinnedParent {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw HookConfigInstallerError.fileOperation("could not open filesystem root")
        }
        var ownsDescriptor = true
        do {
            for component in path.split(separator: "/").map(String.init) {
                var child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0, errno == ENOENT, createMissing {
                    guard mkdirat(descriptor, component, S_IRWXU) == 0 || errno == EEXIST else {
                        throw HookConfigInstallerError.fileOperation("could not create hooks directory")
                    }
                    guard fsync(descriptor) == 0 else {
                        throw HookConfigInstallerError.fileOperation("could not synchronize hooks directory creation")
                    }
                    child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else {
                    if errno == ELOOP { throw HookConfigInstallerError.unsafeSymbolicLink(path) }
                    throw HookConfigInstallerError.invalidPath(path)
                }
                close(descriptor)
                descriptor = child
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
                throw HookConfigInstallerError.invalidPath(path)
            }
            ownsDescriptor = false
            return PinnedParent(
                descriptor: descriptor,
                device: status.st_dev,
                inode: status.st_ino
            )
        } catch {
            if ownsDescriptor { close(descriptor) }
            throw error
        }
    }

    private static func revalidate(parent: PinnedParent, path: String) throws {
        let current = try openParentDirectory(path, createMissing: false)
        defer { close(current.descriptor) }
        guard current.device == parent.device, current.inode == parent.inode else {
            throw HookConfigInstallerError.concurrentModification
        }
    }

    private static func rejectExistingSymbolicLinkComponents(_ path: String) throws {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw HookConfigInstallerError.fileOperation("could not inspect hook binary path")
        }
        defer { close(descriptor) }
        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            let flags = index == components.count - 1
                ? O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                : O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            let child = openat(descriptor, component, flags)
            if child < 0 {
                if errno == ENOENT { return }
                if errno == ELOOP { throw HookConfigInstallerError.unsafeSymbolicLink(path) }
                throw HookConfigInstallerError.invalidPath(path)
            }
            if index == components.count - 1 {
                var status = stat()
                guard fstat(child, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
                    close(child)
                    throw HookConfigInstallerError.invalidPath(path)
                }
            }
            close(descriptor)
            descriptor = child
        }
    }

    private static func validateFileURL(_ url: URL, role: String) throws -> URL {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              !url.path.contains("\n"),
              !url.path.contains("\r"),
              !url.path.contains("\0"),
              !url.path.contains("\""),
              !url.path.contains("'"),
              !url.path.contains("\\"),
              !url.path.contains("`"),
              !url.path.contains("$")
        else { throw HookConfigInstallerError.invalidPath("\(role): \(url.path)") }
        let lexicalPath = try lexicallyCanonicalAbsolutePath(url.path, role: role)
        let standardized = URL(fileURLWithPath: lexicalPath)
        guard lexicalPath != "/", !standardized.lastPathComponent.isEmpty else {
            throw HookConfigInstallerError.invalidPath("\(role): \(url.path)")
        }
        return standardized
    }

    private static func normalizedDirectCommandPath(_ command: String) -> String? {
        var value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.count >= 2,
           let first = value.first,
           let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'")
        {
            value.removeFirst()
            value.removeLast()
        }
        guard value.hasPrefix("/"),
              !value.contains("\n"),
              !value.contains("\r"),
              !value.contains("\0"),
              !value.contains("\""),
              !value.contains("'"),
              !value.contains("\\"),
              !value.contains("`"),
              !value.contains("$"),
              !value.contains("\t")
        else { return nil }
        return try? lexicallyCanonicalAbsolutePath(value, role: "command")
    }

    private static func lexicallyCanonicalAbsolutePath(
        _ path: String,
        role: String
    ) throws -> String {
        guard path.hasPrefix("/"), !path.hasSuffix("/") else {
            throw HookConfigInstallerError.invalidPath("\(role): \(path)")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first == "",
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw HookConfigInstallerError.invalidPath("\(role): \(path)")
        }
        if path == "/var" || path.hasPrefix("/var/") {
            return "/private\(path)"
        }
        if path == "/tmp" || path.hasPrefix("/tmp/") {
            return "/private\(path)"
        }
        return path
    }

    private static func jsonObjectsEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }

    private static func backupTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
    }
}
