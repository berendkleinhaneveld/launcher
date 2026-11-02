import Foundation

/// A line of `launchctl list`. `lastExit` is negative when a signal ended the job.
public struct JobStatus: Equatable, Sendable {
    public var pid: Int32?
    public var lastExit: Int

    public init(pid: Int32?, lastExit: Int) {
        self.pid = pid
        self.lastExit = lastExit
    }
}

public enum Launchctl {
    private static var domain: String { "gui/\(getuid())" }

    public static func parseList(_ output: String, prefix: String) -> [String: JobStatus] {
        var jobs: [String: JobStatus] = [:]
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: "\t", maxSplits: 2)
            guard columns.count == 3,
                columns[2].hasPrefix(prefix),
                let lastExit = Int(columns[1])
            else { continue }
            jobs[String(columns[2])] = JobStatus(pid: Int32(columns[0]), lastExit: lastExit)
        }
        return jobs
    }

    /// The loaded jobs whose label starts with `prefix`, or nil if launchctl failed.
    public static func list(prefix: String) async -> [String: JobStatus]? {
        let result = await run("list")
        return result.status == 0 ? parseList(result.output, prefix: prefix) : nil
    }

    /// Loads the agent, which starts it. Returns an error message on failure.
    public static func bootstrap(_ agent: URL) async -> String? {
        let result = await run("bootstrap", domain, agent.path)
        guard result.status != 0 else { return nil }
        if result.status == 5 {
            return "launchd refused to load it. Check System Settings › General › Login Items."
        }
        return result.output.split(separator: "\n").first.map(String.init) ?? "launchctl failed"
    }

    /// Stops the job and unloads it. Unloading an unknown job is not an error.
    public static func bootout(_ label: String) async {
        _ = await run("bootout", "\(domain)/\(label)")
    }

    /// Clears a persistent `launchctl disable`, which would block `bootstrap`.
    public static func enable(_ label: String) async {
        _ = await run("enable", "\(domain)/\(label)")
    }

    private static func run(_ arguments: String...) async -> (status: Int32, output: String) {
        await runProcess("/bin/launchctl", arguments)
    }
}

/// Runs a tool off the main thread, collecting stdout and stderr together.
func runProcess(
    _ path: String,
    _ arguments: [String],
    input: Data? = nil
) async -> (status: Int32, output: String) {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let stdin = Pipe()
            if input != nil {
                process.standardInput = stdin
                // A tool that exits early must not take the app down with it.
                signal(SIGPIPE, SIG_IGN)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
                return
            }
            if let input {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            continuation.resume(
                returning: (process.terminationStatus, String(decoding: data, as: UTF8.self))
            )
        }
    }
}

/// When a process started, from the kernel, so a freshly launched app can tell
/// a service that just started from one that's been up for days.
public func processStartDate(pid: Int32) -> Date? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let start = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
}
