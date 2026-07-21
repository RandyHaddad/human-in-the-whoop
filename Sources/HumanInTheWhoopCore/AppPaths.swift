import Foundation

public struct AppPaths: Sendable, Equatable {
    public let root: URL

    public init(rootOverride: URL? = nil) {
        if let rootOverride {
            self.root = rootOverride
        } else if let override = ProcessInfo.processInfo.environment["HITW_STATE_ROOT"], !override.isEmpty {
            self.root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/Human in the Whoop",
                    isDirectory: true
                )
        }
    }

    public var database: URL {
        root.appendingPathComponent("state.sqlite3")
    }

    /// Presentation preference only. This intentionally remains outside the
    /// Charge SQLite ledger so selecting a pet cannot mutate health state.
    public var petPreferences: URL {
        root.appendingPathComponent("pet-preferences.json")
    }

    public var binDirectory: URL {
        root.appendingPathComponent("bin", isDirectory: true)
    }

    public var hookBinary: URL {
        binDirectory.appendingPathComponent("hitw-hook")
    }
}
