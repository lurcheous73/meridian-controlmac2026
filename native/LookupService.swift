import Foundation

struct LookupTrack {
    let position: Int
    let title: String
    let length: Int?
}

struct LookupMedium {
    let position: Int
    let format: String
    let trackCount: Int
    let tracks: [LookupTrack]
}

struct LookupRelease {
    let id: String
    let artist: String
    let title: String
    let date: String
    let country: String
    let media: [LookupMedium]

    var displayName: String {
        let formats = media.map { $0.format }.filter { !$0.isEmpty }
        let format = formats.isEmpty ? "?" : Array(Set(formats)).sorted().joined(separator: "/")
        let year = date.isEmpty ? "????" : String(date.prefix(4))
        let place = country.isEmpty ? "??" : country
        return "\(year) · \(place) · \(format) · \(media.count) disc\(media.count == 1 ? "" : "s") — \(title)"
    }
}
private struct MBSearchResponse: Decodable {
    let releases: [MBRelease]
}

private struct MBRelease: Decodable {
    let id: String
    let title: String
    let date: String?
    let country: String?
    let media: [MBMedium]?
    let artistCredit: [MBArtistCredit]?
    enum CodingKeys: String, CodingKey {
        case id, title, date, country, media
        case artistCredit = "artist-credit"
    }
}

private struct MBArtistCredit: Decodable {
    let name: String?
}

private struct MBMedium: Decodable {
    let position: Int?
    let format: String?
    let trackCount: Int?
    let tracks: [MBTrack]?

    enum CodingKeys: String, CodingKey {
        case position, format, tracks
        case trackCount = "track-count"
    }
}

private struct MBTrack: Decodable {
    let position: Int?
    let length: Int?
    let recording: MBRecording
}

private struct MBRecording: Decodable {
    let title: String
}

private struct MBRecordingSearchResponse: Decodable {
    let recordings: [MBRecordingHit]
}

private struct MBRecordingHit: Decodable {
    let title: String
    let releases: [MBRecordingRelease]?
}

private struct MBRecordingRelease: Decodable {
    let id: String
    let title: String
    let date: String?
    let country: String?
}


struct ArtworkLookupCandidate {
    let source: String
    let sourceID: String
    let artist: String
    let title: String
    let year: String
    let country: String
    let format: String
    let detail: String
    let thumbURL: URL?
    let fullURL: URL?
    let musicBrainzReleaseID: String?
}

private struct AudioDBAlbumResponse: Decodable {
    let album: [AudioDBAlbum]?
}

private struct AudioDBAlbum: Decodable {
    let idAlbum: String?
    let strArtist: String?
    let strAlbum: String?
    let intYearReleased: String?
    let strReleaseFormat: String?
    let strAlbumThumb: String?
    let strAlbumThumbHQ: String?
    let strMusicBrainzID: String?
}

private struct CAAResponse: Decodable {
    let images: [CAAImage]
}

private struct CAAImage: Decodable {
    let image: String
    let front: Bool?
    let thumbnails: [String: String]?
}

final class LookupService {
    static let userAgent = "ControlMac2026/0.2 (https://github.com/lurcheous73/meridian-controlmac2026)"
    private static let queue = DispatchQueue(label: "ControlMac.LookupService")
    private static var lastRequest = Date.distantPast

    private static func throttled(_ work: @escaping () -> Void) {
        queue.async {
            let wait = max(0, 1.05 - Date().timeIntervalSince(lastRequest))
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            lastRequest = Date()
            work()
        }
    }

