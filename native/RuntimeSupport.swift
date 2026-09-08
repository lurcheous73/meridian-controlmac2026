import Foundation

enum ControlMacRuntime {
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    static func bundledTool(_ name: String) -> URL? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let url = root.appendingPathComponent("runtime/\(architecture)/bin/\(name)")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func tool(_ name: String) -> URL? {
        if let bundled = bundledTool(name) { return bundled }
        let fallbacks = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return fallbacks.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func backendConfig() -> (mono: String, managed: String)? {
        if let root = Bundle.main.resourceURL {
            let mono = root.appendingPathComponent("runtime/\(architecture)/mono", isDirectory: true)
            let managed = root.appendingPathComponent("managed", isDirectory: true)
            let launcher = mono.appendingPathComponent("bin/mono-sgen64")
            if FileManager.default.isExecutableFile(atPath: launcher.path), FileManager.default.fileExists(atPath: managed.path) {
                return (mono.path, managed.path)
            }
        }
        guard let u = Bundle.main.url(forResource: "Backend", withExtension: "plist"),
              let p = NSDictionary(contentsOf: u),
              let mono = p["MonoRoot"] as? String,
              let managed = p["ManagedRoot"] as? String else { return nil }
        return (mono, managed)
    }
}

extension ControlMacRuntime {
    static func relocatedMonoConfig(monoRoot: String) -> URL? {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: monoRoot).appendingPathComponent("etc/mono/config")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else { return nil }
        let lib = URL(fileURLWithPath: monoRoot).appendingPathComponent("lib").path
        let relocated = text.replacingOccurrences(of: "$mono_libdir/", with: lib + "/")
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("ControlMac2026/runtime/\(architecture)/mono-config", isDirectory: true)
        let output = dir.appendingPathComponent("config")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try relocated.write(to: output, atomically: true, encoding: .utf8)
            return output
        } catch { return nil }
    }

    static func configureMonoEnvironment(_ env: inout [String: String], monoRoot: String, managed: String) {
        env["MONO_PATH"] = monoRoot + "/lib/mono/4.5:" + managed
        env["DYLD_LIBRARY_PATH"] = monoRoot + "/lib"
        if let root = Bundle.main.resourceURL {
            env["CONTROLMAC_TOOL_DIR"] = root.appendingPathComponent("runtime/\(architecture)/bin", isDirectory: true).path
        }
    }

    static func monoArguments(executable: URL, arguments: [String], monoRoot: String) -> [String] {
        if let config = relocatedMonoConfig(monoRoot: monoRoot) {
            return ["--config", config.path, executable.path] + arguments
        }
        return [executable.path] + arguments
    }
}
