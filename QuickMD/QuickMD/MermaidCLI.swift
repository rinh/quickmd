import AppKit
import WebKit

// MARK: - Mermaid via mermaid-cli (mmdc)

/// Optional second Mermaid renderer: the reader's own `mmdc` (mermaid-cli)
/// instead of the bundled mermaid.min.js. Settings ▸ General ▸ Mermaid.
///
/// Only the SVG comes from mmdc. The page that shows it is the same template
/// as the built-in path (`renderDiagram(…, useCLI: true)` asks Swift through
/// the `mmdc` reply handler), so sizing, zoom, the height report, snapshots
/// and PDF export do not know which renderer drew the diagram. Any mmdc
/// failure (not found, parse error, timeout) rejects the page's promise and
/// the template falls back to the built-in renderer.
///
/// Needs an unsandboxed build: mmdc is a Node script that starts a headless
/// Chromium, neither of which a sandboxed child process may do.
enum MermaidCLI {

    static let rendererKey = "mermaidRenderer"
    static let pathKey = "mmdcPath"
    static let configPathKey = "mmdcConfigPath"

    enum Renderer: String, CaseIterable, Identifiable {
        case builtIn
        case mmdc
        var id: String { rawValue }
        var title: String {
            switch self {
            case .builtIn: return "Built-in (mermaid.js)"
            case .mmdc: return "mmdc (mermaid-cli)"
            }
        }
    }

    static var isEnabled: Bool {
        UserDefaults.standard.string(forKey: rendererKey) == Renderer.mmdc.rawValue
    }

    struct Failure: Error {
        let message: String
    }

    // MARK: Rendering

    private static let svgCache = NSCache<NSString, NSString>()
    /// Each mmdc run starts a Chromium; a document with twenty diagrams must
    /// not start twenty at once.
    private static let slots = DispatchSemaphore(value: 2)
    private static let queue = DispatchQueue(label: "QuickMD.mmdc", qos: .userInitiated, attributes: .concurrent)

