import Foundation
import UIKit

// MARK: - Data Models

struct StickerPackSticker {
  let id: String
  let packId: String
  let bundleFileName: String?   // e.g. "cat_love" → loads cat_love.json from resource bundle
  let remoteUrl: String?        // future: remote Lottie JSON URL
  let emoji: String?
  let width: Int
  let height: Int
}

struct StickerPack {
  let id: String
  let name: String
  let icon: String              // emoji icon for the pack tab strip
  let author: String
  let stickers: [StickerPackSticker]
  let source: StickerPackSource
  let version: Int
}

enum StickerPackSource {
  case bundled
  case remote
}

// MARK: - Recent Sticker

struct RecentSticker {
  let stickerId: String
  let packId: String
  let bundleFileName: String?
  let remoteUrl: String?
  let usedAt: TimeInterval
}

// MARK: - Store

final class ChatStickerPackStore {
  static let shared = ChatStickerPackStore()

  private(set) var installedPacks: [StickerPack] = []
  private(set) var recentStickers: [RecentSticker] = []

  private let maxRecent = 30
  private let recentDefaultsKey = "chat.sticker.pack.recent"
  private let installedOrderDefaultsKey = "chat.sticker.pack.installed.order"

  private init() {
    installedPacks = Self.bundledPacks()
    loadRecentStickers()
    loadInstalledOrder()
  }

  // MARK: - Bundled Packs

  private static func bundledPacks() -> [StickerPack] {
    [
      StickerPack(
        id: "vibe_cats",
        name: "Cats",
        icon: "🐱",
        author: "Vibe",
        stickers: [
          StickerPackSticker(
            id: "cats_love", packId: "vibe_cats",
            bundleFileName: "cat_love", remoteUrl: nil,
            emoji: "❤️", width: 512, height: 512),
          StickerPackSticker(
            id: "cats_play", packId: "vibe_cats",
            bundleFileName: "cat_play", remoteUrl: nil,
            emoji: "🎮", width: 512, height: 512),
          StickerPackSticker(
            id: "cats_loader", packId: "vibe_cats",
            bundleFileName: "cat_loader", remoteUrl: nil,
            emoji: "😺", width: 512, height: 512),
        ],
        source: .bundled,
        version: 1
      ),
      StickerPack(
        id: "vibe_emoji",
        name: "Emoji",
        icon: "😜",
        author: "Vibe",
        stickers: [
          StickerPackSticker(
            id: "emoji_wink", packId: "vibe_emoji",
            bundleFileName: "emoji_wink", remoteUrl: nil,
            emoji: "😉", width: 512, height: 512),
          StickerPackSticker(
            id: "emoji_smiley", packId: "vibe_emoji",
            bundleFileName: "emoji_smiley", remoteUrl: nil,
            emoji: "😊", width: 512, height: 512),
          StickerPackSticker(
            id: "emoji_lmao", packId: "vibe_emoji",
            bundleFileName: "emoji_lmao", remoteUrl: nil,
            emoji: "🤣", width: 512, height: 512),
          StickerPackSticker(
            id: "emoji_test", packId: "vibe_emoji",
            bundleFileName: "emoji_test", remoteUrl: nil,
            emoji: "🙂", width: 512, height: 512),
        ],
        source: .bundled,
        version: 1
      ),
      StickerPack(
        id: "vibe_fun",
        name: "Fun",
        icon: "🎪",
        author: "Vibe",
        stickers: [
          StickerPackSticker(
            id: "fun_orange", packId: "vibe_fun",
            bundleFileName: "fun_orange", remoteUrl: nil,
            emoji: "🍊", width: 512, height: 512),
          StickerPackSticker(
            id: "fun_potato", packId: "vibe_fun",
            bundleFileName: "fun_potato", remoteUrl: nil,
            emoji: "🥔", width: 512, height: 512),
          StickerPackSticker(
            id: "fun_groovy", packId: "vibe_fun",
            bundleFileName: "fun_groovy", remoteUrl: nil,
            emoji: "🕺", width: 512, height: 512),
          StickerPackSticker(
            id: "fun_coffee", packId: "vibe_fun",
            bundleFileName: "fun_coffee", remoteUrl: nil,
            emoji: "☕️", width: 512, height: 512),
        ],
        source: .bundled,
        version: 1
      ),
    ]
  }

  // MARK: - Resource Bundle

