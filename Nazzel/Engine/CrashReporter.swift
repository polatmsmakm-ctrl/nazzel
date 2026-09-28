import Darwin
import Foundation
import UIKit

/// Catches crashes so they can be reported and fixed:
/// - Swift runtime errors ("Fatal error: …") are printed to stderr, which we keep in a file
/// - signals (SIGSEGV, SIGABRT, SIGTRAP …) append a stack trace
/// - Objective-C exceptions append their reason and call stack
/// On the next launch the report is shown in Settings with a copy button.
enum CrashReporter {
    private static var folder: URL { Paths.support.appendingPathComponent("crash", isDirectory: true) }
    private static var stderrFile: URL { folder.appendingPathComponent("stderr.log") }
    private static var signalFile: URL { folder.appendingPathComponent("signal.log") }
    private static var runningFlag: URL { folder.appendingPathComponent("running") }
    static var reportFile: URL { Paths.support.appendingPathComponent("last-crash.txt") }

    static var lastReport: String? {
        guard let text = try? String(contentsOf: reportFile, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    static func clearReport() {
        try? FileManager.default.removeItem(at: reportFile)
    }

    @MainActor
    static func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // The flag survives only if the last session ended without leaving the foreground cleanly.
        if fm.fileExists(atPath: runningFlag.path) {
            let signalText = (try? String(contentsOf: signalFile, encoding: .utf8)) ?? ""
            let stderrText = (try? String(contentsOf: stderrFile, encoding: .utf8)) ?? ""
            let interesting = stderrText.split(separator: "\n").suffix(60).joined(separator: "\n")
            if !signalText.isEmpty || stderrText.contains("Fatal error") || stderrText.contains("Terminating app") {
                let info = Bundle.main.infoDictionary
                let version = "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
                let report = """
                Nazzel \(version) · iOS \(UIDevice.current.systemVersion) · \(deviceModel())
                \(Date())

                \(signalText)
                --- stderr ---
                \(interesting)
                """
                try? report.write(to: reportFile, atomically: true, encoding: .utf8)
            }
        }
        try? fm.removeItem(at: signalFile)

        if !SelfTest.isRequested {
            // Keep stderr in a file (Swift prints its fatal error message there).
            freopen(stderrFile.path, "w", stderr)
            setvbuf(stderr, nil, _IONBF, 0)
        }
        signalFD = open(signalFile.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig, crashSignalHandler)
        }
        NSSetUncaughtExceptionHandler(crashExceptionHandler)

        markRunning(true)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            markRunning(false)
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            markRunning(true)
        }
        center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            markRunning(false)
        }
    }

    private static func markRunning(_ running: Bool) {
        if running {
            FileManager.default.createFile(atPath: runningFlag.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: runningFlag)
        }
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

// Signal handling must avoid allocation: everything is prepared up front.
nonisolated(unsafe) private var signalFD: Int32 = -1
nonisolated(unsafe) private var crashFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)

private func crashExceptionHandler(_ exception: NSException) {
    var text = "Exception: \(exception.name.rawValue)\nReason: \(exception.reason ?? "-")\n"
    text += exception.callStackSymbols.prefix(40).joined(separator: "\n")
    text += "\n"
    if signalFD >= 0 {
        text.withCString { pointer in
            _ = write(signalFD, pointer, strlen(pointer))
        }
    }
}

private func crashSignalHandler(_ sig: Int32) {
    if signalFD >= 0 {
        let header: StaticString = "Signal "
        _ = write(signalFD, header.utf8Start, header.utf8CodeUnitCount)
        var digits: (UInt8, UInt8, UInt8) = (0x30, 0x30, 0x0A)
        digits.0 = UInt8(0x30 + (sig / 10) % 10)
        digits.1 = UInt8(0x30 + sig % 10)
        withUnsafeBytes(of: &digits) { raw in
            _ = write(signalFD, raw.baseAddress, 3)
        }
        let count = backtrace(crashFrames, 128)
        backtrace_symbols_fd(crashFrames, count, signalFD)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}
