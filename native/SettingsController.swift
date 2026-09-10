import AppKit
import Security

final class SecretStore {
    static func save(service: String, value: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "ControlMac2026"
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func load(service: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "ControlMac2026",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

final class SettingsController: NSWindowController {
    var configurationChanged: (() -> Void)?

    private let discovery = ControlMacNetworkDiscovery()
    private var discovered: [ControlMacDiscoveredService] = []

    private let scanStatus = NSTextField(labelWithString: "Not scanned yet")
    private let scanResults = NSTextView()
    private let sooloosPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let surroundPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sooloosAddress = NSTextField(string: "")
    private let surroundAddress = NSTextField(string: "")
    private let sooloosStatus = NSTextField(labelWithString: "")
    private let surroundStatus = NSTextField(labelWithString: "")

    let musicBrainz = NSButton(checkboxWithTitle: "MusicBrainz / Cover Art Archive", target: nil, action: nil)
    let audioDB = NSButton(checkboxWithTitle: "TheAudioDB", target: nil, action: nil)
    let audioDBKey = NSSecureTextField(string: "")
    let bandcamp = NSButton(checkboxWithTitle: "Bandcamp purchases / metadata", target: nil, action: nil)
    let bandcampServer = NSTextField(string: "https://bandcamp.com/api/subsonic")
    let bandcampUser = NSTextField(string: "")
    let bandcampSecret = NSSecureTextField(string: "")
    let discogs = NSButton(checkboxWithTitle: "Discogs", target: nil, action: nil)
    let discogsToken = NSSecureTextField(string: "")
    let providerStatus = NSTextField(labelWithString: "")

    init(configurationChanged: (() -> Void)? = nil) {
        self.configurationChanged = configurationChanged
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "ControlMac 2026 Settings"
        w.minSize = NSSize(width: 700, height: 580)
        super.init(window: w)
        buildUI()
        loadValues()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func row(_ label: String, _ field: NSView, labelWidth: CGFloat = 150) -> NSStackView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        let s = NSStackView(views: [l, field])
        s.orientation = .horizontal
        s.spacing = 10
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        return s
    }

    private func section(_ title: String) -> NSTextField {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 15, weight: .semibold)
        return l
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])

        let equipment = NSTabViewItem(identifier: "equipment")
        equipment.label = "Equipment Scan"
        equipment.view = buildEquipmentView()
        tabs.addTabViewItem(equipment)

        let sooloos = NSTabViewItem(identifier: "sooloos")
        sooloos.label = "Sooloos"
        sooloos.view = buildSooloosView()
        tabs.addTabViewItem(sooloos)

        let surround = NSTabViewItem(identifier: "surround")
        surround.label = "SurroundCore"
        surround.view = buildSurroundView()
        tabs.addTabViewItem(surround)

        let providers = NSTabViewItem(identifier: "providers")
        providers.label = "Metadata"
        providers.view = buildProviderView()
        tabs.addTabViewItem(providers)
    }

