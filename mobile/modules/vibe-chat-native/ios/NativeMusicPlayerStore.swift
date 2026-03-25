import CryptoKit
import Foundation

enum NativeMusicPlayerQueueOrderMode: String, CaseIterable {
  case forward
  case reverse
  case random

  func next() -> NativeMusicPlayerQueueOrderMode {
    switch self {
    case .forward:
      return .reverse
    case .reverse:
      return .random
    case .random:
      return .forward
    }
  }
}

struct NativeMusicPlayerTrack: Codable, Equatable {
  let trackId: String
  var videoId: String?
  var id: String?
  var source: String?
  var title: String
  var artist: String
  var album: String?
  var duration: String?
  var durationSeconds: Double?
  var cover: String?
  var previewURL: String?
  var streamURL: String?
  var localURI: String?
  var cachedAt: Double?
  var playCount: Int
  var lastPlayedAt: Double?
  var links: [String: String]

  init(
    trackId: String,
    videoId: String? = nil,
    id: String? = nil,
    source: String? = nil,
    title: String,
    artist: String,
    album: String? = nil,
    duration: String? = nil,
    durationSeconds: Double? = nil,
    cover: String? = nil,
    previewURL: String? = nil,
    streamURL: String? = nil,
    localURI: String? = nil,
    cachedAt: Double? = nil,
    playCount: Int = 0,
    lastPlayedAt: Double? = nil,
    links: [String: String] = [:]
  ) {
    self.trackId = trackId
    self.videoId = videoId
    self.id = id
    self.source = source
    self.title = title
    self.artist = artist
    self.album = album
    self.duration = duration
    self.durationSeconds = durationSeconds
    self.cover = cover
    self.previewURL = previewURL
    self.streamURL = streamURL
    self.localURI = localURI
    self.cachedAt = cachedAt
    self.playCount = playCount
    self.lastPlayedAt = lastPlayedAt
    self.links = links
  }

