import Foundation
import Testing

@testable import LauncherCore

@Suite struct ServiceStatusTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    private func status(
        _ job: JobStatus?,
        restart: Service.Restart = .no,
        launchedAt: Date? = nil,
        age: TimeInterval = 100
    ) -> ServiceStatus {
        ServiceStatus(job: job, restart: restart, launchedAt: launchedAt, now: now) { _ in
            now.addingTimeInterval(-age)
        }
    }

    @Test func notLoadedIsStopped() {
        #expect(status(nil) == .stopped)
    }

    @Test func aNewProcessIsStartingThenRunning() {
        let job = JobStatus(pid: 12, lastExit: 0)
        #expect(status(job, age: 1) == .starting)
        #expect(status(job, age: 5) == .running(pid: 12, since: now.addingTimeInterval(-5)))
    }

    @Test func aRunningRestartHidesTheOldFailure() {
        #expect(status(JobStatus(pid: 12, lastExit: 7)).isRunning)
    }

    @Test func nonZeroExitIsAFailure() {
        #expect(status(JobStatus(pid: nil, lastExit: 3)) == .failed("Exited with code 3"))
        #expect(
            status(JobStatus(pid: nil, lastExit: 3), restart: .onFailure)
                == .failed("Exited with code 3, launchd will retry"))
    }

    @Test func signalsAreNamed() {
        #expect(status(JobStatus(pid: nil, lastExit: -9)) == .failed("Killed: 9"))
        #expect(status(JobStatus(pid: nil, lastExit: -11)) == .failed("Segmentation fault: 11"))
    }

    @Test func cleanExitIsFinished() {
        #expect(status(JobStatus(pid: nil, lastExit: 0)) == .finished)
    }

    @Test func cleanExitWaitingForRespawnIsStarting() {
        #expect(status(JobStatus(pid: nil, lastExit: 0), restart: .always) == .starting)
    }

    @Test func parsesLaunchctlList() {
        let output = """
            PID\tStatus\tLabel
            -\t78\tlocal.launcher.bad
            64846\t0\tlocal.launcher.ok
            -\t-9\tlocal.launcher.killed
            123\t0\tcom.apple.other
            """
        #expect(
            Launchctl.parseList(output, prefix: "local.launcher.") == [
                "local.launcher.bad": JobStatus(pid: nil, lastExit: 78),
                "local.launcher.ok": JobStatus(pid: 64846, lastExit: 0),
                "local.launcher.killed": JobStatus(pid: nil, lastExit: -9),
            ])
    }
}
