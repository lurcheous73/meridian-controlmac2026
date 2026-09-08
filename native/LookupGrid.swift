import AppKit
import Foundation

final class ArtworkGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ArtworkGridItem")
    private let art = NSImageView()
    private let caption = NSTextField(wrappingLabelWithString: "")
    private var representedID = ""

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        art.imageScaling = .scaleProportionallyUpOrDown
        art.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        caption.font = .systemFont(ofSize: 11)
        caption.alignment = .center
        caption.maximumNumberOfLines = 4
        for v in [art, caption] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        NSLayoutConstraint.activate([
            art.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            art.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            art.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            art.heightAnchor.constraint(equalTo: art.widthAnchor),
            caption.topAnchor.constraint(equalTo: art.bottomAnchor, constant: 6),
            caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6)
        ])
    }
    func configure(_ c: ArtworkLookupCandidate) {
        representedID = c.source + "|" + c.sourceID
        art.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        let detail = c.detail.isEmpty ? c.source : "\(c.source) · \(c.detail)"
        caption.stringValue = "\(c.artist)\n\(c.title)\n\(detail)"
        guard let url = c.thumbURL else { return }
        let expected = representedID
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(LookupService.userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard self.representedID == expected else { return }
                self.art.image = image
            }
        }.resume()
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 3 : 0
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }
}

final class ArtworkGridController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let window: NSWindow
    private let collection = NSCollectionView()
    private let candidates: [ArtworkLookupCandidate]
    private let onPick: (ArtworkLookupCandidate) -> Void
    private let onSearch: (String, String) -> Void
    private let artistField = NSTextField(string: "")
    private let albumField = NSTextField(string: "")
    private let okButton = NSButton(title: "OK", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    init(title: String, subtitle: String, artist: String, album: String, candidates: [ArtworkLookupCandidate],
         onSearch: @escaping (String, String) -> Void, onPick: @escaping (ArtworkLookupCandidate) -> Void) {
        self.candidates = candidates
        self.onPick = onPick
        self.onSearch = onSearch
        self.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: subtitle)
        heading.font = .systemFont(ofSize: 13, weight: .medium)
        heading.textColor = .secondaryLabelColor
        artistField.stringValue = artist; artistField.placeholderString = "Artist"
        albumField.stringValue = album; albumField.placeholderString = "Album"
        let searchButton = NSButton(title: "Search", target: self, action: #selector(searchAgain))
        let searchRow = NSStackView(views: [artistField, albumField, searchButton])
        searchRow.orientation = .horizontal; searchRow.spacing = 8
        artistField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        albumField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 210, height: 275)
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 14
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.register(ArtworkGridItem.self, forItemWithIdentifier: ArtworkGridItem.identifier)
        collection.dataSource = self
        collection.delegate = self
        okButton.target = self; okButton.action = #selector(acceptSelection); okButton.keyEquivalent = "\r"
        cancelButton.target = self; cancelButton.action = #selector(cancelSelection); cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancelButton, okButton])
        buttons.orientation = .horizontal; buttons.spacing = 8
        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        heading.translatesAutoresizingMaskIntoConstraints = false
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(heading); content.addSubview(searchRow); content.addSubview(scroll); content.addSubview(buttons)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            searchRow.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            searchRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            searchRow.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        if !candidates.isEmpty {
            collection.selectItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: .top)
        }
    }


    @objc private func searchAgain() {
        let artist = artistField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = albumField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty || !album.isEmpty else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
        onSearch(artist, album)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        candidates.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ArtworkGridItem.identifier, for: indexPath) as! ArtworkGridItem
        item.configure(candidates[indexPath.item])
        return item
    }

    @objc private func acceptSelection() {
        guard let index = collection.selectionIndexPaths.first?.item, index < candidates.count else { return }
        let chosen = candidates[index]
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
        onPick(chosen)
    }

    @objc private func cancelSelection() {
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        okButton.isEnabled = !indexPaths.isEmpty
    }
}
