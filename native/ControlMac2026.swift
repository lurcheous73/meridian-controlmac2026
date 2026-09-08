import AppKit
import WebKit
import UniformTypeIdentifiers

final class ControlMacApp: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var web: WKWebView!
    let address = NSTextField(string: "")
    let status = NSTextField(labelWithString: "Enter your Core address")
    let importButton = NSButton(title: "Import FLAC…", target: nil, action: nil)
    var activeImport: Process?
    var core: URL?
    var probeOutput: String?
    var probeScheduled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit ControlMac 2026", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
        for (name, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: name, action: action, keyEquivalent: key)
        }
        editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "cmdebug")
        let debugScript = WKUserScript(source: """
        (function(){
          function send(kind, value){ try { window.webkit.messageHandlers.cmdebug.postMessage(kind + ': ' + String(value)); } catch(e) {} }
          try {
            var desc = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'src');
            Object.defineProperty(HTMLIFrameElement.prototype, 'src', {
              get: desc.get,
              set: function(v){
                if (String(v).indexOf('javascript:') === 0) { send('GWT_SHIM', 'iframe javascript URL -> about:blank'); v = 'about:blank'; }
                return desc.set.call(this, v);
              },
              configurable: true
            });
          } catch(e) { send('GWT_SHIM_ERROR', e); }
          window.addEventListener('error', function(e){ send('JS_ERROR', e.message + ' @ ' + e.filename + ':' + e.lineno + ':' + e.colno); });
          window.addEventListener('unhandledrejection', function(e){ send('PROMISE_REJECTION', e.reason); });
          send('DOC_START', location.href);
          var ticks = 0;
          setInterval(function(){
            if (++ticks <= 15) send('TICK', 'ready=' + document.readyState + ' scripts=' + document.scripts.length + ' frames=' + document.getElementsByTagName('iframe').length + ' body=' + (document.body ? document.body.innerHTML.length : -1));
          }, 1000);
          document.addEventListener('DOMContentLoaded', function(){ send('DOM_READY', 'frames=' + document.getElementsByTagName('iframe').length); });
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(debugScript)
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self; web.uiDelegate = self
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1240,height: 850),
                          styleMask: [.titled,.closable,.miniaturizable,.resizable],backing: .buffered,defer: false)
        window.title = "ControlMac 2026 — Preview"
        window.minSize = NSSize(width: 980,height: 650); window.isReleasedWhenClosed = false
        address.placeholderString = "Sooloos Core address"
        address.target = self; address.action = #selector(connect)
        let connectButton = NSButton(title: "Connect",target: self,action: #selector(connect))
        let reload = NSButton(title: "Reload",target: self,action: #selector(reloadPage))
        importButton.target = self; importButton.action = #selector(importFile)
        let toolbar = NSStackView(views: [address,connectButton,reload,importButton])
        toolbar.orientation = .horizontal; toolbar.spacing = 10
        let content = window.contentView!
        for v in [toolbar,status,web!] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        status.textColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor,constant: 14),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor,constant: 12),
            address.widthAnchor.constraint(equalToConstant: 340),
            status.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            status.topAnchor.constraint(equalTo: toolbar.bottomAnchor,constant: 8),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor,constant: -14),
            web.topAnchor.constraint(equalTo: status.bottomAnchor,constant: 10),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--probe-output"), args.indices.contains(i+1) { probeOutput = args[i+1] }
        address.stringValue = UserDefaults.standard.string(forKey: "core") ?? ""
        if let i = args.firstIndex(of: "--core"), args.indices.contains(i+1) { address.stringValue = args[i+1] }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if !address.stringValue.isEmpty { connect() }
    }
    @objc func connect() {
        let raw = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: raw.contains("://") ? raw : "http://"+raw),
              parts.scheme == "http", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { status.stringValue = "Enter the Core hostname or IP address"; return }
        parts.path = "/webclient/WebClient.html"
        parts.queryItems = [URLQueryItem(name: "platform",value: "web"),
                            URLQueryItem(name: "sysversion",value: "538"), URLQueryItem(name: "version",value: "474")]
        guard let url = parts.url else { return }
        core = url; UserDefaults.standard.set(raw,forKey: "core")
        status.stringValue = "Connecting to your music library…"; web.load(URLRequest(url: url))
    }
    @objc func reloadPage() { web.reload() }
    func alert(_ title: String, _ detail: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = detail; a.beginSheetModal(for: window)
    }
    @objc func importFile() {
        guard activeImport == nil, let host = core?.host else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "flac")!]
        panel.message = "Preview importer: one stereo 24-bit / 44.1 kHz FLAC. Put cover.jpg beside the track. Existing album titles are skipped."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let file = panel.url else { return }
            self.startImport(host: host,file: file)
        }
    }
    func startImport(host: String,file: URL) {
        guard let configURL = Bundle.main.url(forResource: "Backend",withExtension: "plist"),
              let config = NSDictionary(contentsOf: configURL),
              let mono = config["MonoRoot"] as? String, let managed = config["ManagedRoot"] as? String,
              let executable = Bundle.main.url(forResource: "ImportOne",withExtension: "exe") else {
            alert("Importer unavailable", "The local backend configuration is missing."); return
        }
        let p = Process(); p.executableURL = URL(fileURLWithPath: mono+"/bin/mono-sgen64")
        p.arguments = [executable.path,"--import",host,file.path]
        var env = ProcessInfo.processInfo.environment; env["MONO_PATH"] = mono+"/lib/mono/4.5:"+managed; p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        activeImport = p; importButton.isEnabled = false; status.stringValue = "Checking and importing \(file.lastPathComponent)…"
        do { try p.run() } catch { activeImport = nil; importButton.isEnabled = true; alert("Import could not start",error.localizedDescription); return }
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let text = String(data: data,encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.activeImport = nil; self.importButton.isEnabled = true
                if p.terminationStatus == 0 && text.contains("CORE CONFIRMED IMPORT COMPLETE") {
                    self.status.stringValue = "Import complete — audio and library entry verified"; self.web.reload()
                } else {
                    self.status.stringValue = "Import did not complete"
                    let reason = text.contains("avoid duplicates") ? "An album with this title already exists. No duplicate was imported." : String(text.suffix(1800))
                    self.alert("Import stopped",reason)
                }
            }
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        print("WEBKIT_DEBUG \(message.body)"); fflush(stdout)
    }
    func webView(_ webView: WKWebView,didFinish navigation: WKNavigation!) {
        print("WEBKIT_DID_FINISH \(webView.url?.absoluteString ?? "nil")"); fflush(stdout)
        if activeImport == nil { status.stringValue = "Core interface loaded · Import preview supports one 24-bit / 44.1 kHz FLAC" }
        if let output = probeOutput, !probeScheduled {
            probeScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now()+20) {
                self.web.evaluateJavaScript("JSON.stringify({href:location.href,ready:document.readyState,title:document.title,text:document.body.innerText,html:document.body.innerHTML,scripts:Array.from(document.scripts).map(s=>s.src)})") { value,error in
                    print("PAGE_STATE \(value ?? "nil") ERROR \(String(describing:error))"); fflush(stdout)
                }
                self.web.takeSnapshot(with: nil) { image,error in
                    if let data = image?.tiffRepresentation,let bitmap = NSBitmapImageRep(data: data),let png = bitmap.representation(using: .png,properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: output)); print("SNAPSHOT_SAVED"); fflush(stdout)
                    }
                }
            }
        }
    }
    func webView(_ webView: WKWebView,didFailProvisionalNavigation navigation: WKNavigation!,withError error: Error) { status.stringValue = error.localizedDescription }
    func webView(_ webView: WKWebView,runJavaScriptAlertPanelWithMessage message: String,initiatedByFrame frame: WKFrameInfo,completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = "Sooloos"; a.informativeText = message
        a.beginSheetModal(for: window) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView,runJavaScriptConfirmPanelWithMessage message: String,initiatedByFrame frame: WKFrameInfo,completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = "Confirm library change"; a.informativeText = message
        a.addButton(withTitle: "Continue"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if activeImport != nil { alert("Import running", "Wait for the current import to finish before quitting."); return .terminateCancel }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = ControlMacApp(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()

