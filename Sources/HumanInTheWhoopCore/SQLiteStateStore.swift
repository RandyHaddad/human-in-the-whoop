import Foundation
import SQLite3

public final class SQLiteStateStore: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private var simulateRollbackFailure = false
    private var simulateAuditWriteFailure = false

    public init(databaseURL: URL) throws {
        let directoryURL = databaseURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            throw StoreError.fileSystemFailure(operation: "prepare the database directory")
        }

        var openedDatabase: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &openedDatabase,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let openedDatabase else {
            if let openedDatabase {
                sqlite3_close_v2(openedDatabase)
            }
            throw StoreError.sqliteFailure(operation: "open the database", code: openResult)
        }
        database = openedDatabase

        do {
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: databaseURL.path
                )
            } catch {
                throw StoreError.fileSystemFailure(operation: "secure the database file")
            }

            try check(
                sqlite3_busy_timeout(openedDatabase, 2_000),
                operation: "configure the database busy timeout"
            )
            let initializationDeadline = ContinuousClock().now.advanced(by: .seconds(2))
            try configureJournalModeWAL(deadline: initializationDeadline)
            try initializeSchemaAndSeed(deadline: initializationDeadline)
        } catch {
            invalidateConnection()
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    public func read() throws -> PersistentState {
        try lock.withLock {
            try readState()
        }
    }

    @discardableResult
    public func mutate<T>(_ body: (inout PersistentState) throws -> T) throws -> T {
        try lock.withLock {
            try withMutationTransaction {
                var state = try readState()
                let result = try body(&state)
                try updateState(state)
                return result
            }
        }
    }

    @discardableResult
    func mutateAndAppendAudit<T>(
        _ body: (inout PersistentState) throws -> (T, AuditEvent)
    ) throws -> T {
        try lock.withLock {
            try withMutationTransaction {
                var state = try readState()
                let (result, event) = try body(&state)
                try updateState(state)
                try insertAudit(event)
                return result
            }
        }
    }

    @discardableResult
    func mutateAndAppendAudits<T>(
        _ body: (inout PersistentState) throws -> (T, [AuditEvent])
    ) throws -> T {
        try lock.withLock {
            try withMutationTransaction {
                var state = try readState()
                let (result, events) = try body(&state)
                try updateState(state)
                for event in events {
                    try insertAudit(event)
                }
                return result
            }
        }
    }

    func simulateNextRollbackFailureForTesting() {
        lock.withLock {
            simulateRollbackFailure = true
        }
    }

    func simulateNextAuditWriteFailureForTesting() {
        lock.withLock {
            simulateAuditWriteFailure = true
        }
    }

    public func appendAudit(_ event: AuditEvent) throws {
        try lock.withLock {
            try insertAudit(event)
        }
    }

    public func readAuditEvents() throws -> [AuditEvent] {
        try lock.withLock {
            let statement = try prepare(
                "SELECT occurred_at, name, metadata_json FROM audit_events ORDER BY id ASC"
            )
            defer { sqlite3_finalize(statement) }

            var events: [AuditEvent] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    let occurredAtText = try text(from: statement, column: 0)
                    guard let occurredAt = parseDate(occurredAtText) else {
                        throw StoreError.invalidStoredData(description: "an audit timestamp is invalid")
                    }
                    let name = try text(from: statement, column: 1)
                    let metadata: [String: String] = try decode(
                        blob(from: statement, column: 2),
                        description: "audit metadata is invalid"
                    )
                    events.append(
                        AuditEvent(name: name, occurredAt: occurredAt, metadata: metadata)
                    )
                case SQLITE_DONE:
                    return events
                default:
                    throw sqliteError(operation: "read audit events")
                }
            }
        }
    }

    /// Logically deletes all local Charge/WHOOP state without unlinking the
    /// SQLite database under other live processes. Existing and newly opened
    /// connections observe the same default state after this transaction.
    public func resetToDefaults() throws {
        try lock.withLock {
            try withMutationTransaction {
                try updateState(PersistentState())
                try execute("DELETE FROM audit_events")
            }
        }
    }

    private func withMutationTransaction<T>(_ body: () throws -> T) throws -> T {
        do {
            try execute("BEGIN IMMEDIATE")
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try recoverFromFailedMutation(error)
        }
    }

    private func insertAudit(_ event: AuditEvent) throws {
        if simulateAuditWriteFailure {
            simulateAuditWriteFailure = false
            throw StoreError.simulatedAuditWriteFailure
        }

        let statement = try prepare(
            "INSERT INTO audit_events(occurred_at, name, metadata_json) VALUES(?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }

        try bindText(format(event.occurredAt), to: statement, index: 1)
        try bindText(event.name, to: statement, index: 2)
        try bindBlob(try encode(event.metadata), to: statement, index: 3)
        try expectDone(statement, operation: "append an audit event")
    }

    private func configureJournalModeWAL(deadline: ContinuousClock.Instant) throws {
        var retryCount = 0
        while true {
            do {
                let statement = try prepare("PRAGMA journal_mode=WAL")
                defer { sqlite3_finalize(statement) }

                let result = sqlite3_step(statement)
                guard result == SQLITE_ROW else {
                    throw sqliteError(operation: "enable WAL journal mode", fallbackCode: result)
                }
                let mode = try text(from: statement, column: 0)
                guard mode.lowercased() == "wal" else {
                    throw StoreError.unexpectedJournalMode
                }
                let completionResult = sqlite3_step(statement)
                guard completionResult == SQLITE_DONE else {
                    throw sqliteError(
                        operation: "finish enabling WAL journal mode",
                        fallbackCode: completionResult
                    )
                }
                return
            } catch {
                guard shouldRetry(error, before: deadline) else {
                    throw error
                }
                backOff(retryCount: retryCount)
                retryCount += 1
            }
        }
    }

    private func initializeSchemaAndSeed(deadline: ContinuousClock.Instant) throws {
        var retryCount = 0
        while true {
            do {
                try initializeSchemaAndSeedAttempt()
                return
            } catch {
                guard shouldRetry(error, before: deadline) else {
                    throw error
                }
                backOff(retryCount: retryCount)
                retryCount += 1
            }
        }
    }

    private func initializeSchemaAndSeedAttempt() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute(
                """
                CREATE TABLE IF NOT EXISTS app_state(
                    id INTEGER PRIMARY KEY CHECK(id = 1),
                    json BLOB NOT NULL
                )
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS audit_events(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    occurred_at TEXT NOT NULL,
                    name TEXT NOT NULL,
                    metadata_json BLOB NOT NULL
                )
                """
            )
            try seedInitialStateIfNeeded()
            try execute("COMMIT")
            guard isAutocommitEnabled else {
                throw StoreError.initializationRecoveryFailure
            }
        } catch {
            do {
                try rollbackInitializationTransaction()
            } catch {
                invalidateConnection()
                throw StoreError.initializationRecoveryFailure
            }
            throw error
        }
    }

    private func rollbackInitializationTransaction() throws {
        guard !isAutocommitEnabled else {
            return
        }
        try execute("ROLLBACK")
        guard isAutocommitEnabled else {
            throw StoreError.initializationRecoveryFailure
        }
    }

    private func seedInitialStateIfNeeded() throws {
        let statement = try prepare("INSERT OR IGNORE INTO app_state(id, json) VALUES(1, ?)")
        defer { sqlite3_finalize(statement) }

        try bindBlob(try encode(PersistentState()), to: statement, index: 1)
        try expectDone(statement, operation: "initialize application state")
    }

    private func readState() throws -> PersistentState {
        let statement = try prepare("SELECT json FROM app_state WHERE id = 1")
        defer { sqlite3_finalize(statement) }

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decode(
                blob(from: statement, column: 0),
                description: "application state is invalid"
            )
        case SQLITE_DONE:
            throw StoreError.invalidStoredData(description: "application state is missing")
        default:
            throw sqliteError(operation: "read application state")
        }
    }

    private func updateState(_ state: PersistentState) throws {
        let statement = try prepare("UPDATE app_state SET json = ? WHERE id = 1")
        defer { sqlite3_finalize(statement) }

        try bindBlob(try encode(state), to: statement, index: 1)
        try expectDone(statement, operation: "update application state")
        guard let database else {
            throw StoreError.connectionInvalidated
        }
        guard sqlite3_changes(database) == 1 else {
            throw StoreError.invalidStoredData(description: "application state is missing")
        }
    }

    private func recoverFromFailedMutation(_ originalError: Error) throws -> Never {
        guard database != nil else {
            throw originalError
        }
        guard !isAutocommitEnabled else {
            throw originalError
        }

        let rollbackFailed: Bool
        if simulateRollbackFailure {
            simulateRollbackFailure = false
            rollbackFailed = true
        } else {
            do {
                try execute("ROLLBACK")
                rollbackFailed = false
            } catch {
                rollbackFailed = true
            }
        }

        guard !rollbackFailed, isAutocommitEnabled else {
            invalidateConnection()
            throw StoreError.mutationRollbackFailure
        }
        throw originalError
    }

    private func execute(_ sql: String) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                continue
            case SQLITE_DONE:
                return
            default:
                throw sqliteError(operation: "execute a database command")
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else {
            throw StoreError.connectionInvalidated
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw sqliteError(operation: "prepare a database command", fallbackCode: result)
        }
        return statement
    }

    private func bindBlob(_ data: Data, to statement: OpaquePointer, index: Int32) throws {
        let result = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                sqliteTransient
            )
        }
        try check(result, operation: "bind encoded data")
    }

    private func bindText(_ value: String, to statement: OpaquePointer, index: Int32) throws {
        try check(
            sqlite3_bind_text(statement, index, value, -1, sqliteTransient),
            operation: "bind text data"
        )
    }

    private func blob(from statement: OpaquePointer, column: Int32) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else {
            throw StoreError.invalidStoredData(description: "stored encoded data is empty")
        }
        return Data(bytes: bytes, count: count)
    }

    private func text(from statement: OpaquePointer, column: Int32) throws -> String {
        guard let bytes = sqlite3_column_text(statement, column) else {
            throw StoreError.invalidStoredData(description: "stored text data is missing")
        }
        return String(cString: bytes)
    }

    private func expectDone(_ statement: OpaquePointer, operation: String) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw sqliteError(operation: operation, fallbackCode: result)
        }
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result == SQLITE_OK else {
            throw sqliteError(operation: operation, fallbackCode: result)
        }
    }

    private func sqliteError(operation: String, fallbackCode: Int32? = nil) -> StoreError {
        let code: Int32
        if let database {
            code = sqlite3_extended_errcode(database)
        } else {
            code = fallbackCode ?? SQLITE_ERROR
        }
        return .sqliteFailure(operation: operation, code: code)
    }

    private var isAutocommitEnabled: Bool {
        guard let database else {
            return false
        }
        return sqlite3_get_autocommit(database) != 0
    }

    private func shouldRetry(_ error: Error, before deadline: ContinuousClock.Instant) -> Bool {
        guard ContinuousClock().now < deadline,
              case let StoreError.sqliteFailure(_, code) = error
        else {
            return false
        }
        let primaryCode = code & 0xFF
        return primaryCode == SQLITE_BUSY || primaryCode == SQLITE_LOCKED
    }

    private func backOff(retryCount: Int) {
        let multiplier = 1 << min(retryCount, 3)
        Thread.sleep(forTimeInterval: min(Double(multiplier) * 0.005, 0.05))
    }

    private func invalidateConnection() {
        guard let database else {
            return
        }
        sqlite3_close_v2(database)
        self.database = nil
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(FractionalISO8601.string(from: date))
        }
        do {
            return try encoder.encode(value)
        } catch {
            throw StoreError.encodingFailure
        }
    }

    private func decode<Value: Decodable>(
        _ data: Data,
        description: String
    ) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = FractionalISO8601.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a fractional ISO-8601 date."
                )
            }
            return date
        }
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw StoreError.invalidStoredData(description: description)
        }
    }

    private func format(_ date: Date) -> String {
        FractionalISO8601.string(from: date)
    }

    private func parseDate(_ value: String) -> Date? {
        FractionalISO8601.date(from: value)
    }
}

