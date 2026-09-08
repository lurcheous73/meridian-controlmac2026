import AppKit
import Foundation

struct PlaybackZoneRow {
    let id: String
    let name: String
    let state: String
    let volume: Int
    let volumeMin: Int
    let volumeMax: Int
    let muted: Bool
    let queueCount: Int
    let queueIndex: Int
    let media: String
    let subtitle: String
}

struct PlaybackQueueRow {
    let zoneID: String
    let index: Int
    let played: Bool
    let title: String
    let subtitle: String
}

final class PlaybackQueueController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    private let table = NSTableView()
    private var rows: [PlaybackQueueRow]
    private var currentIndex: Int
    init(rows: [PlaybackQueueRow], currentIndex: Int) {
        self.rows = rows
        self.currentIndex = currentIndex
        self.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Play Queue"
        window.minSize = NSSize(width: 620, height: 420)
        window.isReleasedWhenClosed = false
        table.headerView = NSTableHeaderView()
        table.rowHeight = 30
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self; table.dataSource = self
        let state = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("state")); state.title = ""; state.width = 36
        let no = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("index")); no.title = "#"; no.width = 52
        let title = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title")); title.title = "Track"; title.width = 300
        let sub = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("subtitle")); sub.title = "Album / Artist"; sub.width = 390
        table.addTableColumn(state); table.addTableColumn(no); table.addTableColumn(title); table.addTableColumn(sub)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(scroll)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
        selectCurrent()
    }
    func update(rows: [PlaybackQueueRow], currentIndex: Int) {
        self.rows = rows; self.currentIndex = currentIndex
        table.reloadData(); selectCurrent()
    }

    private func selectCurrent() {
        guard currentIndex >= 0, currentIndex < rows.count else { return }
        table.selectRowIndexes(IndexSet(integer: currentIndex), byExtendingSelection: false)
        table.scrollRowToVisible(currentIndex)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let r = rows[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "state": value = row == currentIndex ? "▶︎" : (r.played ? "✓" : "")
        case "index": value = "\(r.index + 1)"
        case "title": value = r.title
        case "subtitle": value = r.subtitle
        default: value = ""
        }
        let cell = NSTextField(labelWithString: value)
        cell.lineBreakMode = .byTruncatingTail; cell.toolTip = value
        return cell
    }
}

extension ControlMacApp {
    func setPlaybackEnabled(_ enabled: Bool) {
        zonePopup.isEnabled = enabled
        previousButton.isEnabled = enabled
        playPauseButton.isEnabled = enabled
        nextButton.isEnabled = enabled
        muteButton.isEnabled = enabled
        volumeDownButton.isEnabled = enabled
        volumeUpButton.isEnabled = enabled
        queueButton.isEnabled = enabled
        if !enabled {
            nowPlayingLabel.stringValue = "Playback unavailable"
            queueButton.title = "Queue"
        }
        updatePlaybackSelectionButtons()
    }

    func updatePlaybackSelectionButtons() {
        let ready = selectedZoneID != nil && !playbackZones.isEmpty
        playAlbumButton.isEnabled = ready && selectedAlbumID != nil
        queueAlbumButton.isEnabled = ready && selectedAlbumID != nil
        playTrackButton.isEnabled = ready && selectedTrackID != nil
        queueTrackButton.isEnabled = ready && selectedTrackID != nil
    }