    /// Renders `source` to SVG text off the main thread. `completion` runs on
    /// the main thread.
    static func render(source: String, isDark: Bool,
                       completion: @escaping (Result<String, Failure>) -> Void) {
        let configPath = trimmedDefault(configPathKey)
        let key = cacheKey(source: source, isDark: isDark, configPath: configPath) as NSString
        if let cached = svgCache.object(forKey: key) {
            completion(.success(cached as String))
            return
        }
        queue.async {
            slots.wait()
            defer { slots.signal() }
            let result = renderNow(source: source, isDark: isDark, configPath: configPath)
            if case .success(let svg) = result {
                svgCache.setObject(svg as NSString, forKey: key)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The config file's modification date is part of the key, so editing
    /// the config re-renders without a restart.
    private static func cacheKey(source: String, isDark: Bool, configPath: String?) -> String {
        var config = "-"
        if let configPath {
            let modified = (try? FileManager.default.attributesOfItem(atPath: configPath)[.modificationDate] as? Date)
            config = "\(configPath)@\(modified?.timeIntervalSince1970 ?? 0)"
        }
        return "\(isDark)|\(config)|\(source)"
    }

    private static func renderNow(source: String, isDark: Bool,
                                  configPath: String?) -> Result<String, Failure> {
        guard let tool = resolveTool() else {
            return .failure(Failure(message: "mmdc not found. Install it with `npm install -g @mermaid-js/mermaid-cli` or set its path in Settings."))
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("QuickMD-mmdc-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
        defer { try? fm.removeItem(at: dir) }
        let input = dir.appendingPathComponent("diagram.mmd")
        let output = dir.appendingPathComponent("diagram.svg")
        do {
            try source.write(to: input, atomically: true, encoding: .utf8)
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }

        var arguments = ["-i", input.path, "-o", output.path,
                         "-t", isDark ? "dark" : "default", "-b", "transparent", "-q"]
        if let configPath { arguments += ["-c", configPath] }

        guard let run = Self.run(tool.executable, arguments, environment: tool.environment, timeout: 30) else {
            return .failure(Failure(message: "mmdc timed out."))
        }
        guard run.status == 0, let svg = try? String(contentsOf: output, encoding: .utf8), !svg.isEmpty else {
            let detail = String(data: run.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(Failure(message: detail.isEmpty ? "mmdc exited with status \(run.status)." : detail))
        }
        return .success(svg)
    }

    // MARK: Finding mmdc

    struct Tool {
        let executable: URL
        let environment: [String: String]
    }

    private static let lock = NSLock()
    private static var loginShellProbe: (path: String?, mmdc: String?)?

    /// The Settings path when set, else `mmdc` on the login shell's PATH. An
    /// app started from the Finder does not inherit that PATH (nvm, Homebrew
    /// and npm prefixes live in the shell's startup files), so it is asked once
    /// and remembered. The same PATH goes to mmdc, whose `#!/usr/bin/env node`
    /// needs to find node.
    static func resolveTool() -> Tool? {
        let probe = shellProbe()
        let executable: String
        if let override = trimmedDefault(pathKey) {
            executable = (override as NSString).expandingTildeInPath
        } else if let found = probe.mmdc {
            executable = found
        } else {
            return nil
        }
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        var environment = ProcessInfo.processInfo.environment
        let toolDir = (executable as NSString).deletingLastPathComponent
        let basePath = probe.path ?? environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = toolDir + ":" + basePath
        return Tool(executable: URL(fileURLWithPath: executable), environment: environment)
    }

    /// Forgets the login-shell answer (Settings ▸ Test, after installing mmdc).
    static func resetDiscovery() {
        lock.lock()
        loginShellProbe = nil
        lock.unlock()
        svgCache.removeAllObjects()
    }

    private static func shellProbe() -> (path: String?, mmdc: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let loginShellProbe { return loginShellProbe }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Markers, because interactive startup files may print anything.
        let script = #"printf '\n__QMD_PATH__%s\n__QMD_MMDC__%s\n' "$PATH" "$(command -v mmdc)""#
        var result: (path: String?, mmdc: String?) = (nil, nil)
        if let run = run(URL(fileURLWithPath: shell), ["-ilc", script], environment: nil, timeout: 10),
           let text = String(data: run.stdout, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if line.hasPrefix("__QMD_PATH__") {
                    let value = String(line.dropFirst("__QMD_PATH__".count))
                    if !value.isEmpty { result.path = value }
                } else if line.hasPrefix("__QMD_MMDC__") {
                    let value = String(line.dropFirst("__QMD_MMDC__".count))
                    if value.hasPrefix("/") { result.mmdc = value }
                }
            }
        }
        loginShellProbe = result
        return result
    }

    /// "mmdc 12.0.0 — /path/to/mmdc", or why it cannot run. Blocking: call
    /// off the main thread.
    static func statusDescription() -> String {
        guard let tool = resolveTool() else {
            return "mmdc not found. Install it with `npm install -g @mermaid-js/mermaid-cli`, or set its path above."
        }
        guard let run = run(tool.executable, ["--version"], environment: tool.environment, timeout: 15),
              run.status == 0 else {
            return "\(tool.executable.path) did not run."
        }
        let version = String(data: run.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        return "mmdc \(version) — \(tool.executable.path)"
    }

    // MARK: Helpers

    private static func trimmedDefault(_ key: String) -> String? {
        guard let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return (value as NSString).expandingTildeInPath
    }

    private final class Output {
        var stdout = Data()
        var stderr = Data()
    }

    /// Runs a process to completion; nil when it could not start or ran past
    /// `timeout` (it is terminated then).
    private static func run(_ executable: URL, _ arguments: [String],
                            environment: [String: String]?,
                            timeout: TimeInterval) -> (status: Int32, stdout: Data, stderr: Data)? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Both pipes drained concurrently: a full pipe would stall the child.
        let output = Output()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            output.stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            output.stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return (process.terminationStatus, output.stdout, output.stderr)
    }
}

// MARK: - Bridge for the template page

/// `window.webkit.messageHandlers.mmdc.postMessage({source, isDark})` in
/// mermaid-template.html resolves with mmdc's SVG or rejects with its error.
/// One shared instance: the user content controller retains its handlers, and
/// this one holds no per-view state.
final class MermaidCLIBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = MermaidCLIBridge()
    static let handlerName = "mmdc"

    static func install(in configuration: WKWebViewConfiguration) {
        configuration.userContentController.addScriptMessageHandler(shared, contentWorld: .page, name: handlerName)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let source = body["source"] as? String else {
            replyHandler(nil, "Bad mmdc request.")
            return
        }
        let isDark = body["isDark"] as? Bool ?? false
        MermaidCLI.render(source: source, isDark: isDark) { result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let svg): replyHandler(svg, nil)
                case .failure(let failure): replyHandler(nil, failure.message)
                }
            }
        }
    }
}
