import AppKit
import Foundation

private struct MeridianConfigDevice {
    let id: String
    let configType: String
    let model: String
    let name: String
    let serial: String
    let endpointID: String
}

final class MeridianConfigController: NSWindowController {
    private var host: String
    private let tabs = NSTabView()
    private let coreInfo = NSTextField(labelWithString: "Loading Core information…")
    private let systemInfo = NSTextField(labelWithString: "")
    private let dealerInfo = NSTextField(wrappingLabelWithString: "")
    private let devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let deviceInfo = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var devices: [MeridianConfigDevice] = []

    private let currentIP = NSTextField(labelWithString: "—")
    private let dhcp = NSButton(checkboxWithTitle: "Obtain address automatically (DHCP)", target: nil, action: nil)
    private let ipField = NSTextField(string: "")
    private let maskField = NSTextField(string: "")
    private let gatewayField = NSTextField(string: "")
    private let dnsField = NSTextField(string: "")
    private let networkStatus = NSTextField(labelWithString: "")

    private let registrationFields: [String: NSTextField] = [
        "fname": NSTextField(string: ""), "lname": NSTextField(string: ""),
        "email": NSTextField(string: ""), "phone": NSTextField(string: ""),
        "street1": NSTextField(string: ""), "street2": NSTextField(string: ""),
        "city": NSTextField(string: ""), "state": NSTextField(string: ""),
        "zip": NSTextField(string: ""), "country": NSTextField(string: "")
    ]
    private let registrationStatus = NSTextField(labelWithString: "")
    private let firmwareInfo = NSTextField(wrappingLabelWithString: "Reading firmware catalogue…")
    private let firmwareWarning = NSTextField(wrappingLabelWithString: "⚠︎ Firmware updates must be performed while the Core/device is connected to a UPS. Do not interrupt power during an update or downgrade.")

