import AppKit
import Foundation

extension ControlMacApp {
    func stagedGroupKey(_ row: ImportStageRow) -> String {
        return normalized(row.artist) + "\u{1f}" + normalized(row.album) + "\u{1f}" + String(max(1, row.disc))
    }

    func orderedStagedGroups(_ rows: [ImportStageRow]) -> [[ImportStageRow]] {
        let grouped = Dictionary(grouping: rows, by: stagedGroupKey)
        return grouped.values.map { group in
            group.sorted { a, b in
                if a.track != b.track { return a.track < b.track }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }.sorted { a, b in
            let ak = a.first.map(stagedGroupKey) ?? ""
            let bk = b.first.map(stagedGroupKey) ?? ""
            return ak < bk
        }
    }

    func importStagedRows(_ selected: [ImportStageRow]) {
        guard activeImportProcess == nil, host != nil else {
            alert("Importer unavailable", "Connect to the Core and wait for the current operation to finish.")
            return
        }
        let needsReview = selected.filter { !$0.status.hasPrefix("Ready") }
        guard needsReview.isEmpty else {
            let sample = needsReview.prefix(5).map { "• \($0.artist) — \($0.album) — \($0.title) [\($0.status)]" }.joined(separator: "\n")
            alert("Review required before import", "\(needsReview.count) staged track(s) are not marked Ready.\n\n\(sample)")
            return
        }
        let groups = orderedStagedGroups(selected)
        guard !groups.isEmpty else { return }
        let summary = groups.prefix(8).compactMap { group -> String? in
            guard let first = group.first else { return nil }
            let disc = max(1, first.disc)
            return "• \(first.artist) — \(first.album) · Disc \(disc) · \(group.count) tracks"
        }.joined(separator: "\n")
        let more = groups.count > 8 ? "\n…and \(groups.count - 8) more batch(es)." : ""
        let a = NSAlert(); a.alertStyle = .informational
        a.messageText = "Import selected music to Sooloos?"
        a.informativeText = "\(selected.count) tracks across \(groups.count) album/disc batch(es).\n\n\(summary)\(more)\n\nEach batch is checksum-verified and read back from the Core after import."
        a.addButton(withTitle: "Import"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                self.importExportController?.setOperationState("Import cancelled · no changes made", busy: false)
                return
            }
            self.performStagedGroups(groups, index: 0, imported: 0, skipped: 0)
        }
    }
    func importB64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    func handleBatchProgressLine(_ line: String, batch: Int, batchCount: Int) {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 7, f[0] == "CMPROGRESS",
              let track = Int(f[2]), let trackCount = Int(f[3]),
              let current = Int64(f[4]), let total = Int64(f[5]) else { return }
        let title: String
        if let data = Data(base64Encoded: f[6]), let value = String(data: data, encoding: .utf8) { title = value }
        else { title = f[6] }
        DispatchQueue.main.async {
            self.importExportController?.setImportProgress(batch: batch, batchCount: batchCount, phase: f[1],
                track: track, trackCount: trackCount, title: title, current: current, total: total)
        }
    }

