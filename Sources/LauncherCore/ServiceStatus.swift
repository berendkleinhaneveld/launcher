import Foundation

public enum ServiceStatus: Equatable, Sendable {
    case stopped
    /// Ended by itself with exit code 0.
    case finished
    case starting
    case running(pid: Int32, since: Date?)
    case stopping
    case failed(String)

    /// launchd has no notion of "ready", so a service counts as starting for this
    /// long after launch. Anything that crashes on startup never shows as running.
    public static let startingPeriod: TimeInterval = 3

    public init(
        job: JobStatus?,
        restart: Service.Restart,
        launchedAt: Date?,
        now: Date = Date(),
        startDate: (Int32) -> Date? = processStartDate
    ) {
        guard let job else {
            self = .stopped
            return
        }
        if let pid = job.pid {
            let since = startDate(pid)
            if let since, now.timeIntervalSince(since) < Self.startingPeriod {
                self = .starting
            } else {
                self = .running(pid: pid, since: since)
            }
        } else if job.lastExit != 0 {
            let retrying = restart == .no ? "" : ", launchd will retry"
            self = .failed(Self.describeExit(job.lastExit) + retrying)
        } else if restart == .always {
            self = .starting
        } else if let launchedAt, now.timeIntervalSince(launchedAt) < 1 {
            self = .starting
        } else {
            self = .finished
        }
    }

    static func describeExit(_ code: Int) -> String {
        switch code {
        case ..<0:
            return String(cString: strsignal(Int32(-code)))
        case 78:
            return "launchd couldn't launch it (exit 78)"
        case 127:
            return "Command not found (exit 127)"
        default:
            return "Exited with code \(code)"
        }
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// One line for the menu.
    public func summary(now: Date = Date()) -> String {
        switch self {
        case .stopped: return "Stopped"
        case .finished: return "Finished"
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        case .failed(let message): return message
        case .running(let pid, let since):
            let uptime = since.flatMap { Self.uptimeFormatter.string(from: now.timeIntervalSince($0)) }
            return uptime.map { "Running for \($0), pid \(pid)" } ?? "Running, pid \(pid)"
        }
    }

    private static let uptimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        return formatter
    }()
}
