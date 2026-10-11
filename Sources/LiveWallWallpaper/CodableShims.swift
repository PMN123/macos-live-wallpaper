// LiveWallWallpaper — Codable mirrors of WallpaperTypes' settings view-model types.
//
// Adapted from Phosphene (https://github.com/kageroumado/phosphene), MIT License, © 2026 kageroumado
// Source: PhospheneExtension/CodableShims.swift at commit db03edf. See THIRD_PARTY_NOTICES.md.
//
// These shapes encode to the same keyed archive as the private WallpaperTypes values,
// so an archive of LiveWallShimViewModelsXPC decodes as WallpaperSettingsViewModelsXPC
// (see SettingsProvider.swift). Property names and enum case names are load-bearing.
// Trimmed to the cases M1 uses; Phosphene's file has the custom-button thumbnail too.

import Foundation

struct SettingsViewModels: Codable {
    var desktop: SettingsViewModel?
    var screenSaver: SettingsViewModel?
}

struct SettingsViewModel: Codable {
    var groups: [SettingsGroup]
    var refreshPolicy: RefreshPolicy
    var isModificationDisabled: Bool
}

struct SettingsGroup: Codable {
    var id: GroupID
    var items: [SettingsItem]
    var localizedName: String
    var disposability: Disposability
    var sortOrder: Int
    var sortID: GroupSortID?
    var allChoiceID: ChoiceID?
    var shouldHideItemLabels: Bool?
    var contextMenu: ContextMenu?
    var thumbnail: Data?
}

/// Real type: WallpaperTypes.WallpaperDisposability — cases none, removable, purgeable.
enum Disposability: Codable {
    case none
    case removable
    case purgeable

    private enum CodingKeys: String, CodingKey {
        case none
        case removable
        case purgeable
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .none)
        case .removable:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .removable)
        case .purgeable:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .purgeable)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.removable) {
            self = .removable
        } else if container.contains(.purgeable) {
            self = .purgeable
        } else {
            self = .none
        }
    }
}

/// ID types use a keyed container with an "id" property.
struct GroupID: Codable {
    var id: String
}

struct GroupSortID: Codable {
    var id: String
}

struct ChoiceID: Codable {
    var id: String
    var descriptor: ChoiceIDDescriptor
}

/// Nested descriptor inside WallpaperChoiceID — provider and the opaque configuration
/// bytes the agent hands back in every acquire.
struct ChoiceIDDescriptor: Codable {
    var provider: ChoiceProviderID
    var identifier: String
    var files: [URL]
    var configuration: Data
}

struct SettingsItem: Codable {
    var id: ChoiceID
    var localizedName: String
    var thumbnail: Thumbnail
    var choice: ChoiceDescriptor
    var contentBadge: ContentBadge
    var showInTopLevel: Bool
    var sortOrder: Int
    var disposability: Disposability
    var contextMenu: ContextMenu?
}

/// WallpaperSettingsItem.ContentBadge — cases none, video, dynamic.
enum ContentBadge: Codable {
    case none
    case video
    case dynamic

    private enum CodingKeys: String, CodingKey {
        case none
        case video
        case dynamic
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .none)
        case .video:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .video)
        case .dynamic:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .dynamic)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.video) {
            self = .video
        } else if container.contains(.dynamic) {
            self = .dynamic
        } else {
            self = .none
        }
    }
}

/// WallpaperThumbnail — real cases: image, solidColor, customButton, shuffleColors,
/// shuffleImages, currentColorOption. Only image and shuffleImages are modelled.
enum Thumbnail: Codable {
    case image(url: URL)
    case shuffleImages(urls: [URL])

    private enum CodingKeys: String, CodingKey {
        case image
        case shuffleImages
    }

    private enum ImageCodingKeys: String, CodingKey {
        case url
    }

    private enum ShuffleImagesCodingKeys: String, CodingKey {
        case urls
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .image(url):
            var nested = container.nestedContainer(keyedBy: ImageCodingKeys.self, forKey: .image)
            try nested.encode(url, forKey: .url)
        case let .shuffleImages(urls):
            var nested = container.nestedContainer(keyedBy: ShuffleImagesCodingKeys.self, forKey: .shuffleImages)
            try nested.encode(urls, forKey: .urls)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.shuffleImages) {
            let nested = try container.nestedContainer(keyedBy: ShuffleImagesCodingKeys.self, forKey: .shuffleImages)
            self = .shuffleImages(urls: try nested.decode([URL].self, forKey: .urls))
        } else {
            let nested = try container.nestedContainer(keyedBy: ImageCodingKeys.self, forKey: .image)
            self = .image(url: try nested.decode(URL.self, forKey: .url))
        }
    }
}