    private static func request(_ url: URL, attempt: Int = 0, completion: @escaping (Result<Data, Error>) -> Void) {
        throttled {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: req) { data, response, error in
                if let error = error {
                    if attempt < 2 { queue.asyncAfter(deadline: .now() + Double(attempt + 1) * 2.0) { request(url, attempt: attempt + 1, completion: completion) } }
                    else { completion(.failure(error)) }
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    completion(.failure(NSError(domain: "ControlMacLookup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Lookup service returned no HTTP response."]))); return
                }
                if (http.statusCode == 429 || http.statusCode == 503), attempt < 3 {
                    let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(attempt + 1) * 2.0
                    queue.asyncAfter(deadline: .now() + max(1.5, retry)) { request(url, attempt: attempt + 1, completion: completion) }
                    return
                }
                guard (200..<300).contains(http.statusCode), let data = data else {
                    completion(.failure(NSError(domain: "ControlMacLookup", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Lookup service returned HTTP \(http.statusCode)."])))
                    return
                }
                completion(.success(data))
            }.resume()
        }
    }
    static func searchDiscTOC(firstTrack: Int, offsets: [Int], leadout: Int, completion: @escaping (Result<[LookupRelease], Error>) -> Void) {
        guard ProviderSettings.musicBrainzEnabled else { completion(.success([])); return }
        guard !offsets.isEmpty else { completion(.success([])); return }
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/discid/-")!
        let toc = ([String(firstTrack), String(offsets.count), String(leadout)] + offsets.map(String.init)).joined(separator: " ")
        c.queryItems = [
            URLQueryItem(name: "toc", value: toc),
            URLQueryItem(name: "inc", value: "recordings+artist-credits"),
            URLQueryItem(name: "fmt", value: "json")
        ]
        request(c.url!) { result in
            completion(result.flatMap { data in
                do { return .success(try JSONDecoder().decode(MBSearchResponse.self, from: data).releases.map(convert)) }
                catch { return .failure(error) }
            })
        }
    }

    static func search(artist: String, title: String, completion: @escaping (Result<[LookupRelease], Error>) -> Void) {
        guard ProviderSettings.musicBrainzEnabled else { completion(.success([])); return }
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        c.queryItems = [
            URLQueryItem(name: "query", value: "release:\"\(title)\" AND artist:\"\(artist)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "20")
        ]
        request(c.url!) { result in
            completion(result.flatMap { data in
                do {
                    let decoded = try JSONDecoder().decode(MBSearchResponse.self, from: data)
                    return .success(decoded.releases.map(convert))
                } catch { return .failure(error) }
            })
        }
    }

    private static func audioDBSearch(artist: String, title: String, completion: @escaping ([ArtworkLookupCandidate]) -> Void) {
        guard ProviderSettings.audioDBEnabled else { completion([]); return }
        let key = ProviderSettings.audioDBKey
        var c = URLComponents(string: "https://www.theaudiodb.com/api/v1/json/\(key)/searchalbum.php")!
        c.queryItems = [URLQueryItem(name: "s", value: artist), URLQueryItem(name: "a", value: title)]
        request(c.url!) { result in
            guard case .success(let data) = result,
                  let decoded = try? JSONDecoder().decode(AudioDBAlbumResponse.self, from: data) else { completion([]); return }
            let candidates = (decoded.album ?? []).compactMap { a -> ArtworkLookupCandidate? in
                guard let id = a.idAlbum, let album = a.strAlbum else { return nil }
                let thumb = (a.strAlbumThumb ?? "").isEmpty ? nil : try? secureExternalURL(a.strAlbumThumb ?? "")
                let fullValue = (a.strAlbumThumbHQ?.isEmpty == false ? a.strAlbumThumbHQ : a.strAlbumThumb) ?? ""
                let full = fullValue.isEmpty ? nil : try? secureExternalURL(fullValue)
                return ArtworkLookupCandidate(source: "TheAudioDB", sourceID: id,
                    artist: a.strArtist ?? artist, title: album, year: a.intYearReleased ?? "",
                    country: "", format: a.strReleaseFormat ?? "Album", detail: "TheAudioDB",
                    thumbURL: thumb, fullURL: full, musicBrainzReleaseID: nil)
            }
            completion(candidates)
        }
    }

    static func artworkCandidates(artist: String, title: String, completion: @escaping (Result<[ArtworkLookupCandidate], Error>) -> Void) {
        let group = DispatchGroup(); let lock = NSLock()
        var all: [ArtworkLookupCandidate] = []; var firstError: Error?
        group.enter()
        search(artist: artist, title: title) { result in
            switch result {
            case .failure(let e): lock.lock(); if firstError == nil { firstError = e }; lock.unlock()
            case .success(let releases):
                let mapped = releases.map { r -> ArtworkLookupCandidate in
                    let format = Array(Set(r.media.map { $0.format }.filter { !$0.isEmpty })).sorted().joined(separator: "/")
                    let year = r.date.isEmpty ? "" : String(r.date.prefix(4))
                    let detail = [year, r.country, format, r.media.isEmpty ? "" : "\(r.media.count) disc\(r.media.count == 1 ? "" : "s")"].filter { !$0.isEmpty }.joined(separator: " · ")
                    let thumb = URL(string: "https://coverartarchive.org/release/\(r.id)/front-250")
                    return ArtworkLookupCandidate(source: "MusicBrainz", sourceID: r.id,
                        artist: artist, title: r.title, year: year, country: r.country, format: format,
                        detail: detail, thumbURL: thumb, fullURL: nil, musicBrainzReleaseID: r.id)
                }
                lock.lock(); all.append(contentsOf: mapped); lock.unlock()
            }
            group.leave()
        }
        group.enter()
        audioDBSearch(artist: artist, title: title) { found in
            lock.lock(); all.append(contentsOf: found); lock.unlock(); group.leave()
        }
        group.enter()
        ExternalArtworkProviders.bandcamp(artist: artist, title: title) { found in
            lock.lock(); all.append(contentsOf: found); lock.unlock(); group.leave()
        }
        group.enter()
        ExternalArtworkProviders.discogs(artist: artist, title: title) { found in
            lock.lock(); all.append(contentsOf: found); lock.unlock(); group.leave()
        }
        group.notify(queue: queue) {
            var seen = Set<String>(); var deduped: [ArtworkLookupCandidate] = []
            for c in all {
                let key = (c.source + "|" + c.sourceID).lowercased()
                if seen.insert(key).inserted { deduped.append(c) }
            }
            if deduped.isEmpty, let e = firstError { completion(.failure(e)) }
            else { completion(.success(deduped)) }
        }
    }

    static func cleanedTrackTitle(_ raw: String, artist: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "\\", with: "/")
        if value.contains("/") { value = String(value.split(separator: "/").last ?? Substring(value)) }
        let lower = value.lowercased()
        for ext in [".flac", ".wav", ".aiff", ".aif", ".mp3", ".m4a", ".aac", ".ogg", ".alac"] {
            if lower.hasSuffix(ext) { value = String(value.dropLast(ext.count)); break }
        }
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanArtist.isEmpty {
            let prefixes = [cleanArtist + " - ", cleanArtist + " – ", cleanArtist + " — "]
            if let prefix = prefixes.first(where: { value.lowercased().hasPrefix($0.lowercased()) }) {
                value = String(value.dropFirst(prefix.count))
            }
        }
        value = value.replacingOccurrences(of: #"^\s*\d{1,3}\s*[-._:]\s*"#, with: "", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func broadTrackTitle(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: #"\s*[\(\[][^\)\]]+[\)\]]\s*$"#, with: "", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func releasesForTrack(artist: String?, track: String, allowBroadFallback: Bool = true,
                                         completion: @escaping (Result<[MBRecordingRelease], Error>) -> Void) {
        func run(_ title: String, broadTried: Bool) {
            var c = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")!
            let cleanArtist = (artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let query = cleanArtist.isEmpty ? "recording:\"\(title)\"" : "recording:\"\(title)\" AND artist:\"\(cleanArtist)\""
            c.queryItems = [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "fmt", value: "json"),
                URLQueryItem(name: "limit", value: "20")
            ]
            request(c.url!) { result in
                switch result {
                case .failure(let error): completion(.failure(error))
                case .success(let data):
                    do {
                        let decoded = try JSONDecoder().decode(MBRecordingSearchResponse.self, from: data)
                        let releases = decoded.recordings.flatMap { $0.releases ?? [] }
                        let broader = broadTrackTitle(title)
                        if releases.isEmpty && allowBroadFallback && !broadTried && !broader.isEmpty && broader.caseInsensitiveCompare(title) != .orderedSame {
                            run(broader, broadTried: true)
                        } else { completion(.success(releases)) }
                    } catch { completion(.failure(error)) }
                }
            }
        }
        run(track, broadTried: false)
    }

    static func searchByTracks(artist: String, tracks: [String], useArtistConstraint: Bool = true,
                               completion: @escaping (Result<[LookupRelease], Error>) -> Void) {
        let cleaned = tracks.map { cleanedTrackTitle($0, artist: artist) }.filter { !$0.isEmpty }
        var unique: [String] = []
        for t in cleaned where !unique.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { unique.append(t) }
        guard !unique.isEmpty else {
            completion(.failure(NSError(domain: "ControlMacLookup", code: 20, userInfo: [NSLocalizedDescriptionKey: "This album has no usable track titles to search."])))
            return
        }
        let positions: [Int]
        if unique.count <= 5 { positions = Array(unique.indices) }
        else { positions = [0, unique.count / 4, unique.count / 2, (unique.count * 3) / 4, unique.count - 1] }
        var seen = Set<Int>(); let sample = positions.filter { seen.insert($0).inserted }.map { unique[$0] }
        let group = DispatchGroup(); let lock = NSLock()
        var hits: [String: Int] = [:]
        for track in sample {
            group.enter()
            releasesForTrack(artist: useArtistConstraint ? artist : nil, track: track) { result in
                if case .success(let releases) = result {
                    let ids = Set(releases.map { $0.id })
                    lock.lock(); for id in ids { hits[id, default: 0] += 1 }; lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: queue) {
            let rankedIDs = hits.keys.sorted {
                let lh = hits[$0, default: 0], rh = hits[$1, default: 0]
                return lh == rh ? $0 < $1 : lh > rh
            }.prefix(16)
            guard !rankedIDs.isEmpty else {
                completion(.failure(NSError(domain: "ControlMacLookup", code: 21, userInfo: [NSLocalizedDescriptionKey: "No release could be identified from these track titles."])))
                return
            }
            let detailGroup = DispatchGroup(); var found: [String: LookupRelease] = [:]
            for id in rankedIDs {
                detailGroup.enter()
                details(releaseID: id) { result in
                    if case .success(let release) = result { lock.lock(); found[id] = release; lock.unlock() }
                    detailGroup.leave()
                }
            }
            detailGroup.notify(queue: queue) {
                completion(.success(rankedIDs.compactMap { found[$0] }))
            }
        }
    }

    static func details(releaseID: String, completion: @escaping (Result<LookupRelease, Error>) -> Void) {
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/release/\(releaseID)")!
        c.queryItems = [URLQueryItem(name: "inc", value: "recordings"), URLQueryItem(name: "fmt", value: "json")]
        request(c.url!) { result in
            completion(result.flatMap { data in
                do { return .success(convert(try JSONDecoder().decode(MBRelease.self, from: data))) }
                catch { return .failure(error) }
            })
        }
    }

    private static func secureExternalURL(_ value: String) throws -> URL {
        guard var parts = URLComponents(string: value) else { throw URLError(.badURL) }
        if parts.scheme?.lowercased() == "http" { parts.scheme = "https" }
        guard parts.scheme?.lowercased() == "https", let url = parts.url else {
            throw NSError(domain: "ControlMacLookup", code: 3, userInfo: [NSLocalizedDescriptionKey: "Artwork provider returned an insecure or invalid URL."])
        }
        return url
    }

    static func frontCoverURL(releaseID: String, completion: @escaping (Result<URL, Error>) -> Void) {
        let url = URL(string: "https://coverartarchive.org/release/\(releaseID)")!
        request(url) { result in
            completion(result.flatMap { data in
                do {
                    let decoded = try JSONDecoder().decode(CAAResponse.self, from: data)
                    guard let image = decoded.images.first(where: { $0.front == true }) ?? decoded.images.first else {
                        return .failure(NSError(domain: "ControlMacLookup", code: 2, userInfo: [NSLocalizedDescriptionKey: "No artwork is available for this release."]))
                    }
                    let value = image.thumbnails?["1200"] ?? image.thumbnails?["large"] ?? image.image
                    return .success(try secureExternalURL(value))
                } catch { return .failure(error) }
            })
        }
    }
    private static func convert(_ r: MBRelease) -> LookupRelease {
        let media = (r.media ?? []).map { m in
            let tracks = (m.tracks ?? []).map {
                LookupTrack(position: $0.position ?? 0, title: $0.recording.title, length: $0.length)
            }
            return LookupMedium(position: m.position ?? 0, format: m.format ?? "", trackCount: m.trackCount ?? tracks.count, tracks: tracks)
        }
        let artist = (r.artistCredit ?? []).compactMap { $0.name }.joined(separator: " / ")
        return LookupRelease(id: r.id, artist: artist, title: r.title, date: r.date ?? "", country: r.country ?? "", media: media)
    }
}