    private func paddedStack(_ views: [NSView]) -> NSView {
        let container = NSView()
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24)
        ])
        return container
    }

    private func buildEquipmentView() -> NSView {
        let intro = NSTextField(wrappingLabelWithString: "Scan this Mac's local IPv4 networks for Meridian/Sooloos WebClient cores and SurroundCore HTTP APIs. Nothing is selected automatically when multiple matching cores are found.")
        intro.maximumNumberOfLines = 3
        intro.widthAnchor.constraint(equalToConstant: 650).isActive = true

        let scan = NSButton(title: "Scan Local Network", target: self, action: #selector(scanNetwork))
        let buttons = NSStackView(views: [scan, scanStatus])
        buttons.orientation = .horizontal; buttons.spacing = 12; buttons.alignment = .centerY

        sooloosPopup.target = self; sooloosPopup.action = #selector(selectSooloosDiscovery)
        surroundPopup.target = self; surroundPopup.action = #selector(selectSurroundDiscovery)
        sooloosPopup.addItem(withTitle: "No Sooloos cores discovered")
        surroundPopup.addItem(withTitle: "No SurroundCore instances discovered")
        sooloosPopup.widthAnchor.constraint(equalToConstant: 440).isActive = true
        surroundPopup.widthAnchor.constraint(equalToConstant: 440).isActive = true

        scanResults.isEditable = false
        scanResults.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = scanResults
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 650).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 250).isActive = true

        return paddedStack([
            section("Equipment discovery"), intro, buttons,
            row("Sooloos Core", sooloosPopup),
            row("SurroundCore", surroundPopup),
            section("Detected equipment"), scroll
        ])
    }

    private func buildSooloosView() -> NSView {
        let intro = NSTextField(wrappingLabelWithString: "ControlMac keeps Meridian/Sooloos separate from SurroundCore. Automatic discovery is preferred; manual host/IP entry is an advanced fallback.")
        intro.maximumNumberOfLines = 3
        intro.widthAnchor.constraint(equalToConstant: 650).isActive = true
        sooloosAddress.placeholderString = "Hostname or IPv4 address"
        let test = NSButton(title: "Test Connection", target: self, action: #selector(testSooloos))
        let save = NSButton(title: "Save Sooloos Core", target: self, action: #selector(saveSooloos))
        let buttons = NSStackView(views: [save, test])
        buttons.orientation = .horizontal; buttons.spacing = 8
        sooloosStatus.textColor = .secondaryLabelColor
        return paddedStack([
            section("Meridian / Sooloos"), intro,
            row("Selected Core", sooloosAddress), buttons, sooloosStatus,
            section("Expected capabilities"),
            NSTextField(wrappingLabelWithString: "Library, import destination, zones/endpoints and playback remain provided by the existing proven Meridian/Sooloos backend. This page changes how the Core is selected, not the working Meridian protocol implementation.")
        ])
    }

    private func buildSurroundView() -> NSView {
        let intro = NSTextField(wrappingLabelWithString: "SurroundCore is the separate network/audio backend. Its provider credentials stay on the Core; ControlMac stores only the selected Core address here.")
        intro.maximumNumberOfLines = 3
        intro.widthAnchor.constraint(equalToConstant: 650).isActive = true
        surroundAddress.placeholderString = "http://core-host:8080"
        let test = NSButton(title: "Test API", target: self, action: #selector(testSurroundCore))
        let save = NSButton(title: "Save SurroundCore", target: self, action: #selector(saveSurroundCore))
        let setup = NSButton(title: "Open Streaming Setup", target: self, action: #selector(openSurroundSetup))
        let buttons = NSStackView(views: [save, test, setup])
        buttons.orientation = .horizontal; buttons.spacing = 8
        surroundStatus.textColor = .secondaryLabelColor
        return paddedStack([
            section("SurroundCore"), intro,
            row("Core URL", surroundAddress), buttons, surroundStatus,
            section("ControlMac relationship"),
            NSTextField(wrappingLabelWithString: "Library/storage/cache/endpoints/ingest/streaming capability status will be populated from the SurroundCore API. Streaming account passwords and API credentials are not copied into ControlMac.")
        ])
    }

    private func buildProviderView() -> NSView {
        let save = NSButton(title: "Save Settings", target: self, action: #selector(saveProviderSettings))
        let test = NSButton(title: "Test Bandcamp", target: self, action: #selector(testBandcamp))
        let buttons = NSStackView(views: [save, test])
        buttons.orientation = .horizontal; buttons.spacing = 8
        providerStatus.textColor = .secondaryLabelColor
        providerStatus.maximumNumberOfLines = 2
        audioDBKey.placeholderString = "Optional API key (stored in Keychain)"
        bandcampSecret.placeholderString = "Stored in Keychain if already configured"
        discogsToken.placeholderString = "Personal access token (stored in Keychain)"

        return paddedStack([
            section("Metadata providers"),
            musicBrainz, audioDB, row("TheAudioDB key", audioDBKey),
            discogs, row("Discogs token", discogsToken),
            section("Bandcamp metadata"), bandcamp,
            row("Server", bandcampServer), row("Username", bandcampUser), row("Password", bandcampSecret),
            buttons, providerStatus
        ])
    }

    private func loadValues() {
        let d = UserDefaults.standard
        sooloosAddress.stringValue = ControlMacConfiguration.sooloosAddress
        surroundAddress.stringValue = ControlMacConfiguration.surroundCoreAddress

        let mb = d.object(forKey: "metadataMusicBrainzEnabled") == nil || d.bool(forKey: "metadataMusicBrainzEnabled")
        let adb = d.object(forKey: "metadataAudioDBEnabled") == nil || d.bool(forKey: "metadataAudioDBEnabled")
        let bc = d.object(forKey: "metadataBandcampEnabled") == nil || d.bool(forKey: "metadataBandcampEnabled")
        musicBrainz.state = mb ? .on : .off
        audioDB.state = adb ? .on : .off
        bandcamp.state = bc ? .on : .off
        discogs.state = d.bool(forKey: "metadataDiscogsEnabled") ? .on : .off
        bandcampServer.stringValue = d.string(forKey: "bandcampSubsonicServer") ?? "https://bandcamp.com/api/subsonic"
        bandcampUser.stringValue = d.string(forKey: "bandcampSubsonicUsername") ?? ""
    }

    @objc private func scanNetwork() {
        scanStatus.stringValue = "Starting scan…"
        scanResults.string = ""
        discovered.removeAll()
        discovery.scan(progress: { [weak self] text in self?.scanStatus.stringValue = text }) { [weak self] services in
            guard let self = self else { return }
            self.discovered = services
            self.scanStatus.stringValue = services.isEmpty ? "Scan complete — nothing recognised" : "Scan complete — \(services.count) service(s) recognised"
            self.scanResults.string = services.isEmpty ? "No recognised Sooloos or SurroundCore service responded. Manual entry remains available." : services.map {
                "\($0.kind.rawValue)\t\($0.name)\t\($0.displayAddress)\t\($0.detail)"
            }.joined(separator: "\n")
            self.reloadDiscoveryPopups()
        }
    }

    private func reloadDiscoveryPopups() {
        let sooloos = discovered.filter { $0.kind == .sooloos }
        let surround = discovered.filter { $0.kind == .surroundCore }
        sooloosPopup.removeAllItems()
        surroundPopup.removeAllItems()
        if sooloos.isEmpty { sooloosPopup.addItem(withTitle: "No Sooloos cores discovered") }
        else { sooloos.forEach { sooloosPopup.addItem(withTitle: "\($0.name) — \($0.displayAddress)") } }
        if surround.isEmpty { surroundPopup.addItem(withTitle: "No SurroundCore instances discovered") }
        else { surround.forEach { surroundPopup.addItem(withTitle: "\($0.name) — \($0.displayAddress)") } }
    }

    @objc private func selectSooloosDiscovery() {
        let matches = discovered.filter { $0.kind == .sooloos }
        guard matches.indices.contains(sooloosPopup.indexOfSelectedItem) else { return }
        sooloosAddress.stringValue = matches[sooloosPopup.indexOfSelectedItem].displayAddress
    }

    @objc private func selectSurroundDiscovery() {
        let matches = discovered.filter { $0.kind == .surroundCore }
        guard matches.indices.contains(surroundPopup.indexOfSelectedItem) else { return }
        surroundAddress.stringValue = matches[surroundPopup.indexOfSelectedItem].displayAddress
    }

    @objc private func saveSooloos() {
        ControlMacConfiguration.sooloosAddress = sooloosAddress.stringValue
        sooloosStatus.stringValue = "Sooloos Core saved."
        configurationChanged?()
    }

    @objc private func saveSurroundCore() {
        ControlMacConfiguration.surroundCoreAddress = surroundAddress.stringValue
        surroundStatus.stringValue = "SurroundCore saved."
        configurationChanged?()
    }

    @objc private func testSooloos() {
        sooloosStatus.stringValue = "Testing Sooloos…"
        discovery.testSooloos(sooloosAddress.stringValue) { [weak self] ok, detail in
            self?.sooloosStatus.stringValue = ok ? "Connected — \(detail)" : "Test failed — \(detail)"
        }
    }

    @objc private func testSurroundCore() {
        surroundStatus.stringValue = "Testing SurroundCore…"
        discovery.testSurroundCore(surroundAddress.stringValue) { [weak self] ok, detail in
            self?.surroundStatus.stringValue = ok ? "Connected — \(detail)" : "Test failed — \(detail)"
        }
    }

    @objc private func openSurroundSetup() {
        var raw = surroundAddress.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { surroundStatus.stringValue = "Set a SurroundCore address first."; return }
        if !raw.contains("://") { raw = "http://" + raw }
        guard var parts = URLComponents(string: raw), let host = parts.host, !host.isEmpty else {
            surroundStatus.stringValue = "Invalid SurroundCore address."; return
        }
        if parts.port == nil { parts.port = 8080 }
        parts.path = "/setup/streaming"
        parts.query = nil; parts.fragment = nil
        guard let url = parts.url else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func saveProviderSettings() {
        do {
            try saveProviderValues()
            providerStatus.stringValue = "Settings saved. Provider changes apply to the next lookup."
        } catch {
            providerStatus.stringValue = error.localizedDescription
        }
    }

    private func saveProviderValues() throws {
        let d = UserDefaults.standard
        d.set(musicBrainz.state == .on, forKey: "metadataMusicBrainzEnabled")
        d.set(audioDB.state == .on, forKey: "metadataAudioDBEnabled")
        d.set(discogs.state == .on, forKey: "metadataDiscogsEnabled")
        d.set(bandcamp.state == .on, forKey: "metadataBandcampEnabled")
        d.set(bandcampServer.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "bandcampSubsonicServer")
        let user = bandcampUser.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        d.set(user, forKey: "bandcampSubsonicUsername")
        if !audioDBKey.stringValue.isEmpty {
            try SecretStore.save(service: "uk.controlmac2026.audiodb", value: audioDBKey.stringValue)
            audioDBKey.stringValue = ""
        }
        if !discogsToken.stringValue.isEmpty {
            try SecretStore.save(service: "uk.controlmac2026.discogs", value: discogsToken.stringValue)
            discogsToken.stringValue = ""
        }
        let secret = bandcampSecret.stringValue
        if !user.isEmpty && !secret.isEmpty {
            try BandcampService.save(.init(username: user, password: secret))
            bandcampSecret.stringValue = ""
            bandcampSecret.placeholderString = "Stored in Keychain"
        }
    }

    @objc private func testBandcamp() {
        do { try saveProviderValues() }
        catch { providerStatus.stringValue = error.localizedDescription; return }
        providerStatus.stringValue = "Testing Bandcamp…"
        BandcampService.ping { result in
            DispatchQueue.main.async {
                switch result {
                case .success: self.providerStatus.stringValue = "Bandcamp connected successfully."
                case .failure(let error): self.providerStatus.stringValue = "Bandcamp test failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
