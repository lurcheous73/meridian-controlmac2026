import Foundation
import CryptoKit
import Security

struct BandcampSong: Decodable {
    let id: String
    let title: String
    let album: String?
    let artist: String?
    let suffix: String?
    let contentType: String?
    let duration: Int?
    let coverArt: String?
}

struct BandcampAlbum: Decodable {
    let id: String
    let name: String
    let artist: String?
    let year: Int?
    let coverArt: String?
    let songCount: Int?
}
final class BandcampService {
    static let baseURL = URL(string: "https://bandcamp.com/api/subsonic")!
    static let clientName = "ControlMac2026"
    static let apiVersion = "1.16.1"
    static let keychainService = "uk.controlmac2026.bandcamp-subsonic"

    struct Credentials {
        let username: String
        let password: String
    }

    enum BandcampError: LocalizedError {
        case badResponse(String)
        case notConfigured
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .badResponse(let s): return s
            case .notConfigured: return "Bandcamp Subsonic credentials are not configured."
            case .keychain(let s): return "macOS Keychain error \(s)."
            }
        }
    }
    static func save(_ credentials: Credentials) throws {
        UserDefaults.standard.set(credentials.username, forKey: "bandcampSubsonicUsername")
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: credentials.username
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(credentials.password.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw BandcampError.keychain(status) }
    }

    static func load() throws -> Credentials {
        guard let username = UserDefaults.standard.string(forKey: "bandcampSubsonicUsername"), !username.isEmpty else {
            throw BandcampError.notConfigured
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: username,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            if status == errSecItemNotFound { throw BandcampError.notConfigured }
            throw BandcampError.keychain(status)
        }
        return Credentials(username: username, password: secret)
    }

    static func serverURL() -> URL {
        let fallback = "https://bandcamp.com/api/subsonic"
        let raw = UserDefaults.standard.string(forKey: "bandcampSubsonicServer") ?? fallback
        return URL(string: raw) ?? baseURL
    }
    private static func authItems(_ credentials: Credentials) -> [URLQueryItem] {
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let material = Data((credentials.password + salt).utf8)
        let digest = Insecure.MD5.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return [
            URLQueryItem(name: "u", value: credentials.username),
            URLQueryItem(name: "t", value: digest),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json")
        ]
    }
    private static func endpoint(_ method: String, credentials: Credentials, extra: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: serverURL().appendingPathComponent("rest/\(method).view"), resolvingAgainstBaseURL: false)!
        c.queryItems = authItems(credentials) + extra
        return c.url!
    }

    private static func responseObject(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["subsonic-response"] as? [String: Any] else {
            throw BandcampError.badResponse("Bandcamp returned an invalid Subsonic response.")
        }
        if let error = response["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Bandcamp rejected the request."
            throw BandcampError.badResponse(message)
        }
        guard (response["status"] as? String) == "ok" else {
            throw BandcampError.badResponse("Bandcamp Subsonic request did not succeed.")
        }
        return response
    }
    static func request(_ method: String, extra: [URLQueryItem] = [], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let credentials: Credentials
        do { credentials = try load() }
        catch { completion(.failure(error)); return }
        let url = endpoint(method, credentials: credentials, extra: extra)
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("ControlMac2026/0.2", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data = data else {
                completion(.failure(BandcampError.badResponse("Bandcamp returned an unexpected HTTP response."))); return
            }
            do { completion(.success(try responseObject(data))) }
            catch { completion(.failure(error)) }
        }.resume()
    }

    static func ping(completion: @escaping (Result<Void, Error>) -> Void) {
        request("ping") { result in completion(result.map { _ in () }) }
    }
    static func albums(offset: Int = 0, completion: @escaping (Result<[BandcampAlbum], Error>) -> Void) {
        let extra = [
            URLQueryItem(name: "type", value: "alphabeticalByArtist"),
            URLQueryItem(name: "size", value: "500"),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        request("getAlbumList2", extra: extra) { result in
            completion(result.flatMap { response in
                guard let list = response["albumList2"] as? [String: Any] else { return .success([]) }
                let rows = list["album"] as? [[String: Any]] ?? []
                let albums = rows.compactMap { row -> BandcampAlbum? in
                    guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
                    return BandcampAlbum(id: id, name: name, artist: row["artist"] as? String,
                        year: row["year"] as? Int, coverArt: row["coverArt"] as? String,
                        songCount: row["songCount"] as? Int)
                }
                return .success(albums)
            })
        }
    }
    static func album(id: String, completion: @escaping (Result<[BandcampSong], Error>) -> Void) {
        request("getAlbum", extra: [URLQueryItem(name: "id", value: id)]) { result in
            completion(result.flatMap { response in
                guard let album = response["album"] as? [String: Any] else { return .success([]) }
                let rows = album["song"] as? [[String: Any]] ?? []
                let songs = rows.compactMap { row -> BandcampSong? in
                    guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
                    return BandcampSong(id: id, title: title, album: row["album"] as? String,
                        artist: row["artist"] as? String, suffix: row["suffix"] as? String,
                        contentType: row["contentType"] as? String, duration: row["duration"] as? Int,
                        coverArt: row["coverArt"] as? String)
                }
                return .success(songs)
            })
        }
    }

    static func downloadURL(songID: String) throws -> URL {
        let credentials = try load()
        return endpoint("download", credentials: credentials, extra: [URLQueryItem(name: "id", value: songID)])
    }
}
