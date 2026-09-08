import Foundation

enum ExternalArtworkProviders {
    private static func httpsURL(_ raw: String?) -> URL? {
        guard let raw = raw, !raw.isEmpty, var c = URLComponents(string: raw) else { return nil }
        if c.scheme?.lowercased() == "http" { c.scheme = "https" }
        guard c.scheme?.lowercased() == "https" else { return nil }
        return c.url
    }

    static func bandcamp(artist: String, title: String,
                         completion: @escaping ([ArtworkLookupCandidate]) -> Void) {
        guard ProviderSettings.bandcampEnabled else { completion([]); return }
        var c = URLComponents(string: "https://bandcamp.com/api/fuzzysearch/2/app_autocomplete")!
        c.queryItems = [
            URLQueryItem(name: "q", value: artist + " " + title),
            URLQueryItem(name: "param_with_locations", value: "true")
        ]
        var req = URLRequest(url: c.url!, timeoutInterval: 20)
        req.setValue("ControlMac2026/0.2", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = root["results"] as? [[String: Any]] else { completion([]); return }
            var seen = Set<String>()
            var out: [ArtworkLookupCandidate] = []
            for row in rows {
                let type = row["type"] as? String ?? ""
                var sourceID = ""
                var albumTitle = ""
                if type == "a" {
                    if let id = row["id"] { sourceID = String(describing: id) }
                    albumTitle = row["name"] as? String ?? ""
                } else if type == "t" {
                    if let id = row["album_id"] { sourceID = String(describing: id) }
                    albumTitle = row["album_name"] as? String ?? ""
                }
                guard !sourceID.isEmpty, !albumTitle.isEmpty,
                      seen.insert(sourceID).inserted else { continue }
                let band = row["band_name"] as? String ?? artist
                let image = httpsURL(row["img"] as? String)
                out.append(ArtworkLookupCandidate(source: "Bandcamp", sourceID: sourceID,
                    artist: band, title: albumTitle, year: "", country: "",
                    format: "Digital", detail: "Bandcamp", thumbURL: image,
                    fullURL: image, musicBrainzReleaseID: nil))
            }
            completion(out)
        }.resume()
    }
    static func discogs(artist: String, title: String,
                        completion: @escaping ([ArtworkLookupCandidate]) -> Void) {
        guard ProviderSettings.discogsEnabled,
              let token = ProviderSettings.discogsToken, !token.isEmpty else { completion([]); return }
        var c = URLComponents(string: "https://api.discogs.com/database/search")!
        c.queryItems = [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "release_title", value: title),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: "20"),
            URLQueryItem(name: "token", value: token)
        ]
        var req = URLRequest(url: c.url!, timeoutInterval: 20)
        req.setValue("ControlMac2026/0.2", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = root["results"] as? [[String: Any]] else { completion([]); return }
            let out = rows.compactMap { row -> ArtworkLookupCandidate? in
                guard let id = row["id"] else { return nil }
                let rawTitle = row["title"] as? String ?? title
                let albumTitle = rawTitle.contains(" - ") ? String(rawTitle.split(separator: " - ", maxSplits: 1).last ?? Substring(rawTitle)) : rawTitle
                let formats = (row["format"] as? [String] ?? []).joined(separator: "/")
                let year = row["year"].map { String(describing: $0) } ?? ""
                let country = row["country"] as? String ?? ""
                let thumb = httpsURL(row["thumb"] as? String)
                let full = httpsURL(row["cover_image"] as? String)
                let detail = ["Discogs", year, country, formats].filter { !$0.isEmpty }.joined(separator: " · ")
                return ArtworkLookupCandidate(source: "Discogs", sourceID: String(describing: id),
                    artist: artist, title: albumTitle, year: year, country: country,
                    format: formats, detail: detail, thumbURL: thumb, fullURL: full,
                    musicBrainzReleaseID: nil)
            }
            completion(out)
        }.resume()
    }
}
