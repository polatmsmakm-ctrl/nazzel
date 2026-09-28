import Foundation

/// Swift wrapper around the embedded Python download engine.
///
/// All calls block while Python works, so they must never run on the main thread
/// (the WebKit JS helper used for YouTube needs the main run loop to stay free).
final class PythonEngine: @unchecked Sendable {
    static let shared = PythonEngine()

    private let lock = NSLock()
    private let bootGroup = DispatchGroup()
    private var bootStarted = false
    private(set) var bootError: String?
    private let workQueue = DispatchQueue(label: "nazzel.python.calls", qos: .userInitiated, attributes: .concurrent)

    private init() {}

    /// Starts Python on a background thread (idempotent).
    func bootInBackground(warmUp: Bool = true) {
        lock.lock()
        if bootStarted {
            lock.unlock()
            return
        }
        bootStarted = true
        bootGroup.enter()
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            self.bootNow()
            self.bootGroup.leave()
            Task { @MainActor in EngineStatus.shared.bootFinished(error: self.bootError) }
            guard warmUp, self.bootError == nil else { return }
            let info = self.call("warmup")
            Task { @MainActor in EngineStatus.shared.update(with: info) }
        }
    }

    private func bootNow() {
        Paths.ensure()
        let resources = Bundle.main.resourcePath ?? Bundle.main.bundlePath
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = nz_python_start(resources, Paths.pycache.path, &errorPointer)
        if rc != 0 {
            if let errorPointer {
                bootError = String(cString: errorPointer)
                nz_python_free(errorPointer)
            } else {
                bootError = "Python failed to start"
            }
            return
        }
        var initArgs: [String: Any] = [
            "documents": Paths.downloads.path,
            "caches": Paths.caches.path,
            "engine_dir": Paths.engine.path,
        ]
        if SelfTest.isRequested {
            initArgs["watchdog"] = SelfTest.watchdogFile.path
            initArgs["watchdog_seconds"] = 30
        }
        let result = rawCall("init", initArgs)
        if result["ok"] as? Bool != true {
            bootError = result["error"] as? String ?? "engine init failed"
        }
    }

    /// Blocking call. Never use from the main thread.
    func call(_ name: String, _ args: [String: Any] = [:]) -> [String: Any] {
        precondition(!Thread.isMainThread, "Python calls must not run on the main thread")
        bootInBackground()
        bootGroup.wait()
        if let bootError {
            return ["ok": false, "error": "تعذر تشغيل المحرك", "detail": bootError]
        }
        return rawCall(name, args)
    }

    func callAsync(_ name: String, _ args: [String: Any] = [:]) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            workQueue.async {
                let result = self.call(name, args)
                continuation.resume(returning: result)
            }
        }
    }

    private func rawCall(_ name: String, _ args: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        guard let out = nz_python_call(name, json) else {
            return ["ok": false, "error": "no response from engine"]
        }
        defer { nz_python_free(out) }
        let text = String(cString: out)
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return ["ok": false, "error": "bad response from engine", "detail": text]
        }
        return object
    }
}

/// UI-facing state of the engine (versions, boot errors).
@MainActor
final class EngineStatus: ObservableObject {
    static let shared = EngineStatus()

    @Published private(set) var isBooting = true
    @Published private(set) var bootError: String?
    @Published private(set) var ytDlpVersion: String?
    @Published private(set) var pythonVersion: String?
    @Published private(set) var source: String?
    @Published private(set) var extras: [String: String] = [:]

    func bootFinished(error: String?) {
        bootError = error
        if error != nil { isBooting = false }
    }

    func update(with info: [String: Any]) {
        isBooting = false
        if info["ok"] as? Bool == false, let error = info["error"] as? String {
            bootError = (info["detail"] as? String).map { "\(error)\n\($0)" } ?? error
            return
        }
        ytDlpVersion = info["yt_dlp"] as? String
        pythonVersion = info["python"] as? String
        source = info["source"] as? String
        var extras: [String: String] = [:]
        if let ejs = info["ejs"] as? String { extras["yt-dlp-ejs"] = ejs }
        if let jsi = info["webkit_jsi"] as? String { extras["WebKit JS"] = jsi }
        if let gallery = info["gallery_dl"] as? String { extras["gallery-dl"] = gallery }
        self.extras = extras
    }

    var isUpdated: Bool { source == "updated" }
}
