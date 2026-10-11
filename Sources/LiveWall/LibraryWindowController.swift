import AppKit
import AVFoundation
import LiveWallShared
import UniformTypeIdentifiers

/// A small window showing a grid of saved videos. Drop video files or folders anywhere
/// in it to add them; click one to set it as the wallpaper; click the × on a tile to
/// remove it from the library. In system wallpaper mode every video here is also a
/// tile in System Settings › Wallpaper, and the videos macOS is playing are marked.
final class LibraryWindowController: NSObject, NSWindowDelegate,
                                     NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let engine: WallpaperEngine
    /// Present on macOS 26 and later only.
    private let systemWallpaper: SystemWallpaperBridge?
    private var window: NSWindow?
    private var collectionView: NSCollectionView!
    private var emptyLabel: NSTextField!
    private var hintLabel: NSTextField!
    private var hintReset: DispatchWorkItem?
    private var urls: [URL] = []
    /// Library videos whose file is gone (moved, deleted, volume not mounted).
    private var missing = Set<String>()
    /// Library videos the system wallpaper is playing.
    private var onDesktop = Set<String>()

    private let itemID = NSUserInterfaceItemIdentifier("LibraryItem")
    private static let defaultHint = "Drag & drop videos or folders here, then click one to set it as your wallpaper."

    init(engine: WallpaperEngine, systemWallpaper: SystemWallpaperBridge?) {
        self.engine = engine
        self.systemWallpaper = systemWallpaper
        super.init()
    }

    /// The system wallpaper's status or what it plays changed.
    func systemWallpaperStatusChanged() {
        guard window?.isVisible == true else { return }
        reload()
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

        let container = VideoDropView()
        container.onDrop = { [weak self] urls in
            self?.add(urls)
        }

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
            "No videos yet.\nDrag & drop videos or a folder of videos here, or click “Add Video…”.")
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

        let addFolderButton = NSButton(title: "Add Folder…", target: self, action: #selector(addFolderClicked))
        addFolderButton.bezelStyle = .rounded
        addFolderButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(addFolderButton)

        let hint = NSTextField(labelWithString: Self.defaultHint)
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.addSubview(hint)
        hintLabel = hint

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

            addFolderButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 8),
            addFolderButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            hint.leadingAnchor.constraint(equalTo: addFolderButton.trailingAnchor, constant: 14),
            hint.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            hint.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        win.contentView = container
        window = win
    }

    // MARK: - Data

    private func reload() {
        // Videos whose file is gone stay listed (dimmed) so they can be removed: in
        // system wallpaper mode their tile keeps playing LiveWall's copy until then.
        urls = Settings.shared.library
        missing = Set(urls.map(\.path).filter { !FileManager.default.fileExists(atPath: $0) })
        onDesktop = systemWallpaper?.libraryPathsPlayedBySystem() ?? []
        collectionView?.reloadData()
        emptyLabel?.isHidden = !urls.isEmpty
    }

    private func remove(_ url: URL) {
        Settings.shared.removeFromLibrary(url)
        reload()
    }

    /// Add videos (folders contribute the videos directly inside them).
    private func add(_ dropped: [URL]) {
        let videos = Self.expandMovieURLs(dropped)
        guard !videos.isEmpty else {
            flashHint("No videos found there.")
            return
        }
        let added = Settings.shared.addToLibrary(videos)
        reload()
        if videos.count > 1 || added == 0 {
            flashHint(added == 0 ? "Already in the library." : "Added \(added) video\(added == 1 ? "" : "s").")
        }
    }

    /// Show `text` in the bottom bar for a few seconds.
    private func flashHint(_ text: String, seconds: TimeInterval = 4) {
        guard let hintLabel else { return }
        hintReset?.cancel()
        hintLabel.stringValue = text
        hintLabel.textColor = .labelColor
        let work = DispatchWorkItem { [weak self] in
            self?.hintLabel?.stringValue = Self.defaultHint
            self?.hintLabel?.textColor = .secondaryLabelColor
        }
        hintReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    @objc private func addClicked() {
        let panel = NSOpenPanel()
        panel.title = "Add Videos"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            add(panel.urls)
        }
    }

    @objc private func addFolderClicked() {
        let panel = NSOpenPanel()
        panel.title = "Add Folders of Videos"
        panel.message = "LiveWall adds the videos directly inside each folder you choose."
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK {
            add(panel.urls)
        }
    }

    /// The file URLs being dragged: videos and folders (expanded on drop).
    static func droppedFileURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    /// Whether a drag carries something worth adding. Cheap: folders are not listed
    /// until the drop.
    static func canAccept(_ info: NSDraggingInfo) -> Bool {
        droppedFileURLs(from: info).contains { isMovie($0) || isFolder($0) }
    }

    /// Videos among `urls`, with each folder replaced by the videos directly inside it
    /// (by name, hidden files skipped).
    static func expandMovieURLs(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            if isFolder(url) {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles])) ?? []
                result += children.filter(isMovie).sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
            } else if isMovie(url) {
                result.append(url)
            }
        }
        return result
    }

    private static func isMovie(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .movie) == true
    }

    private static func isFolder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true
    }

    // MARK: - NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        urls.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: itemID, for: indexPath) as! LibraryCollectionViewItem
        let url = urls[indexPath.item]
        item.configure(url: url, isCurrent: url.path == Settings.shared.videoURL?.path,
                       isMissing: missing.contains(url.path), isOnDesktop: onDesktop.contains(url.path))
        item.onDelete = { [weak self] in self?.remove(url) }
        return item
    }

    // MARK: - NSCollectionViewDelegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let ip = indexPaths.first, ip.item < urls.count else { return }
        let url = urls[ip.item]
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            collectionView.deselectItems(at: indexPaths)
            flashHint("“\(url.lastPathComponent)” is missing. Remove it with ×, or add it again from its new place.", seconds: 6)
            return
        }
        engine.load(url: url)
        if systemWallpaper?.shouldHintFixedTiles() == true {
            flashHint("Every desktop uses a fixed video tile, so picks here change only the “Current Video” tile in System Settings › Wallpaper.", seconds: 8)
        }
        DispatchQueue.main.async { [weak self] in self?.reload() } // refresh the "current" ring
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        Self.canAccept(draggingInfo) ? .copy : []
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let dropped = Self.droppedFileURLs(from: draggingInfo)
        guard Self.canAccept(draggingInfo) else { return false }
        add(dropped)
        return true
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        reload() // the wallpaper may have changed via the menu while we were hidden
    }
}