  static func resolveTrackId(from payload: [String: Any]) -> String? {
    let candidates: [Any?] = [
      payload["track_id"],
      payload["video_id"],
      payload["id"],
      payload["preview_url"],
      payload["stream_url"],
      payload["local_uri"],
    ]
    for candidate in candidates {
      if let value = candidate as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          return trimmed
        }
      }
    }
    return nil
  }

  init?(payload: [String: Any]) {
    guard let trackId = Self.resolveTrackId(from: payload) else { return nil }
    let title =
      (payload["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let artist =
      (payload["artist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !title.isEmpty else { return nil }

    self.trackId = trackId
    self.videoId = payload["video_id"] as? String
    self.id = payload["id"] as? String
    self.source = payload["source"] as? String
    self.title = title
    self.artist = artist.isEmpty ? "Unknown Artist" : artist
    self.album = payload["album"] as? String
    self.duration = payload["duration"] as? String
    self.durationSeconds =
      (payload["duration_seconds"] as? NSNumber)?.doubleValue
      ?? (payload["duration_seconds"] as? Double)
    self.cover = payload["cover"] as? String
    self.previewURL = payload["preview_url"] as? String
    self.streamURL = payload["stream_url"] as? String
    self.localURI = payload["local_uri"] as? String
    self.cachedAt =
      (payload["cached_at"] as? NSNumber)?.doubleValue
      ?? (payload["cached_at"] as? Double)
    self.playCount =
      (payload["play_count"] as? NSNumber)?.intValue
      ?? (payload["play_count"] as? Int)
      ?? 0
    self.lastPlayedAt =
      (payload["last_played_at"] as? NSNumber)?.doubleValue
      ?? (payload["last_played_at"] as? Double)
    self.links = payload["links"] as? [String: String] ?? [:]
  }

  func applying(payload: [String: Any]) -> NativeMusicPlayerTrack {
    var next = self
    if let value = payload["video_id"] as? String, !value.isEmpty { next.videoId = value }
    if let value = payload["id"] as? String, !value.isEmpty { next.id = value }
    if let value = payload["source"] as? String, !value.isEmpty { next.source = value }
    if let value = payload["title"] as? String, !value.isEmpty { next.title = value }
    if let value = payload["artist"] as? String, !value.isEmpty { next.artist = value }
    if let value = payload["album"] as? String, !value.isEmpty { next.album = value }
    if let value = payload["duration"] as? String, !value.isEmpty { next.duration = value }
    if let value = (payload["duration_seconds"] as? NSNumber)?.doubleValue
      ?? (payload["duration_seconds"] as? Double)
    {
      next.durationSeconds = value
    }
    if let value = payload["cover"] as? String, !value.isEmpty { next.cover = value }
    if let value = payload["preview_url"] as? String, !value.isEmpty { next.previewURL = value }
    if let value = payload["stream_url"] as? String, !value.isEmpty { next.streamURL = value }
    if let value = payload["local_uri"] as? String, !value.isEmpty { next.localURI = value }
    if let value = (payload["cached_at"] as? NSNumber)?.doubleValue
      ?? (payload["cached_at"] as? Double)
    {
      next.cachedAt = value
    }
    if let value = (payload["play_count"] as? NSNumber)?.intValue ?? (payload["play_count"] as? Int)
    {
      next.playCount = value
    }
    if let value = (payload["last_played_at"] as? NSNumber)?.doubleValue
      ?? (payload["last_played_at"] as? Double)
    {
      next.lastPlayedAt = value
    }
    if let value = payload["links"] as? [String: String] {
      next.links = value
    }
    return next
  }

  func toPayload() -> [String: Any] {
    var payload: [String: Any] = [
      "track_id": trackId,
      "title": title,
      "artist": artist,
      "play_count": playCount,
      "links": links,
    ]
    if let videoId { payload["video_id"] = videoId }
    if let id { payload["id"] = id }
    if let source { payload["source"] = source }
    if let album { payload["album"] = album }
    if let duration { payload["duration"] = duration }
    if let durationSeconds { payload["duration_seconds"] = durationSeconds }
    if let cover { payload["cover"] = cover }
    if let previewURL { payload["preview_url"] = previewURL }
    if let streamURL { payload["stream_url"] = streamURL }
    if let localURI { payload["local_uri"] = localURI }
    if let cachedAt { payload["cached_at"] = cachedAt }
    if let lastPlayedAt { payload["last_played_at"] = lastPlayedAt }
    return payload
  }
}

final class NativeMusicPlayerStore {
  static let shared = NativeMusicPlayerStore()

  private let tracksDefaultsKey = "vibe.native.musicPlayer.tracks.v1"
  private let cacheDirectoryName = "native-music-player-cache"
  private let defaults = UserDefaults.standard

  private var tracks: [String: NativeMusicPlayerTrack] = [:]
  private var downloadingTracks: [String: Double] = [:]

  private init() {
    tracks = loadTracks()
  }

  func allTracksPayload() -> [String: [String: Any]] {
    var payload: [String: [String: Any]] = [:]
    for (trackId, track) in tracks {
      payload[trackId] = track.toPayload()
    }
    return payload
  }

  func downloadingTracksPayload() -> [String: Double] {
    downloadingTracks
  }

  func libraryTracksPayload() -> [[String: Any]] {
    libraryTracks().map { $0.toPayload() }
  }

  func cacheTrack(payload: [String: Any]) -> NativeMusicPlayerTrack? {
    guard var nextTrack = NativeMusicPlayerTrack(payload: payload) else { return nil }
    if let existing = tracks[nextTrack.trackId] {
      nextTrack = existing.applying(payload: payload)
    } else if nextTrack.cachedAt == nil {
      nextTrack.cachedAt = Date().timeIntervalSince1970 * 1000.0
    }
    tracks[nextTrack.trackId] = nextTrack
    persistTracks()
    return nextTrack
  }

  func getTrack(trackId: String) -> NativeMusicPlayerTrack? {
    tracks[trackId]
  }

  @discardableResult
  func updateLocalURI(trackId: String, localURI: String?) -> NativeMusicPlayerTrack? {
    guard var track = tracks[trackId] else { return nil }
    track.localURI = localURI
    if track.cachedAt == nil {
      track.cachedAt = Date().timeIntervalSince1970 * 1000.0
    }
    tracks[trackId] = track
    persistTracks()
    return track
  }

  @discardableResult
  func recordPlay(trackId: String) -> NativeMusicPlayerTrack? {
    guard var track = tracks[trackId] else { return nil }
    track.playCount += 1
    track.lastPlayedAt = Date().timeIntervalSince1970 * 1000.0
    tracks[trackId] = track
    persistTracks()
    return track
  }

  func setDownloadProgress(trackId: String, progress: Double?) {
    if let progress {
      downloadingTracks[trackId] = max(0.0, min(1.0, progress))
    } else {
      downloadingTracks.removeValue(forKey: trackId)
    }
  }

  func removeTrack(trackId: String) {
    if let localURI = tracks[trackId]?.localURI {
      deleteFileIfNeeded(localURI: localURI)
    }
    tracks.removeValue(forKey: trackId)
    downloadingTracks.removeValue(forKey: trackId)
    persistTracks()
  }

  func resolvedCachedFileURL(for track: NativeMusicPlayerTrack) -> URL? {
    guard let localURI = track.localURI else { return nil }
    guard let url = resolvedLocalURL(from: localURI) else { return nil }
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  func cacheDestinationURL(for track: NativeMusicPlayerTrack, remoteURL: URL?) -> URL {
    let cacheDirectory = resolvedCacheDirectory()
    let ext: String = {
      if let remoteURL, !remoteURL.pathExtension.isEmpty {
        return remoteURL.pathExtension
      }
      if let localURI = track.localURI,
        let url = resolvedLocalURL(from: localURI),
        !url.pathExtension.isEmpty
      {
        return url.pathExtension
      }
      return "m4a"
    }()
    let digest = SHA256.hash(data: Data(track.trackId.utf8))
      .compactMap { String(format: "%02x", $0) }
      .joined()
    return cacheDirectory.appendingPathComponent("\(digest).\(ext)", isDirectory: false)
  }

  func hasLocalPlaybackFile(for track: NativeMusicPlayerTrack) -> Bool {
    resolvedPlayableLocalURL(for: track) != nil
  }

  private func loadTracks() -> [String: NativeMusicPlayerTrack] {
    guard let data = defaults.data(forKey: tracksDefaultsKey) else { return [:] }
    guard let decoded = try? JSONDecoder().decode([String: NativeMusicPlayerTrack].self, from: data)
    else {
      return [:]
    }
    return decoded
  }

  private func persistTracks() {
    guard let data = try? JSONEncoder().encode(tracks) else { return }
    defaults.set(data, forKey: tracksDefaultsKey)
  }

  private func libraryTracks() -> [NativeMusicPlayerTrack] {
    tracks.values
      .filter { track in
        guard track.source != "chat-voice" else { return false }
        return hasLocalPlaybackFile(for: track)
      }
      .sorted { lhs, rhs in
        let lhsLastPlayed = lhs.lastPlayedAt ?? 0.0
        let rhsLastPlayed = rhs.lastPlayedAt ?? 0.0
        if lhsLastPlayed != rhsLastPlayed {
          return lhsLastPlayed > rhsLastPlayed
        }

        let lhsCachedAt = lhs.cachedAt ?? 0.0
        let rhsCachedAt = rhs.cachedAt ?? 0.0
        if lhsCachedAt != rhsCachedAt {
          return lhsCachedAt > rhsCachedAt
        }

        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      }
  }

  private func resolvedPlayableLocalURL(for track: NativeMusicPlayerTrack) -> URL? {
    if let localURI = track.localURI,
      let url = resolvedLocalURL(from: localURI),
      FileManager.default.fileExists(atPath: url.path)
    {
      return url
    }
    return nil
  }

  private func deleteFileIfNeeded(localURI: String) {
    guard let url = resolvedLocalURL(from: localURI) else { return }
    try? FileManager.default.removeItem(at: url)
  }

  private func resolvedCacheDirectory() -> URL {
    let baseDirectory =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let directory = baseDirectory.appendingPathComponent(cacheDirectoryName, isDirectory: true)
    if !FileManager.default.fileExists(atPath: directory.path) {
      try? FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
    }
    return directory
  }

  private func resolvedLocalURL(from value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed), url.isFileURL {
      return url
    }
    if trimmed.hasPrefix("/") {
      return URL(fileURLWithPath: trimmed)
    }
    return nil
  }
}
