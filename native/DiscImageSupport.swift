import Foundation

struct MountedDiscImage {
    let devices: [String]
    let mounts: [URL]
}

enum DiscImageSupport {
    private static func run(_ executable: String, _ arguments: [String]) throws -> (Int32, Data, Data) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        try p.run(); let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, stdout, stderr)
    }

    private static func parseAttach(_ data: Data) throws -> MountedDiscImage {
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw NSError(domain: "ControlMac.DiscImage", code: 1, userInfo: [NSLocalizedDescriptionKey: "hdiutil returned no usable image entities."])
        }
        let devices = entities.compactMap { $0["dev-entry"] as? String }
        let mounts = entities.compactMap { ($0["mount-point"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        return MountedDiscImage(devices: devices, mounts: mounts)
    }
    static func mountReadOnly(_ image: URL) throws -> MountedDiscImage {
        let base = ["attach", "-readonly", "-nobrowse", "-plist"]
        var result = try run("/usr/bin/hdiutil", base + [image.path])
        if result.0 != 0 {
            result = try run("/usr/bin/hdiutil", base + ["-imagekey", "diskimage-class=CRawDiskImage", image.path])
        }
        guard result.0 == 0 else {
            let detail = String(data: result.2, encoding: .utf8) ?? "Disc image could not be mounted."
            throw NSError(domain: "ControlMac.DiscImage", code: Int(result.0), userInfo: [NSLocalizedDescriptionKey: detail])
        }
        return try parseAttach(result.1)
    }

    static func detach(_ devices: [String]) {
        for device in devices.reversed() { _ = try? run("/usr/bin/hdiutil", ["detach", device]) }
    }

    static func opticalDevice() -> String? {
        guard let result = try? run("/usr/bin/drutil", ["status"]), result.0 == 0,
              let text = String(data: result.1, encoding: .utf8) else { return nil }
        let pattern = #"Name:\s*(/dev/disk\d+)"#
        guard let r = try? NSRegularExpression(pattern: pattern),
              let match = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func rawDevice(_ blockDevice: String) -> String {
        blockDevice.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
    }
    static func folderBytes(_ root: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsPackageDescendants]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize { total += Int64(size) }
        }
        return total
    }

    static func mountedPoint(for device: String) -> URL? {
        guard let result = try? run("/usr/sbin/diskutil", ["info", "-plist", device]), result.0 == 0,
              let plist = try? PropertyListSerialization.propertyList(from: result.1, options: [], format: nil) as? [String: Any],
              let path = plist["MountPoint"] as? String, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func createUDF250ISO(from source: URL, to output: URL, volumeName: String) throws {
        let content = folderBytes(source)
        let margin = max(Int64(64 * 1024 * 1024), content / 100 + Int64(32 * 1024 * 1024))
        let bytes = ((content + margin + 2047) / 2048) * 2048
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output); try handle.truncate(atOffset: UInt64(bytes)); try handle.close()
        let name = String(volumeName.prefix(63)).isEmpty ? "CONTROLMAC" : String(volumeName.prefix(63))
        let format = try run("/sbin/newfs_udf", ["-r", "2.50", "-b", "2048", "-v", name, output.path])
        guard format.0 == 0 else { throw NSError(domain: "ControlMac.DiscImage", code: Int(format.0), userInfo: [NSLocalizedDescriptionKey: String(data: format.2, encoding: .utf8) ?? "UDF 2.50 formatting failed."]) }
        let attached = try run("/usr/bin/hdiutil", ["attach", "-nomount", "-plist", "-imagekey", "diskimage-class=CRawDiskImage", output.path])
        guard attached.0 == 0 else { throw NSError(domain: "ControlMac.DiscImage", code: Int(attached.0), userInfo: [NSLocalizedDescriptionKey: "Could not attach the new UDF image for writing."]) }
        let info = try parseAttach(attached.1); guard let device = info.devices.first else { throw NSError(domain: "ControlMac.DiscImage", code: 2, userInfo: [NSLocalizedDescriptionKey: "No block device was created for the UDF image."]) }
        defer { detach([device]) }
        let mounted = try run("/usr/sbin/diskutil", ["mount", device])
        guard mounted.0 == 0, let mount = mountedPoint(for: device) else {
            throw NSError(domain: "ControlMac.DiscImage", code: Int(mounted.0), userInfo: [NSLocalizedDescriptionKey: "Could not mount the UDF image for writing."])
        }
        let fm = FileManager.default
        for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: []) {
            try fm.copyItem(at: child, to: mount.appendingPathComponent(child.lastPathComponent))
        }
        _ = try run("/bin/sync", [])
        let unmount = try run("/usr/sbin/diskutil", ["unmount", device])
        guard unmount.0 == 0 else {
            throw NSError(domain: "ControlMac.DiscImage", code: Int(unmount.0), userInfo: [NSLocalizedDescriptionKey: "UDF image could not be cleanly unmounted."])
        }
    }

    static func deviceSize(_ device: String) -> Int64? {
        guard let result = try? run("/usr/sbin/diskutil", ["info", "-plist", device]), result.0 == 0,
              let plist = try? PropertyListSerialization.propertyList(from: result.1, options: [], format: nil) as? [String: Any] else { return nil }
        if let n = plist["TotalSize"] as? NSNumber { return n.int64Value }
        if let n = plist["Size"] as? NSNumber { return n.int64Value }
        return nil
    }

    static func rawCopyProcess(blockDevice: String, output: URL) -> Process {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/dd")
        p.arguments = ["if=\(rawDevice(blockDevice))", "of=\(output.path)", "bs=4m"]
        return p
    }
}
