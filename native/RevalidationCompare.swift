import AppKit

struct RevalidationCompareRow {
    let localNumber: String
    let localTitle: String
    let remoteDisc: String
    let remoteNumber: String
    let remoteTitle: String
    let status: String
}

final class RevalidationCompareController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    private let rows: [RevalidationCompareRow]
    private let table = NSTableView()
    private let onApply: () -> Void

    init(title: String, subtitle: String, rows: [RevalidationCompareRow], onApply: @escaping () -> Void) {
        self.rows = rows
        self.onApply = onApply
        self.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 680),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.minSize = NSSize(width: 880, height: 500)
        window.isReleasedWhenClosed = false

        let heading = NSTextField(wrappingLabelWithString: subtitle)
        heading.font = .systemFont(ofSize: 13, weight: .medium)
        heading.textColor = .secondaryLabelColor

        table.headerView = NSTableHeaderView()
        table.rowHeight = 30
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self; table.dataSource = self

        func add(_ id: String, _ title: String, _ width: CGFloat) {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); c.title = title; c.width = width
            table.addTableColumn(c)
        }
        add("localNo", "Sooloos #", 70)
        add("localTitle", "Sooloos track", 320)
        add("remoteDisc", "Disc", 55)
        add("remoteNo", "Lookup #", 70)
        add("remoteTitle", "Lookup track", 320)
        add("status", "Match", 180)

        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let apply = NSButton(title: "OK — Apply Validated Metadata", target: self, action: #selector(applyAndClose))
        apply.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeWindow))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, apply]); buttons.orientation = .horizontal; buttons.spacing = 8

        let content = window.contentView!
        for v in [heading, scroll, buttons] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }

    @objc private func applyAndClose() {
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
        onApply()
    }

    @objc private func closeWindow() {
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let r = rows[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "localNo": value = r.localNumber
        case "localTitle": value = r.localTitle
        case "remoteDisc": value = r.remoteDisc
        case "remoteNo": value = r.remoteNumber
        case "remoteTitle": value = r.remoteTitle
        case "status": value = r.status
        default: value = ""
        }
        let cell = NSTextField(labelWithString: value)
        cell.lineBreakMode = .byTruncatingTail
        cell.toolTip = value
        return cell
    }
}