/// The window's root view: accepts dropped videos outside the grid too — on the
/// bottom bar (whose hint says "Drag & drop videos here") and the empty-state text.
final class VideoDropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        LibraryWindowController.canAccept(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard LibraryWindowController.canAccept(sender) else { return false }
        onDrop?(LibraryWindowController.droppedFileURLs(from: sender))
        return true
    }
}

/// One thumbnail tile in the library grid.
final class LibraryCollectionViewItem: NSCollectionViewItem {
    private let thumb = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton()
    /// "On Desktop": the system wallpaper plays this video.
    private let badge = NSTextField(labelWithString: "On Desktop")
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

        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.masksToBounds = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        badge.toolTip = "macOS is playing this video as the system wallpaper"
        badge.isHidden = true
        root.addSubview(badge)

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

            badge.leadingAnchor.constraint(equalTo: thumb.leadingAnchor, constant: 5),
            badge.bottomAnchor.constraint(equalTo: thumb.bottomAnchor, constant: -5),
            badge.widthAnchor.constraint(equalToConstant: 72),
        ])

        view = root
    }

    func configure(url: URL, isCurrent: Bool, isMissing: Bool = false, isOnDesktop: Bool = false) {
        self.url = url
        let name = SharedVideoNames.displayName(forFileName: url.lastPathComponent)
        nameLabel.stringValue = isMissing ? "\(name) (missing)" : name
        nameLabel.textColor = isMissing ? .secondaryLabelColor : .labelColor
        view.toolTip = isMissing ? "File not found: \(url.path)" : url.lastPathComponent
        thumb.alphaValue = isMissing ? 0.4 : 1
        badge.isHidden = !isOnDesktop
        setCurrent(isCurrent)
        thumb.image = nil
        guard !isMissing else { return }
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
