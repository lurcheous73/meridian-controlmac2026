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
    private let host: String
    private let coreInfo = NSTextField(labelWithString: "Loading Core information…")
    private let systemInfo = NSTextField(labelWithString: "")
    private let devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let deviceInfo = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var devices: [MeridianConfigDevice] = []

    init(host: String) {
        self.host = host
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 430),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Meridian Device Configuration"
        w.minSize = NSSize(width: 620, height: 390)
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
        coreInfo.maximumNumberOfLines = 3
        systemInfo.maximumNumberOfLines = 3
        devicePopup.target = self
        devicePopup.action = #selector(deviceChanged)
        devicePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        deviceInfo.maximumNumberOfLines = 8
        deviceInfo.widthAnchor.constraint(equalToConstant: 610).isActive = true
        status.textColor = .secondaryLabelColor
        let refresh = NSButton(title: "Refresh from Core", target: self, action: #selector(reload))
        let stack = NSStackView(views: [title, hostLabel, coreInfo, systemInfo,
                                       NSTextField(labelWithString: "Meridian device"), devicePopup,
                                       deviceInfo, refresh, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26)
        ])
    }

    @objc private func reload() {
        status.stringValue = "Reading configuration from Sooloos Core…"
        guard let cfg = ControlMacRuntime.backendConfig(),
              let exe = Bundle.main.url(forResource: "ConfigTool", withExtension: "exe") else {
            status.stringValue = "Configuration backend is unavailable."
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cfg.mono + "/bin/mono-sgen64")
        p.arguments = ControlMacRuntime.monoArguments(executable: exe, arguments: [host], monoRoot: cfg.mono)
        var env = ProcessInfo.processInfo.environment
        ControlMacRuntime.configureMonoEnvironment(&env, monoRoot: cfg.mono, managed: cfg.managed)
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { status.stringValue = error.localizedDescription; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async { self.apply(text: text, exitCode: p.terminationStatus) }
        }
    }

    private func apply(text: String, exitCode: Int32) {
        var newDevices: [MeridianConfigDevice] = []
        for line in text.split(separator: "\n") {
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if p.first == "CMCORE", p.count >= 4 {
                coreInfo.stringValue = "Core device ID: \(p[1])\nSerial: \(p[2]) · System version: \(p[3])"
            } else if p.first == "CMSETTINGS", p.count >= 4 {
                systemInfo.stringValue = "Language: \(p[1]) · Extra web port: \(p[2].isEmpty ? "not set" : p[2]) · ZoneLink resync often: \(p[3])"
            } else if p.first == "CMDEVICE", p.count >= 7 {
                newDevices.append(.init(id: p[1], configType: p[2], model: p[3], name: p[4], serial: p[5], endpointID: p[6]))
            }
        }
        devices = newDevices
        devicePopup.removeAllItems()
        if devices.isEmpty { devicePopup.addItem(withTitle: "No Meridian devices reported by Core") }
        else { devicePopup.addItems(withTitles: devices.map { $0.name.isEmpty ? $0.model : "\($0.name) — \($0.model)" }) }
        showSelectedDevice()
        status.stringValue = exitCode == 0 ? "Configuration read directly from the Sooloos broker." : "Configuration read was incomplete."
    }

    @objc private func deviceChanged() { showSelectedDevice() }

    private func showSelectedDevice() {
        let i = devicePopup.indexOfSelectedItem
        guard devices.indices.contains(i) else { deviceInfo.stringValue = ""; return }
        let d = devices[i]
        deviceInfo.stringValue = "Model: \(d.model)\nName: \(d.name)\nSerial: \(d.serial)\nAudio endpoint: \(d.endpointID)\nConfiguration type: \(d.configType)\nDevice ID: \(d.id)"
    }
}
