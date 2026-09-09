import Foundation

struct BluRayAudioStream {
    let titleIndex: Int
    let streamIndex: Int
    var kind = ""
    var layoutName = ""
    var languageCode = ""
    var languageName = ""
    var codec = ""
    var codecLong = ""
    var channels = 0
    var sampleRate = 0
    var bits = 0
    var channelLayout = ""

    var isAudio: Bool { kind.caseInsensitiveCompare("Audio") == .orderedSame }
    var isStereo: Bool { channels == 2 }
    var isMultichannel: Bool { channels > 2 }
    var normalizedLayout: String {
        let raw = channelLayout.isEmpty ? layoutName : channelLayout
        let value = raw.lowercased()
        if channels == 4 || value.contains("quad") || value.contains("4.0") { return "4.0/Quad" }
        if channels == 6 || value.contains("5.1") { return "5.1" }
        if channels == 8 || value.contains("7.1") { return "7.1" }
        return channels > 0 ? "\(channels)ch" : "Audio"
    }
    var isLossless: Bool {
        let value = (codec + " " + codecLong).lowercased()
        return value.contains("lpcm") || value.contains("linear pcm") || value.contains("dts-hd ma") ||
               value.contains("dts-hd master") || value.contains("truehd") || value.contains("mlp")
    }
}

struct BluRayTitleInfo {
    let index: Int
    var chapters = 0
    var duration = ""
    var size = ""
    var source = ""
    var audio: [BluRayAudioStream] = []
}

enum BluRayAudioPolicy {
    static func codecRank(_ stream: BluRayAudioStream) -> Int {
        let value = (stream.codec + " " + stream.codecLong).lowercased()
        if value.contains("lpcm") || value.contains("linear pcm") { return 50 }
        if value.contains("truehd") || value.contains("mlp") { return 40 }
        if value.contains("dts-hd ma") || value.contains("dts-hd master") { return 40 }
        if stream.isLossless { return 30 }
        if value.contains("dts") || value.contains("ac3") || value.contains("dolby digital") { return 10 }
        return 0
    }

    static func qualityTuple(_ stream: BluRayAudioStream) -> (Int, Int, Int, Int) {
        (stream.isLossless ? 1 : 0, stream.sampleRate, stream.bits, codecRank(stream))
    }

    static func better(_ lhs: BluRayAudioStream, than rhs: BluRayAudioStream) -> Bool {
        let a = qualityTuple(lhs), b = qualityTuple(rhs)
        if a.0 != b.0 { return a.0 > b.0 }
        if a.1 != b.1 { return a.1 > b.1 }
        if a.2 != b.2 { return a.2 > b.2 }
        if a.3 != b.3 { return a.3 > b.3 }
        return lhs.streamIndex < rhs.streamIndex
    }

    static func preferredStereo(in title: BluRayTitleInfo) -> BluRayAudioStream? {
        title.audio.filter { $0.isStereo }.sorted { better($0, than: $1) }.first
    }

    static func preferredMultichannelByLayout(in title: BluRayTitleInfo) -> [BluRayAudioStream] {
        let grouped = Dictionary(grouping: title.audio.filter { $0.isMultichannel }, by: { $0.normalizedLayout })
        return grouped.values.compactMap { $0.sorted { better($0, than: $1) }.first }
            .sorted { $0.channels == $1.channels ? $0.normalizedLayout < $1.normalizedLayout : $0.channels < $1.channels }
    }
}

enum MakeMKVBridge {
    static func executableURL() -> URL? {
        let candidates = [
            "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon",
            "/opt/homebrew/bin/makemkvcon",
            "/usr/local/bin/makemkvcon"
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private static func value(_ raw: Substring) -> String {
        var text = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, text.first == "\"", text.last == "\"" {
            text.removeFirst(); text.removeLast()
        }
        return text.replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func int(_ text: String) -> Int { Int(text) ?? 0 }

    static func parseInfo(_ text: String) -> [BluRayTitleInfo] {
        var titles: [Int: BluRayTitleInfo] = [:]
        var streams: [String: BluRayAudioStream] = [:]
        for line in text.split(separator: "\n") {
            if line.hasPrefix("TINFO:") {
                let body = line.dropFirst(6)
                let fields = body.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
                guard fields.count == 4 else { continue }
                let titleIndex = int(String(fields[0]))
                let attribute = int(String(fields[1]))
                var title = titles[titleIndex] ?? BluRayTitleInfo(index: titleIndex)
                let v = value(fields[3])
                switch attribute {
                case 8: title.chapters = int(v)
                case 9: title.duration = v
                case 10: title.size = v
                case 16: title.source = v
                default: break
                }
                titles[titleIndex] = title
            } else if line.hasPrefix("SINFO:") {
                let body = line.dropFirst(6)
                let fields = body.split(separator: ",", maxSplits: 4, omittingEmptySubsequences: false)
                guard fields.count == 5 else { continue }
                let titleIndex = int(String(fields[0]))
                let streamIndex = int(String(fields[1]))
                let attribute = int(String(fields[2]))
                let key = "\(titleIndex):\(streamIndex)"
                var stream = streams[key] ?? BluRayAudioStream(titleIndex: titleIndex, streamIndex: streamIndex)
                let v = value(fields[4])
                switch attribute {
                case 1: stream.kind = v
                case 2: stream.layoutName = v
                case 3: stream.languageCode = v
                case 4: stream.languageName = v
                case 6: stream.codec = v
                case 7: stream.codecLong = v
                case 14: stream.channels = int(v)
                case 17: stream.sampleRate = int(v)
                case 18: stream.bits = int(v)
                case 40: stream.channelLayout = v
                default: break
                }
                streams[key] = stream
            }
        }

        for stream in streams.values where stream.isAudio {
            var title = titles[stream.titleIndex] ?? BluRayTitleInfo(index: stream.titleIndex)
            title.audio.append(stream)
            titles[stream.titleIndex] = title
        }
        return titles.values.map { title in
            var t = title
            t.audio.sort { $0.streamIndex < $1.streamIndex }
            return t
        }.sorted { $0.index < $1.index }
    }

    static func scanSource(_ source: String) throws -> [BluRayTitleInfo] {
        guard let exe = executableURL() else {
            throw NSError(domain: "ControlMac.MakeMKV", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "MakeMKV is not installed. Protected Blu-ray discs require MakeMKV access."])
        }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--robot", "--cache=128", "--messages=-stdout", "info", source]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            let detail = text.split(separator: "\n").map(String.init).last ?? "MakeMKV could not open the Blu-ray disc."
            throw NSError(domain: "ControlMac.MakeMKV", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: detail])
        }
        return parseInfo(text)
    }

    static func scanDisc() throws -> [BluRayTitleInfo] { try scanSource("disc:0") }
    static func scanISO(_ image: URL) throws -> [BluRayTitleInfo] { try scanSource("iso:" + image.path) }
    static func scanFolder(_ folder: URL) throws -> [BluRayTitleInfo] { try scanSource("file:" + folder.path) }
}
