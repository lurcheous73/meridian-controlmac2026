import AppKit
import Foundation
import UniformTypeIdentifiers

private let testAlbumID = "1:1:13457d6e-df81-402b-9412-1d372dfba5b7"

struct AlbumRow {
    let id: String
    let artistID: String
    var artist: String
    var title: String
    let mediaNumber: Int
    let mediaCount: Int
    var coverURL: String
    let hasRealCover: Bool
    let quality: String
    let releaseDate: String
    let trackCount: Int
}

struct TrackRow {
    let id: String
    let number: Int
    var title: String
    let artist: String
    let length: Int
    let fileSize: Int64
    let fileType: String
    let sampleRate: Int?
    let bits: Int?
    let channels: Int?
    let bitrate: Int?
}

final class ControlMacApp: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var window: NSWindow!
    var settingsController: SettingsController?
    let coreField = NSTextField(string: "")
    let searchField = NSSearchField(string: "")
    let statusLabel = NSTextField(labelWithString: "Ready")
    let countLabel = NSTextField(labelWithString: "0 albums")
    let duplicateToggle = NSButton(checkboxWithTitle: "Possible duplicates", target: nil, action: nil)
    let albumTable = NSTableView()
    let trackTable = NSTableView()
    let coverView = NSImageView()
    let artistField = NSTextField(string: "")
    let albumField = NSTextField(string: "")
    let trackField = NSTextField(string: "")
    let saveAlbumButton = NSButton(title: "Save Album Title", target: nil, action: nil)
    let coverButton = NSButton(title: "Replace Local Art…", target: nil, action: nil)
    let lookupCoverButton = NSButton(title: "Lookup Artwork Online…", target: nil, action: nil)
    let revalidateButton = NSButton(title: "Revalidate Album", target: nil, action: nil)
    let trackLookupButton = NSButton(title: "Track Lookup", target: nil, action: nil)
    let saveTrackButton = NSButton(title: "Rename Track", target: nil, action: nil)
    let deleteAlbumButton = NSButton(title: "Delete Album…", target: nil, action: nil)
    let importButton = NSButton(title: "Import Music…", target: nil, action: nil)
    let pageSelector = NSSegmentedControl(labels: ["Library", "Import / Export"], trackingMode: .selectOne, target: nil, action: nil)
    let progress = NSProgressIndicator()
    let zonePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let previousButton = NSButton(title: "◀︎◀︎", target: nil, action: nil)
    let playPauseButton = NSButton(title: "▶︎", target: nil, action: nil)
    let nextButton = NSButton(title: "▶︎▶︎", target: nil, action: nil)
    let muteButton = NSButton(title: "Mute", target: nil, action: nil)
    let volumeDownButton = NSButton(title: "−1", target: nil, action: nil)
    let volumeValueLabel = NSTextField(labelWithString: "Vol --")
    let volumeUpButton = NSButton(title: "+1", target: nil, action: nil)
    let nowPlayingLabel = NSTextField(labelWithString: "Playback unavailable")
    let queueButton = NSButton(title: "Queue", target: nil, action: nil)
    let playAlbumButton = NSButton(title: "Play Album", target: nil, action: nil)
    let queueAlbumButton = NSButton(title: "Queue Album", target: nil, action: nil)
    let playTrackButton = NSButton(title: "Play Track", target: nil, action: nil)
    let queueTrackButton = NSButton(title: "Queue Track", target: nil, action: nil)

    var albums: [AlbumRow] = []
    var visibleAlbums: [AlbumRow] = []
    var tracks: [TrackRow] = []
    var tracksByAlbum: [String: [TrackRow]] = [:]
    var duplicateIDs = Set<String>()
    var cacheIsFresh = false
    var selectedAlbumID: String?
    var selectedTrackID: String?
    var activeProcess: Process?
    var activeImportProcess: Process?
    var activeImportCancelURL: URL?
    var lookupGridController: ArtworkGridController?
    var revalidationCompareController: RevalidationCompareController?
    var playbackZones: [PlaybackZoneRow] = []
    var playbackQueue: [PlaybackQueueRow] = []
    var selectedZoneID: String?
    var activePlaybackProcess: Process?
    var playbackQueueController: PlaybackQueueController?
    var playbackRefreshTimer: Timer?
    var libraryPageView: NSView?
    var importExportController: ImportExportController?
    var host: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        coreField.stringValue = UserDefaults.standard.string(forKey: "core") ?? ""
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        connect()
        playbackRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in self?.refreshPlayback() }
    }
    func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About ControlMac 2026", action: #selector(showAbout), keyEquivalent: "")
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit ControlMac 2026", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
        for (name, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
                                    ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: name, action: action, keyEquivalent: key)
        }
        editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @objc func showSettings() {
        if settingsController == nil { settingsController = SettingsController() }
        settingsController?.showWindow(nil)
        settingsController?.window?.center()
        settingsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showAbout() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let a = NSAlert()
        a.messageText = "ControlMac 2026"
        a.informativeText = "Version \(version) (build \(build))\n\nNative Meridian Sooloos library control, import/export, disc management and playback.\n\nAlbum deletion uses a fresh Core re-read and guarded confirmation."
        a.runModal()
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ControlMac 2026"
        window.minSize = NSSize(width: 1050, height: 680)
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        let titleIcon = NSImageView(image: NSImage(systemSymbolName: "music.note.list", accessibilityDescription: nil) ?? NSImage())
        titleIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        let title = NSTextField(labelWithString: "ControlMac 2026")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        coreField.placeholderString = "Sooloos Core address"
        coreField.target = self; coreField.action = #selector(connect)
        let connectButton = NSButton(title: "Connect", target: self, action: #selector(connect))
        let refreshButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!, target: self, action: #selector(refreshLibrary))
        refreshButton.bezelStyle = .texturedRounded
        pageSelector.selectedSegment = 0
        pageSelector.target = self; pageSelector.action = #selector(pageChanged)
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        let toolbar = NSStackView(views: [titleIcon, title, pageSelector, coreField, connectButton, refreshButton, progress])
        toolbar.orientation = .horizontal; toolbar.spacing = 10; toolbar.alignment = .centerY
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            coreField.widthAnchor.constraint(equalToConstant: 190),
            statusLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 5),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16)
        ])
        let zoneLabel = NSTextField(labelWithString: "Playback Unit")
        zoneLabel.textColor = .secondaryLabelColor
        zonePopup.target = self; zonePopup.action = #selector(playbackZoneChanged)
        previousButton.target = self; previousButton.action = #selector(playbackPrevious)
        playPauseButton.target = self; playPauseButton.action = #selector(playbackPlayPause)
        nextButton.target = self; nextButton.action = #selector(playbackNext)
        muteButton.target = self; muteButton.action = #selector(playbackMute)
        volumeDownButton.target = self; volumeDownButton.action = #selector(playbackVolumeDownOne)
        volumeValueLabel.textColor = .secondaryLabelColor
        volumeValueLabel.alignment = .center
        volumeValueLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        volumeUpButton.target = self; volumeUpButton.action = #selector(playbackVolumeUpOne)
        queueButton.target = self; queueButton.action = #selector(showPlaybackQueue)
        nowPlayingLabel.textColor = .secondaryLabelColor; nowPlayingLabel.lineBreakMode = .byTruncatingMiddle
        let playbackBar = NSStackView(views: [zoneLabel, zonePopup, previousButton, playPauseButton, nextButton, muteButton, volumeDownButton, volumeValueLabel, volumeUpButton, nowPlayingLabel, queueButton])
        playbackBar.orientation = .horizontal; playbackBar.spacing = 8; playbackBar.alignment = .centerY
        playbackBar.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(playbackBar)
        zonePopup.widthAnchor.constraint(equalToConstant: 230).isActive = true
        nowPlayingLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        NSLayoutConstraint.activate([
            playbackBar.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            playbackBar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            playbackBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6)
        ])
        searchField.placeholderString = "Search artist or album"
        searchField.delegate = self
        duplicateToggle.target = self; duplicateToggle.action = #selector(filterChanged)
        duplicateToggle.toolTip = "Show only exact artist/title groups that do not look like a normal multi-disc set"
        countLabel.textColor = .secondaryLabelColor
        let filterBar = NSStackView(views: [searchField, duplicateToggle, countLabel])
        filterBar.orientation = .vertical; filterBar.spacing = 7; filterBar.alignment = .leading
        searchField.widthAnchor.constraint(equalToConstant: 380).isActive = true

        albumTable.headerView = NSTableHeaderView()
        albumTable.rowHeight = 36
        albumTable.usesAlternatingRowBackgroundColors = true
        albumTable.allowsMultipleSelection = false
        albumTable.delegate = self; albumTable.dataSource = self
        let artistCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("artist")); artistCol.title = "Artist"; artistCol.width = 150
        let albumCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("album")); albumCol.title = "Album"; albumCol.width = 200
        let qualityCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("quality")); qualityCol.title = "Quality"; qualityCol.width = 70
        albumTable.addTableColumn(artistCol); albumTable.addTableColumn(albumCol); albumTable.addTableColumn(qualityCol)
        let albumScroll = NSScrollView(); albumScroll.documentView = albumTable; albumScroll.hasVerticalScroller = true
        albumScroll.autohidesScrollers = true; albumScroll.borderType = .bezelBorder

        let left = NSView()
        for v in [filterBar, albumScroll] { v.translatesAutoresizingMaskIntoConstraints = false; left.addSubview(v) }
        NSLayoutConstraint.activate([
            filterBar.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 12),
            filterBar.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -12),
            filterBar.topAnchor.constraint(equalTo: left.topAnchor, constant: 12),
            albumScroll.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 10),
            albumScroll.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 8),
            albumScroll.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -8),
            albumScroll.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: -8)
        ])
        coverView.imageScaling = .scaleProportionallyUpOrDown
        coverView.wantsLayer = true; coverView.layer?.cornerRadius = 8; coverView.layer?.masksToBounds = true
        coverView.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
        coverView.widthAnchor.constraint(equalToConstant: 220).isActive = true
        coverView.heightAnchor.constraint(equalToConstant: 220).isActive = true
        artistField.placeholderString = "Artist"
        artistField.isEditable = false; artistField.isBezeled = false; artistField.drawsBackground = false
        artistField.font = .systemFont(ofSize: 18, weight: .medium)
        albumField.placeholderString = "Album title"
        albumField.font = .systemFont(ofSize: 24, weight: .semibold)
        saveAlbumButton.target = self; saveAlbumButton.action = #selector(saveAlbumTitle)
        coverButton.target = self; coverButton.action = #selector(replaceCover)
        lookupCoverButton.target = self; lookupCoverButton.action = #selector(replaceCoverLookup)
        revalidateButton.target = self; revalidateButton.action = #selector(revalidateAlbum)
        trackLookupButton.target = self; trackLookupButton.action = #selector(revalidateByTracks)
        deleteAlbumButton.target = self; deleteAlbumButton.action = #selector(deleteAlbum)
        deleteAlbumButton.isEnabled = false
        playAlbumButton.target = self; playAlbumButton.action = #selector(playbackPlayAlbum)
        queueAlbumButton.target = self; queueAlbumButton.action = #selector(playbackQueueAlbum)
        let editButtons = NSStackView(views: [saveAlbumButton, coverButton, lookupCoverButton, revalidateButton, trackLookupButton, deleteAlbumButton])
        editButtons.orientation = .horizontal; editButtons.spacing = 8
        let albumPlaybackButtons = NSStackView(views: [playAlbumButton, queueAlbumButton])
        albumPlaybackButtons.orientation = .horizontal; albumPlaybackButtons.spacing = 8
        let meta = NSStackView(views: [artistField, albumField, editButtons, albumPlaybackButtons])
        meta.orientation = .vertical; meta.spacing = 10; meta.alignment = .leading
        albumField.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        let header = NSStackView(views: [coverView, meta]); header.orientation = .horizontal; header.spacing = 20; header.alignment = .top

        trackTable.headerView = NSTableHeaderView(); trackTable.rowHeight = 30
        trackTable.usesAlternatingRowBackgroundColors = true
        trackTable.delegate = self; trackTable.dataSource = self
        let ncol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("trackNo")); ncol.title = "#"; ncol.width = 42
        let tcol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("trackTitle")); tcol.title = "Track"; tcol.width = 360
        let fcol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("format")); fcol.title = "Format"; fcol.width = 120
        let rcol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rate")); rcol.title = "Audio"; rcol.width = 150
        trackTable.addTableColumn(ncol); trackTable.addTableColumn(tcol); trackTable.addTableColumn(fcol); trackTable.addTableColumn(rcol)
        let trackScroll = NSScrollView(); trackScroll.documentView = trackTable; trackScroll.hasVerticalScroller = true
        trackScroll.autohidesScrollers = true; trackScroll.borderType = .bezelBorder
        trackField.placeholderString = "Selected track title"
        trackField.isEnabled = false
        saveTrackButton.target = self; saveTrackButton.action = #selector(saveTrackTitle); saveTrackButton.isEnabled = false
        playTrackButton.target = self; playTrackButton.action = #selector(playbackPlayTrack)
        queueTrackButton.target = self; queueTrackButton.action = #selector(playbackQueueTrack)
        let trackEdit = NSStackView(views: [trackField, saveTrackButton, playTrackButton, queueTrackButton]); trackEdit.orientation = .horizontal; trackEdit.spacing = 8
        trackField.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        let trackLabel = NSTextField(labelWithString: "Tracks")
        trackLabel.font = .systemFont(ofSize: 16, weight: .semibold)

        let right = NSView()
        for v in [header, trackLabel, trackScroll, trackEdit] { v.translatesAutoresizingMaskIntoConstraints = false; right.addSubview(v) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(lessThanOrEqualTo: right.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: right.topAnchor, constant: 20),
            trackLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            trackLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            trackScroll.topAnchor.constraint(equalTo: trackLabel.bottomAnchor, constant: 8),
            trackScroll.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 20),
            trackScroll.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -20),
            trackEdit.topAnchor.constraint(equalTo: trackScroll.bottomAnchor, constant: 8),
            trackEdit.leadingAnchor.constraint(equalTo: trackScroll.leadingAnchor),
            trackEdit.trailingAnchor.constraint(lessThanOrEqualTo: trackScroll.trailingAnchor),
            trackEdit.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -16)
        ])

        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(left); split.addArrangedSubview(right)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: playbackBar.bottomAnchor, constant: 8),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 410),
            left.widthAnchor.constraint(lessThanOrEqualToConstant: 520)
        ])
        libraryPageView = split
        let io = ImportExportController()
        importExportController = io
        io.coreHost = { [weak self] in self?.host }
        io.importHandler = { [weak self] rows in self?.importStagedRows(rows) }
        io.cancelImportHandler = { [weak self] in self?.cancelActiveImport() }
        io.exportAlbumChoices = { [weak self] in
            guard let self = self else { return [] }
            return self.albums.map { album in
                ExportAlbumChoice(id: album.id, artist: album.artist, album: album.title,
                                  tracks: album.trackCount, disc: album.mediaNumber, discs: album.mediaCount,
                                  releaseDate: album.releaseDate)
            }
        }
        io.miniDiscMetadataGuess = { [weak self] discTitle in
            guard let self = self else { return nil }
            let source = self.normalized(discTitle)
            let matches = self.albums.compactMap { album -> (AlbumRow, Int)? in
                let artist = self.normalized(album.artist), title = self.normalized(album.title)
                guard !artist.isEmpty, !title.isEmpty else { return nil }
                let combined = self.normalized(album.artist + " " + album.title)
                guard source == combined || (source.contains(artist) && source.contains(title)) else { return nil }
                return (album, artist.count + title.count)
            }.sorted { $0.1 > $1.1 }
            if let best = matches.first?.0 { return (artist: best.artist, album: best.title) }
            let artists = Array(Set(self.albums.map { $0.artist }.filter { !$0.isEmpty })).sorted { $0.count > $1.count }
            if let artist = artists.first(where: { source.hasPrefix(self.normalized($0) + " ") }) {
                let remainder = String(discTitle.dropFirst(min(artist.count, discTitle.count))).trimmingCharacters(in: .whitespacesAndNewlines)
                if !remainder.isEmpty { return (artist: artist, album: remainder.capitalized) }
            }
            return nil
        }
        io.view.translatesAutoresizingMaskIntoConstraints = false
        io.view.isHidden = true
        content.addSubview(io.view)
        NSLayoutConstraint.activate([
            io.view.topAnchor.constraint(equalTo: playbackBar.bottomAnchor, constant: 8),
            io.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            io.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            io.view.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        setEditorEnabled(false)
        setPlaybackEnabled(false)
    }


    @objc func pageChanged() {
        let showImport = pageSelector.selectedSegment == 1
        libraryPageView?.isHidden = showImport
        importExportController?.view.isHidden = !showImport
        if showImport { importExportController?.reloadExportAlbums() }
        statusLabel.stringValue = showImport ? "Import / Export staging" : (cacheIsFresh ? "Core library ready" : "Library")
    }

    func setEditorEnabled(_ enabled: Bool) {
        albumField.isEnabled = enabled
        saveAlbumButton.isEnabled = enabled
        coverButton.isEnabled = enabled
        lookupCoverButton.isEnabled = enabled
        revalidateButton.isEnabled = enabled
        trackLookupButton.isEnabled = enabled
        lookupCoverButton.isEnabled = enabled
        revalidateButton.isEnabled = enabled
        if !enabled {
            artistField.stringValue = ""
            albumField.stringValue = ""
            tracks = []; trackTable.reloadData()
            trackField.stringValue = ""; trackField.isEnabled = false; saveTrackButton.isEnabled = false
            deleteAlbumButton.isEnabled = false
            coverView.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
        }
    }

    func alert(_ title: String, _ detail: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = detail
        a.beginSheetModal(for: window)
    }

    func decode(_ value: String) -> String {
        guard let data = Data(base64Encoded: value), let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
    func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ControlMac2026", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    func snapshotURL() -> URL {
        let safe = (host ?? "default").replacingOccurrences(of: ":", with: "_")
        return cacheDirectory().appendingPathComponent("library-\(safe).tsv")
    }
    func artworkURL(for albumID: String) -> URL {
        let dir = cacheDirectory().appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = albumID.split(separator: ":").last.map(String.init) ?? albumID.replacingOccurrences(of: ":", with: "_")
        return dir.appendingPathComponent(name + ".img")
    }
    func saveSnapshot(_ text: String) {
        let kept = text.split(separator: "\n").filter {
            $0.hasPrefix("CMSCAN\t") || $0.hasPrefix("CMCACHEALBUM\t") || $0.hasPrefix("CMCACHETRACK\t")
        }.joined(separator: "\n") + "\n"
        try? kept.write(to: snapshotURL(), atomically: true, encoding: .utf8)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "cacheDate-" + (host ?? "default"))
    }

    func backendConfig() -> (mono: String, managed: String)? {
        ControlMacRuntime.backendConfig()
    }

    func runLibrary(_ arguments: [String], busyText: String, completion: @escaping (Int32, String) -> Void) {
        guard activeProcess == nil else { completion(1, "CMERROR\tBackend is already busy."); return }
        guard let cfg = backendConfig() else { completion(1, "CMERROR\tBackend.plist could not be read."); return }
        guard let host = host else { completion(1, "CMERROR\tCore host is not set."); return }
        guard let exe = Bundle.main.url(forResource: "LibraryTool", withExtension: "exe") else {
            completion(1, "CMERROR\tLibraryTool.exe is missing from the app bundle."); return
        }
        let p = Process(); p.executableURL = URL(fileURLWithPath: cfg.mono + "/bin/mono-sgen64")
        var managedArgs: [String] = []
        if let command = arguments.first { managedArgs.append(command); managedArgs.append(host); managedArgs.append(contentsOf: arguments.dropFirst()) }
        p.arguments = ControlMacRuntime.monoArguments(executable: exe, arguments: managedArgs, monoRoot: cfg.mono)
        var env = ProcessInfo.processInfo.environment
        ControlMacRuntime.configureMonoEnvironment(&env, monoRoot: cfg.mono, managed: cfg.managed); p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        activeProcess = p; statusLabel.stringValue = busyText; progress.startAnimation(nil)
        do { try p.run() } catch { activeProcess = nil; progress.stopAnimation(nil); completion(1, error.localizedDescription); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.activeProcess = nil; self.progress.stopAnimation(nil)
                completion(p.terminationStatus, text)
            }
        }
    }
    func parseSnapshot(_ text: String, fresh: Bool) {
        var found: [AlbumRow] = []
        var byAlbum: [String: [TrackRow]] = [:]
        for line in text.split(separator: "\n") {
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if line.hasPrefix("CMCACHEALBUM\t"), p.count >= 14 {
                found.append(AlbumRow(id: p[1], artistID: p[2], artist: decode(p[3]), title: decode(p[4]),
                    mediaNumber: Int(p[5]) ?? 0, mediaCount: Int(p[6]) ?? 0, coverURL: decode(p[7]),
                    hasRealCover: p[8].lowercased() == "true", quality: p[9], releaseDate: decode(p[12]), trackCount: Int(p[13]) ?? 0))
            } else if line.hasPrefix("CMCACHETRACK\t"), p.count >= 13 {
                let albumID = p[1]
                byAlbum[albumID, default: []].append(TrackRow(id: p[2], number: Int(p[3]) ?? 0, title: decode(p[4]), artist: decode(p[5]),
                    length: Int(p[6]) ?? 0, fileSize: Int64(p[7]) ?? 0, fileType: p[8], sampleRate: Int(p[9]), bits: Int(p[10]),
                    channels: Int(p[11]), bitrate: Int(p[12])))
            }
        }
        for key in byAlbum.keys { byAlbum[key]?.sort { $0.number < $1.number } }
        albums = found; tracksByAlbum = byAlbum; cacheIsFresh = fresh
        computeDuplicateCandidates(); applyFilters()
    }
    func loadCachedSnapshot() {
        guard let text = try? String(contentsOf: snapshotURL(), encoding: .utf8), text.contains("CMCACHEALBUM\t") else { return }
        parseSnapshot(text, fresh: false)
        statusLabel.stringValue = "Showing cached library snapshot · refreshing Core before changes are enabled"
    }

    @objc func connect() {
        let raw = coreField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = raw.contains("://") ? raw : "http://" + raw
        guard let parts = URLComponents(string: candidate), let h = parts.host, !h.isEmpty else {
            statusLabel.stringValue = "Enter a valid Sooloos Core hostname or IP address"; return
        }
        host = h
        ControlMacConfiguration.sooloosAddress = raw
        statusLabel.stringValue = "Connecting to Sooloos Core…"
        loadCachedSnapshot()
        refreshPlayback()
        refreshLibrary()
    }

    @objc func refreshLibrary() {
        guard host != nil else { connect(); return }
        cacheIsFresh = false; setEditorEnabled(false); importButton.isEnabled = false
        runLibrary(["scan"], busyText: "Scanning and caching the complete Sooloos library…") { code, text in
            self.importButton.isEnabled = true
            guard code == 0 else {
                self.statusLabel.stringValue = self.albums.isEmpty ? "Could not read library" : "Core refresh failed · cached snapshot remains read-only"
                if self.albums.isEmpty { self.alert("Library unavailable", self.backendError(text)) }
                return
            }
            self.saveSnapshot(text); self.parseSnapshot(text, fresh: true)
            self.statusLabel.stringValue = "Core cached · \(self.albums.count) albums · \(self.tracksByAlbum.values.reduce(0) { $0 + $1.count }) tracks · \(self.duplicateIDs.count) entries need duplicate review"
            self.warmArtworkCache()
        }
    }

    func backendError(_ text: String) -> String {
        if let line = text.split(separator: "\n").last(where: { $0.hasPrefix("CMERROR\t") }) {
            return String(line.dropFirst("CMERROR\t".count))
        }
        return String(text.suffix(1600))
    }
    func normalized(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        return folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined().split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }

    func computeDuplicateCandidates() {
        duplicateIDs.removeAll()
        let groups = Dictionary(grouping: albums) { normalized($0.artist) + "\u{1f}" + normalized($0.title) }
        for group in groups.values where group.count > 1 {
            let counts = Set(group.map { $0.mediaCount })
            let media = Set(group.map { $0.mediaNumber })
            let oneCount = counts.count == 1 ? counts.first! : 0
            let cleanMultiDisc = oneCount > 1 && media.count == group.count &&
                group.allSatisfy { $0.mediaNumber >= 1 && $0.mediaNumber <= oneCount }
            if !cleanMultiDisc { group.forEach { duplicateIDs.insert($0.id) } }
        }
    }

    @objc func filterChanged() { applyFilters() }
    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === searchField { applyFilters() }
    }

    func applyFilters() {
        let q = normalized(searchField.stringValue)
        visibleAlbums = albums.filter { a in
            let matches = q.isEmpty || normalized(a.artist).contains(q) || normalized(a.title).contains(q)
            return matches && (duplicateToggle.state != .on || duplicateIDs.contains(a.id))
        }.sorted {
            let l = normalized($0.artist) + "\u{1f}" + normalized($0.title)
            let r = normalized($1.artist) + "\u{1f}" + normalized($1.title)
            return l == r ? $0.mediaNumber < $1.mediaNumber : l < r
        }
        countLabel.stringValue = duplicateToggle.state == .on ? "\(visibleAlbums.count) candidate entries" : "\(visibleAlbums.count) albums"
        albumTable.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === albumTable ? visibleAlbums.count : tracks.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail; cell.maximumNumberOfLines = 1
        if tableView === albumTable {
            guard row < visibleAlbums.count else { return cell }
            let a = visibleAlbums[row]
            switch tableColumn?.identifier.rawValue {
            case "artist": cell.stringValue = a.artist
            case "album":
                cell.stringValue = a.mediaCount > 1 ? "Disk \(a.mediaNumber)/\(a.mediaCount) — \(a.title)" : a.title
                if duplicateIDs.contains(a.id) { cell.toolTip = "Possible duplicate — review only; nothing is auto-deleted" }
            case "quality": cell.stringValue = a.quality
            default: break
            }
        } else {
            guard row < tracks.count else { return cell }
            let t = tracks[row]
            switch tableColumn?.identifier.rawValue {
            case "trackNo": cell.stringValue = "\(t.number)"
            case "trackTitle": cell.stringValue = t.title
            case "format": cell.stringValue = t.fileType
            case "rate":
                let rate = t.sampleRate.map { "\($0 / 1000).\(($0 % 1000) / 100) kHz" } ?? "? kHz"
                let bits = t.bits.map { "\($0)-bit" } ?? ""
                cell.stringValue = bits + (bits.isEmpty ? "" : " / ") + rate
            default: break
            }
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === albumTable { loadSelectedAlbum() }
        else if table === trackTable { selectTrack() }
    }
    func loadSelectedAlbum() {
        let row = albumTable.selectedRow
        guard row >= 0, row < visibleAlbums.count else { selectedAlbumID = nil; setEditorEnabled(false); updatePlaybackSelectionButtons(); return }
        let summary = visibleAlbums[row]
        selectedAlbumID = summary.id; selectedTrackID = nil
        artistField.stringValue = summary.artist; albumField.stringValue = summary.title
        let editable = cacheIsFresh
        albumField.isEnabled = editable; saveAlbumButton.isEnabled = editable; coverButton.isEnabled = editable
        lookupCoverButton.isEnabled = editable; revalidateButton.isEnabled = editable; trackLookupButton.isEnabled = editable
        lookupCoverButton.isEnabled = editable; revalidateButton.isEnabled = editable
        deleteAlbumButton.isEnabled = editable
        tracks = tracksByAlbum[summary.id] ?? []; trackTable.reloadData()
        trackField.stringValue = ""; trackField.isEnabled = false; saveTrackButton.isEnabled = false
        loadCover(summary.coverURL, albumID: summary.id)
        let dup = duplicateIDs.contains(summary.id) ? " · possible duplicate candidate" : ""
        let cacheNote = editable ? "" : " · cached snapshot (read-only until Core refresh)"
        statusLabel.stringValue = "\(summary.artist) — \(summary.title) · \(tracks.count) tracks\(dup)\(cacheNote)"
        updatePlaybackSelectionButtons()
    }

    func loadCover(_ value: String, albumID: String) {
        let cached = artworkURL(for: albumID)
        if let image = NSImage(contentsOf: cached) { coverView.image = image; return }
        guard let url = URL(string: value), !value.isEmpty else {
            coverView.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil); return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let image = NSImage(data: data) else { return }
            try? data.write(to: cached, options: .atomic)
            DispatchQueue.main.async { if self.selectedAlbumID == albumID { self.coverView.image = image } }
        }.resume()
    }
    func warmArtworkCache() {
        let snapshot = albums
        DispatchQueue.global(qos: .utility).async {
            for album in snapshot {
                let target = self.artworkURL(for: album.id)
                if FileManager.default.fileExists(atPath: target.path) { continue }
                guard let url = URL(string: album.coverURL), !album.coverURL.isEmpty,
                      let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { continue }
                try? data.write(to: target, options: .atomic)
            }
        }
    }

    func selectTrack() {
        let row = trackTable.selectedRow
        guard row >= 0, row < tracks.count else {
            selectedTrackID = nil; trackField.stringValue = ""; trackField.isEnabled = false; saveTrackButton.isEnabled = false; updatePlaybackSelectionButtons(); return
        }
        let t = tracks[row]
        selectedTrackID = t.id; trackField.stringValue = t.title
        trackField.isEnabled = true; saveTrackButton.isEnabled = true
        updatePlaybackSelectionButtons()
    }

    @objc func saveAlbumTitle() {
        guard let id = selectedAlbumID else { return }
        let title = albumField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { alert("Album title required", "Enter a title before saving."); return }
        runLibrary(["rename-album", id, title], busyText: "Saving album title…") { code, text in
            guard code == 0 else { self.alert("Album title was not changed", self.backendError(text)); return }
            if let i = self.albums.firstIndex(where: { $0.id == id }) { self.albums[i].title = title }
            self.computeDuplicateCandidates(); self.applyFilters()
            self.statusLabel.stringValue = "Saved album title: \(title)"
        }
    }
    @objc func saveTrackTitle() {
        guard let id = selectedTrackID else { return }
        let title = trackField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { alert("Track title required", "Enter a title before saving."); return }
        runLibrary(["rename-track", id, title], busyText: "Saving track title…") { code, text in
            guard code == 0 else { self.alert("Track title was not changed", self.backendError(text)); return }
            if let i = self.tracks.firstIndex(where: { $0.id == id }) { self.tracks[i].title = title }
            self.trackTable.reloadData(); self.statusLabel.stringValue = "Saved track title: \(title)"
        }
    }

    func selectedSummary() -> AlbumRow? {
        guard let id = selectedAlbumID else { return nil }
        return albums.first(where: { $0.id == id })
    }
    func lookupScore(_ r: LookupRelease, for a: AlbumRow) -> Int {
        var score = normalized(r.title) == normalized(a.title) ? 50 : 0
        if r.media.count == max(1, a.mediaCount) { score += 30 }
        let disc = r.media.first(where: { $0.position == max(1, a.mediaNumber) })
        if let disc = disc, disc.trackCount == a.trackCount { score += 40 }
        if a.mediaCount <= 1, r.media.count == 1, r.media.first?.trackCount == a.trackCount { score += 20 }
        return score
    }
    func showArtworkGrid(title: String, subtitle: String, artist: String, album: String,
                         candidates: [ArtworkLookupCandidate],
                         onSearch: @escaping (String, String) -> Void,
                         onPick: @escaping (ArtworkLookupCandidate) -> Void) {
        let controller = ArtworkGridController(title: title, subtitle: subtitle, artist: artist, album: album,
                                               candidates: candidates, onSearch: onSearch, onPick: onPick)
        lookupGridController = controller
        window.beginSheet(controller.window) { _ in
            if self.lookupGridController === controller { self.lookupGridController = nil }
        }
    }

    func remoteArtworkSearch(artist: String, title: String) {
        statusLabel.stringValue = "Searching remote artwork: \(artist) — \(title)…"
        progress.startAnimation(nil)
        LookupService.artworkCandidates(artist: artist, title: title) { result in
            DispatchQueue.main.async {
                self.progress.stopAnimation(nil)
                switch result {
                case .failure(let error): self.alert("Remote lookup failed", error.localizedDescription)
                case .success(let found):
                    let ranked = found.sorted {
                        if $0.source != $1.source { return $0.source == "TheAudioDB" }
                        if self.normalized($0.title) != self.normalized($1.title) {
                            return self.normalized($0.title) == self.normalized(title)
                        }
                        return $0.year > $1.year
                    }
                    guard !ranked.isEmpty else {
                        self.alert("No remote matches", "Try correcting the Artist or Album search terms.")
                        return
                    }
                    self.showArtworkGrid(title: "Remote album artwork",
                        subtitle: "\(ranked.count) candidates · click an album to preview its cover",
                        artist: artist, album: title, candidates: ranked,
                        onSearch: { a, t in self.remoteArtworkSearch(artist: a, title: t) },
                        onPick: { c in self.previewRemoteArtwork(c, searchArtist: artist, searchTitle: title, candidates: ranked) })
                }
            }
        }
    }

    func downloadArtworkCandidate(_ candidate: ArtworkLookupCandidate, completion: @escaping (Result<(Data, NSImage), Error>) -> Void) {
        func fetch(_ url: URL) {
            guard url.scheme?.lowercased() == "https" else {
                completion(.failure(NSError(domain: "ControlMacLookup", code: 30, userInfo: [NSLocalizedDescriptionKey: "Artwork provider returned a non-secure URL."]))); return
            }
            var req = URLRequest(url: url, timeoutInterval: 30)
            req.setValue(LookupService.userAgent, forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, _, error in
                if let error = error { completion(.failure(error)); return }
                guard let data = data, let image = NSImage(data: data) else {
                    completion(.failure(NSError(domain: "ControlMacLookup", code: 31, userInfo: [NSLocalizedDescriptionKey: "The artwork image could not be decoded."]))); return
                }
                completion(.success((data, image)))
            }.resume()
        }
        if let direct = candidate.fullURL { fetch(direct); return }
        if let mbid = candidate.musicBrainzReleaseID {
            LookupService.frontCoverURL(releaseID: mbid) { result in
                switch result { case .success(let url): fetch(url); case .failure(let e): completion(.failure(e)) }
            }
            return
        }
        completion(.failure(NSError(domain: "ControlMacLookup", code: 32, userInfo: [NSLocalizedDescriptionKey: "This candidate has no usable artwork URL."])))
    }

    func previewRemoteArtwork(_ candidate: ArtworkLookupCandidate, searchArtist: String, searchTitle: String,
                              candidates: [ArtworkLookupCandidate]) {
        statusLabel.stringValue = "Loading \(candidate.source) artwork…"; progress.startAnimation(nil)
        downloadArtworkCandidate(candidate) { result in
            DispatchQueue.main.async {
                self.progress.stopAnimation(nil)
                switch result {
                case .failure(let error): self.alert("Artwork unavailable", error.localizedDescription)
                case .success(let pair):
                    let (data, image) = pair
                    let preview = NSImageView(frame: NSRect(x: 0, y: 0, width: 420, height: 420))
                    preview.image = image; preview.imageScaling = .scaleProportionallyUpOrDown
                    let a = NSAlert(); a.messageText = "Use this cover?"
                    a.informativeText = "\(candidate.source) · \(candidate.artist) — \(candidate.title)\n\(candidate.detail)\n\nNothing changes until you confirm."
                    a.accessoryView = preview; a.addButton(withTitle: "Use This Cover"); a.addButton(withTitle: "Back to Results"); a.addButton(withTitle: "Cancel")
                    a.beginSheetModal(for: self.window) { response in
                        if response == .alertFirstButtonReturn {
                            guard let id = self.selectedAlbumID else { return }
                            let tmp = self.cacheDirectory().appendingPathComponent("lookup-cover-" + UUID().uuidString + ".image")
                            do { try data.write(to: tmp, options: .atomic) } catch { self.alert("Artwork could not be staged", error.localizedDescription); return }
                            self.runLibrary(["cover", id, tmp.path], busyText: "Saving remote artwork…") { code, text in
                                try? FileManager.default.removeItem(at: tmp)
                                guard code == 0 else { self.alert("Artwork was not changed", self.backendError(text)); return }
                                try? data.write(to: self.artworkURL(for: id), options: .atomic)
                                self.coverView.image = image; self.statusLabel.stringValue = "Artwork applied from \(candidate.source)"
                            }
                        } else if response == .alertSecondButtonReturn {
                            self.showArtworkGrid(title: "Remote album artwork", subtitle: "Click an album to preview its cover",
                                artist: searchArtist, album: searchTitle, candidates: candidates,
                                onSearch: { ar, al in self.remoteArtworkSearch(artist: ar, title: al) },
                                onPick: { c in self.previewRemoteArtwork(c, searchArtist: searchArtist, searchTitle: searchTitle, candidates: candidates) })
                        }
                    }
                }
            }
        }
    }

    @objc func replaceCoverLookup() {
        guard cacheIsFresh, let album = selectedSummary() else { alert("Refresh required", "Refresh the Core before changing artwork."); return }
        remoteArtworkSearch(artist: album.artist, title: album.title)
    }

    func looksLikePathMetadata(_ value: String) -> Bool {
        let v = value.lowercased()
        return v.contains("\\users\\") || v.contains("/users/") || v.contains("\\downloads\\") || v.contains("/downloads/") || v.hasPrefix("c:\\")
    }

    func audioFingerprint(_ albumID: String) -> [(Int, Int64)] {
        return (tracksByAlbum[albumID] ?? []).sorted { $0.number < $1.number }.map { ($0.length, $0.fileSize) }
    }

    func fingerprintsEqual(_ a: [(Int, Int64)], _ b: [(Int, Int64)]) -> Bool {
        guard !a.isEmpty, a.count == b.count else { return false }
        return zip(a, b).allSatisfy { $0.0.0 == $0.1.0 && $0.0.1 == $0.1.1 }
    }

    func relatedLocalAlbums(current: AlbumRow, externalTitle: String) -> [AlbumRow] {
        let artist = normalized(current.artist)
        let ext = normalized(externalTitle)
        let cur = normalized(current.title)
        return albums.filter { a in
            guard normalized(a.artist) == artist else { return false }
            let t = normalized(a.title)
            return a.id == current.id || (!ext.isEmpty && (t == ext || t.contains(ext))) || (!cur.isEmpty && t == cur)
        }
    }

    func externalTrackMap(_ release: LookupRelease) -> [String: (disc: Int, track: Int, title: String)] {
        var map: [String: (Int, Int, String)] = [:]
        for medium in release.media {
            for track in medium.tracks {
                let key = normalized(track.title)
                if !key.isEmpty { map[key] = (medium.position, track.position, track.title) }
            }
        }
        return map
    }

    func trackStyleKey(_ value: String, artist: String) -> String {
        var words = normalized(LookupService.cleanedTrackTitle(value, artist: artist)).split(separator: " ").map(String.init)
        words = words.map { token in
            switch token {
            case "pt": return "part"
            case "vol": return "volume"
            case "no": return "number"
            default: return token
            }
        }
        return words.joined(separator: " ")
    }

    func presentRevalidationReport(current: AlbumRow, full: LookupRelease, source: String) {
        let local = (tracksByAlbum[current.id] ?? []).sorted { $0.number < $1.number }
        let remote = full.media.flatMap { medium in
            medium.tracks.sorted { $0.position < $1.position }.map { (disc: medium.position, track: $0.position, title: $0.title, length: $0.length) }
        }
        var used = Set<String>()
        var rows: [RevalidationCompareRow] = []
        var trackChanges: [(id: String, from: String, to: String)] = []
        var exactMatches = 0

        func key(_ r: (disc: Int, track: Int, title: String, length: Int?)) -> String { "\(r.disc):\(r.track)" }
        func cleaned(_ value: String) -> String { normalized(LookupService.cleanedTrackTitle(value, artist: current.artist)) }

        for lt in local {
            let lname = cleaned(lt.title)
            var candidates = remote.filter { !used.contains(key($0)) && cleaned($0.title) == lname && !lname.isEmpty }
            var status = ""
            var chosen: (disc: Int, track: Int, title: String, length: Int?)?
            if !candidates.isEmpty {
                candidates.sort {
                    let l = ($0.disc == max(1, current.mediaNumber) ? 20 : 0) + ($0.track == lt.number ? 10 : 0)
                    let r = ($1.disc == max(1, current.mediaNumber) ? 20 : 0) + ($1.track == lt.number ? 10 : 0)
                    return l > r
                }
                chosen = candidates[0]; exactMatches += 1
                status = chosen!.disc == max(1, current.mediaNumber) && chosen!.track == lt.number ? "Exact" : "Track match · different position"
            } else {
                let timed = remote.filter { r in
                    guard !used.contains(key(r)), let ms = r.length else { return false }
                    return abs(Int(ms / 1000) - lt.length) <= 2
                }
                if timed.count == 1 { chosen = timed[0]; status = "Likely match · duration" }
                else if let positional = remote.first(where: { !used.contains(key($0)) && $0.disc == max(1, current.mediaNumber) && $0.track == lt.number }) {
                    chosen = positional; status = "Different title"
                } else { status = "Extra / not found in lookup" }
            }
            if let r = chosen {
                used.insert(key(r))
                rows.append(RevalidationCompareRow(localNumber: "\(lt.number)", localTitle: lt.title,
                    remoteDisc: "\(r.disc)/\(full.media.count)", remoteNumber: "\(r.track)", remoteTitle: r.title, status: status))
                let confident = status == "Exact" || status == "Track match · different position" ||
                    (status == "Likely match · duration" && r.track == lt.number) || status == "Different title"
                if confident && trackStyleKey(lt.title, artist: current.artist) != trackStyleKey(r.title, artist: current.artist) {
                    trackChanges.append((lt.id, lt.title, r.title))
                }
            } else {
                rows.append(RevalidationCompareRow(localNumber: "\(lt.number)", localTitle: lt.title,
                    remoteDisc: "", remoteNumber: "", remoteTitle: "", status: status))
            }
        }
        for r in remote where !used.contains(key(r)) {
            rows.append(RevalidationCompareRow(localNumber: "", localTitle: "",
                remoteDisc: "\(r.disc)/\(full.media.count)", remoteNumber: "\(r.track)", remoteTitle: r.title, status: "Missing locally"))
        }

        var warnings: [String] = []
        if looksLikePathMetadata(current.title) || local.contains(where: { $0.title.lowercased().hasSuffix(".flac") || $0.title.lowercased().hasSuffix(".mp3") || $0.title.lowercased().hasSuffix(".wav") }) {
            warnings.append("SHADOW IMPORT metadata detected")
        }
        let mappedDiscs = Set(rows.compactMap { Int($0.remoteDisc.split(separator: "/").first ?? "") })
        if mappedDiscs.count > 1 { warnings.append("SCRAMBLED DISC: local tracks map across discs " + mappedDiscs.sorted().map(String.init).joined(separator: ", ")) }
        let related = relatedLocalAlbums(current: current, externalTitle: full.title)
        for other in related where other.id != current.id {
            if fingerprintsEqual(audioFingerprint(current.id), audioFingerprint(other.id)) {
                warnings.append("LIKELY DUPLICATE AUDIO with ‘\(other.title)’")
            }
        }

        var subtitle = "\(source)\nSooloos: \(current.artist) — \(current.title.isEmpty ? "(blank title)" : current.title) · \(local.count) tracks\nOffered: \(full.displayName) · \(exactMatches)/\(local.count) exact title matches"
        if !warnings.isEmpty { subtitle += "\n⚠ " + warnings.joined(separator: "  ·  ") }
        subtitle += "\nProposed metadata changes: album title + \(trackChanges.count) meaningful track title\(trackChanges.count == 1 ? "" : "s")."
        subtitle += "\nREVIEW ONLY — nothing has been changed until you press OK."

        let controller = RevalidationCompareController(title: "Album revalidation", subtitle: subtitle, rows: rows) { [weak self] in
            guard let self = self else { return }
            let validatedTitle = full.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !validatedTitle.isEmpty else { self.alert("Lookup title is blank", "Nothing was changed."); return }
            self.applyValidatedMetadata(current: current, albumTitle: validatedTitle, trackChanges: trackChanges)
        }
        revalidationCompareController = controller
        window.beginSheet(controller.window) { _ in
            if self.revalidationCompareController === controller { self.revalidationCompareController = nil }
        }
        statusLabel.stringValue = "Revalidation comparison ready · no changes made"
    }

    func applyValidatedMetadata(current: AlbumRow, albumTitle: String, trackChanges: [(id: String, from: String, to: String)]) {
        var operations: [[String]] = []
        if current.title != albumTitle { operations.append(["rename-album", current.id, albumTitle]) }
        for change in trackChanges { operations.append(["rename-track", change.id, change.to]) }
        guard !operations.isEmpty else {
            statusLabel.stringValue = "Validation confirmed · metadata already matches"
            return
        }
        func runNext(_ index: Int) {
            if index >= operations.count {
                self.statusLabel.stringValue = "Validated metadata applied · refreshing Core…"
                self.refreshLibrary(); return
            }
            let op = operations[index]
            let label = op[0] == "rename-album" ? "Applying validated album name…" : "Applying validated track titles…"
            self.runLibrary(op, busyText: label) { code, text in
                guard code == 0 else {
                    self.alert("Validated metadata stopped safely", self.backendError(text)); return
                }
                runNext(index + 1)
            }
        }
        runNext(0)
    }

    func revalidationEvidence(_ release: LookupRelease, current: AlbumRow) -> (score: Int, exact: Int) {
        let local = (tracksByAlbum[current.id] ?? []).sorted { $0.number < $1.number }
        let remote = release.media.flatMap { medium in
            medium.tracks.map { (disc: medium.position, track: $0.position, title: $0.title, length: $0.length) }
        }
        var used = Set<String>(), score = 0, exact = 0
        func key(_ d: Int, _ t: Int) -> String { "\(d):\(t)" }
        for lt in local {
            let lname = normalized(LookupService.cleanedTrackTitle(lt.title, artist: current.artist))
            let hits = remote.filter { !used.contains(key($0.disc, $0.track)) && normalized(LookupService.cleanedTrackTitle($0.title, artist: current.artist)) == lname && !lname.isEmpty }
            if let best = hits.sorted(by: {
                (($0.disc == max(1,current.mediaNumber) ? 10 : 0) + ($0.track == lt.number ? 5 : 0)) >
                (($1.disc == max(1,current.mediaNumber) ? 10 : 0) + ($1.track == lt.number ? 5 : 0))
            }).first {
                used.insert(key(best.disc, best.track)); exact += 1; score += 100
                if best.disc == max(1, current.mediaNumber) { score += 15 }
                if best.track == lt.number { score += 10 }
                if let ms = best.length, abs(Int(ms / 1000) - lt.length) <= 2 { score += 8 }
            }
        }
        if exact == local.count && !local.isEmpty { score += 500 }
        score -= max(0, local.count - exact) * 20
        if release.media.count == max(1, current.mediaCount) { score += 25 }
        if normalized(release.title) == normalized(current.title) && !normalized(current.title).isEmpty { score += 15 }
        return (score, exact)
    }

    func revalidationArtworkCandidate(_ release: LookupRelease, artist: String, source: String, best: Bool, matches: Int, total: Int) -> ArtworkLookupCandidate {
        let formats = Array(Set(release.media.map { $0.format }.filter { !$0.isEmpty })).sorted().joined(separator: "/")
        let year = release.date.isEmpty ? "" : String(release.date.prefix(4))
        let lead = best ? "BEST MATCH · \(matches)/\(total) tracks" : "\(matches)/\(total) tracks"
        let detail = [lead, source, year, release.country, formats,
                      release.media.isEmpty ? "" : "\(release.media.count) disc\(release.media.count == 1 ? "" : "s")"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return ArtworkLookupCandidate(source: "MusicBrainz", sourceID: release.id, artist: artist, title: release.title,
            year: year, country: release.country, format: formats, detail: detail,
            thumbURL: URL(string: "https://coverartarchive.org/release/\(release.id)/front-250"),
            fullURL: nil, musicBrainzReleaseID: release.id)
    }

    func showRevalidationGrid(current: AlbumRow, releases: [LookupRelease], searchArtist: String, searchTitle: String, source: String) {
        let localCount = (tracksByAlbum[current.id] ?? []).count
        let ranked = releases.sorted { revalidationEvidence($0, current: current).score > revalidationEvidence($1, current: current).score }
        let shown = Array(ranked.prefix(16))
        guard !shown.isEmpty else { alert("No revalidation candidates", "No candidate release survived the track comparison. Try changing the search terms."); return }
        let cards = shown.enumerated().map { index, release -> ArtworkLookupCandidate in
            let evidence = revalidationEvidence(release, current: current)
            return revalidationArtworkCandidate(release, artist: searchArtist, source: source, best: index == 0, matches: evidence.exact, total: localCount)
        }
        showArtworkGrid(title: "Revalidate album", subtitle: "Best track-list match is first and preselected. Click another release if needed, then OK or Cancel.",
            artist: searchArtist, album: searchTitle, candidates: cards,
            onSearch: { a, t in self.revalidateRemoteSearch(current: current, artist: a, title: t) },
            onPick: { card in
                guard let release = shown.first(where: { $0.id == card.sourceID }) else { return }
                self.statusLabel.stringValue = "Reading selected release track listing…"; self.progress.startAnimation(nil)
                LookupService.details(releaseID: release.id) { result in
                    DispatchQueue.main.async {
                        self.progress.stopAnimation(nil)
                        switch result {
                        case .failure(let error): self.alert("Revalidation failed", error.localizedDescription)
                        case .success(let full): self.presentRevalidationReport(current: current, full: full, source: source)
                        }
                    }
                }
            })
    }

    func revalidateRemoteSearch(current: AlbumRow, artist: String, title: String) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alert("Album title is blank", "Use Track Lookup/Revalidate to identify the album from its tracks, or type a title into the search grid."); return
        }
        statusLabel.stringValue = "Searching album metadata: \(artist) — \(title)…"; progress.startAnimation(nil)
        LookupService.search(artist: artist, title: title) { result in
            DispatchQueue.main.async {
                self.progress.stopAnimation(nil)
                switch result {
                case .success(let releases) where !releases.isEmpty:
                    self.showRevalidationGrid(current: current, releases: releases, searchArtist: artist, searchTitle: title, source: "Manual album-title lookup")
                case .failure(let error): self.alert("Album lookup failed", error.localizedDescription)
                default: self.alert("No album-title matches", "No release matched those manual search terms. Revalidate will still identify from tracks.")
                }
            }
        }
    }

    func revalidateTrackFingerprint(current: AlbumRow, artist: String, title: String, useArtist: Bool) {
        let local = tracksByAlbum[current.id] ?? []
        guard !local.isEmpty else { alert("No tracks cached", "This album has no cached track titles to identify it from."); return }
        statusLabel.stringValue = useArtist ? "Identifying release from tracks + artist…" : "Retrying from tracks without trusting artist…"
        progress.startAnimation(nil)
        LookupService.searchByTracks(artist: artist, tracks: local.map { $0.title }, useArtistConstraint: useArtist) { result in
            DispatchQueue.main.async {
                self.progress.stopAnimation(nil)
                switch result {
                case .success(let releases) where !releases.isEmpty:
                    let source = useArtist ? "Track fingerprint + artist" : "Track fingerprint (artist ignored)"
                    self.showRevalidationGrid(current: current, releases: releases, searchArtist: artist, searchTitle: title, source: source)
                case .failure(let error):
                    if useArtist {
                        self.revalidateTrackFingerprint(current: current, artist: artist, title: title, useArtist: false)
                    } else if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.statusLabel.stringValue = "Track fingerprint inconclusive · trying album title…"
                        self.revalidateRemoteSearch(current: current, artist: artist, title: title)
                    } else {
                        self.alert("No confident release found", "Track fingerprinting failed even without trusting the artist.\n\n\(error.localizedDescription)\n\nUse the manual search fields to supply a likely artist/title.")
                    }
                default:
                    if useArtist { self.revalidateTrackFingerprint(current: current, artist: artist, title: title, useArtist: false) }
                    else if !title.isEmpty { self.revalidateRemoteSearch(current: current, artist: artist, title: title) }
                    else { self.alert("No confident release found", "No release could be identified from the cached tracks.") }
                }
            }
        }
    }

    @objc func revalidateAlbum() {
        guard cacheIsFresh, let current = selectedSummary() else { alert("Refresh required", "Refresh the Core before revalidating an album."); return }
        revalidateTrackFingerprint(current: current, artist: current.artist, title: current.title, useArtist: true)
    }

    @objc func revalidateByTracks() {
        guard cacheIsFresh, let current = selectedSummary() else { alert("Refresh required", "Refresh the Core before using track lookup."); return }
        revalidateTrackFingerprint(current: current, artist: current.artist, title: current.title, useArtist: true)
    }

    @objc func replaceCover() {
        guard let id = selectedAlbumID else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.jpeg, .png]
        panel.message = "Choose JPEG or PNG artwork for this album."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let file = panel.url else { return }
            self.runLibrary(["cover", id, file.path], busyText: "Replacing album artwork…") { code, text in
                guard code == 0 else { self.alert("Artwork was not changed", self.backendError(text)); return }
                self.coverView.image = NSImage(contentsOf: file)
                self.statusLabel.stringValue = "Album artwork replaced"
            }
        }
    }

    @objc func deleteAlbum() {
        guard cacheIsFresh, let current = selectedSummary() else {
            alert("Refresh required", "Refresh the Core before deleting an album."); return
        }
        let displayTitle = current.title.isEmpty ? "(blank album title)" : current.title
        let a = NSAlert(); a.alertStyle = .warning
        a.messageText = "Delete this album from Sooloos?"
        a.informativeText = "Artist: \(current.artist)\nAlbum: \(displayTitle)\nTracks: \(current.trackCount)\nDisc: \(current.mediaNumber)/\(current.mediaCount)\n\nThis removes the selected album from the Core. The backend will re-read and verify it before deletion."
        a.addButton(withTitle: "Delete Album"); a.addButton(withTitle: "Cancel")
        if #available(macOS 11.0, *) { a.buttons.first?.hasDestructiveAction = true }
        a.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                self.statusLabel.stringValue = "Delete cancelled · no changes made"; return
            }
            self.runLibrary(["delete-album", current.id, current.artist, current.title, "\(current.trackCount)", "\(current.mediaNumber)", "\(current.mediaCount)"], busyText: "Verifying and deleting selected album…") { code, text in
                guard code == 0 else { self.alert("Album was not deleted", self.backendError(text)); return }
                self.selectedAlbumID = nil; self.setEditorEnabled(false)
                self.statusLabel.stringValue = "Album deleted · refreshing Core…"
                self.refreshLibrary()
            }
        }
    }

    @objc func importMusic() {
        guard activeProcess == nil, let host = host, let cfg = backendConfig(),
              let exe = Bundle.main.url(forResource: "ImportOne", withExtension: "exe") else {
            alert("Importer unavailable", "Connect to the Core first."); return
        }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "flac")!]
        panel.message = "Current verified path: one FLAC test track. Full album and multi-format import is being enabled in this build."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let file = panel.url else { return }
            let p = Process(); p.executableURL = URL(fileURLWithPath: cfg.mono + "/bin/mono-sgen64")
            p.arguments = ControlMacRuntime.monoArguments(executable: exe, arguments: ["--import", host, file.path], monoRoot: cfg.mono)
            var env = ProcessInfo.processInfo.environment
            ControlMacRuntime.configureMonoEnvironment(&env, monoRoot: cfg.mono, managed: cfg.managed); p.environment = env
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            self.activeProcess = p; self.importButton.isEnabled = false; self.progress.startAnimation(nil)
            self.statusLabel.stringValue = "Importing and verifying \(file.lastPathComponent)…"
            do { try p.run() } catch { self.activeProcess = nil; self.importButton.isEnabled = true; self.progress.stopAnimation(nil); self.alert("Import could not start", error.localizedDescription); return }
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    self.activeProcess = nil; self.importButton.isEnabled = true; self.progress.stopAnimation(nil)
                    if p.terminationStatus == 0 && text.contains("CORE CONFIRMED IMPORT COMPLETE") {
                        self.statusLabel.stringValue = "Import complete and verified"; self.refreshLibrary()
                    } else { self.statusLabel.stringValue = "Import stopped safely"; self.alert("Import did not complete", self.backendError(text)) }
                }
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if activeProcess != nil || activeImportProcess?.isRunning == true || importExportController?.hasActiveOperation() == true {
            alert("ControlMac is busy", "Cancel the active rip/import/export first, then quit after it has stopped safely.")
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        playbackRefreshTimer?.invalidate()
        importExportController?.cleanupTemporaryFiles()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ControlMacMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = ControlMacApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
