import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// A small window showing a grid of saved videos. Drop video files anywhere in
/// it to add them; click one to set it as the wallpaper; hover-click the × to
/// remove it from the library.
final class LibraryWindowController: NSObject, NSWindowDelegate,
                                     NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let engine: WallpaperEngine
    private var window: NSWindow?
    private var collectionView: NSCollectionView!
    private var emptyLabel: NSTextField!
    private var urls: [URL] = []

    private let itemID = NSUserInterfaceItemIdentifier("LibraryItem")

    init(engine: WallpaperEngine) {
        self.engine = engine
        super.init()
    }

    // MARK: - Presentation

    func show() {
        if window == nil { buildWindow() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.title = "Video Library"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 440, height: 320)
        win.delegate = self
        win.center()

        let container = NSView()

        // Grid
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 196, height: 150)
        layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 14

        let cv = NSCollectionView()
        cv.collectionViewLayout = layout
        cv.dataSource = self
        cv.delegate = self
        cv.isSelectable = true
        cv.allowsEmptySelection = true
        cv.allowsMultipleSelection = false
        cv.backgroundColors = [.clear]
        cv.register(LibraryCollectionViewItem.self, forItemWithIdentifier: itemID)
        cv.registerForDraggedTypes([.fileURL])
        cv.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView = cv

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = cv
        container.addSubview(scroll)

        // Empty-state hint
        let empty = NSTextField(labelWithString:
            "No videos yet.\nDrag & drop video files here, or click “Add Video…”.")
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.alignment = .center
        empty.maximumNumberOfLines = 0
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 13)
        empty.isHidden = true
        emptyLabel = empty
        container.addSubview(empty)

        // Bottom bar
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true

        let addButton = NSButton(title: "Add Video…", target: self, action: #selector(addClicked))
        addButton.bezelStyle = .rounded
        addButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(addButton)

        let hint = NSTextField(labelWithString: "Drag & drop videos here, then click one to set it as your wallpaper.")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.lineBreakMode = .byTruncatingTail
        bar.addSubview(hint)

        container.addSubview(bar)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),

            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            empty.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 48),

            addButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            addButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            hint.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 14),
            hint.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            hint.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        win.contentView = container
        window = win
    }

    // MARK: - Data

    private func reload() {
        urls = Settings.shared.library.filter { FileManager.default.fileExists(atPath: $0.path) }
        collectionView?.reloadData()
        emptyLabel?.isHidden = !urls.isEmpty
    }

    private func remove(_ url: URL) {
        Settings.shared.removeFromLibrary(url)
        reload()
    }

    @objc private func addClicked() {
        let panel = NSOpenPanel()
        panel.title = "Add Videos"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            Settings.shared.addToLibrary(panel.urls)
            reload()
        }
    }

    private func movieURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.movie.identifier],
        ]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    // MARK: - NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        urls.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: itemID, for: indexPath) as! LibraryCollectionViewItem
        let url = urls[indexPath.item]
        item.configure(url: url, isCurrent: url.path == Settings.shared.videoURL?.path)
        item.onDelete = { [weak self] in self?.remove(url) }
        return item
    }

    // MARK: - NSCollectionViewDelegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let ip = indexPaths.first, ip.item < urls.count else { return }
        engine.load(url: urls[ip.item])
        DispatchQueue.main.async { [weak self] in self?.reload() } // refresh the "current" ring
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        movieURLs(from: draggingInfo).isEmpty ? [] : .copy
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let dropped = movieURLs(from: draggingInfo)
        guard !dropped.isEmpty else { return false }
        Settings.shared.addToLibrary(dropped)
        reload()
        return true
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        reload() // the wallpaper may have changed via the menu while we were hidden
    }
}

/// One thumbnail tile in the library grid.
final class LibraryCollectionViewItem: NSCollectionViewItem {
    private let thumb = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton()
    private var url: URL?
    var onDelete: (() -> Void)?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 10
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55).cgColor
        root.layer?.borderWidth = 2.5
        root.layer?.borderColor = NSColor.clear.cgColor

        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        root.addSubview(thumb)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.textColor = .labelColor
        root.addSubview(nameLabel)

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.isBordered = false
        deleteButton.bezelStyle = .shadowlessSquare
        deleteButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove")
        deleteButton.imagePosition = .imageOnly
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.toolTip = "Remove from library"
        root.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            thumb.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            thumb.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            thumb.heightAnchor.constraint(equalTo: thumb.widthAnchor, multiplier: 9.0 / 16.0),

            nameLabel.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -6),

            deleteButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 3),
            deleteButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -3),
            deleteButton.widthAnchor.constraint(equalToConstant: 20),
            deleteButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        view = root
    }

    func configure(url: URL, isCurrent: Bool) {
        self.url = url
        nameLabel.stringValue = url.deletingPathExtension().lastPathComponent
        setCurrent(isCurrent)
        thumb.image = nil
        ThumbnailCache.shared.thumbnail(for: url) { [weak self] image in
            guard let self, self.url == url else { return }
            self.thumb.image = image
        }
    }

    private func setCurrent(_ current: Bool) {
        view.layer?.borderColor = current ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
    }

    @objc private func deleteClicked() { onDelete?() }
}

/// Lazily generates and caches a poster frame for each video.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [String: NSImage] = [:]
    private let queue = DispatchQueue(label: "com.praniil.livewall.thumbnails", qos: .utility)

    /// `completion` is always called on the main thread.
    func thumbnail(for url: URL, completion: @escaping (NSImage?) -> Void) {
        if let cached = cache[url.path] { completion(cached); return }
        queue.async {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 360)

            // Prefer a frame ~1s in; fall back to the very first frame for short clips.
            let cg = (try? generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil))
                ?? (try? generator.copyCGImage(at: .zero, actualTime: nil))
            let image = cg.map { NSImage(cgImage: $0, size: .zero) }

            DispatchQueue.main.async {
                if let image { self.cache[url.path] = image }
                completion(image)
            }
        }
    }
}
