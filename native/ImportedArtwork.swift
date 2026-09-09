import AppKit
import Foundation

extension ControlMacApp {
    func canonicalArtworkTitle(_ editionTitle: String) -> String {
        var value = editionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"\s*[\(\[][^\)\]]*(?:blu[ -]?ray|dvd(?:-a)?|sacd|hi[ -]?res|24\s*/\s*\d+|stereo|5\.1|quad|instrumental)[^\)\]]*[\)\]]\s*$"#,
            #"\s*[-–—]\s*(?:blu[ -]?ray|dvd(?:-a)?|sacd|hi[ -]?res).*$"#
        ]
        var changed = true
        while changed {
            changed = false
            for pattern in patterns {
                let next = value.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if next != value { value = next; changed = true }
            }
        }
        return value.isEmpty ? editionTitle : value
    }

    func verifiedAlbumID(from batchOutput: String) -> String? {
        for line in batchOutput.split(separator: "\n").reversed() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.count >= 2, fields[0] == "CMVERIFIED" { return String(fields[1]) }
        }
        return nil
    }
    func preferredArtworkMedium(_ editionTitle: String) -> String? {
        let value = editionTitle.lowercased()
        if value.contains("blu-ray") || value.contains("bluray") { return "blu-ray" }
        if value.contains("dvd-a") || value.contains("dvd audio") { return "dvd-audio" }
        if value.contains("dvd") { return "dvd" }
        if value.contains("sacd") { return "sacd" }
        return nil
    }

    func importedArtworkScore(_ release: LookupRelease, artist: String, canonicalTitle: String, editionTitle: String, trackCount: Int) -> Int {
        guard normalized(release.artist) == normalized(artist) else { return -1000 }
        let remote = normalized(release.title), local = normalized(canonicalTitle)
        var score = 100
        if remote == local { score += 100 }
        else if remote.hasPrefix(local) || local.hasPrefix(remote) { score += 70 }
        else { return -1000 }
        if let wanted = preferredArtworkMedium(editionTitle), release.media.contains(where: { $0.format.lowercased().contains(wanted) }) { score += 80 }
        if release.media.contains(where: { $0.trackCount == trackCount }) { score += 50 }
        if release.media.count == 1 { score += 5 }
        return score
    }

    func autoArtworkAfterImport(albumID: String, group: [ImportStageRow], completion: @escaping () -> Void) {
        guard let first = group.first, !first.artist.isEmpty, !first.album.isEmpty else { completion(); return }
        let canonical = canonicalArtworkTitle(first.album)
        LookupService.search(artist: first.artist, title: canonical) { result in
            guard case .success(let releases) = result else { DispatchQueue.main.async { completion() }; return }
            let ranked = releases.sorted {
                self.importedArtworkScore($0, artist: first.artist, canonicalTitle: canonical, editionTitle: first.album, trackCount: group.count) >
                self.importedArtworkScore($1, artist: first.artist, canonicalTitle: canonical, editionTitle: first.album, trackCount: group.count)
            }
            guard let best = ranked.first,
                  self.importedArtworkScore(best, artist: first.artist, canonicalTitle: canonical, editionTitle: first.album, trackCount: group.count) >= 220 else {
                DispatchQueue.main.async { completion() }; return
            }
            let candidate = ArtworkLookupCandidate(source: "MusicBrainz", sourceID: best.id,
                artist: best.artist, title: best.title, year: best.date.isEmpty ? "" : String(best.date.prefix(4)),
                country: best.country, format: best.media.map { $0.format }.filter { !$0.isEmpty }.joined(separator: "/"),
                detail: "Automatic import artwork", thumbURL: nil, fullURL: nil, musicBrainzReleaseID: best.id)
            self.applyImportedArtwork(candidate, albumID: albumID, completion: completion)
        }
    }
    func applyImportedArtwork(_ candidate: ArtworkLookupCandidate, albumID: String, completion: @escaping () -> Void) {
        downloadArtworkCandidate(candidate) { result in
            switch result {
            case .failure:
                DispatchQueue.main.async { completion() }
            case .success(let pair):
                let data = pair.0
                let tmp = self.cacheDirectory().appendingPathComponent("import-cover-" + UUID().uuidString + ".image")
                do { try data.write(to: tmp, options: .atomic) }
                catch { DispatchQueue.main.async { completion() }; return }
                DispatchQueue.main.async {
                    self.runLibrary(["cover", albumID, tmp.path], busyText: "Applying imported album artwork…") { code, _ in
                        try? FileManager.default.removeItem(at: tmp)
                        if code == 0 { try? data.write(to: self.artworkURL(for: albumID), options: .atomic) }
                        completion()
                    }
                }
            }
        }
    }
}