struct ChoiceDescriptor: Codable {
    var id: ChoiceID
    var provider: ChoiceProviderID
    var identifier: String
    var name: String?
    var localizedDescription: String
    var thumbnail: Thumbnail
    var isDownloaded: Bool
    var options: [WallpaperOption]
}

/// Real type: WallpaperTypes.WallpaperOptionEnum — per-choice controls in the wallpaper
/// header. Cases: picker, color, toggle, group, button; payloads use the synthesized
/// `_0` key. Only picker is modelled (M1 sends no options).
enum WallpaperOption: Codable {
    case picker(MenuPickerOption)

    private enum CodingKeys: String, CodingKey {
        case picker
    }

    private enum PayloadCodingKeys: String, CodingKey {
        case _0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .picker(option):
            var nested = container.nestedContainer(keyedBy: PayloadCodingKeys.self, forKey: .picker)
            try nested.encode(option, forKey: ._0)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try container.nestedContainer(keyedBy: PayloadCodingKeys.self, forKey: .picker)
        self = .picker(try nested.decode(MenuPickerOption.self, forKey: ._0))
    }
}

/// Real type: WallpaperTypes.MenuPickerOption.
struct MenuPickerOption: Codable {
    var id: String
    var localizedLabel: String
    var defaultValueID: String
    var accessibilityIdentifier: String?
    var localizedInformativeText: String?
    var items: [MenuPickerItemEnum]
}

/// Real type: WallpaperTypes.MenuPickerItemEnum — cases item, divider (payload `_0`).
enum MenuPickerItemEnum: Codable {
    case item(MenuPickerItem)
    case divider(MenuPickerDivider)

    private enum CodingKeys: String, CodingKey {
        case item
        case divider
    }

    private enum PayloadCodingKeys: String, CodingKey {
        case _0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .item(item):
            var nested = container.nestedContainer(keyedBy: PayloadCodingKeys.self, forKey: .item)
            try nested.encode(item, forKey: ._0)
        case let .divider(divider):
            var nested = container.nestedContainer(keyedBy: PayloadCodingKeys.self, forKey: .divider)
            try nested.encode(divider, forKey: ._0)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.item) {
            let nested = try container.nestedContainer(keyedBy: PayloadCodingKeys.self, forKey: .item)
            self = .item(try nested.decode(MenuPickerItem.self, forKey: ._0))
        } else {
            let nested = try container.nestedContainer(keyedBy: PayloadCodingKeys.self, forKey: .divider)
            self = .divider(try nested.decode(MenuPickerDivider.self, forKey: ._0))
        }
    }
}

/// Real type: WallpaperTypes.MenuPickerItem. The macOS 27 decoder requires
/// `isDownloaded`; the macOS 26 decoder ignores the extra key (Phosphene #29).
struct MenuPickerItem: Codable {
    var id: String
    var localizedName: String
    var accessibilityIdentifier: String?
    var localizedInformativeText: String?
    var isDownloaded: Bool
}

struct MenuPickerDivider: Codable {
    var id: String
}

/// Encodes as a plain string (single-value container).
struct ChoiceProviderID: Codable {
    var rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }
}

enum RefreshPolicy: Codable {
    case `default`

    private enum CodingKeys: String, CodingKey {
        case `default`
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .default)
    }

    init(from _: Decoder) throws {
        self = .default
    }
}

/// Real type: WallpaperTypes.ContextMenu { items: [ContextMenuItem] }.
struct ContextMenu: Codable {
    var items: [ContextMenuItem]
}

/// Real type: WallpaperTypes.ContextMenuItem.
struct ContextMenuItem: Codable {
    var id: ContextMenuItemID
    var localizedTitle: String
    var isDestructive: Bool
}

struct ContextMenuItemID: Codable {
    var id: String
}

enum EmptyCodingKeys: CodingKey {}

/// NSObject wrapper that encodes SettingsViewModels under the same key the real
/// WallpaperSettingsViewModelsXPC decodes.
@objc(LiveWallShimViewModelsXPC)
final class LiveWallShimViewModelsXPC: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    static let archivedClassName = "LiveWallShimViewModelsXPC"
    let value: SettingsViewModels

    init(value: SettingsViewModels) {
        self.value = value
        super.init()
    }

    required init?(coder _: NSCoder) {
        // Never decoded as this class: the archive is decoded as the real private type.
        return nil
    }

    func encode(with coder: NSCoder) {
        guard let archiver = coder as? NSKeyedArchiver else {
            extensionError("  [ShimXPC] encode error: coder is not NSKeyedArchiver")
            return
        }
        do {
            try archiver.encodeEncodable(value, forKey: "WallpaperSettingsViewModels")
        } catch {
            extensionError("  [ShimXPC] encode error: \(error)")
        }
    }
}