    func makeStagedManifest(_ group: [ImportStageRow]) throws -> URL {
        let lines = group.map { row in
            [
                "CMIMPORT",
                importB64(row.url.path),
                importB64(row.artist),
                importB64(row.album),
                importB64(row.title),
                String(max(1, row.disc)),
                String(row.track),
                String(row.rate),
                String(row.bits),
                String(row.channels)
            ].joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
        let dir = cacheDirectory().appendingPathComponent("import-manifests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("batch-\(UUID().uuidString).tsv")
        try lines.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func makeImportCancelURL() throws -> URL {
        let dir = cacheDirectory().appendingPathComponent("import-manifests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cancel-\(UUID().uuidString).flag")
    }

    func cancelActiveImport() {
        guard let process = activeImportProcess, process.isRunning, let marker = activeImportCancelURL else { return }
        do { try Data("cancel".utf8).write(to: marker, options: .atomic) }
        catch { alert("Could not request cancellation", error.localizedDescription); return }
        statusLabel.stringValue = "Cancelling import safely…"
        importExportController?.setOperationState("Cancelling import safely · cleaning temporary Core project…", busy: true)
    }

    func performStagedGroups(_ groups: [[ImportStageRow]], index: Int, imported: Int, skipped: Int) {
        guard index < groups.count else {
            activeImportProcess = nil
            activeImportCancelURL = nil
            progress.stopAnimation(nil)
            let text = "Import finished · \(imported) batch(es) imported" + (skipped > 0 ? " · \(skipped) duplicate batch(es) skipped" : "")
            statusLabel.stringValue = text
            importExportController?.setOperationState(text, busy: false)
            refreshLibrary()
            return
        }
        guard let host = host, let cfg = backendConfig(),
              let exe = Bundle.main.url(forResource: "BatchImportTool", withExtension: "exe") else {
            progress.stopAnimation(nil)
            importExportController?.setOperationState("Batch importer unavailable", busy: false)
            alert("Batch importer unavailable", "The managed batch import helper is missing from this build.")
            return
        }
        let group = groups[index]
        guard let first = group.first else {
            performStagedGroups(groups, index: index + 1, imported: imported, skipped: skipped)
            return
        }
        let manifest: URL
        let cancelURL: URL
        do { manifest = try makeStagedManifest(group); cancelURL = try makeImportCancelURL() }
        catch { alert("Could not prepare import", error.localizedDescription); return }
        let label = "\(first.artist) — \(first.album) · Disc \(max(1, first.disc))"
        statusLabel.stringValue = "Importing \(label)…"
        importExportController?.setOperationState("Importing \(index + 1)/\(groups.count): \(label)…", busy: true)
        progress.startAnimation(nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cfg.mono + "/bin/mono-sgen64")
        p.arguments = ControlMacRuntime.monoArguments(executable: exe, arguments: ["--import", host, manifest.path, cancelURL.path], monoRoot: cfg.mono)
        var env = ProcessInfo.processInfo.environment
        ControlMacRuntime.configureMonoEnvironment(&env, monoRoot: cfg.mono, managed: cfg.managed)
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        activeImportProcess = p; activeImportCancelURL = cancelURL
        do { try p.run() }
        catch {
            activeImportProcess = nil; activeImportCancelURL = nil; progress.stopAnimation(nil)
            try? FileManager.default.removeItem(at: manifest); try? FileManager.default.removeItem(at: cancelURL)
            importExportController?.setOperationState("Import could not start", busy: false)
            alert("Import could not start", error.localizedDescription)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var collected = Data(); var pending = ""
            while true {
                let chunk = pipe.fileHandleForReading.readData(ofLength: 4096)
                if chunk.isEmpty { break }
                collected.append(chunk)
                pending += String(data: chunk, encoding: .utf8) ?? ""
                while let newline = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<newline]).trimmingCharacters(in: .newlines)
                    pending.removeSubrange(...newline)
                    self.handleBatchProgressLine(line, batch: index + 1, batchCount: groups.count)
                }
            }
            if !pending.isEmpty { self.handleBatchProgressLine(pending, batch: index + 1, batchCount: groups.count) }
            p.waitUntilExit()
            let text = String(data: collected, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.activeImportProcess = nil
                self.activeImportCancelURL = nil
                try? FileManager.default.removeItem(at: manifest); try? FileManager.default.removeItem(at: cancelURL)
                if p.terminationStatus == 0 && text.contains("CORE CONFIRMED BATCH IMPORT COMPLETE") {
                    self.performStagedGroups(groups, index: index + 1, imported: imported + 1, skipped: skipped)
                } else if p.terminationStatus == 3 || text.contains("IMPORT_SKIPPED_DUPLICATE") {
                    self.performStagedGroups(groups, index: index + 1, imported: imported, skipped: skipped + 1)
                } else if p.terminationStatus == 4 || text.contains("IMPORT_CANCELLED") {
                    self.progress.stopAnimation(nil)
                    self.importExportController?.setOperationState("Import cancelled safely · completed earlier batches remain imported", busy: false)
                    self.statusLabel.stringValue = "Import cancelled safely"
                    self.refreshLibrary()
                } else {
                    self.progress.stopAnimation(nil)
                    self.importExportController?.setOperationState("Import stopped safely", busy: false)
                    let detail = self.backendError(text)
                    self.alert("Import did not complete", "\(label)\n\n\(detail)")
                }
            }
        }
    }
}