    func currentPlaybackZone() -> PlaybackZoneRow? {
        guard let id = selectedZoneID else { return nil }
        return playbackZones.first(where: { $0.id == id })
    }
    func runPlayback(_ arguments: [String], completion: @escaping (Int32, String) -> Void) {
        guard activePlaybackProcess == nil else { completion(1, "CMERROR\tPlayback backend is busy."); return }
        guard let cfg = backendConfig(), let host = host else { completion(1, "CMERROR\tPlayback backend is unavailable."); return }
        guard let exe = Bundle.main.url(forResource: "PlaybackTool", withExtension: "exe") else {
            completion(1, "CMERROR\tPlaybackTool.exe is missing from the app bundle."); return
        }
        let p = Process(); p.executableURL = URL(fileURLWithPath: cfg.mono + "/bin/mono-sgen64")
        var managedArgs: [String] = []
        if let command = arguments.first {
            managedArgs.append(command); managedArgs.append(host); managedArgs.append(contentsOf: arguments.dropFirst())
        }
        p.arguments = ControlMacRuntime.monoArguments(executable: exe, arguments: managedArgs, monoRoot: cfg.mono)
        var env = ProcessInfo.processInfo.environment
        ControlMacRuntime.configureMonoEnvironment(&env, monoRoot: cfg.mono, managed: cfg.managed); p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        activePlaybackProcess = p
        do { try p.run() } catch { activePlaybackProcess = nil; completion(1, error.localizedDescription); return }
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.activePlaybackProcess = nil
                completion(p.terminationStatus, text)
            }
        }
    }
    func refreshPlayback() {
        guard host != nil, activePlaybackProcess == nil else { return }
        runPlayback(["status"]) { code, text in
            guard code == 0 else {
                self.setPlaybackEnabled(false)
                return
            }
            self.parsePlaybackStatus(text)
        }
    }

    func parsePlaybackStatus(_ text: String) {
        var zones: [PlaybackZoneRow] = []
        var queue: [PlaybackQueueRow] = []
        for line in text.split(separator: "\n") {
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if p.first == "CMZONE", p.count >= 12 {
                zones.append(PlaybackZoneRow(id: p[1], name: p[2], state: p[3],
                    volume: Int(p[4]) ?? 0, volumeMin: Int(p[5]) ?? 0, volumeMax: Int(p[6]) ?? 100,
                    muted: p[7].lowercased() == "true", queueCount: Int(p[8]) ?? 0,
                    queueIndex: Int(p[9]) ?? -1, media: p[10], subtitle: p[11]))
            } else if p.first == "CMQUEUE", p.count >= 6 {
                queue.append(PlaybackQueueRow(zoneID: p[1], index: Int(p[2]) ?? 0,
                    played: p[3].lowercased() == "true", title: p[4], subtitle: p[5]))
            }
        }
        playbackZones = zones; playbackQueue = queue
        if selectedZoneID == nil || !zones.contains(where: { $0.id == selectedZoneID }) { selectedZoneID = zones.first?.id }
        zonePopup.removeAllItems(); zonePopup.addItems(withTitles: zones.map { $0.name })
        if let id = selectedZoneID, let idx = zones.firstIndex(where: { $0.id == id }) { zonePopup.selectItem(at: idx) }
        applyPlaybackZoneState()
    }
    func applyPlaybackZoneState() {
        guard let z = currentPlaybackZone() else { setPlaybackEnabled(false); return }
        setPlaybackEnabled(true)
        volumeValueLabel.stringValue = "Vol \(z.volume)"
        muteButton.title = z.muted ? "Unmute" : "Mute"
        playPauseButton.title = z.state.lowercased() == "playing" ? "❚❚" : "▶︎"
        queueButton.title = "Queue (\(z.queueCount))"
        let now = z.media.isEmpty ? z.state : "\(z.state) · \(z.media)" + (z.subtitle.isEmpty ? "" : " — \(z.subtitle)")
        nowPlayingLabel.stringValue = now
        let rows = playbackQueue.filter { $0.zoneID == z.id }
        playbackQueueController?.update(rows: rows, currentIndex: z.queueIndex)
    }

    @objc func playbackZoneChanged() {
        let index = zonePopup.indexOfSelectedItem
        guard index >= 0, index < playbackZones.count else { return }
        selectedZoneID = playbackZones[index].id
        applyPlaybackZoneState()
    }

    func playbackCommand(_ args: [String], success: String) {
        statusLabel.stringValue = success + "…"
        runPlayback(args) { code, text in
            guard code == 0 else { self.alert("Playback command failed", self.backendError(text)); return }
            self.statusLabel.stringValue = success
            self.refreshPlayback()
        }
    }
    @objc func playbackPrevious() {
        guard let z = currentPlaybackZone() else { return }
        playbackCommand(["transport", z.id, "previous"], success: "Previous track")
    }

    @objc func playbackPlayPause() {
        guard let z = currentPlaybackZone() else { return }
        playbackCommand(["transport", z.id, "playpause"], success: "Play / pause")
    }

    @objc func playbackNext() {
        guard let z = currentPlaybackZone() else { return }
        playbackCommand(["transport", z.id, "next"], success: "Next track")
    }

    @objc func playbackMute() {
        guard let z = currentPlaybackZone() else { return }
        playbackCommand(["mute", z.id, String(!z.muted)], success: z.muted ? "Unmuting" : "Muting")
    }

    @objc func playbackVolumeDownOne() {
        guard let z = currentPlaybackZone() else { return }
        playbackCommand(["volume-relative", z.id, "-1"], success: "Volume −1")
    }

    @objc func playbackVolumeUpOne() {
        guard let z = currentPlaybackZone() else { return }
        playbackCommand(["volume-relative", z.id, "+1"], success: "Volume +1")
    }
    @objc func playbackPlayAlbum() {
        guard let z = currentPlaybackZone(), let album = selectedSummary() else { return }
        playbackCommand(["album", z.id, album.id, "now"], success: "Playing \(album.title)")
    }

    @objc func playbackQueueAlbum() {
        guard let z = currentPlaybackZone(), let album = selectedSummary() else { return }
        playbackCommand(["album", z.id, album.id, "later"], success: "Queued \(album.title)")
    }

    @objc func playbackPlayTrack() {
        guard let z = currentPlaybackZone(), let trackID = selectedTrackID,
              let track = tracks.first(where: { $0.id == trackID }) else { return }
        playbackCommand(["track", z.id, trackID, "now"], success: "Playing \(track.title)")
    }

    @objc func playbackQueueTrack() {
        guard let z = currentPlaybackZone(), let trackID = selectedTrackID,
              let track = tracks.first(where: { $0.id == trackID }) else { return }
        playbackCommand(["track", z.id, trackID, "later"], success: "Queued \(track.title)")
    }

    @objc func showPlaybackQueue() {
        guard let z = currentPlaybackZone() else { return }
        let rows = playbackQueue.filter { $0.zoneID == z.id }
        if let controller = playbackQueueController {
            controller.update(rows: rows, currentIndex: z.queueIndex)
            controller.window.makeKeyAndOrderFront(nil)
        } else {
            let controller = PlaybackQueueController(rows: rows, currentIndex: z.queueIndex)
            playbackQueueController = controller; controller.window.center(); controller.window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
