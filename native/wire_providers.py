from pathlib import Path

root = Path(__file__).resolve().parent
p = root / 'LookupService.swift'
s = p.read_text()
old = '''    static func search(artist: String, title: String, completion: @escaping (Result<[LookupRelease], Error>) -> Void) {
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
'''
new = '''    static func search(artist: String, title: String, completion: @escaping (Result<[LookupRelease], Error>) -> Void) {
        guard ProviderSettings.musicBrainzEnabled else { completion(.success([])); return }
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
'''
if old not in s: raise SystemExit('MusicBrainz search pattern not found')
s = s.replace(old, new, 1)

old = '''    private static func audioDBSearch(artist: String, title: String, completion: @escaping ([ArtworkLookupCandidate]) -> Void) {
        var c = URLComponents(string: "https://www.theaudiodb.com/api/v1/json/123/searchalbum.php")!
'''
new = '''    private static func audioDBSearch(artist: String, title: String, completion: @escaping ([ArtworkLookupCandidate]) -> Void) {
        guard ProviderSettings.audioDBEnabled else { completion([]); return }
        let key = ProviderSettings.audioDBKey
        var c = URLComponents(string: "https://www.theaudiodb.com/api/v1/json/\\(key)/searchalbum.php")!
'''
if old not in s: raise SystemExit('AudioDB pattern not found')
s = s.replace(old, new, 1)
old = '''        group.enter()
        audioDBSearch(artist: artist, title: title) { found in
            lock.lock(); all.append(contentsOf: found); lock.unlock(); group.leave()
        }
        group.notify(queue: queue) {
'''
new = '''        group.enter()
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
'''
if old not in s: raise SystemExit('Federated insertion pattern not found')
s = s.replace(old, new, 1)
p.write_text(s)
print('LookupService provider settings wired')

b = root / 'build.sh'
t = b.read_text()
needle = '  "$controlmac_repo/native/LookupService.swift" \\\n'
addition = '  "$controlmac_repo/native/ProviderSettings.swift" \\\n  "$controlmac_repo/native/LookupService.swift" \\\n  "$controlmac_repo/native/ExternalProviders.swift" \\\n'
if 'ProviderSettings.swift' not in t:
    if needle not in t: raise SystemExit('build insertion point not found')
    t = t.replace(needle, addition, 1)
b.write_text(t)
print('build includes provider adapters')
