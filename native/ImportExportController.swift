import AppKit
import Foundation
import Darwin
import UniformTypeIdentifiers

struct ExportAlbumChoice {
    let id: String
    let artist: String
    let album: String
    let tracks: Int
    let disc: Int
    let discs: Int
    let releaseDate: String
}

struct ImportStageRow {
    let url: URL
    var artist: String
    var album: String
    var title: String
    var disc: Int
    var track: Int
    var codec: String
    var rate: Int
    var bits: Int
    var channels: Int
    var status: String
}

final class ImportExportController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "Nothing staged")
    private let importButton = NSButton(title: "Import Selected to Sooloos", target: nil, action: nil)
    private let miniDiscRipButton = NSButton(title: "Rip MiniDisc → FLAC", target: nil, action: nil)
    private let miniDiscWipeButton = NSButton(title: "Wipe MiniDisc…", target: nil, action: nil)
    private let importProgress = NSProgressIndicator()
    private let importProgressLabel = NSTextField(labelWithString: "")
    private let trackProgress = NSProgressIndicator()
    private let trackProgressLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel Operation", target: nil, action: nil)
    private let exportFormatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let exportAlbumPopup = NSComboBox(frame: .zero)
    private let exportButton = NSButton(title: "OK…", target: nil, action: nil)
    private var rows: [ImportStageRow] = []
    private var exportChoices: [ExportAlbumChoice] = []
    private var activeMediaProcess: Process?
    private var mediaCancelMarker: URL?
    private var cancelRequested = false
    private var operationBusy = false
    private var localOperationKind: String?
    private var scanning = false
    private var mountedImageDevices: [String] = []
    var coreHost: (() -> String?)?
    var importHandler: (([ImportStageRow]) -> Void)?
    var cancelImportHandler: (() -> Void)?
    var exportAlbumChoices: (() -> [ExportAlbumChoice])?
    var miniDiscMetadataGuess: ((String) -> (artist: String, album: String)?)?

    override init() {
        super.init()
        buildUI()
    }
    private func buildUI() {
        let title = NSTextField(labelWithString: "Import / Export")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Stage files, folders, disc images and physical media before anything is sent to the Core.")
        subtitle.textColor = .secondaryLabelColor

        let addFolders = NSButton(title: "Add Folders…", target: self, action: #selector(addFoldersAction))
        let addFiles = NSButton(title: "Add Files…", target: self, action: #selector(addFilesAction))
        let addISO = NSButton(title: "Add ISO…", target: self, action: #selector(addISOAction))
        let optical = NSButton(title: "CD / DVD / Blu-ray…", target: self, action: #selector(scanOpticalAction))
        let miniDisc = NSButton(title: "MiniDisc…", target: self, action: #selector(scanMiniDiscAction))
        miniDiscRipButton.target = self; miniDiscRipButton.action = #selector(ripMiniDiscAction); miniDiscRipButton.isEnabled = false
        miniDiscWipeButton.target = self; miniDiscWipeButton.action = #selector(wipeMiniDiscAction); miniDiscWipeButton.isEnabled = true
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearAction))
        let buttons = NSStackView(views: [addFolders, addFiles, addISO, optical, miniDisc, miniDiscRipButton, miniDiscWipeButton, clear])
        buttons.orientation = .horizontal; buttons.spacing = 8

        table.headerView = NSTableHeaderView()
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.delegate = self; table.dataSource = self
        addColumn("artist", "Artist", 145)
        addColumn("album", "Album", 210)
        addColumn("disc", "Disc", 55)
        addColumn("track", "#", 45)
        addColumn("title", "Track", 250)
        addColumn("format", "Format", 90)
        addColumn("audio", "Audio", 130)
        addColumn("status", "Status", 150)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        status.textColor = .secondaryLabelColor
        importButton.target = self
        importButton.action = #selector(importSelectedAction)
        importButton.isEnabled = false
        cancelButton.target = self; cancelButton.action = #selector(cancelOperationAction)
        cancelButton.isHidden = true; cancelButton.isEnabled = false
        let footer = NSStackView(views: [status, NSView(), cancelButton, importButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.alignment = .centerY
        importProgress.style = .bar
        importProgress.isIndeterminate = false
        importProgress.minValue = 0; importProgress.maxValue = 100
        importProgress.doubleValue = 0; importProgress.isHidden = true
        importProgressLabel.textColor = .secondaryLabelColor
        importProgressLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        importProgressLabel.lineBreakMode = .byTruncatingMiddle
        importProgressLabel.isHidden = true
        trackProgress.style = .bar
        trackProgress.isIndeterminate = false
        trackProgress.minValue = 0; trackProgress.maxValue = 100
        trackProgress.doubleValue = 0; trackProgress.isHidden = true
        trackProgressLabel.textColor = .secondaryLabelColor
        trackProgressLabel.font = .systemFont(ofSize: 12, weight: .medium)
        trackProgressLabel.lineBreakMode = .byTruncatingMiddle
        trackProgressLabel.isHidden = true
        let progressStack = NSStackView(views: [importProgressLabel, importProgress, trackProgressLabel, trackProgress])
        progressStack.orientation = .vertical; progressStack.spacing = 5; progressStack.alignment = .leading
        importProgress.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        trackProgress.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true

        let exportBox = makeExportBox()
        for v in [title, subtitle, buttons, scroll, footer, progressStack, exportBox] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            buttons.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            buttons.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            footer.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            progressStack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            progressStack.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor),
            progressStack.topAnchor.constraint(equalTo: footer.bottomAnchor, constant: 6),
            exportBox.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            exportBox.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            exportBox.topAnchor.constraint(equalTo: progressStack.bottomAnchor, constant: 12),
            exportBox.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -18)
        ])
    }

    private func addColumn(_ id: String, _ title: String, _ width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        table.addTableColumn(column)
    }

    private func makeExportBox() -> NSView {
        let box = NSBox()
        box.title = "Export from Sooloos"
        let text = NSTextField(wrappingLabelWithString: "Modern export pulls the Core's original audio directly. Choose FLAC/ALAC at native resolution, make a CD-A image, send an album to MiniDisc, or back up the whole Sooloos library to FLAC. Old Sync Companion is not used.")
        text.textColor = .secondaryLabelColor
        exportFormatPopup.removeAllItems(); exportFormatPopup.addItems(withTitles: [
            "FLAC · native resolution",
            "ALAC · native resolution",
            "CD-A Disc Image (BIN/CUE) · 16-bit / 44.1 kHz",
            "MiniDisc · direct to device",
            "Sooloos Backup → FLAC"
        ])
        exportFormatPopup.target = self; exportFormatPopup.action = #selector(exportFormatChanged)
        exportAlbumPopup.isEditable = true; exportAlbumPopup.completes = true; exportAlbumPopup.numberOfVisibleItems = 20
        exportAlbumPopup.placeholderString = "Select album…"; exportAlbumPopup.widthAnchor.constraint(equalToConstant: 430).isActive = true
        refreshExportAlbumChoices()
        exportButton.target = self; exportButton.action = #selector(exportAlbumAction)
        let formatLabel = NSTextField(labelWithString: "Format:")
        let albumLabel = NSTextField(labelWithString: "Album:")
        let controls = NSStackView(views: [formatLabel, exportFormatPopup, albumLabel, exportAlbumPopup, exportButton]); controls.orientation = .horizontal; controls.spacing = 8
        let stack = NSStackView(views: [text, controls])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor, constant: -12)
        ])
        return box
    }

    private func exportChoiceLabel(_ choice: ExportAlbumChoice) -> String {
        var bits: [String] = [choice.artist, choice.album]
        let date = choice.releaseDate.trimmingCharacters(in: .whitespacesAndNewlines)
        if date.range(of: #"^\d{4}(-\d{2}(-\d{2})?)?$"#, options: .regularExpression) != nil { bits.append(String(date.prefix(4))) }
        bits.append("\(choice.tracks) tracks")
        if choice.discs > 1 { bits.append("Disc \(choice.disc)/\(choice.discs)") }
        return bits.joined(separator: " · ")
    }

    private func refreshExportAlbumChoices() {
        exportChoices = (exportAlbumChoices?() ?? []).sorted {
            let a = "\($0.artist)\u{0}\($0.album)\u{0}\($0.releaseDate)\u{0}\($0.tracks)"
            let b = "\($1.artist)\u{0}\($1.album)\u{0}\($1.releaseDate)\u{0}\($1.tracks)"
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        let current = exportAlbumPopup.stringValue
        exportAlbumPopup.removeAllItems()
        exportAlbumPopup.addItems(withObjectValues: exportChoices.map(exportChoiceLabel))
        if let index = exportChoices.indices.first(where: { exportChoiceLabel(exportChoices[$0]) == current }) {
            exportAlbumPopup.selectItem(at: index)
        }
        exportFormatChanged()
    }

    func reloadExportAlbums() { refreshExportAlbumChoices() }

    @objc private func exportFormatChanged() {
        let backup = exportFormatPopup.indexOfSelectedItem == 4
        exportAlbumPopup.isEnabled = !backup
        if backup { exportAlbumPopup.stringValue = "Entire Sooloos library" }
        else if exportAlbumPopup.stringValue == "Entire Sooloos library" { exportAlbumPopup.stringValue = "" }
    }

    private func chosenExportAlbum() -> ExportAlbumChoice? {
        refreshExportAlbumChoices()
        guard exportFormatPopup.indexOfSelectedItem != 4 else { return nil }
        let index = exportAlbumPopup.indexOfSelectedItem
        if index >= 0 && index < exportChoices.count { return exportChoices[index] }
        let typed = exportAlbumPopup.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = exportChoices.first(where: { exportChoiceLabel($0).caseInsensitiveCompare(typed) == .orderedSame }) { return exact }
        let matches = exportChoices.filter { exportChoiceLabel($0).localizedCaseInsensitiveContains(typed) }
        return matches.count == 1 ? matches[0] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let r = rows[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "artist": value = r.artist
        case "album": value = r.album
        case "disc": value = r.disc > 0 ? "\(r.disc)" : ""
        case "track": value = r.track > 0 ? "\(r.track)" : ""
        case "title": value = r.title
        case "format": value = r.codec.uppercased()
        case "audio":
            let rate = r.rate > 0 ? String(format: "%.1f kHz", Double(r.rate) / 1000.0) : "? kHz"
            let bits = r.bits > 0 ? "\(r.bits)-bit" : ""
            value = bits.isEmpty ? rate : "\(bits) / \(rate)"
        case "status": value = r.status
        default: value = ""
        }
        let cell = NSTextField(labelWithString: value)
        cell.lineBreakMode = .byTruncatingTail
        cell.toolTip = value
        return cell
    }

    @objc private func clearAction() {
        guard !scanning else { return }
        rows.removeAll(); table.reloadData(); detachImages(); updateStatus()
    }

    @objc private func addFoldersAction() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more folders. ControlMac will scan them recursively."
        panel.begin { response in if response == .OK { self.stage(urls: panel.urls) } }
    }

    @objc private func addFilesAction() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = supportedTypes()
        panel.message = "Choose one or more audio files."
        panel.begin { response in if response == .OK { self.stage(urls: panel.urls) } }
    }

    @objc private func addISOAction() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "iso")!]
        panel.message = "Choose one or more ISO images. Mountable filesystems will be scanned read-only."
        panel.begin { response in
            guard response == .OK else { return }
            self.stageISOImages(panel.urls)
        }
    }

    @objc private func scanOpticalAction() {
        let roots = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        if let audioCD = roots.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".TOC.plist").path) }) {
            stageAudioCD(audioCD)
        } else if let bluRay = roots.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("BDMV/index.bdmv").path) }) {
            stageBluRay(bluRay)
        } else {
            status.stringValue = "Scanning mounted optical media…"
            scanMountedVolumes(preferOptical: true)
        }
    }

    private func stageBluRay(_ volume: URL) {
        guard !scanning, !operationBusy else { return }
        scanning = true
        status.stringValue = "Scanning Blu-ray audio with MakeMKV…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let titles = try MakeMKVBridge.scanDisc()
                var staged: [ImportStageRow] = []
                for title in titles where !title.audio.isEmpty {
                    let stereo = BluRayAudioPolicy.preferredStereo(in: title)
                    let multichannel = BluRayAudioPolicy.preferredMultichannelByLayout(in: title)
                    let archiveKeys = Set(multichannel.map { "\($0.titleIndex):\($0.streamIndex)" })
                    for stream in title.audio {
                        let pseudo = URL(string: "bluray://disc/title/\(title.index)/audio/\(stream.streamIndex)")!
                        let source = title.source.isEmpty ? "Title \(title.index)" : title.source
                        let duration = title.duration.isEmpty ? "" : " · \(title.duration)"
                        let layout: String
                        if !stream.layoutName.isEmpty { layout = stream.layoutName }
                        else if stream.isStereo { layout = "Stereo" }
                        else if stream.channels > 0 { layout = "\(stream.channels)ch" }
                        else { layout = "Audio" }
                        let codec = stream.codecLong.isEmpty ? stream.codec : stream.codecLong
                        let key = "\(stream.titleIndex):\(stream.streamIndex)"
                        let recommendation: String
                        if let selected = stereo, selected.streamIndex == stream.streamIndex {
                            recommendation = "Blu-ray · Default stereo → Sooloos"
                        } else if archiveKeys.contains(key) {
                            recommendation = "Blu-ray · Archive \(stream.normalizedLayout) locally"
                        } else {
                            recommendation = "Blu-ray · Alternate stream · not selected by default"
                        }
                        staged.append(ImportStageRow(
                            url: pseudo, artist: "", album: volume.lastPathComponent,
                            title: "\(source)\(duration) · \(layout)", disc: 1, track: title.index + 1,
                            codec: codec, rate: stream.sampleRate, bits: stream.bits,
                            channels: stream.channels,
                            status: recommendation))
                    }
                }
                DispatchQueue.main.async {
                    self.rows.removeAll { $0.url.scheme?.lowercased() == "bluray" }
                    self.rows.append(contentsOf: staged)
                    self.sortRows(); self.table.reloadData(); self.scanning = false
                    self.updateStatus()
                    self.status.stringValue = "Blu-ray scanned · \(titles.count) title(s) · \(staged.count) audio stream(s) · review programme before ripping"
                }
            } catch {
                DispatchQueue.main.async {
                    self.scanning = false; self.updateStatus()
                    self.status.stringValue = "Blu-ray scan failed"
                    let a = NSAlert(); a.alertStyle = .warning
                    a.messageText = "Blu-ray could not be scanned"
                    a.informativeText = error.localizedDescription
                    if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) } else { a.runModal() }
                }
            }
        }
    }

    @objc private func scanMiniDiscAction() {
        showMiniDiscInfo()
    }

    @objc private func wipeMiniDiscAction() {
        guard !operationBusy, !scanning else { return }
        status.stringValue = "Checking MiniDisc before erase…"
        DispatchQueue.global(qos: .userInitiated).async {
            let (disc, error) = self.miniDiscWriteStatus()
            DispatchQueue.main.async {
                guard let disc = disc else {
                    let a = NSAlert(); a.alertStyle = .warning; a.messageText = "MiniDisc unavailable"; a.informativeText = error
                    if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) } else { a.runModal() }
                    return
                }
                guard disc.writable && !disc.writeProtected else {
                    let a = NSAlert(); a.alertStyle = .warning; a.messageText = "MiniDisc is write-protected"
                    a.informativeText = "The connected MiniDisc cannot be erased."
                    if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) } else { a.runModal() }
                    return
                }
                guard disc.trackCount > 0 else { self.status.stringValue = "MiniDisc is already blank"; return }
                let title = disc.title.isEmpty ? "Untitled MiniDisc" : disc.title
                let a = NSAlert(); a.alertStyle = .critical; a.messageText = "Erase this MiniDisc?"
                a.informativeText = "\(title) · \(disc.trackCount) tracks · \(self.miniDiscTime(disc.used)) used\n\nThis permanently removes every track and the disc title."
                a.addButton(withTitle: "Erase MiniDisc"); a.addButton(withTitle: "Cancel")
                let erase = { self.runMiniDiscWipe(expected: disc) }
                if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) { if $0 == .alertFirstButtonReturn { erase() } } }
                else if a.runModal() == .alertFirstButtonReturn { erase() }
            }
        }
    }

    private func runMiniDiscWipe(expected disc: MiniDiscWriteStatus) {
        guard let node = nodeURL(), let root = Bundle.main.resourceURL else { status.stringValue = "NetMD helper unavailable"; return }
        let helper = root.appendingPathComponent("netmd/controlmac-md-wipe.cjs")
        guard FileManager.default.fileExists(atPath: helper.path) else { status.stringValue = "MiniDisc wipe helper missing"; return }
        operationBusy = true; localOperationKind = "minidisc-wipe"
        setOperationState("Erasing MiniDisc…", busy: true); cancelButton.isHidden = true; cancelButton.isEnabled = false
        let title64 = Data(disc.title.utf8).base64EncodedString()
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(); p.executableURL = node
            p.arguments = [helper.path, String(disc.trackCount), String(disc.used), title64]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            DispatchQueue.main.sync { self.activeMediaProcess = p }
            var launchError: String?
            do { try p.run() } catch { launchError = error.localizedDescription }
            let data = launchError == nil ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
            if launchError == nil { p.waitUntilExit() }
            let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.activeMediaProcess = nil; self.localOperationKind = nil; self.operationBusy = false
                if launchError == nil && p.terminationStatus == 0 && text.contains("CMMDWIPEDONE") {
                    self.rows.removeAll { $0.url.scheme?.lowercased() == "minidisc" || $0.status.localizedCaseInsensitiveContains("MiniDisc") }
                    self.table.reloadData(); self.updateStatus(); self.setOperationState("MiniDisc erased and USB released", busy: false)
                } else {
                    self.setOperationState("MiniDisc erase stopped safely", busy: false)
                    let detail = launchError ?? text.split(separator: "\n").last(where: { $0.hasPrefix("CMMDWIPEERROR\t") }).map { String($0.dropFirst("CMMDWIPEERROR\t".count)) } ?? "MiniDisc erase did not complete."
                    let a = NSAlert(); a.alertStyle = .warning; a.messageText = "MiniDisc was not erased"; a.informativeText = detail
                    if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) } else { a.runModal() }
                }
            }
        }
    }

    @objc private func importSelectedAction() {
        let chosen: [ImportStageRow]
        if table.selectedRowIndexes.isEmpty { chosen = rows }
        else { chosen = table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil } }
        guard !chosen.isEmpty else { return }
        let blocked = chosen.filter { !$0.status.hasPrefix("Ready") || $0.status.localizedCaseInsensitiveContains("review") }
        if !blocked.isEmpty {
            let a = NSAlert(); a.alertStyle = .warning; a.messageText = "Some selected tracks are not ready"
            a.informativeText = "Finish ripping or metadata review before importing these tracks to Sooloos."
            a.runModal(); return
        }
        importHandler?(chosen)
    }

    @objc private func ripMiniDiscAction() {
        let selected = table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }.filter { $0.url.scheme?.lowercased() == "minidisc" }
        let chosen = selected.isEmpty ? rows.filter { $0.url.scheme?.lowercased() == "minidisc" } : selected
        guard !chosen.isEmpty else { return }
        ripMiniDiscRows(chosen.sorted { $0.track < $1.track })
    }

    @objc private func cancelOperationAction() {
        cancelRequested = true
        cancelButton.isEnabled = false
        status.stringValue = "Cancellation requested…"
        if let marker = mediaCancelMarker {
            try? Data("cancel".utf8).write(to: marker, options: .atomic)
            if let process = activeMediaProcess,
               process.executableURL?.lastPathComponent.lowercased().contains("ffmpeg") == true,
               process.isRunning {
                process.terminate()
            }
            return
        }
        if let process = activeMediaProcess, process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            return
        }
        if localOperationKind != nil { return }
        cancelImportHandler?()
    }

    func hasActiveOperation() -> Bool {
        operationBusy || scanning || activeMediaProcess?.isRunning == true
    }

    func cleanupTemporaryFiles() {
        let fm = FileManager.default
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let root = caches.appendingPathComponent("ControlMac2026", isDirectory: true)
            for name in ["CD Rips", "MiniDisc Rips", "Export Work"] {
                try? fm.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
            }
            if let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                for item in items where item.lastPathComponent.hasPrefix("Export Test ") { try? fm.removeItem(at: item) }
            }
        }
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let root = support.appendingPathComponent("ControlMac2026", isDirectory: true)
            for name in ["MiniDisc Rips", "import-manifests"] {
                try? fm.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
            }
        }
    }

    @objc private func exportAlbumAction() {
        guard !operationBusy, !scanning else { return }
        let mode = exportFormatPopup.indexOfSelectedItem
        if mode == 4 {
            chooseExportDestination(message: "Choose where to save the complete Sooloos FLAC backup") { destination in
                self.startLibraryBackup(destination: destination)
            }
            return
        }
        guard let selected = chosenExportAlbum() else {
            let a = NSAlert(); a.alertStyle = .warning; a.messageText = "Select an album"
            a.informativeText = "Choose an album in the Album box. Type part of the artist or title to find it."
            if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) }
            return
        }
        switch mode {
        case 0, 1:
            chooseExportDestination(message: "Export \(selected.artist) — \(selected.album)") { destination in
                self.startAlbumExport(selected: (selected.id, selected.artist, selected.album), format: mode == 1 ? "alac" : "flac", destination: destination)
            }
        case 2:
            chooseExportDestination(message: "Create CD-A image from \(selected.artist) — \(selected.album)") { destination in
                self.startAudioCDImageExport(selected: selected, destination: destination)
            }
        case 3:
            startMiniDiscAlbumExport(selected: selected)
        default: break
        }
    }

    private func chooseExportDestination(message: String, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Choose Location"; panel.message = message
        panel.begin { response in if response == .OK, let destination = panel.url { completion(destination) } }
    }

    private func startLibraryBackup(destination: URL) {
        let albums = exportAlbumChoices?() ?? []
        guard !albums.isEmpty else { status.stringValue = "No albums available to back up"; return }
        let a = NSAlert(); a.alertStyle = .informational; a.messageText = "Back up the entire Sooloos library?"
        a.informativeText = "ControlMac will export \(albums.count) albums as native-resolution FLAC with artwork and metadata. Same-title editions are kept in separate folders."
        a.addButton(withTitle: "Start Backup"); a.addButton(withTitle: "Cancel")
        let begin: () -> Void = { self.runLibraryBackup(albums: albums, destination: destination) }
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            a.beginSheetModal(for: parent) { if $0 == .alertFirstButtonReturn { begin() } }
        } else if a.runModal() == .alertFirstButtonReturn { begin() }
    }

    private func handleBackupProgress(_ line: String, albumIndex: Int, albumCount: Int, album: ExportAlbumChoice) {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 7, f[0] == "CMEXPROGRESS", let track = Int(f[2]), let tracks = Int(f[3]),
              let current = Int64(f[4]), let total = Int64(f[5]) else { return }
        let title = (Data(base64Encoded: f[6]).flatMap { String(data: $0, encoding: .utf8) }) ?? f[6]
        let trackFraction = min(1.0, max(0.0, Double(current) / Double(max(Int64(1), total))))
        let albumFraction = tracks > 0 ? (Double(max(0, track - 1)) + trackFraction) / Double(tracks) : 0
        let overall = (Double(albumIndex) + albumFraction) / Double(max(1, albumCount))
        DispatchQueue.main.async {
            self.importProgress.isHidden = false; self.importProgressLabel.isHidden = false
            self.trackProgress.isHidden = false; self.trackProgressLabel.isHidden = false
            self.importProgress.doubleValue = overall * 100
            self.importProgressLabel.stringValue = String(format: "Sooloos backup · album %d/%d · %.1f%%", albumIndex + 1, albumCount, overall * 100)
            self.trackProgress.doubleValue = albumFraction * 100
            self.trackProgressLabel.stringValue = "\(album.artist) — \(album.album) · track \(track)/\(tracks) · \(title)"
        }
    }

    private func runLibraryBackup(albums: [ExportAlbumChoice], destination: URL) {
        guard let host = coreHost?(), let cfg = exportBackendConfig(), let exe = Bundle.main.url(forResource: "ExportTool", withExtension: "exe") else {
            status.stringValue = "Exporter unavailable"; return
        }
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("ControlMac2026/Export Work", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let cancelMarker = cacheRoot.appendingPathComponent("cancel.flag")
        cancelRequested = false; localOperationKind = "export"; mediaCancelMarker = cancelMarker; operationBusy = true
        setOperationState("Backing up Sooloos library…", busy: true)
        DispatchQueue.global(qos: .utility).async {
            var cancelled = false; var skipped: [String] = []; var exported = 0
            for (index, album) in albums.enumerated() {
                if FileManager.default.fileExists(atPath: cancelMarker.path) { cancelled = true; break }
                let p = Process(); p.executableURL = URL(fileURLWithPath: cfg.mono + "/bin/mono-sgen64")
                p.arguments = ControlMacRuntime.monoArguments(executable: exe, arguments: ["backup-one", host, album.id, destination.path, cancelMarker.path], monoRoot: cfg.mono)
                var env = ProcessInfo.processInfo.environment; ControlMacRuntime.configureMonoEnvironment(&env, monoRoot: cfg.mono, managed: cfg.managed); p.environment = env
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                DispatchQueue.main.sync { self.activeMediaProcess = p }
                do { try p.run() } catch {
                    skipped.append("\(album.artist) — \(album.album) [\(album.id)] · could not start: \(error.localizedDescription)")
                    continue
                }
                var data = Data(); var pending = ""
                while true {
                    let chunk = pipe.fileHandleForReading.readData(ofLength: 4096); if chunk.isEmpty { break }
                    data.append(chunk); pending += String(data: chunk, encoding: .utf8) ?? ""
                    while let nl = pending.firstIndex(of: "\n") {
                        let line = String(pending[..<nl]); pending.removeSubrange(...nl)
                        self.handleBackupProgress(line, albumIndex: index, albumCount: albums.count, album: album)
                    }
                }
                p.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                if p.terminationStatus == 4 || text.contains("CMEXPORTCANCELLED") { cancelled = true; break }
                if p.terminationStatus != 0 {
                    let reason = text.split(separator: "\n").last(where: { $0.hasPrefix("CMERROR\t") }).map { String($0.dropFirst("CMERROR\t".count)) } ?? "Core could not prepare album for export."
                    skipped.append("\(album.artist) — \(album.album) [\(album.id)] · \(reason)")
                    continue
                }
                exported += 1
            }
            let reportURL = destination.appendingPathComponent("ControlMac Backup Report.txt")
            var report = [
                "ControlMac 2026 Sooloos Backup Report",
                "Date: \(ISO8601DateFormatter().string(from: Date()))",
                "Core: \(host)",
                "Destination: \(destination.path)",
                "Albums requested: \(albums.count)",
                "Albums exported: \(exported)",
                "Albums skipped: \(skipped.count)",
                "Cancelled: \(cancelled ? "yes" : "no")"
            ]
            if !skipped.isEmpty { report += ["", "Skipped albums:"] + skipped }
            try? (report.joined(separator: "\n") + "\n").write(to: reportURL, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                self.activeMediaProcess = nil; self.mediaCancelMarker = nil; self.localOperationKind = nil; self.operationBusy = false
                try? FileManager.default.removeItem(at: cacheRoot)
                if cancelled || self.cancelRequested {
                    self.setOperationState("Sooloos backup cancelled · \(exported) exported · \(skipped.count) skipped", busy: false)
                    self.status.stringValue = "Backup cancelled · report saved"
                } else {
                    self.importProgress.doubleValue = 100; self.trackProgress.doubleValue = 100
                    self.setOperationState("Sooloos backup complete · \(exported) exported · \(skipped.count) skipped", busy: false)
                    self.status.stringValue = "Backup complete · report: \(reportURL.path)"
                    if !skipped.isEmpty {
                        let a = NSAlert(); a.alertStyle = .warning; a.messageText = "Backup completed with \(skipped.count) skipped album(s)"
                        a.informativeText = "\(exported) albums exported. The Core refused \(skipped.count) album(s). Details are in ControlMac Backup Report.txt."
                        if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) }
                    }
                }
            }
        }
    }


    private func startAudioCDImageExport(selected: ExportAlbumChoice, destination: URL) {
        guard let host = coreHost?(), let cfg = exportBackendConfig(), let exe = Bundle.main.url(forResource: "ExportTool", withExtension: "exe") else {
            status.stringValue = "Exporter unavailable"; return
        }
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("ControlMac2026/Export Work", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let cancelMarker = cacheRoot.appendingPathComponent("cancel.flag")
        cancelRequested = false; localOperationKind = "export"; mediaCancelMarker = cancelMarker; operationBusy = true
        setOperationState("Creating CD-A image · \(selected.artist) — \(selected.album)…", busy: true)
        let p = Process(); p.executableURL = URL(fileURLWithPath: cfg.mono + "/bin/mono-sgen64")
        p.arguments = ControlMacRuntime.monoArguments(executable: exe, arguments: ["cda", host, selected.id, destination.path, cancelMarker.path], monoRoot: cfg.mono)
        var env = ProcessInfo.processInfo.environment; ControlMacRuntime.configureMonoEnvironment(&env, monoRoot: cfg.mono, managed: cfg.managed); p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe; activeMediaProcess = p
        do { try p.run() } catch {
            activeMediaProcess = nil; mediaCancelMarker = nil; localOperationKind = nil; operationBusy = false
            try? FileManager.default.removeItem(at: cacheRoot); setOperationState("CD-A export could not start", busy: false); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var collected = Data(); var pending = ""
            while true {
                let chunk = pipe.fileHandleForReading.readData(ofLength: 4096); if chunk.isEmpty { break }
                collected.append(chunk); pending += String(data: chunk, encoding: .utf8) ?? ""
                while let nl = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<nl]); pending.removeSubrange(...nl); self.handleExportProgress(line)
                }
            }
            p.waitUntilExit(); let text = String(data: collected, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.activeMediaProcess = nil; self.mediaCancelMarker = nil; self.localOperationKind = nil; self.operationBusy = false
                try? FileManager.default.removeItem(at: cacheRoot)
                if p.terminationStatus == 0, let done = text.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("CMEXPORTDONE\t") }) {
                    let path = String(done.dropFirst("CMEXPORTDONE\t".count)); self.setOperationState("CD-A image complete · \(path)", busy: false); self.status.stringValue = "CD-A image complete · \(path)"
                } else if p.terminationStatus == 4 || text.contains("CMEXPORTCANCELLED") || self.cancelRequested {
                    self.setOperationState("CD-A export cancelled", busy: false)
                } else {
                    let detail = text.split(separator: "\n").last(where: { $0.hasPrefix("CMERROR\t") }).map { String($0.dropFirst("CMERROR\t".count)) } ?? "CD-A image did not complete."
                    self.setOperationState("CD-A export stopped safely", busy: false)
                    let a = NSAlert(); a.alertStyle = .warning; a.messageText = "CD-A export did not complete"; a.informativeText = detail
                    if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) }
                }
            }
        }
    }

    private struct MiniDiscWriteStatus {
        let writable: Bool
        let writeProtected: Bool
        let trackCount: Int
        let used: Int64
        let left: Int64
        let total: Int64
        let title: String
        let deviceName: String
        let netMDLevel: Int
        let hiMDCapable: Bool
    }

    private func miniDiscWriteStatus() -> (MiniDiscWriteStatus?, String) {
        guard let node = nodeURL(), let root = Bundle.main.resourceURL else { return (nil, "NetMD helper unavailable") }
        let helper = root.appendingPathComponent("netmd/controlmac-md-status.cjs")
        guard FileManager.default.fileExists(atPath: helper.path) else { return (nil, "MiniDisc status helper missing") }
        let p = Process(); p.executableURL = node; p.arguments = [helper.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (nil, error.localizedDescription) }
        let deadline = Date().addingTimeInterval(15)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); Thread.sleep(forTimeInterval: 0.25); if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) } }
        p.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n").map(String.init)
        if let hi = lines.first(where: { $0.hasPrefix("CMMDHIMD\t") }) {
            let f = hi.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let device = f.count > 1 ? (Data(base64Encoded: f[1]).flatMap { String(data: $0, encoding: .utf8) } ?? "Hi-MD recorder") : "Hi-MD recorder"
            return (nil, "Hi-MD media detected in \(device). 1 GB Hi-MD support uses a separate protocol and is not enabled for writing yet.")
        }
        guard p.terminationStatus == 0,
              let line = lines.first(where: { $0.hasPrefix("CMMDSTATUS\t") }) else {
            return (nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "MiniDisc did not respond" : text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 8, let tracks = Int(f[3]), let used = Int64(f[4]), let left = Int64(f[5]), let total = Int64(f[6]) else { return (nil, "MiniDisc status response was invalid") }
        let title = Data(base64Encoded: f[7]).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let device = f.count > 8 ? (Data(base64Encoded: f[8]).flatMap { String(data: $0, encoding: .utf8) } ?? "NetMD") : "NetMD"
        let level = f.count > 9 ? (Int(f[9]) ?? 0) : 0
        let hiMD = f.count > 10 && f[10] == "1"
        return (MiniDiscWriteStatus(writable: f[1] == "1", writeProtected: f[2] == "1", trackCount: tracks, used: used, left: left, total: total, title: title, deviceName: device, netMDLevel: level, hiMDCapable: hiMD), "")
    }

    private struct HiMDWriteStatus {
        let deviceName: String
        let title: String
        let trackCount: Int
        let used: Int64
        let left: Int64
        let total: Int64
    }

    private func hiMDWriteStatus() -> (HiMDWriteStatus?, String) {
        guard let node = nodeURL(), let root = Bundle.main.resourceURL else { return (nil, "Hi-MD helper unavailable") }
        let helper = root.appendingPathComponent("netmd/controlmac-himd-track.cjs")
        guard FileManager.default.fileExists(atPath: helper.path) else { return (nil, "Hi-MD helper missing") }
        let p = Process(); p.executableURL = node; p.arguments = [helper.path, "status"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (nil, error.localizedDescription) }
        let deadline = Date().addingTimeInterval(30)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0, let line = text.split(separator: "\n").map(String.init).first(where: { $0.hasPrefix("CMHIMDSTATUS\t") }) else {
            return (nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Hi-MD did not respond" : text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 7, let tracks = Int(f[3]), let used = Int64(f[4]), let left = Int64(f[5]), let total = Int64(f[6]) else { return (nil, "Hi-MD status response was invalid") }
        let device = Data(base64Encoded: f[1]).flatMap { String(data: $0, encoding: .utf8) } ?? "Hi-MD"
        let title = Data(base64Encoded: f[2]).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return (HiMDWriteStatus(deviceName: device, title: title, trackCount: tracks, used: used, left: left, total: total), "")
    }

    private func miniDiscTime(_ frames: Int64) -> String {
        let seconds = max(Int64(0), frames / 512)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func miniDiscSupportsMDLP(_ disc: MiniDiscWriteStatus) -> Bool {
        if disc.netMDLevel >= 80 { return true }
        let name = disc.deviceName.uppercased()
        let knownMDLPModels = [
            "MZ-N510", "N610", "MZ-N710", "NF810", "MZ-N910", "MZ-N10",
            "MZ-NE810", "NE910", "MDS-S500"
        ]
        return knownMDLPModels.contains { name.contains($0) }
    }

    private func startMiniDiscAlbumExport(selected: ExportAlbumChoice) {
        status.stringValue = "Checking connected MiniDisc…"
        DispatchQueue.global(qos: .userInitiated).async {
            let (disc, error) = self.miniDiscWriteStatus()
            DispatchQueue.main.async {
                guard let disc = disc else {
                    if error.contains("Hi-MD media detected") { self.startHiMDAlbumExport(selected: selected); return }
                    let a = NSAlert(); a.alertStyle = .warning; a.messageText = "MiniDisc unavailable"; a.informativeText = error
                    if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) } else { a.runModal() }
                    return
                }
                guard disc.writable && !disc.writeProtected else {
                    let a = NSAlert(); a.alertStyle = .warning; a.messageText = "MiniDisc is write-protected"
                    a.informativeText = "Insert a writable MiniDisc before exporting. Nothing has been prepared or written."
                    if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) } else { a.runModal() }
                    return
                }
                let a = NSAlert(); a.alertStyle = .warning; a.messageText = "Prepare album for MiniDisc?"
                let hiNote = disc.hiMDCapable ? " Hi-MD-capable recorder detected; 1 GB Hi-MD media uses a separate path and is not written as classic MD." : ""
                a.informativeText = "\(disc.deviceName) · ControlMac will first convert and verify all \(selected.tracks) tracks locally, then re-check the disc before writing. Free SP time: \(self.miniDiscTime(disc.left)). LP2 uses about half the disc time; LP4 about a quarter. Existing tracks will not be erased.\(hiNote)"
                let modePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 28), pullsDown: false)
                modePopup.addItem(withTitle: "SP Stereo · best classic MD quality")
                if self.miniDiscSupportsMDLP(disc) {
                    modePopup.addItem(withTitle: "LP2 · ATRAC3 · about 2× duration")
                    modePopup.addItem(withTitle: "LP4 · ATRAC3 · about 4× duration")
                }
                a.accessoryView = modePopup
                a.addButton(withTitle: "Prepare & Write"); a.addButton(withTitle: "Cancel")
                let begin: () -> Void = {
                    let mode = modePopup.indexOfSelectedItem == 1 ? "lp2" : (modePopup.indexOfSelectedItem == 2 ? "lp4" : "sp")
                    self.runMiniDiscAlbumExport(selected: selected, mode: mode)
                }
                if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) { if $0 == .alertFirstButtonReturn { begin() } } }
                else if a.runModal() == .alertFirstButtonReturn { begin() }
            }
        }
    }

    private func startHiMDAlbumExport(selected: ExportAlbumChoice) {
        status.stringValue = "Checking Hi-MD filesystem…"
        DispatchQueue.global(qos: .userInitiated).async {
            let (disc, error) = self.hiMDWriteStatus()
            DispatchQueue.main.async {
                guard let disc = disc else {
                    let a = NSAlert(); a.alertStyle = .warning; a.messageText = "Hi-MD unavailable"; a.informativeText = error
                    if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) } else { a.runModal() }
                    return
                }
                let free = ByteCountFormatter.string(fromByteCount: disc.left, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: disc.total, countStyle: .file)
                let a = NSAlert(); a.alertStyle = .warning; a.messageText = "Write album to Hi-MD?"
                a.informativeText = "Hi-MD 1 GB · Experimental · \(disc.deviceName) · \(disc.trackCount) existing track(s) · \(free) free of \(total). ControlMac will prepare every track as 16-bit / 44.1 kHz LPCM before writing. Existing tracks will not be erased and the disc will never be auto-formatted."
                a.addButton(withTitle: "Prepare & Write"); a.addButton(withTitle: "Cancel")
                let begin: () -> Void = { self.runMiniDiscAlbumExport(selected: selected, mode: "himd-pcm") }
                if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) { if $0 == .alertFirstButtonReturn { begin() } } }
                else if a.runModal() == .alertFirstButtonReturn { begin() }
            }
        }
    }

    private func runMiniDiscAlbumExport(selected: ExportAlbumChoice, mode: String) {
        guard let host = coreHost?(), let cfg = exportBackendConfig(), let exe = Bundle.main.url(forResource: "ExportTool", withExtension: "exe") else {
            status.stringValue = "MiniDisc exporter unavailable"; return
        }
        let writer: URL
        if mode == "himd-pcm" {
            guard let w = Bundle.main.url(forResource: "controlmac-himd-track", withExtension: "cjs", subdirectory: "netmd") else { status.stringValue = "Hi-MD exporter unavailable"; return }
            writer = w
        } else {
            guard let w = Bundle.main.url(forResource: "controlmac-upload-track", withExtension: "cjs", subdirectory: "netmd") else { status.stringValue = "MiniDisc exporter unavailable"; return }
            writer = w
        }
        let modeLabel = mode == "himd-pcm" ? "Hi-MD LPCM" : mode.uppercased()
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("ControlMac2026/Export Work", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pulled = root.appendingPathComponent("album", isDirectory: true); let work = root.appendingPathComponent("pcm", isDirectory: true)
        do { try FileManager.default.createDirectory(at: pulled, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) }
        catch { status.stringValue = "Could not create MiniDisc work area"; return }
        let cancelMarker = root.appendingPathComponent("cancel.flag")
        cancelRequested = false; localOperationKind = "minidisc-write"; mediaCancelMarker = cancelMarker; operationBusy = true
        setOperationState("Preparing \(selected.artist) — \(selected.album) for MiniDisc…", busy: true)
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?; var cancelled = false
            let pull = Process(); pull.executableURL = URL(fileURLWithPath: cfg.mono + "/bin/mono-sgen64")
            pull.arguments = ControlMacRuntime.monoArguments(executable: exe, arguments: ["folder", host, selected.id, "flac", pulled.path, cancelMarker.path], monoRoot: cfg.mono)
            var env = ProcessInfo.processInfo.environment; ControlMacRuntime.configureMonoEnvironment(&env, monoRoot: cfg.mono, managed: cfg.managed); pull.environment = env
            let pipe = Pipe(); pull.standardOutput = pipe; pull.standardError = pipe
            DispatchQueue.main.sync { self.activeMediaProcess = pull }
            do { try pull.run() } catch { failure = error.localizedDescription }
            var pullData = Data(); var pending = ""
            if failure == nil {
                while true {
                    let chunk = pipe.fileHandleForReading.readData(ofLength: 4096); if chunk.isEmpty { break }
                    pullData.append(chunk); pending += String(data: chunk, encoding: .utf8) ?? ""
                    while let nl = pending.firstIndex(of: "\n") { let line = String(pending[..<nl]); pending.removeSubrange(...nl); self.handleExportProgress(line) }
                }
                pull.waitUntilExit(); let text = String(data: pullData, encoding: .utf8) ?? ""
                if pull.terminationStatus == 4 || text.contains("CMEXPORTCANCELLED") { cancelled = true }
                else if pull.terminationStatus != 0 { failure = text.split(separator: "\n").last(where: { $0.hasPrefix("CMERROR\t") }).map { String($0.dropFirst("CMERROR\t".count)) } ?? "Could not prepare album for MiniDisc." }
            }
            var prepared: [(title: String, media: URL, spFrames: Int64)] = []
            if failure == nil && !cancelled {
                let dirs = (try? FileManager.default.contentsOfDirectory(at: pulled, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                let albumDir = dirs.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) ?? pulled
                let files = ((try? FileManager.default.contentsOfDirectory(at: albumDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).filter { $0.pathExtension.lowercased() == "flac" }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                if files.isEmpty { failure = "No prepared tracks were found for MiniDisc." }
                let atrac = self.runtimeTool("atracdenc")
                if mode != "sp" && mode != "himd-pcm", !FileManager.default.isExecutableFile(atPath: atrac.path) { failure = "Bundled ATRAC encoder is unavailable." }
                for (index, flac) in files.enumerated() where failure == nil && !cancelled {
                    if FileManager.default.fileExists(atPath: cancelMarker.path) { cancelled = true; break }
                    let title = flac.deletingPathExtension().lastPathComponent.replacingOccurrences(of: #"^\d+\s+"#, with: "", options: .regularExpression)
                    let seconds = self.audioDurationSeconds(flac)
                    let spFrames = Int64(ceil(max(0, seconds) * 512.0))
                    let media = work.appendingPathComponent(String(format: "%02d.%@", index + 1, (mode == "sp" || mode == "himd-pcm") ? "pcm" : "atrac"))
                    DispatchQueue.main.async {
                        self.importProgress.isHidden = false; self.importProgressLabel.isHidden = false; self.trackProgress.isHidden = false; self.trackProgressLabel.isHidden = false
                        self.importProgress.doubleValue = Double(index) / Double(max(1, files.count)) * 40
                        self.importProgressLabel.stringValue = "MiniDisc prepare · track \(index + 1)/\(files.count) · \(modeLabel)"
                        self.trackProgress.doubleValue = 0; self.trackProgressLabel.stringValue = "\(title) · preparing \(modeLabel)"
                    }
                    if mode == "sp" || mode == "himd-pcm" {
                        let ff = Process(); ff.executableURL = self.runtimeTool("ffmpeg")
                        ff.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", flac.path, "-map", "0:a:0", "-ar", "44100", "-ac", "2", "-c:a", "pcm_s16be", "-f", "s16be", media.path]
                        DispatchQueue.main.sync { self.activeMediaProcess = ff }
                        do { try ff.run(); ff.waitUntilExit() } catch { failure = error.localizedDescription; break }
                        if ff.terminationStatus != 0 { if FileManager.default.fileExists(atPath: cancelMarker.path) { cancelled = true } else { failure = "PCM conversion failed for \(title)." }; break }
                        let size = Int64((try? media.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                        if size <= 0 || size % 4 != 0 { failure = "Prepared \(modeLabel) PCM verification failed for \(title)."; break }
                    } else {
                        let wav = work.appendingPathComponent(String(format: "%02d.wav", index + 1))
                        let oma = work.appendingPathComponent(String(format: "%02d.oma", index + 1))
                        let ff = Process(); ff.executableURL = self.runtimeTool("ffmpeg")
                        ff.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", flac.path, "-map", "0:a:0", "-ar", "44100", "-ac", "2", "-c:a", "pcm_s16le", wav.path]
                        DispatchQueue.main.sync { self.activeMediaProcess = ff }
                        do { try ff.run(); ff.waitUntilExit() } catch { failure = error.localizedDescription; break }
                        if ff.terminationStatus != 0 { failure = "WAV preparation failed for \(title)."; break }
                        let enc = Process(); enc.executableURL = atrac
                        enc.arguments = ["-e", "atrac3", "-i", wav.path, "-o", oma.path, "--bitrate", mode == "lp2" ? "128" : "64"]
                        enc.standardOutput = Pipe(); enc.standardError = Pipe(); DispatchQueue.main.sync { self.activeMediaProcess = enc }
                        do { try enc.run(); enc.waitUntilExit() } catch { failure = error.localizedDescription; break }
                        if enc.terminationStatus != 0 { failure = "ATRAC3 \(mode.uppercased()) encoding failed for \(title)."; break }
                        guard let omaData = try? Data(contentsOf: oma), omaData.count > 96 else { failure = "ATRAC3 output verification failed for \(title)."; break }
                        do { try omaData.subdata(in: 96..<omaData.count).write(to: media, options: .atomic) } catch { failure = error.localizedDescription; break }
                        let size = Int64((try? media.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                        let frameSize: Int64 = mode == "lp2" ? 192 : 96
                        if size <= 0 || size % frameSize != 0 { failure = "Prepared \(mode.uppercased()) ATRAC frame verification failed for \(title)."; break }
                        try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: oma)
                    }
                    prepared.append((title: title, media: media, spFrames: spFrames))
                    DispatchQueue.main.async { self.trackProgress.doubleValue = 100; self.trackProgressLabel.stringValue = "\(title) · \(modeLabel) prepared and verified" }
                }
            }
            if failure == nil && !cancelled {
                if mode == "himd-pcm" {
                    let (disc, error) = self.hiMDWriteStatus()
                    if let disc = disc {
                        let bytes = prepared.reduce(Int64(0)) { total, item in total + Int64((try? item.media.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                        let reserve = Int64(prepared.count) * 2 * 1024 * 1024
                        if bytes + reserve > disc.left {
                            failure = "Not enough Hi-MD capacity. Prepared audio needs about \(ByteCountFormatter.string(fromByteCount: bytes + reserve, countStyle: .file)); free \(ByteCountFormatter.string(fromByteCount: disc.left, countStyle: .file)). Nothing was written."
                        }
                    } else { failure = "Hi-MD could not be re-checked before writing: \(error)" }
                } else {
                    let (disc, error) = self.miniDiscWriteStatus()
                    if let disc = disc {
                        if !disc.writable || disc.writeProtected { failure = "The MiniDisc is now write-protected or not writable. Nothing was written." }
                        else if mode != "sp" && !self.miniDiscSupportsMDLP(disc) { failure = "This recorder does not report MDLP support for \(mode.uppercased()). Nothing was written." }
                        else {
                            let spFrames = prepared.reduce(Int64(0)) { $0 + $1.spFrames }
                            let divisor: Double = mode == "lp2" ? 2.0 : (mode == "lp4" ? 4.0 : 1.0)
                            let requiredFrames = Int64(ceil(Double(spFrames) / divisor))
                            if requiredFrames > disc.left { failure = "Not enough MiniDisc capacity in \(mode.uppercased()). Required \(self.miniDiscTime(requiredFrames)); free SP-equivalent \(self.miniDiscTime(disc.left)). Nothing was written." }
                        }
                    } else { failure = "MiniDisc could not be re-checked before writing: \(error)" }
                }
            }
            if failure == nil && !cancelled {
                for (index, item) in prepared.enumerated() {
                    if FileManager.default.fileExists(atPath: cancelMarker.path) { cancelled = true; break }
                    DispatchQueue.main.async {
                        self.importProgress.doubleValue = 40 + (Double(index) / Double(max(1, prepared.count)) * 60)
                        self.importProgressLabel.stringValue = "MiniDisc write · track \(index + 1)/\(prepared.count)"
                        self.trackProgress.doubleValue = 0; self.trackProgressLabel.stringValue = "\(item.title) · writing \(modeLabel)"
                    }
                    let md = Process(); md.executableURL = self.runtimeTool("node")
                    if mode == "himd-pcm" { md.arguments = [writer.path, "write", item.media.path, item.title, selected.album, selected.artist, cancelMarker.path] }
                    else { md.arguments = [writer.path, item.media.path, item.title, cancelMarker.path, mode] }
                    let mdPipe = Pipe(); md.standardOutput = mdPipe; md.standardError = mdPipe
                    DispatchQueue.main.sync { self.activeMediaProcess = md }
                    do { try md.run() } catch { failure = error.localizedDescription; break }
                    var mdText = ""
                    while md.isRunning {
                        let chunk = mdPipe.fileHandleForReading.availableData
                        if !chunk.isEmpty {
                            let text = String(data: chunk, encoding: .utf8) ?? ""; mdText += text
                            for line in text.split(separator: "\n").map(String.init) {
                                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                                let progressTag = mode == "himd-pcm" ? "CMHIMDPROGRESS" : "CMMDWRITEPROGRESS"
                                if parts.count >= 3, parts[0] == progressTag, let current = Int64(parts[1]), let total = Int64(parts[2]) {
                                    let fraction = Double(current) / Double(max(Int64(1), total))
                                    DispatchQueue.main.async {
                                        self.trackProgress.doubleValue = fraction * 100; self.trackProgressLabel.stringValue = String(format: "%@ · writing %@ · %.0f%%", item.title, modeLabel, fraction * 100)
                                        self.importProgress.doubleValue = 40 + ((Double(index) + fraction) / Double(max(1, prepared.count)) * 60)
                                    }
                                }
                            }
                        }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    md.waitUntilExit(); mdText += String(data: mdPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    if md.terminationStatus == 4 || mdText.contains("CMMDWRITECANCELLED") || mdText.contains("CMHIMDCANCELLED") { cancelled = true; break }
                    if md.terminationStatus != 0 {
                        let prefix = mode == "himd-pcm" ? "CMHIMDERROR\t" : "CMMDWRITEERROR\t"
                        failure = mdText.split(separator: "\n").last(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) } ?? "\(modeLabel) write failed for \(item.title)."
                        break
                    }
                    try? FileManager.default.removeItem(at: item.media)
                    DispatchQueue.main.async { self.trackProgress.doubleValue = 100; self.trackProgressLabel.stringValue = "\(item.title) · written" }
                }
            }
            DispatchQueue.main.async {
                self.activeMediaProcess = nil; self.mediaCancelMarker = nil; self.localOperationKind = nil; self.operationBusy = false
                try? FileManager.default.removeItem(at: root)
                if cancelled || self.cancelRequested { self.setOperationState("MiniDisc write cancelled and USB released", busy: false); self.status.stringValue = "MiniDisc write cancelled" }
                else if let failure = failure {
                    self.setOperationState("MiniDisc write stopped safely", busy: false)
                    let a = NSAlert(); a.alertStyle = .warning; a.messageText = "MiniDisc write did not complete"; a.informativeText = failure
                    if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) }
                } else { self.importProgress.doubleValue = 100; self.trackProgress.doubleValue = 100; self.setOperationState("MiniDisc write complete", busy: false); self.status.stringValue = "MiniDisc write complete" }
            }
        }
    }

    private func exportBackendConfig() -> (mono: String, managed: String)? {
        ControlMacRuntime.backendConfig()
    }

    private func handleExportProgress(_ line: String) {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 7, f[0] == "CMEXPROGRESS", let track = Int(f[2]), let count = Int(f[3]), let current = Int64(f[4]), let total = Int64(f[5]) else { return }
        let title = (Data(base64Encoded: f[6]).flatMap { String(data: $0, encoding: .utf8) }) ?? f[6]
        let fraction = min(1.0, max(0.0, Double(current) / Double(max(Int64(1), total))))
        let phaseFraction: Double
        let phaseName: String
        switch f[1] {
        case "DOWNLOAD": phaseFraction = 0.85 * fraction; phaseName = "Downloading original"
        case "CONVERT": phaseFraction = 0.90; phaseName = "Converting"
        case "VERIFY": phaseFraction = 1.0; phaseName = "Verifying"
        default: phaseFraction = fraction; phaseName = f[1].capitalized
        }
        let overall = count > 0 ? min(1.0, max(0.0, (Double(max(0, track - 1)) + phaseFraction) / Double(count))) : phaseFraction
        DispatchQueue.main.async {
            self.importProgress.isHidden = false; self.importProgressLabel.isHidden = false; self.trackProgress.isHidden = false; self.trackProgressLabel.isHidden = false
            self.importProgress.doubleValue = overall * 100; self.importProgressLabel.stringValue = String(format: "Overall export · %d/%d · %@ · %.0f%%", track, count, phaseName, overall * 100)
            self.trackProgress.doubleValue = phaseFraction * 100; self.trackProgressLabel.stringValue = String(format: "Track %d/%d · %@ · %@ · %.0f%%", track, count, title, phaseName, phaseFraction * 100)
        }
    }

    private func startAlbumExport(selected: (id: String, artist: String, album: String), format: String, destination: URL) {
        guard let host = coreHost?(), let cfg = exportBackendConfig(), let exe = Bundle.main.url(forResource: "ExportTool", withExtension: "exe") else {
            status.stringValue = "Exporter unavailable"; return
        }
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("ControlMac2026/Export Work", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true) }
        catch { status.stringValue = "Could not create export work area"; return }
        let cancelMarker = cacheRoot.appendingPathComponent("cancel.flag")
        cancelRequested = false; localOperationKind = "export"; mediaCancelMarker = cancelMarker; operationBusy = true
        setOperationState("Exporting \(selected.artist) — \(selected.album)…", busy: true)
        importProgress.isHidden = false; importProgressLabel.isHidden = false; importProgress.doubleValue = 0
        trackProgress.isHidden = false; trackProgressLabel.isHidden = false; trackProgress.doubleValue = 0
        let p = Process(); p.executableURL = URL(fileURLWithPath: cfg.mono + "/bin/mono-sgen64")
        p.arguments = ControlMacRuntime.monoArguments(executable: exe, arguments: ["folder", host, selected.id, format, destination.path, cancelMarker.path], monoRoot: cfg.mono)
        var env = ProcessInfo.processInfo.environment; ControlMacRuntime.configureMonoEnvironment(&env, monoRoot: cfg.mono, managed: cfg.managed); p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe; activeMediaProcess = p
        do { try p.run() }
        catch {
            activeMediaProcess = nil; mediaCancelMarker = nil; localOperationKind = nil; operationBusy = false; try? FileManager.default.removeItem(at: cacheRoot)
            setOperationState("Export could not start", busy: false); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var collected = Data(); var pending = ""
            while true {
                let chunk = pipe.fileHandleForReading.readData(ofLength: 4096); if chunk.isEmpty { break }
                collected.append(chunk); pending += String(data: chunk, encoding: .utf8) ?? ""
                while let nl = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<nl]); pending.removeSubrange(...nl); self.handleExportProgress(line)
                }
            }
            p.waitUntilExit(); let text = String(data: collected, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.activeMediaProcess = nil; self.mediaCancelMarker = nil; self.localOperationKind = nil; self.operationBusy = false
                try? FileManager.default.removeItem(at: cacheRoot)
                if p.terminationStatus == 0, let doneLine = text.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("CMEXPORTDONE\t") }) {
                    let path = String(doneLine.dropFirst("CMEXPORTDONE\t".count)); self.setOperationState("Export complete · \(path)", busy: false); self.status.stringValue = "Export complete · \(path)"
                } else if p.terminationStatus == 4 || text.contains("CMEXPORTCANCELLED") || self.cancelRequested {
                    self.setOperationState("Export cancelled · completed files left in destination", busy: false); self.status.stringValue = "Export cancelled"
                } else {
                    let detail = text.split(separator: "\n").last(where: { $0.hasPrefix("CMERROR\t") }).map { String($0.dropFirst("CMERROR\t".count)) } ?? "Export did not complete."
                    self.setOperationState("Export stopped safely", busy: false)
                    let a = NSAlert(); a.alertStyle = .warning; a.messageText = "Export did not complete"; a.informativeText = detail
                    if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) }
                }
            }
        }
    }

    private func supportedTypes() -> [UTType] {
        ["flac", "aiff", "aif", "wav", "m4a", "mp4", "aac", "mp3", "ogg", "oga"].compactMap { UTType(filenameExtension: $0) }
    }

    private func isSupportedAudio(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["flac", "aiff", "aif", "wav", "m4a", "mp4", "aac", "mp3", "ogg", "oga"].contains(ext)
    }

    private func stage(urls: [URL]) {
        guard !scanning else { return }
        scanning = true
        status.stringValue = "Scanning sources…"
        importButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            var files: [URL] = []
            let fm = FileManager.default
            for url in urls {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                        for case let file as URL in e where self.isSupportedAudio(file) { files.append(file) }
                    }
                } else if self.isSupportedAudio(url) { files.append(url) }
            }
            let existing = Set(self.rows.map { $0.url.standardizedFileURL.path })
            let unique = files.filter { !existing.contains($0.standardizedFileURL.path) }
            var discovered: [ImportStageRow] = []
            for (index, file) in unique.enumerated() {
                if let row = self.probe(file) { discovered.append(row) }
                DispatchQueue.main.async {
                    self.status.stringValue = "Scanning \(index + 1)/\(unique.count)…"
                }
            }
            DispatchQueue.main.async {
                self.rows.append(contentsOf: discovered)
                self.sortRows(); self.table.reloadData()
                self.scanning = false; self.updateStatus()
            }
        }
    }

    private func probe(_ url: URL) -> ImportStageRow? {
        let ffprobe = self.runtimeTool("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe.path) else { return fallbackRow(url, status: "ffprobe missing") }
        let p = Process(); p.executableURL = ffprobe
        p.arguments = ["-v", "error", "-select_streams", "a:0", "-show_entries",
                       "stream=codec_name,sample_rate,channels,bits_per_sample,bits_per_raw_sample:format_tags=artist,album,title,track,disc,date,album_artist",
                       "-of", "json", url.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return fallbackRow(url, status: "Probe failed") }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fallbackRow(url, status: "Unreadable audio")
        }
        let format = json["format"] as? [String: Any] ?? [:]
        let tagsRaw = format["tags"] as? [String: Any] ?? [:]
        var tags: [String: String] = [:]
        for (k, v) in tagsRaw { tags[k.lowercased()] = String(describing: v) }
        let stream = (json["streams"] as? [[String: Any]])?.first ?? [:]
        let codec = String(describing: stream["codec_name"] ?? url.pathExtension.lowercased())
        let rate = Int(String(describing: stream["sample_rate"] ?? "0")) ?? 0
        let channels = intValue(stream["channels"])
        let bits = max(intValue(stream["bits_per_raw_sample"]), intValue(stream["bits_per_sample"]))
        var artist = tags["album_artist"] ?? tags["artist"] ?? ""
        var album = tags["album"] ?? ""
        var title = tags["title"] ?? ""
        var derived: [String] = []
        if title.isEmpty { title = url.deletingPathExtension().lastPathComponent; derived.append("title") }
        if album.isEmpty { album = url.deletingLastPathComponent().lastPathComponent; derived.append("album") }
        if artist.isEmpty {
            let parent = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            if !parent.isEmpty { artist = parent; derived.append("artist") }
        }
        let state = derived.isEmpty ? "Ready" : "Review derived " + derived.joined(separator: "/")
        return ImportStageRow(url: url, artist: artist, album: album, title: title,
            disc: leadingInt(tags["disc"]), track: leadingInt(tags["track"]), codec: codec,
            rate: rate, bits: bits, channels: channels, status: state)
    }

    private func intValue(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        return Int(String(describing: value ?? "0")) ?? 0
    }

    private func leadingInt(_ value: String?) -> Int {
        guard let value = value else { return 0 }
        let first = value.split(separator: "/").first.map(String.init) ?? value
        return Int(first.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func fallbackRow(_ url: URL, status: String) -> ImportStageRow {
        ImportStageRow(url: url,
            artist: "",
            album: url.deletingLastPathComponent().lastPathComponent,
            title: url.deletingPathExtension().lastPathComponent,
            disc: 0, track: 0, codec: url.pathExtension.lowercased(),
            rate: 0, bits: 0, channels: 0, status: status)
    }

    private func sortRows() {
        rows.sort {
            let la = $0.artist.localizedCaseInsensitiveCompare($1.artist)
            if la != .orderedSame { return la == .orderedAscending }
            let lb = $0.album.localizedCaseInsensitiveCompare($1.album)
            if lb != .orderedSame { return lb == .orderedAscending }
            if $0.disc != $1.disc { return $0.disc < $1.disc }
            if $0.track != $1.track { return $0.track < $1.track }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func updateStatus() {
        let albums = Set(rows.map { $0.artist.lowercased() + "\u{1f}" + $0.album.lowercased() })
        let review = rows.filter { !$0.status.hasPrefix("Ready") || $0.status.localizedCaseInsensitiveContains("review") }.count
        status.stringValue = rows.isEmpty ? "Nothing staged" : "\(rows.count) tracks · \(albums.count) album groups" + (review > 0 ? " · \(review) need review" : "")
        importButton.isEnabled = !rows.isEmpty && !scanning && !operationBusy && coreHost?() != nil && importHandler != nil
        miniDiscRipButton.isEnabled = !scanning && !operationBusy && rows.contains { $0.url.scheme?.lowercased() == "minidisc" }
        miniDiscWipeButton.isEnabled = !scanning && !operationBusy
    }

    func setOperationState(_ text: String, busy: Bool) {
        operationBusy = busy
        status.stringValue = text
        importButton.isEnabled = !busy && !rows.isEmpty && !scanning && coreHost?() != nil && importHandler != nil
        miniDiscRipButton.isEnabled = !busy && !scanning && rows.contains { $0.url.scheme?.lowercased() == "minidisc" }
        miniDiscWipeButton.isEnabled = !busy && !scanning
        cancelButton.isHidden = !busy
        cancelButton.isEnabled = busy
        if !busy {
            importProgress.isHidden = true; importProgressLabel.isHidden = true
            trackProgress.isHidden = true; trackProgressLabel.isHidden = true
        }
    }

    func setImportProgress(batch: Int, batchCount: Int, phase: String, track: Int, trackCount: Int, title: String, current: Int64, total: Int64) {
        importProgress.isHidden = false; importProgressLabel.isHidden = false
        trackProgress.isHidden = false; trackProgressLabel.isHidden = false
        let safeTotal = max(Int64(1), total)
        let fraction = min(1.0, max(0.0, Double(current) / Double(safeTotal)))
        let trackPosition = trackCount > 0 ? min(1.0, max(0.0, (Double(max(0, track - 1)) + fraction) / Double(trackCount))) : fraction
        let batchFraction: Double
        let phaseName: String
        switch phase {
        case "ANALYZE": batchFraction = 0.15 * trackPosition; phaseName = "Analyzing"
        case "COPY": batchFraction = 0.15 + 0.75 * trackPosition; phaseName = "Copying"
        case "VERIFY": batchFraction = 0.90 + 0.10 * fraction; phaseName = "Verifying"
        default: batchFraction = trackPosition; phaseName = phase.capitalized
        }
        let overallFraction = batchCount > 0 ? min(1.0, max(0.0, (Double(max(0, batch - 1)) + batchFraction) / Double(batchCount))) : batchFraction
        let overallPercent = overallFraction * 100
        importProgress.doubleValue = overallPercent
        importProgressLabel.stringValue = String(format: "Overall · Batch %d/%d · %@ · %.0f%%", batch, batchCount, phaseName, overallPercent)

        trackProgress.doubleValue = fraction * 100
        switch phase {
        case "ANALYZE":
            trackProgressLabel.stringValue = String(format: "Track %d/%d · %@ · analyzing %.0f%%", track, trackCount, title, fraction * 100)
        case "COPY":
            let mb = 1024.0 * 1024.0
            trackProgressLabel.stringValue = String(format: "Track %d/%d · %@ · %.0f%% · %.1f / %.1f MB", track, trackCount, title, fraction * 100, Double(current)/mb, Double(total)/mb)
        case "VERIFY":
            trackProgress.doubleValue = fraction * 100
            trackProgressLabel.stringValue = String(format: "Verification · %@ · %.0f%%", title, fraction * 100)
        default:
            trackProgressLabel.stringValue = String(format: "Track %d/%d · %@ · %.0f%%", track, trackCount, title, fraction * 100)
        }
    }

    private func stageISOImages(_ urls: [URL]) {
        guard !scanning else { return }
        scanning = true; status.stringValue = "Mounting disc image(s) read-only…"; importButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            var mounts: [URL] = []
            for image in urls {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                p.arguments = ["attach", "-readonly", "-nobrowse", "-plist", image.path]
                let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
                do { try p.run() } catch { continue }
                let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                guard p.terminationStatus == 0,
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                      let entities = plist["system-entities"] as? [[String: Any]] else { continue }
                for entity in entities {
                    if let dev = entity["dev-entry"] as? String { self.mountedImageDevices.append(dev) }
                    if let mount = entity["mount-point"] as? String { mounts.append(URL(fileURLWithPath: mount, isDirectory: true)) }
                }
            }
            DispatchQueue.main.async {
                self.scanning = false
                if mounts.isEmpty { self.status.stringValue = "Image mounted no scannable filesystem — raw disc extraction will be needed" }
                else { self.stage(urls: mounts) }
            }
        }
    }

    private func readAudioCDTOC(_ mount: URL) -> (first: Int, offsets: [Int], leadout: Int)? {
        let tocURL = mount.appendingPathComponent(".TOC.plist")
        guard let data = try? Data(contentsOf: tocURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let sessions = plist["Sessions"] as? [[String: Any]], let session = sessions.first,
              let tracks = session["Track Array"] as? [[String: Any]],
              let leadout = session["Leadout Block"] as? Int else { return nil }
        let audio = tracks.compactMap { t -> (Int, Int)? in
            guard (t["Data"] as? Bool) != true, let point = t["Point"] as? Int, let start = t["Start Block"] as? Int else { return nil }
            return (point, start)
        }.sorted { $0.0 < $1.0 }
        guard let first = audio.first?.0, !audio.isEmpty else { return nil }
        return (first, audio.map { $0.1 }, leadout)
    }

    private func stageAudioCD(_ mount: URL) {
        guard !scanning, let toc = readAudioCDTOC(mount) else { status.stringValue = "Could not read Audio CD TOC"; return }
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { ["aiff", "aif"].contains($0.pathExtension.lowercased()) }
            .sorted { self.numericTrack($0) < self.numericTrack($1) }
        guard !files.isEmpty else { status.stringValue = "Audio CD mounted, but no audio tracks were exposed by macOS"; return }
        scanning = true; importButton.isEnabled = false; status.stringValue = "Reading Audio CD · \(files.count) tracks…"
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [ImportStageRow] = []
            for file in files {
                let n = self.numericTrack(file)
                var row = self.probe(file) ?? self.fallbackRow(file, status: "Unreadable CD track")
                row.artist = ""; row.album = "Audio CD"; row.title = "Track \(n)"
                row.disc = 1; row.track = n; row.status = "CD TOC lookup pending"
                found.append(row)
            }
            DispatchQueue.main.async {
                self.rows.removeAll { $0.url.deletingLastPathComponent().standardizedFileURL == mount.standardizedFileURL }
                self.rows.append(contentsOf: found); self.sortRows(); self.table.reloadData()
                self.scanning = false; self.updateStatus()
                self.lookupAudioCD(mount: mount, toc: toc)
            }
        }
    }

    private func numericTrack(_ url: URL) -> Int {
        let base = url.deletingPathExtension().lastPathComponent
        return Int(base.split(separator: " ").first ?? "") ?? 0
    }

    private func lookupAudioCD(mount: URL, toc: (first: Int, offsets: [Int], leadout: Int)) {
        status.stringValue = "Looking up Audio CD from frame-accurate TOC…"
        LookupService.searchDiscTOC(firstTrack: toc.first, offsets: toc.offsets, leadout: toc.leadout) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error): self.status.stringValue = "CD staged · TOC lookup failed: \(error.localizedDescription)"
                case .success(let releases):
                    let localLengths = (0..<toc.offsets.count).map { i -> Double in
                        let end = i + 1 < toc.offsets.count ? toc.offsets[i + 1] : toc.leadout
                        return Double(end - toc.offsets[i]) / 75.0
                    }
                    var matches: [(LookupRelease, LookupMedium, Double)] = []
                    for release in releases {
                        for medium in release.media where medium.tracks.count == localLengths.count {
                            let lengths = medium.tracks.map { Double($0.length ?? 0) / 1000.0 }
                            guard lengths.allSatisfy({ $0 > 0 }) else { continue }
                            let difference = zip(localLengths, lengths).reduce(0.0) { $0 + abs($1.0 - $1.1) }
                            matches.append((release, medium, difference))
                        }
                    }
                    matches.sort { $0.2 < $1.2 }
                    guard let best = matches.first else { self.status.stringValue = "CD staged · no usable TOC metadata match"; return }
                    let a = NSAlert(); a.messageText = "CD identified"
                    a.informativeText = "Best match: \(best.0.artist) — \(best.0.title)\n\(best.0.date) · \(best.0.country) · Disc \(best.1.position) · \(best.1.tracks.count) tracks\nTiming difference: \(String(format: "%.2f", best.2)) seconds across the whole disc.\n\n\(matches.count) candidate pressing(s) were found. Apply this metadata to the staged CD?"
                    a.addButton(withTitle: "OK — Use Metadata"); a.addButton(withTitle: "Cancel")
                    a.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow!) { response in
                        guard response == .alertFirstButtonReturn else { self.status.stringValue = "CD metadata lookup cancelled · staged audio unchanged"; return }
                        self.applyCDMetadata(mount: mount, release: best.0, medium: best.1, difference: best.2)
                    }
                }
            }
        }
    }

    private func applyCDMetadata(mount: URL, release: LookupRelease, medium: LookupMedium, difference: Double) {
        let byNumber = Dictionary(uniqueKeysWithValues: medium.tracks.map { ($0.position, $0.title) })
        for i in rows.indices where rows[i].url.deletingLastPathComponent().standardizedFileURL == mount.standardizedFileURL {
            rows[i].artist = release.artist; rows[i].album = release.title
            if let title = byNumber[rows[i].track] { rows[i].title = title }
            rows[i].disc = max(1, medium.position); rows[i].status = "CD metadata accepted · awaiting FLAC rip"
        }
        sortRows(); table.reloadData()
        convertAudioCDToFLAC(mount: mount, difference: difference)
    }


    private func cdRipDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ControlMac2026/CD Rips", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func safeCDFileName(_ text: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = text.components(separatedBy: bad).joined(separator: "-")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func audioDurationSeconds(_ url: URL) -> Double {
        let ffprobe = self.runtimeTool("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe.path) else { return 0 }
        let p = Process(); p.executableURL = ffprobe
        p.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", url.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return 0 }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return 0 }
        return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func convertAudioCDToFLAC(mount: URL, difference: Double) {
        guard !scanning, !operationBusy else { return }
        let sourceRows = rows.filter { $0.url.deletingLastPathComponent().standardizedFileURL == mount.standardizedFileURL }
            .sorted { $0.track < $1.track }
        guard !sourceRows.isEmpty else { status.stringValue = "CD metadata accepted, but no source tracks remain staged"; return }
        scanning = true; cancelRequested = false; localOperationKind = "cd"; mediaCancelMarker = nil; activeMediaProcess = nil
        setOperationState("Converting Audio CD to 16-bit / 44.1 kHz FLAC…", busy: true)
        importProgress.isHidden = false; importProgressLabel.isHidden = false; importProgress.doubleValue = 0
        trackProgress.isHidden = false; trackProgressLabel.isHidden = false; trackProgress.doubleValue = 0
        DispatchQueue.global(qos: .userInitiated).async {
            var workDir: URL?
            do {
                let outDir = try self.cdRipDirectory(); workDir = outDir
                var converted: [ImportStageRow] = []
                for (index, row) in sourceRows.enumerated() {
                    if self.cancelRequested { throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
                    let number = String(format: "%02d", row.track)
                    let name = self.safeCDFileName(row.title.isEmpty ? "Track \(row.track)" : row.title)
                    let output = outDir.appendingPathComponent("\(number) \(name).flac")
                    let duration = self.audioDurationSeconds(row.url)
                    DispatchQueue.main.async {
                        let overall = Double(index) / Double(sourceRows.count) * 100
                        self.importProgress.doubleValue = overall; self.trackProgress.doubleValue = 0
                        self.importProgressLabel.stringValue = String(format: "Overall CD rip · %d/%d · %.0f%%", index + 1, sourceRows.count, overall)
                        self.trackProgressLabel.stringValue = "Track \(index + 1)/\(sourceRows.count) · \(row.title) · 0% → FLAC"
                    }
                    let p = Process(); p.executableURL = self.runtimeTool("ffmpeg")
                    p.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", row.url.path,
                        "-map", "0:a:0", "-map_metadata", "-1", "-c:a", "flac", "-compression_level", "8",
                        "-sample_fmt", "s16", "-ar", "44100", "-ac", "2",
                        "-metadata", "artist=\(row.artist)", "-metadata", "album_artist=\(row.artist)",
                        "-metadata", "album=\(row.album)", "-metadata", "title=\(row.title)",
                        "-metadata", "track=\(row.track)", "-metadata", "disc=\(max(1, row.disc))",
                        "-progress", "pipe:1", "-nostats", output.path]
                    let err = Pipe(); let ffProgress = Pipe(); p.standardError = err; p.standardOutput = ffProgress
                    self.activeMediaProcess = p
                    try p.run()
                    var pendingProgress = ""
                    while true {
                        if self.cancelRequested && p.isRunning { p.terminate() }
                        let data = ffProgress.fileHandleForReading.availableData
                        if data.isEmpty { break }
                        pendingProgress += String(data: data, encoding: .utf8) ?? ""
                        while let newline = pendingProgress.firstIndex(of: "\n") {
                            let line = String(pendingProgress[..<newline]); pendingProgress.removeSubrange(...newline)
                            guard line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)), duration > 0 else { continue }
                            let trackFraction = min(1.0, max(0.0, us / (duration * 1_000_000.0)))
                            let overallFraction = (Double(index) + trackFraction) / Double(sourceRows.count)
                            DispatchQueue.main.async {
                                self.trackProgress.doubleValue = trackFraction * 100; self.importProgress.doubleValue = overallFraction * 100
                                self.trackProgressLabel.stringValue = String(format: "Track %d/%d · %@ · %.0f%% → FLAC", index + 1, sourceRows.count, row.title, trackFraction * 100)
                                self.importProgressLabel.stringValue = String(format: "Overall CD rip · %d/%d · %.0f%%", index + 1, sourceRows.count, overallFraction * 100)
                            }
                        }
                    }
                    p.waitUntilExit(); self.activeMediaProcess = nil
                    if self.cancelRequested { throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
                    if p.terminationStatus != 0 {
                        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        throw NSError(domain: "ControlMac.CDRip", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Track \(row.track) FLAC conversion failed. \(text)"])
                    }
                    guard var checked = self.probe(output), checked.codec.lowercased() == "flac", checked.rate == 44100, checked.bits == 16, checked.channels == 2 else {
                        throw NSError(domain: "ControlMac.CDRip", code: 2, userInfo: [NSLocalizedDescriptionKey: "Track \(row.track) did not verify as stereo 16-bit/44.1 kHz FLAC."])
                    }
                    checked.artist = row.artist; checked.album = row.album; checked.title = row.title; checked.disc = max(1, row.disc); checked.track = row.track
                    checked.status = "Ready · CD rip verified FLAC"; converted.append(checked)
                    DispatchQueue.main.async {
                        let overall = Double(index + 1) / Double(sourceRows.count) * 100
                        self.trackProgress.doubleValue = 100; self.importProgress.doubleValue = overall
                        self.trackProgressLabel.stringValue = "Track \(index + 1)/\(sourceRows.count) · \(row.title) · 100% · verified"
                        self.importProgressLabel.stringValue = String(format: "Overall CD rip · %d/%d · %.0f%%", index + 1, sourceRows.count, overall)
                    }
                }
                DispatchQueue.main.async {
                    self.rows.removeAll { $0.url.deletingLastPathComponent().standardizedFileURL == mount.standardizedFileURL }
                    self.rows.append(contentsOf: converted); self.sortRows(); self.table.reloadData()
                    self.scanning = false; self.localOperationKind = nil; self.activeMediaProcess = nil
                    self.importProgress.doubleValue = 100; self.trackProgress.doubleValue = 100
                    self.importProgressLabel.stringValue = "Overall CD rip · 100% · \(converted.count) tracks complete"
                    self.trackProgressLabel.stringValue = "All \(converted.count) tracks verified · 16-bit / 44.1 kHz FLAC"
                    self.operationBusy = false; self.cancelButton.isHidden = true; self.cancelButton.isEnabled = false
                    self.updateStatus(); self.status.stringValue = "CD ready to import · \(converted.count) FLAC tracks · \(String(format: "%.2f", difference)) sec TOC difference"
                }
            } catch {
                if let dir = workDir { try? FileManager.default.removeItem(at: dir) }
                DispatchQueue.main.async {
                    self.activeMediaProcess = nil; self.scanning = false; self.localOperationKind = nil; self.operationBusy = false
                    self.cancelButton.isHidden = true; self.cancelButton.isEnabled = false
                    self.importProgress.isHidden = true; self.importProgressLabel.isHidden = true
                    self.trackProgress.isHidden = true; self.trackProgressLabel.isHidden = true
                    self.updateStatus()
                    if (error as NSError).code == NSUserCancelledError { self.status.stringValue = "CD rip cancelled · temporary files removed" }
                    else {
                        self.status.stringValue = "CD FLAC conversion stopped safely"
                        let a = NSAlert(); a.alertStyle = .warning; a.messageText = "CD conversion failed"; a.informativeText = error.localizedDescription
                        if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) }
                    }
                }
            }
        }
    }

    private func scanMountedVolumes(preferOptical: Bool) {
        let roots = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey, .volumeIsRemovableKey], options: [.skipHiddenVolumes]) ?? []
        let removable = roots.filter {
            let values = try? $0.resourceValues(forKeys: [.volumeIsRemovableKey])
            return values?.volumeIsRemovable == true
        }
        if removable.isEmpty {
            status.stringValue = preferOptical ? "No mounted removable/optical media found" : "No removable media found"
            return
        }
        stage(urls: removable)
    }

    private func netMDCLIURL() -> URL? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let url = root.appendingPathComponent("netmd/node_modules/netmd-js/dist/cli.js")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func nodeURL() -> URL? {
        ControlMacRuntime.tool("node")
    }

    private func runtimeTool(_ name: String) -> URL {
        ControlMacRuntime.tool(name) ?? URL(fileURLWithPath: "/usr/bin/false")
    }

    private func runNetMDCLI(_ arguments: [String], timeout: TimeInterval = 6.0) -> String {
        guard let node = nodeURL(), let cli = netMDCLIURL() else { return "NetMD helper unavailable" }
        let p = Process(); p.executableURL = node; p.arguments = [cli.path] + arguments
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return error.localizedDescription }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning {
            p.terminate(); Thread.sleep(forTimeInterval: 0.25)
            if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) }
        }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func showMiniDiscInfo() {
        status.stringValue = "Reading MiniDisc device and disc…"
        DispatchQueue.global(qos: .userInitiated).async {
            let devices = self.runNetMDCLI(["devices"], timeout: 4)
            let disc = self.runNetMDCLI(["ls"], timeout: 6)
            DispatchQueue.main.async {
                let deviceLine = devices.split(separator: "\n").map(String.init).first { $0.contains("Found Device:") } ?? devices
                let titleLine = disc.split(separator: "\n").map(String.init).first { $0.hasPrefix("Title:") } ?? ""
                let discTitle = titleLine.replacingOccurrences(of: "Title:", with: "").trimmingCharacters(in: .whitespaces)
                let tracksLine = disc.split(separator: "\n").map(String.init).first { $0.hasSuffix(" tracks") } ?? ""
                self.stageMiniDisc(discText: disc, discTitle: discTitle)
                self.status.stringValue = [deviceLine.replacingOccurrences(of: "Found Device: ", with: "MiniDisc: "), titleLine, tracksLine, "staged for rip"].filter { !$0.isEmpty }.joined(separator: " · ")
                let a = NSAlert(); a.messageText = "MiniDisc staged"
                a.informativeText = "\(devices)\n\n\(disc)\n\nThe disc tracks are now in the staging table. They are marked Rip pending until the digital NetMD extraction step is enabled."
                a.addButton(withTitle: "OK")
                if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) } else { a.runModal() }
            }
        }
    }

    private func stageMiniDisc(discText: String, discTitle: String) {
        let guess = miniDiscMetadataGuess?(discTitle)
        let artist = guess?.artist ?? ""
        let album = guess?.album ?? (discTitle.isEmpty ? "MiniDisc" : discTitle)
        var staged: [ImportStageRow] = []
        for line in discText.split(separator: "\n").map(String.init) {
            guard line.count > 5, let colon = line.firstIndex(of: ":"),
                  let zeroIndex = Int(line[..<colon]) else { continue }
            let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let parts = rest.components(separatedBy: " - ")
            guard parts.count >= 2 else { continue }
            let mode = parts[1].lowercased()
            let rawTitle = parts.count >= 3 ? parts[2].components(separatedBy: "|").first?.trimmingCharacters(in: .whitespaces) ?? "" : ""
            let trackNo = zeroIndex + 1
            let title = rawTitle.isEmpty ? "Track \(trackNo)" : rawTitle
            let codec = mode.contains("lp4") ? "ATRAC LP4" : (mode.contains("lp2") ? "ATRAC LP2" : "ATRAC SP")
            let pseudo = URL(string: "minidisc://current/\(trackNo)")!
            let state = guess == nil ? "MiniDisc · Rip pending · Review metadata" : "MiniDisc · Rip pending"
            staged.append(ImportStageRow(url: pseudo, artist: artist, album: album, title: title, disc: 1, track: trackNo, codec: codec, rate: 44100, bits: 0, channels: 2, status: state))
        }
        rows.removeAll { $0.url.scheme?.lowercased() == "minidisc" }
        rows.append(contentsOf: staged)
        sortRows(); table.reloadData(); updateStatus()
        if let guess = guess, !staged.isEmpty { resolveMiniDiscMetadata(artist: guess.artist, album: guess.album, trackCount: staged.count) }
    }

    private func resolveMiniDiscMetadata(artist: String, album: String, trackCount: Int) {
        guard !artist.isEmpty, !album.isEmpty, trackCount > 0 else { return }
        LookupService.search(artist: artist, title: album) { result in
            guard case .success(let releases) = result else { return }
            let candidates = releases.filter { $0.media.reduce(0) { $0 + $1.tracks.count } == trackCount }
            let scored = candidates.sorted { a, b in
                func score(_ r: LookupRelease) -> Int {
                    var n = 0
                    if r.artist.caseInsensitiveCompare(artist) == .orderedSame { n += 20 }
                    if r.title.caseInsensitiveCompare(album) == .orderedSame { n += 30 }
                    return n
                }
                return score(a) > score(b)
            }
            guard let best = scored.first else { return }
            let tracks = best.media.sorted { $0.position < $1.position }.flatMap { $0.tracks.sorted { $0.position < $1.position } }
            guard tracks.count == trackCount else { return }
            DispatchQueue.main.async {
                for i in self.rows.indices where self.rows[i].url.scheme?.lowercased() == "minidisc" || self.rows[i].status.contains("MiniDisc rip") {
                    let pos = self.rows[i].track - 1
                    guard pos >= 0, pos < tracks.count else { continue }
                    self.rows[i].artist = best.artist.isEmpty ? artist : best.artist
                    self.rows[i].album = best.title
                    self.rows[i].title = tracks[pos].title
                    self.rows[i].status = self.rows[i].url.scheme?.lowercased() == "minidisc" ? "MiniDisc · Rip pending · metadata matched" : "Ready · MiniDisc rip verified FLAC"
                }
                self.sortRows(); self.table.reloadData(); self.updateStatus()
                self.status.stringValue = "MiniDisc metadata matched · \(best.artist) — \(best.title) · \(trackCount) tracks"
            }
        }
    }

    private func netMDRipHelperURL() -> URL? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let url = root.appendingPathComponent("netmd/controlmac-rip-track.cjs")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func miniDiscRipDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ControlMac2026/MiniDisc Rips", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func ripMiniDiscRows(_ sourceRows: [ImportStageRow]) {
        guard !scanning, !operationBusy, let node = nodeURL(), let helper = netMDRipHelperURL() else { status.stringValue = "MiniDisc rip helper unavailable"; return }
        scanning = true; cancelRequested = false; localOperationKind = "minidisc"; activeMediaProcess = nil
        setOperationState("Digitally ripping MiniDisc…", busy: true)
        importProgress.isHidden = false; importProgressLabel.isHidden = false; importProgress.doubleValue = 0
        trackProgress.isHidden = false; trackProgressLabel.isHidden = false; trackProgress.doubleValue = 0
        DispatchQueue.global(qos: .userInitiated).async {
            var workDir: URL?
            do {
                let outDir = try self.miniDiscRipDirectory(); workDir = outDir
                let cancelMarker = outDir.appendingPathComponent(".cancel-request")
                self.mediaCancelMarker = cancelMarker
                var converted: [ImportStageRow] = []
                for (index, row) in sourceRows.enumerated() {
                    if self.cancelRequested { throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
                    let number = String(format: "%02d", row.track)
                    let base = outDir.appendingPathComponent("\(number) \(self.safeCDFileName(row.title))")
                    DispatchQueue.main.async {
                        let overall = Double(index) / Double(sourceRows.count) * 100
                        self.importProgress.doubleValue = overall; self.trackProgress.doubleValue = 0
                        self.importProgressLabel.stringValue = String(format: "Overall MiniDisc rip · %d/%d · %.0f%%", index + 1, sourceRows.count, overall)
                        self.trackProgressLabel.stringValue = "Track \(index + 1)/\(sourceRows.count) · \(row.title) · 0% · reading ATRAC"
                    }
                    let p = Process(); p.executableURL = node
                    p.arguments = [helper.path, "\(max(0, row.track - 1))", base.path, cancelMarker.path]
                    let out = Pipe(); let err = Pipe(); p.standardOutput = out; p.standardError = err
                    self.activeMediaProcess = p
                    try p.run(); var pending = ""; var rawPath: String?
                    while true {
                        let data = out.fileHandleForReading.availableData; if data.isEmpty { break }
                        pending += String(data: data, encoding: .utf8) ?? ""
                        while let nl = pending.firstIndex(of: "\n") {
                            let line = String(pending[..<nl]); pending.removeSubrange(...nl)
                            let parts = line.components(separatedBy: "\t")
                            if parts.count >= 5, parts[0] == "CMMDPROGRESS", let pct = Double(parts[4]) {
                                let f = min(1.0, max(0.0, pct / 100.0)); let overall = (Double(index) + f) / Double(sourceRows.count)
                                DispatchQueue.main.async {
                                    self.trackProgress.doubleValue = f * 100; self.importProgress.doubleValue = overall * 100
                                    self.trackProgressLabel.stringValue = String(format: "Track %d/%d · %@ · %.0f%% · reading ATRAC", index + 1, sourceRows.count, row.title, f * 100)
                                    self.importProgressLabel.stringValue = String(format: "Overall MiniDisc rip · %d/%d · %.0f%%", index + 1, sourceRows.count, overall * 100)
                                }
                            } else if parts.count >= 2, parts[0] == "CMMDDONE" { rawPath = parts[1] }
                        }
                    }
                    p.waitUntilExit(); self.activeMediaProcess = nil
                    let errorText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    if self.cancelRequested || FileManager.default.fileExists(atPath: cancelMarker.path) || errorText.contains("CMMD_CANCELLED") {
                        throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                    }
                    if p.terminationStatus != 0 || rawPath == nil {
                        throw NSError(domain: "ControlMac.MiniDiscRip", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "MiniDisc track \(row.track) recovery failed. \(errorText)"])
                    }
                    let raw = URL(fileURLWithPath: rawPath!); let flac = outDir.appendingPathComponent("\(number) \(self.safeCDFileName(row.title)).flac")
                    DispatchQueue.main.async { self.trackProgressLabel.stringValue = "Track \(index + 1)/\(sourceRows.count) · \(row.title) · decoding ATRAC → FLAC" }
                    if self.cancelRequested { throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
                    let ff = Process(); ff.executableURL = self.runtimeTool("ffmpeg")
                    ff.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", raw.path, "-map", "0:a:0", "-map_metadata", "-1", "-c:a", "flac", "-compression_level", "8", "-sample_fmt", "s16", "-ar", "44100", "-ac", "2", "-metadata", "artist=\(row.artist)", "-metadata", "album_artist=\(row.artist)", "-metadata", "album=\(row.album)", "-metadata", "title=\(row.title)", "-metadata", "track=\(row.track)", "-metadata", "disc=1", flac.path]
                    let ffErr = Pipe(); ff.standardError = ffErr; self.activeMediaProcess = ff; try ff.run(); ff.waitUntilExit(); self.activeMediaProcess = nil
                    if self.cancelRequested { throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
                    if ff.terminationStatus != 0 { let text = String(data: ffErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; throw NSError(domain: "ControlMac.MiniDiscRip", code: Int(ff.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "MiniDisc track \(row.track) FLAC conversion failed. \(text)"]) }
                    guard var checked = self.probe(flac), checked.codec.lowercased() == "flac", checked.rate == 44100, checked.bits == 16, checked.channels == 2 else { throw NSError(domain: "ControlMac.MiniDiscRip", code: 2, userInfo: [NSLocalizedDescriptionKey: "MiniDisc track \(row.track) did not verify as stereo 16-bit/44.1 kHz FLAC."]) }
                    checked.artist = row.artist; checked.album = row.album; checked.title = row.title; checked.disc = 1; checked.track = row.track
                    let needsReview = row.artist.isEmpty || row.title.hasPrefix("Track ") || row.status.localizedCaseInsensitiveContains("review")
                    checked.status = needsReview ? "Ready · MiniDisc rip verified FLAC · Review metadata" : "Ready · MiniDisc rip verified FLAC"
                    converted.append(checked)
                    DispatchQueue.main.async {
                        let overall = Double(index + 1) / Double(sourceRows.count) * 100
                        self.trackProgress.doubleValue = 100; self.importProgress.doubleValue = overall
                        self.trackProgressLabel.stringValue = "Track \(index + 1)/\(sourceRows.count) · \(row.title) · 100% · FLAC verified"
                        self.importProgressLabel.stringValue = String(format: "Overall MiniDisc rip · %d/%d · %.0f%%", index + 1, sourceRows.count, overall)
                    }
                }
                try? FileManager.default.removeItem(at: cancelMarker)
                DispatchQueue.main.async {
                    let nums = Set(sourceRows.map { $0.track })
                    self.rows.removeAll { $0.url.scheme?.lowercased() == "minidisc" && nums.contains($0.track) }
                    self.rows.append(contentsOf: converted); self.sortRows(); self.table.reloadData()
                    self.scanning = false; self.localOperationKind = nil; self.activeMediaProcess = nil; self.mediaCancelMarker = nil
                    self.operationBusy = false; self.cancelButton.isHidden = true; self.cancelButton.isEnabled = false
                    self.importProgress.doubleValue = 100; self.trackProgress.doubleValue = 100
                    self.updateStatus(); self.status.stringValue = "MiniDisc rip complete · \(converted.count) verified FLAC track(s)"
                }
            } catch {
                if let dir = workDir { try? FileManager.default.removeItem(at: dir) }
                DispatchQueue.main.async {
                    self.activeMediaProcess = nil; self.mediaCancelMarker = nil; self.scanning = false; self.localOperationKind = nil; self.operationBusy = false
                    self.cancelButton.isHidden = true; self.cancelButton.isEnabled = false
                    self.importProgress.isHidden = true; self.importProgressLabel.isHidden = true
                    self.trackProgress.isHidden = true; self.trackProgressLabel.isHidden = true
                    self.updateStatus()
                    if (error as NSError).code == NSUserCancelledError { self.status.stringValue = "MiniDisc rip cancelled safely · temporary files removed" }
                    else {
                        self.status.stringValue = "MiniDisc rip stopped safely"
                        let a = NSAlert(); a.alertStyle = .warning; a.messageText = "MiniDisc rip failed"; a.informativeText = error.localizedDescription
                        if let parent = NSApp.keyWindow ?? NSApp.mainWindow { a.beginSheetModal(for: parent) }
                    }
                }
            }
        }
    }

    private func scanUSBForMiniDisc() {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPUSBDataType", "-json"]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            do { try p.run() } catch { return }
            let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            let needles = ["minidisc", "netmd", "hi-md", "sony"]
            let found = needles.contains { text.lowercased().contains($0) }
            DispatchQueue.main.async {
                self.status.stringValue = found
                    ? "MiniDisc-class USB device detected · transfer backend can now be selected"
                    : "No MiniDisc / NetMD / Hi-MD USB device detected"
            }
        }
    }

    private func detachImages() {
        let devices = mountedImageDevices
        mountedImageDevices.removeAll()
        DispatchQueue.global(qos: .utility).async {
            for dev in devices {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                p.arguments = ["detach", dev]
                try? p.run(); p.waitUntilExit()
            }
        }
    }

    deinit { detachImages() }
}