private enum FractionalISO8601 {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum StoreError: LocalizedError {
    case fileSystemFailure(operation: String)
    case sqliteFailure(operation: String, code: Int32)
    case invalidStoredData(description: String)
    case encodingFailure
    case unexpectedJournalMode
    case initializationRecoveryFailure
    case mutationRollbackFailure
    case connectionInvalidated
    case simulatedAuditWriteFailure

    var errorDescription: String? {
        switch self {
        case let .fileSystemFailure(operation):
            "Unable to \(operation)."
        case let .sqliteFailure(operation, code):
            "Unable to \(operation) (SQLite code \(code): \(String(cString: sqlite3_errstr(code))))."
        case let .invalidStoredData(description):
            "Unable to read local state because \(description)."
        case .encodingFailure:
            "Unable to encode local state."
        case .unexpectedJournalMode:
            "Unable to enable WAL journal mode."
        case .initializationRecoveryFailure:
            "Database initialization failed, and its transaction could not be safely recovered."
        case .mutationRollbackFailure:
            "The mutation failed, and its transaction could not roll back. The database connection was invalidated."
        case .connectionInvalidated:
            "The database connection was invalidated and can no longer be used."
        case .simulatedAuditWriteFailure:
            "The audit write failed during testing."
        }
    }
}
