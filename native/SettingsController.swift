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
    let musicBrainz = NSButton(checkboxWithTitle: "MusicBrainz / Cover Art Archive", target: nil, action: nil)
    let audioDB = NSButton(checkboxWithTitle: "TheAudioDB", target: nil, action: nil)
    let audioDBKey = NSSecureTextField(string: "")
    let bandcamp = NSButton(checkboxWithTitle: "Bandcamp purchases / metadata", target: nil, action: nil)
    let bandcampServer = NSTextField(string: "https://bandcamp.com/api/subsonic")
    let bandcampUser = NSTextField(string: "")
    let bandcampSecret = NSSecureTextField(string: "")
    let discogs = NSButton(checkboxWithTitle: "Discogs", target: nil, action: nil)
    let discogsToken = NSSecureTextField(string: "")
    let status = NSTextField(labelWithString: "")

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 590),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "ControlMac 2026 Settings"
        super.init(window: w)
        buildUI()
        loadValues()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func row(_ label: String, _ field: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 150).isActive = true
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
        let save = NSButton(title: "Save Settings", target: self, action: #selector(saveSettings))
        let test = NSButton(title: "Test Bandcamp", target: self, action: #selector(testBandcamp))
        let buttons = NSStackView(views: [save, test])
        buttons.orientation = .horizontal; buttons.spacing = 8
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        audioDBKey.placeholderString = "Optional API key (stored in Keychain)"
        bandcampSecret.placeholderString = "Stored in Keychain if already configured"
        discogsToken.placeholderString = "Personal access token (stored in Keychain)"

        let stack = NSStackView(views: [
            section("Metadata providers"),
            musicBrainz,
            audioDB,
            row("TheAudioDB key", audioDBKey),
            discogs,
            row("Discogs token", discogsToken),
            section("Bandcamp"),
            bandcamp,
            row("Server", bandcampServer),
            row("Username", bandcampUser),
            row("Password", bandcampSecret),
            buttons,
            status
        ])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26)
        ])
    }
    private func loadValues() {
        let d = UserDefaults.standard
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

    @objc private func saveSettings() {
        do {
            try saveValues()
            status.stringValue = "Settings saved. Provider changes apply to the next lookup."
        } catch {
            status.stringValue = error.localizedDescription
        }
    }
    private func saveValues() throws {
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
        do { try saveValues() }
        catch { status.stringValue = error.localizedDescription; return }
        status.stringValue = "Testing Bandcamp…"
        BandcampService.ping { result in
            DispatchQueue.main.async {
                switch result {
                case .success: self.status.stringValue = "Bandcamp connected successfully."
                case .failure(let error): self.status.stringValue = "Bandcamp test failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