  /// Resolves the resource bundle that contains sticker pack Lottie JSON files.
  static func resourceBundle() -> Bundle? {
    // CocoaPods resource bundles are embedded inside the framework bundle.
    // Try the module's own bundle first, then fall back to main.
    let moduleBundle = Bundle(for: ChatStickerPackStore.self)
    var candidates: [Bundle] = [moduleBundle, Bundle.main]

    // Also try any .bundle inside the module bundle (resource_bundles creates these)
    if let resourceBundles = moduleBundle.urls(
      forResourcesWithExtension: "bundle", subdirectory: nil)
    {
      for url in resourceBundles {
        if let nested = Bundle(url: url) {
          candidates.append(nested)
        }
      }
    }

    for bundle in candidates {
      // Check with subdirectory structure
      if bundle.path(
        forResource: "cat_love", ofType: "json", inDirectory: "StickerPacks/cats") != nil
      {
        NSLog("[StickerPackStore] resourceBundle found (subdir) in %@", bundle.bundlePath)
        return bundle
      }
      // Check flat layout
      if bundle.path(forResource: "cat_love", ofType: "json") != nil {
        NSLog("[StickerPackStore] resourceBundle found (flat) in %@", bundle.bundlePath)
        return bundle
      }
    }
    NSLog(
      "[StickerPackStore] resourceBundle NOT FOUND! moduleBundle=%@ mainBundle=%@",
      moduleBundle.bundlePath, Bundle.main.bundlePath)
    return nil
  }

  /// Returns the file path for a bundled sticker's Lottie JSON.
  func lottieFilePath(for sticker: StickerPackSticker) -> String? {
    guard let fileName = sticker.bundleFileName else { return nil }
    guard let bundle = Self.resourceBundle() else {
      NSLog("[StickerPackStore] lottieFilePath: no resource bundle for %@", fileName)
      return nil
    }

    // Try subdirectory first (StickerPacks/<packSubdir>/)
    let packSubdir: String? = {
      switch sticker.packId {
      case "vibe_cats": return "StickerPacks/cats"
      case "vibe_emoji": return "StickerPacks/emoji"
      case "vibe_fun": return "StickerPacks/fun"
      default: return nil
      }
    }()
    if let subdir = packSubdir,
      let path = bundle.path(forResource: fileName, ofType: "json", inDirectory: subdir)
    {
      return path
    }
    // Fallback: flat lookup
    if let path = bundle.path(forResource: fileName, ofType: "json") {
      return path
    }
    NSLog(
      "[StickerPackStore] lottieFilePath: NOT FOUND file=%@ pack=%@ bundle=%@",
      fileName, sticker.packId, bundle.bundlePath)
    return nil
  }

  // MARK: - Pack Access

  func pack(byId packId: String) -> StickerPack? {
    installedPacks.first(where: { $0.id == packId })
  }

  func sticker(byId stickerId: String) -> StickerPackSticker? {
    for pack in installedPacks {
      if let sticker = pack.stickers.first(where: { $0.id == stickerId }) {
        return sticker
      }
    }
    return nil
  }

  // MARK: - Recent Stickers

  func recordUsed(sticker: StickerPackSticker) {
    recentStickers.removeAll(where: { $0.stickerId == sticker.id })
    let recent = RecentSticker(
      stickerId: sticker.id,
      packId: sticker.packId,
      bundleFileName: sticker.bundleFileName,
      remoteUrl: sticker.remoteUrl,
      usedAt: Date().timeIntervalSince1970
    )
    recentStickers.insert(recent, at: 0)
    if recentStickers.count > maxRecent {
      recentStickers = Array(recentStickers.prefix(maxRecent))
    }
    persistRecentStickers()
  }

  // MARK: - Persistence

  private func persistRecentStickers() {
    let encoded = recentStickers.map { recent -> [String: Any] in
      var dict: [String: Any] = [
        "stickerId": recent.stickerId,
        "packId": recent.packId,
        "usedAt": recent.usedAt,
      ]
      if let name = recent.bundleFileName { dict["bundleFileName"] = name }
      if let url = recent.remoteUrl { dict["remoteUrl"] = url }
      return dict
    }
    UserDefaults.standard.set(encoded, forKey: recentDefaultsKey)
  }

  private func loadRecentStickers() {
    guard let stored = UserDefaults.standard.array(forKey: recentDefaultsKey) as? [[String: Any]]
    else { return }
    recentStickers = stored.compactMap { dict in
      guard let stickerId = dict["stickerId"] as? String,
        let packId = dict["packId"] as? String,
        let usedAt = dict["usedAt"] as? TimeInterval
      else { return nil }
      return RecentSticker(
        stickerId: stickerId,
        packId: packId,
        bundleFileName: dict["bundleFileName"] as? String,
        remoteUrl: dict["remoteUrl"] as? String,
        usedAt: usedAt
      )
    }
  }

  private func loadInstalledOrder() {
    guard let order = UserDefaults.standard.array(forKey: installedOrderDefaultsKey) as? [String],
      !order.isEmpty
    else { return }
    let byId = Dictionary(uniqueKeysWithValues: installedPacks.map { ($0.id, $0) })
    var reordered: [StickerPack] = []
    for id in order {
      if let pack = byId[id] { reordered.append(pack) }
    }
    for pack in installedPacks where !order.contains(pack.id) {
      reordered.append(pack)
    }
    installedPacks = reordered
  }
}