    init(host: String) {
        self.host = host
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Meridian Device Configuration — ControlMac 2026"
        w.minSize = NSSize(width: 700, height: 580)
        super.init(window: w)
        buildUI()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Meridian / Sooloos Configuration")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let hostLabel = NSTextField(labelWithString: "Core: \(host)")
        hostLabel.textColor = .secondaryLabelColor

        tabs.addTabViewItem(tab(title: "Device", view: buildDeviceTab()))
        tabs.addTabViewItem(tab(title: "Network", view: buildNetworkTab()))
        tabs.addTabViewItem(tab(title: "Registration", view: buildRegistrationTab()))
        tabs.addTabViewItem(tab(title: "Firmware", view: buildFirmwareTab()))
        tabs.translatesAutoresizingMaskIntoConstraints = false
        status.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, hostLabel, tabs, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            tabs.widthAnchor.constraint(equalTo: stack.widthAnchor), tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 475)
        ])
    }

    private func tab(title: String, view: NSView) -> NSTabViewItem { let i = NSTabViewItem(); i.label = title; i.view = view; return i }

    private func buildDeviceTab() -> NSView {
        let v = NSView(); coreInfo.maximumNumberOfLines = 3; systemInfo.maximumNumberOfLines = 3; dealerInfo.maximumNumberOfLines = 5
        devicePopup.target = self; devicePopup.action = #selector(deviceChanged)
        let refresh = NSButton(title: "Refresh from Core", target: self, action: #selector(reload))
        let stack = NSStackView(views: [coreInfo, systemInfo, NSTextField(labelWithString: "Meridian device"), devicePopup, deviceInfo,
                                        NSTextField(labelWithString: "Dealer information"), dealerInfo, refresh])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 18)])
        return v
    }

    private func buildNetworkTab() -> NSView {
        let v = NSView(); dhcp.target = self; dhcp.action = #selector(dhcpChanged)
        for f in [ipField, maskField, gatewayField, dnsField] { f.widthAnchor.constraint(equalToConstant: 220).isActive = true }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Current address"), currentIP],
            [NSTextField(labelWithString: "IP address"), ipField],
            [NSTextField(labelWithString: "Subnet mask"), maskField],
            [NSTextField(labelWithString: "Gateway"), gatewayField],
            [NSTextField(labelWithString: "DNS server"), dnsField]
        ])
        grid.rowSpacing = 10; grid.columnSpacing = 16; grid.column(at: 0).xPlacement = .trailing; grid.column(at: 1).xPlacement = .leading
        let apply = NSButton(title: "Apply Network Settings…", target: self, action: #selector(applyNetwork))
        let refresh = NSButton(title: "Refresh IP", target: self, action: #selector(refreshNetwork))
        let buttons = NSStackView(views: [apply, refresh]); buttons.orientation = .horizontal; buttons.spacing = 10
        networkStatus.maximumNumberOfLines = 3; networkStatus.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [dhcp, grid, buttons, networkStatus]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 18), stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 18)])
        return v
    }

    private func buildRegistrationTab() -> NSView {
        let v = NSView()
        let rows: [(String,String)] = [("First name","fname"),("Last name","lname"),("Email","email"),("Phone","phone"),("Address 1","street1"),("Address 2","street2"),("Town / City","city"),("County / State","state"),("Postcode / ZIP","zip"),("Country","country")]
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), registrationFields[$0.1]!] })
        grid.rowSpacing = 7; grid.columnSpacing = 16; grid.column(at: 0).xPlacement = .trailing; grid.column(at: 1).xPlacement = .leading
        registrationFields.values.forEach { $0.widthAnchor.constraint(equalToConstant: 320).isActive = true }
        let save = NSButton(title: "Save Registration…", target: self, action: #selector(saveRegistration))
        let refresh = NSButton(title: "Refresh Registration", target: self, action: #selector(refreshRegistration))
        let buttons = NSStackView(views: [save, refresh]); buttons.orientation = .horizontal; buttons.spacing = 10
        registrationStatus.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [grid, buttons, registrationStatus]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 18), stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 18)])
        return v
    }

    private func buildFirmwareTab() -> NSView {
        let v = NSView(); firmwareWarning.textColor = .systemOrange; firmwareWarning.maximumNumberOfLines = 4; firmwareInfo.maximumNumberOfLines = 12
        let refresh = NSButton(title: "Refresh Firmware Catalogue", target: self, action: #selector(refreshFirmware))
        let note = NSTextField(wrappingLabelWithString: "Upgrade/downgrade installation will only be enabled after ControlMac has verified Meridian's original IFTP transfer and reboot sequence on real hardware. Package discovery is active now.")
        note.textColor = .secondaryLabelColor; note.maximumNumberOfLines = 5
        let stack = NSStackView(views: [firmwareWarning, firmwareInfo, refresh, note]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 18), firmwareWarning.widthAnchor.constraint(lessThanOrEqualToConstant: 650), firmwareInfo.widthAnchor.constraint(lessThanOrEqualToConstant: 650)])
        return v
    }

    @objc private func reload() {
        status.stringValue = "Reading configuration from Sooloos Core…"
        runManaged("ConfigTool", [host]) { text, code in
            self.applyCore(text: text, exitCode: code)
            self.refreshNetworkThenRegistration()
            self.refreshFirmware()
        }
    }

    private func runManaged(_ name: String, _ args: [String], completion: @escaping (String, Int32) -> Void) {
        guard let cfg = ControlMacRuntime.backendConfig(), let exe = Bundle.main.url(forResource: name, withExtension: "exe") else {
            completion("CMERROR\tConfiguration backend is unavailable.", 1); return
        }
        let p = Process(); p.executableURL = URL(fileURLWithPath: cfg.mono + "/bin/mono-sgen64")
        p.arguments = ControlMacRuntime.monoArguments(executable: exe, arguments: args, monoRoot: cfg.mono)
        var env = ProcessInfo.processInfo.environment; ControlMacRuntime.configureMonoEnvironment(&env, monoRoot: cfg.mono, managed: cfg.managed); p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { completion("CMERROR\t\(error.localizedDescription)", 1); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async { completion(text, p.terminationStatus) }
        }
    }

    private func applyCore(text: String, exitCode: Int32) {
        var newDevices: [MeridianConfigDevice] = []
        for line in text.split(separator: "\n") {
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if p.first == "CMCORE", p.count >= 4 { coreInfo.stringValue = "Core device ID: \(p[1])\nSerial: \(p[2]) · System version: \(p[3])" }
            else if p.first == "CMSETTINGS", p.count >= 4 { systemInfo.stringValue = "Language: \(p[1]) · Extra web port: \(p[2].isEmpty ? "not set" : p[2]) · ZoneLink resync often: \(p[3])" }
            else if p.first == "CMDEALER", p.count >= 2 { dealerInfo.stringValue = p[1].isEmpty ? "No dealer information stored." : p[1] }
            else if p.first == "CMDEVICE", p.count >= 7 { newDevices.append(.init(id: p[1], configType: p[2], model: p[3], name: p[4], serial: p[5], endpointID: p[6])) }
        }
        devices = newDevices; devicePopup.removeAllItems()
        if devices.isEmpty { devicePopup.addItem(withTitle: "No Meridian devices reported by Core") }
        else { devicePopup.addItems(withTitles: devices.map { $0.name.isEmpty ? $0.model : "\($0.name) — \($0.model)" }) }
        showSelectedDevice(); status.stringValue = exitCode == 0 ? "Configuration read from Sooloos." : "Configuration read was incomplete."
    }

    @objc private func deviceChanged() { showSelectedDevice(); refreshNetwork() }
    private func showSelectedDevice() {
        let i = devicePopup.indexOfSelectedItem; guard devices.indices.contains(i) else { deviceInfo.stringValue = ""; return }
        let d = devices[i]; deviceInfo.stringValue = "Model: \(d.model)\nName: \(d.name)\nSerial: \(d.serial)\nAudio endpoint: \(d.endpointID)\nConfiguration type: \(d.configType)\nDevice ID: \(d.id)"
    }

    private func selectedSerial() -> String? {
        let i = devicePopup.indexOfSelectedItem; guard devices.indices.contains(i) else { return nil }; return devices[i].serial
    }

    @objc private func dhcpChanged() { updateNetworkFields() }
    private func updateNetworkFields() {
        let enabled = dhcp.state != .on
        [ipField, maskField, gatewayField, dnsField].forEach { $0.isEnabled = enabled }
    }


    private func refreshNetworkThenRegistration() {
        guard let serial = selectedSerial(), !serial.isEmpty else {
            networkStatus.stringValue = "Select a Meridian device first."
            refreshRegistration()
            return
        }
        networkStatus.stringValue = "Reading network configuration…"
        runManaged("IPNPConfigTool", ["status", host, serial]) { text, code in
            self.applyNetworkRead(text: text, code: code)
            self.refreshRegistration()
        }
    }

    private func applyNetworkRead(text: String, code: Int32) {
        var values: [String:String] = [:]
        for line in text.split(separator: "\n") {
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if p.first == "CMIPNP", p.count >= 2 { self.currentIP.stringValue = p[1] }
            else if p.first == "CMNET", p.count >= 3 { values[p[1]] = p[2] }
        }
        if code == 0 {
            self.dhcp.state = values["dhcp"] == "1" ? .on : .off
            self.ipField.stringValue = values["ip"] ?? ""; self.maskField.stringValue = values["netmask"] ?? ""
            self.gatewayField.stringValue = values["gateway"] ?? ""; self.dnsField.stringValue = values["dns"] ?? ""
            self.updateNetworkFields(); self.networkStatus.stringValue = "Network configuration refreshed directly from the Meridian device."
        } else { self.networkStatus.stringValue = self.errorText(text) }
    }

    @objc private func refreshNetwork() {
        guard let serial = selectedSerial(), !serial.isEmpty else { networkStatus.stringValue = "Select a Meridian device first."; return }
        networkStatus.stringValue = "Reading network configuration…"
        runManaged("IPNPConfigTool", ["status", host, serial]) { text, code in
            self.applyNetworkRead(text: text, code: code)
        }
    }

    @objc private func applyNetwork() {
        guard let serial = selectedSerial() else { return }
        let a = NSAlert(); a.messageText = "Apply Meridian network settings?"
        a.informativeText = dhcp.state == .on ? "This will switch the selected device to DHCP. Its address may change and ControlMac may temporarily lose contact." : "This will change the selected device's static IP configuration. Incorrect values can make the device unreachable."
        a.alertStyle = .warning; a.addButton(withTitle: "Apply"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var args = ["apply", host, serial]
        if dhcp.state == .on { args.append("dhcp") }
        else { args += ["static", ipField.stringValue, maskField.stringValue, gatewayField.stringValue, dnsField.stringValue] }
        networkStatus.stringValue = "Applying network configuration…"
        runManaged("IPNPConfigTool", args) { text, code in
            if code == 0 {
                self.networkStatus.stringValue = "Network settings accepted by the Meridian device."
                if self.dhcp.state != .on {
                    let newHost = self.ipField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !newHost.isEmpty { self.host = newHost; ControlMacConfiguration.sooloosAddress = newHost; self.currentIP.stringValue = newHost }
                }
            } else { self.networkStatus.stringValue = self.errorText(text) }
        }
    }

    @objc private func refreshRegistration() {
        registrationStatus.stringValue = "Reading stored registration…"
        runManaged("IPNPConfigTool", ["registration-status", host]) { text, code in
            guard code == 0 else { self.registrationStatus.stringValue = self.errorText(text); return }
            var values: [String:String] = [:]
            for line in text.split(separator: "\n") {
                let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if p.first == "CMREG", p.count >= 3 { values[p[1]] = p[2] }
            }
            for (key, field) in self.registrationFields { field.stringValue = values[key] ?? "" }
            self.registrationStatus.stringValue = values["is_registered"] == "1" ? "Registration loaded from the Sooloos broker." : "This system is not currently registered."
        }
    }

    @objc private func saveRegistration() {
        let a = NSAlert(); a.messageText = "Save Sooloos registration?"
        a.informativeText = "These details will be written to the Sooloos broker using Meridian's original register_user command."
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let order = ["fname","lname","email","phone","street1","street2","city","state","zip","country"]
        var args = ["registration-apply", host, "registration"]
        args += order.map { registrationFields[$0]?.stringValue ?? "" }
        registrationStatus.stringValue = "Saving registration…"
        runManaged("IPNPConfigTool", args) { text, code in
            self.registrationStatus.stringValue = code == 0 ? "Registration saved to the Sooloos broker." : self.errorText(text)
            if code == 0 { self.refreshRegistration() }
        }
    }

    @objc private func refreshFirmware() {
        firmwareInfo.stringValue = "Reading firmware catalogue from Sooloos…"
        let baseHost = host
        DispatchQueue.global(qos: .userInitiated).async {
            let channels = ["live", "live.old", "staging", "staging.old"]
            var lines: [String] = []
            for channel in channels {
                let base = "http://\(baseHost):9080/Music/updates/\(channel)"
                let system = self.fetchText("\(base)/SYSVERSION")
                let c15 = self.fetchText("\(base)/ControlFifteen.lnk/VERSION")
                if system != nil || c15 != nil {
                    lines.append("\(channel): system \(system ?? "—") · ControlFifteen \(c15 ?? "—")")
                }
            }
            DispatchQueue.main.async {
                self.firmwareInfo.stringValue = lines.isEmpty ? "No Meridian firmware catalogue could be read from this Core." : "Available packages on this Core:\n\n" + lines.joined(separator: "\n")
            }
        }
    }

    private func fetchText(_ raw: String) -> String? {
        guard let u = URL(string: raw), let d = try? Data(contentsOf: u), let s = String(data: d, encoding: .utf8) else { return nil }
        let clean = s.trimmingCharacters(in: .whitespacesAndNewlines); return clean.isEmpty ? nil : clean
    }

    private func errorText(_ text: String) -> String {
        for line in text.split(separator: "\n") where line.hasPrefix("CMERROR\t") { return String(line.dropFirst(8)) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Operation failed." : String(text.suffix(800))
    }
}
