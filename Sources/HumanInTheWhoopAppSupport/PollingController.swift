import AppKit
import Foundation

public protocol Sleeper: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct TaskSleeper: Sleeper {
    public init() {}

    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

private final class NotificationObserverToken: @unchecked Sendable {
    let value: NSObjectProtocol

    init(_ value: NSObjectProtocol) {
        self.value = value
    }
}

private final class PollingRunState: @unchecked Sendable {
    let generation: UUID
    private let lock = NSLock()
    private var storedEnabled = true

    var enabled: Bool {
        get { lock.withLock { storedEnabled } }
        set { lock.withLock { storedEnabled = newValue } }
    }

    init(generation: UUID) {
        self.generation = generation
    }
}

/// Owns only WHOOP launch/wake/interval scheduling.
/// Local one-second SQLite observation deliberately lives in `MenuBarViewModel`.
@MainActor
public final class PollingController {
    public typealias RefreshAction = @MainActor @Sendable () async -> Void

    public private(set) var isRunning = false

    private let sleeper: any Sleeper
    private let notificationCenter: NotificationCenter
    private let refreshAction: RefreshAction
    private var enabled = false
    private var pollingTask: Task<Void, Never>?
    private var activeRun: PollingRunState?
    private var wakeTask: Task<Void, Never>?
    private var wakeObserver: NotificationObserverToken?

    public init(
        sleeper: any Sleeper = TaskSleeper(),
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        wakeNotificationName: Notification.Name = NSWorkspace.didWakeNotification,
        refresh: @escaping RefreshAction
    ) {
        self.sleeper = sleeper
        self.notificationCenter = notificationCenter
        self.refreshAction = refresh
        wakeObserver = NotificationObserverToken(notificationCenter.addObserver(
            forName: wakeNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleWakeRefresh()
            }
        })
    }

    deinit {
        activeRun?.enabled = false
        pollingTask?.cancel()
        wakeTask?.cancel()
        if let wakeObserver {
            notificationCenter.removeObserver(wakeObserver.value)
        }
    }

    /// Launch entry point. When enabled it refreshes immediately and then every
    /// 900 seconds; when disabled it creates no task and performs no refresh.
    public func start(enabled: Bool) {
        configure(enabled: enabled, refreshImmediately: true)
    }

    public func setEnabled(_ enabled: Bool) {
        configure(enabled: enabled, refreshImmediately: false)
    }

    private func configure(enabled: Bool, refreshImmediately: Bool) {
        self.enabled = enabled
        guard enabled else {
            cancelPollingTask()
            return
        }
        guard pollingTask == nil else { return }

        let generation = UUID()
        let runState = PollingRunState(generation: generation)
        activeRun = runState
        isRunning = true
        let sleeper = self.sleeper
        let refresh = refreshAction
        pollingTask = Task { @MainActor [weak self, runState] in
            guard runState.enabled, !Task.isCancelled else {
                self?.finish(generation: generation)
                return
            }

            if refreshImmediately {
                await refresh()
            }
            while runState.enabled, !Task.isCancelled {
                do {
                    try await sleeper.sleep(seconds: 900)
                    try Task.checkCancellation()
                } catch {
                    self?.finish(generation: generation)
                    return
                }
                guard runState.enabled else {
                    self?.finish(generation: generation)
                    return
                }
                await refresh()
            }
            self?.finish(generation: generation)
        }
    }

    public func stop() {
        enabled = false
        cancelPollingTask()
    }

    private func scheduleWakeRefresh() {
        guard enabled, wakeTask == nil else { return }
        let generation = activeRun?.generation
        let refresh = refreshAction
        wakeTask = Task { @MainActor [weak self] in
            await refresh()
            guard let self, self.enabled, self.activeRun?.generation == generation else { return }
            self.wakeTask = nil
        }
    }

    private func cancelPollingTask() {
        activeRun?.enabled = false
        pollingTask?.cancel()
        wakeTask?.cancel()
        pollingTask = nil
        wakeTask = nil
        activeRun = nil
        isRunning = false
    }

    private func finish(generation: UUID) {
        guard activeRun?.generation == generation else { return }
        pollingTask = nil
        activeRun = nil
        isRunning = false
    }
}
