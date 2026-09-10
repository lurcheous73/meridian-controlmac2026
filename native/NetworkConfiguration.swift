import Foundation
import Darwin

enum ControlMacServiceKind: String {
    case sooloos = "Sooloos"
    case surroundCore = "SurroundCore"
}

struct ControlMacDiscoveredService: Hashable {
    let kind: ControlMacServiceKind
    let name: String
    let host: String
    let port: Int
    let detail: String

    var displayAddress: String {
        switch kind {
        case .sooloos:
            return host
        case .surroundCore:
            return "http://\(host):\(port)"
        }
    }
}

enum ControlMacConfiguration {
    private static let defaults = UserDefaults.standard
    static let sooloosKey = "sooloosCore"
    static let surroundCoreKey = "surroundCore"

    static var sooloosAddress: String {
        get {
            if let value = defaults.string(forKey: sooloosKey), !value.isEmpty { return value }
            return defaults.string(forKey: "core") ?? ""
        }
        set {
            let clean = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(clean, forKey: sooloosKey)
            // Keep the old key during the transition so existing code/builds do not regress.
            defaults.set(clean, forKey: "core")
        }
    }

    static var surroundCoreAddress: String {
        get { defaults.string(forKey: surroundCoreKey) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: surroundCoreKey) }
    }
}

final class ControlMacNetworkDiscovery {
    private let session: URLSession
    private let callbackQueue = DispatchQueue.main

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.2
        cfg.timeoutIntervalForResource = 1.8
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: cfg)
    }

    func scan(progress: @escaping (String) -> Void,
              completion: @escaping ([ControlMacDiscoveredService]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let candidates = self.localIPv4Candidates()
            guard !candidates.isEmpty else {
                self.callbackQueue.async { completion([]) }
                return
            }
            self.callbackQueue.async { progress("Scanning \(candidates.count) local addresses…") }

            let group = DispatchGroup()
            let lock = NSLock()
            var found = Set<ControlMacDiscoveredService>()
            let limiter = DispatchSemaphore(value: 24)

            for host in candidates {
                limiter.wait()
                group.enter()
                self.probe(host: host) { services in
                    lock.lock(); services.forEach { found.insert($0) }; lock.unlock()
                    limiter.signal(); group.leave()
                }
            }

            group.notify(queue: .global(qos: .userInitiated)) {
                let result = Array(found).sorted {
                    if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                    return $0.host.localizedStandardCompare($1.host) == .orderedAscending
                }
                self.callbackQueue.async { completion(result) }
            }
        }
    }

    func testSooloos(_ raw: String, completion: @escaping (Bool, String) -> Void) {
        guard let host = normalizedHost(raw) else {
            completion(false, "Invalid Sooloos address")
            return
        }
        probeSooloos(host: host) { service in
            self.callbackQueue.async {
                completion(service != nil, service?.detail ?? "No Sooloos WebClient response")
            }
        }
    }

    func testSurroundCore(_ raw: String, completion: @escaping (Bool, String) -> Void) {
        guard let target = normalizedSurroundCore(raw) else {
            completion(false, "Invalid SurroundCore address")
            return
        }
        probeSurroundCore(host: target.host, port: target.port) { service in
            self.callbackQueue.async {
                completion(service != nil, service?.detail ?? "No SurroundCore API response")
            }
        }
    }

    private func probe(host: String, completion: @escaping ([ControlMacDiscoveredService]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var services: [ControlMacDiscoveredService] = []

        group.enter()
        probeSooloos(host: host) { service in
            if let service = service { lock.lock(); services.append(service); lock.unlock() }
            group.leave()
        }

        group.enter()
        probeSurroundCore(host: host, port: 8080) { service in
            if let service = service { lock.lock(); services.append(service); lock.unlock() }
            group.leave()
        }

        group.notify(queue: .global(qos: .utility)) { completion(services) }
    }

    private func probeSooloos(host: String, completion: @escaping (ControlMacDiscoveredService?) -> Void) {
        guard let url = URL(string: "http://\(host)/webclient/WebClient.html") else { completion(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        session.dataTask(with: req) { data, response, _ in
            guard let http = response as? HTTPURLResponse,
                  (200...399).contains(http.statusCode),
                  let data = data,
                  let text = String(data: data.prefix(131072), encoding: .utf8) else {
                completion(nil); return
            }
            let lower = text.lowercased()
            guard lower.contains("sooloos") || lower.contains("webclient") || lower.contains("gwt") else {
                completion(nil); return
            }
            completion(.init(kind: .sooloos,
                             name: "Meridian Sooloos Core",
                             host: host,
                             port: http.url?.port ?? 80,
                             detail: "Sooloos WebClient detected"))
        }.resume()
    }

    private func probeSurroundCore(host: String, port: Int, completion: @escaping (ControlMacDiscoveredService?) -> Void) {
        guard let url = URL(string: "http://\(host):\(port)/openapi.json") else { completion(nil); return }
        session.dataTask(with: url) { data, response, _ in
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = json["info"] as? [String: Any] else {
                completion(nil); return
            }
            let title = (info["title"] as? String) ?? ""
            let version = (info["version"] as? String) ?? "unknown"
            guard title.lowercased().contains("surround") || String(data: data, encoding: .utf8)?.lowercased().contains("surroundcore") == true else {
                completion(nil); return
            }
            completion(.init(kind: .surroundCore,
                             name: title.isEmpty ? "SurroundCore" : title,
                             host: host,
                             port: port,
                             detail: "API version \(version)"))
        }.resume()
    }

    private func normalizedHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let parts = URLComponents(string: candidate), let host = parts.host, !host.isEmpty else { return nil }
        return host
    }

    private func normalizedSurroundCore(_ raw: String) -> (host: String, port: Int)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let parts = URLComponents(string: candidate), let host = parts.host, !host.isEmpty else { return nil }
        return (host, parts.port ?? 8080)
    }

    private func localIPv4Candidates() -> [String] {
        var result = Set<String>()
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0, let first = ptr else { return [] }
        defer { freeifaddrs(ptr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let flags = Int32(current.pointee.ifa_flags)
            let address = current.pointee.ifa_addr
            if flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
               let address = address, address.pointee.sa_family == UInt8(AF_INET) {
                var addr = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(cString: buffer)
                    let parts = ip.split(separator: ".")
                    if parts.count == 4 {
                        let prefix = parts.prefix(3).joined(separator: ".")
                        for last in 1...254 { result.insert("\(prefix).\(last)") }
                    }
                }
            }
            cursor = current.pointee.ifa_next
        }
        return Array(result)
    }
}
