import AsyncStorage from '@react-native-async-storage/async-storage'
import * as FileSystem from 'expo-file-system/legacy'
import { create } from 'zustand'
import { createJSONStorage, persist } from 'zustand/middleware'

import {
  addNativeMusicPlayerListener,
  getNativeMusicPlayerModule,
  type NativeMusicPlayerStateEvent,
} from '../../native/music/runtime'

export interface CachedTrack {
  video_id: string
  title: string
  artist: string
  album?: string
  duration?: string
  duration_seconds?: number
  cover?: string
  stream_url?: string
  preview_url?: string
  local_uri?: string
  links?: {
    youtube?: string
    youtube_music?: string
    spotify?: string
    deezer?: string
  }
  cached_at: number
  play_count: number
  last_played_at?: number
}

export interface MediaCacheState {
  tracks: Record<string, CachedTrack>
  recentlyPlayed: string[]
  favorites: string[]
  settings: {
    maxCacheSize: number
    cacheExpiryDays: number
    autoPlayNext: boolean
    streamQuality: 'low' | 'medium' | 'high'
  }
  downloadingTracks: Record<string, number>

  cacheTrack: (track: Omit<CachedTrack, 'cached_at' | 'play_count'>) => void
  downloadTrack: (track: CachedTrack) => Promise<string | null>
  getTrack: (videoId: string) => CachedTrack | undefined
  recordPlay: (videoId: string) => void
  toggleFavorite: (videoId: string) => void
  isFavorite: (videoId: string) => boolean
  getRecentlyPlayed: (limit?: number) => CachedTrack[]
  getFavorites: () => CachedTrack[]
  removeTrack: (videoId: string) => void
  clearExpired: () => void
  clearAll: () => void
  updateSettings: (settings: Partial<MediaCacheState['settings']>) => void
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === 'object' && !Array.isArray(value)

const asString = (value: unknown): string | undefined =>
  typeof value === 'string' && value.trim().length > 0 ? value : undefined

const asNumber = (value: unknown): number | undefined =>
  typeof value === 'number' && Number.isFinite(value)
    ? value
    : typeof value === 'string' && value.trim().length > 0 && Number.isFinite(Number(value))
      ? Number(value)
      : undefined

const normalizeCachedTrack = (value: unknown): CachedTrack | null => {
  if (!isRecord(value)) return null
  const videoId =
    asString(value.video_id)
    ?? asString(value.track_id)
    ?? asString(value.id)
    ?? asString(value.preview_url)
    ?? asString(value.stream_url)
    ?? asString(value.local_uri)
  const title = asString(value.title)
  const artist = asString(value.artist)
  if (!videoId || !title || !artist) return null

  return {
    video_id: videoId,
    title,
    artist,
    album: asString(value.album),
    duration: asString(value.duration),
    duration_seconds: asNumber(value.duration_seconds),
    cover: asString(value.cover),
    stream_url: asString(value.stream_url),
    preview_url: asString(value.preview_url),
    local_uri: asString(value.local_uri),
    links: isRecord(value.links) ? value.links as CachedTrack['links'] : {},
    cached_at: asNumber(value.cached_at) ?? Date.now(),
    play_count: Math.max(0, Math.round(asNumber(value.play_count) ?? 0)),
    last_played_at: asNumber(value.last_played_at),
  }
}

const normalizeTracksMap = (value: unknown): Record<string, CachedTrack> => {
  if (!isRecord(value)) return {}
  const next: Record<string, CachedTrack> = {}
  for (const [key, payload] of Object.entries(value)) {
    const track = normalizeCachedTrack(payload)
    if (!track) continue
    next[track.video_id || key] = track
  }
  return next
}

const toNativePayload = (
  track: Partial<CachedTrack> & { video_id: string; title: string; artist: string },
): Record<string, unknown> => ({
  video_id: track.video_id,
  title: track.title,
  artist: track.artist,
  album: track.album,
  duration: track.duration,
  duration_seconds: track.duration_seconds,
  cover: track.cover,
  stream_url: track.stream_url,
  preview_url: track.preview_url,
  local_uri: track.local_uri,
  links: track.links ?? {},
  cached_at: track.cached_at,
  play_count: track.play_count,
  last_played_at: track.last_played_at,
})

const mergeLocalTrack = (
  existing: CachedTrack | undefined,
  incoming: Partial<CachedTrack> & { video_id: string; title: string; artist: string },
): CachedTrack => ({
  video_id: incoming.video_id,
  title: incoming.title,
  artist: incoming.artist,
  album: incoming.album ?? existing?.album,
  duration: incoming.duration ?? existing?.duration,
  duration_seconds: incoming.duration_seconds ?? existing?.duration_seconds,
  cover: incoming.cover ?? existing?.cover,
  stream_url: incoming.stream_url ?? existing?.stream_url,
  preview_url: incoming.preview_url ?? existing?.preview_url,
  local_uri: incoming.local_uri ?? existing?.local_uri,
  links: incoming.links ?? existing?.links ?? {},
  cached_at: existing?.cached_at ?? incoming.cached_at ?? Date.now(),
  play_count: existing?.play_count ?? incoming.play_count ?? 0,
  last_played_at: incoming.last_played_at ?? existing?.last_played_at,
})

const downloadTrackFallback = async (
  track: CachedTrack,
  setDownloading: (progress: number | null) => void,
  cacheTrack: (track: Omit<CachedTrack, 'cached_at' | 'play_count'>) => void,
): Promise<string | null> => {
  const originalUrl = track.preview_url || track.stream_url
  if (!originalUrl) return null

  if (originalUrl.startsWith('file://')) {
    if (originalUrl.includes('/tmp/')) {
      return originalUrl
    }
    cacheTrack({
      video_id: track.video_id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      duration: track.duration,
      duration_seconds: track.duration_seconds,
      cover: track.cover,
      stream_url: track.stream_url,
      preview_url: track.preview_url,
      local_uri: originalUrl,
      links: track.links,
    })
    return originalUrl
  }

  const hashCode = (str: string) => {
    let hash = 0
    for (let i = 0; i < str.length; i += 1) {
      const char = str.charCodeAt(i)
      hash = ((hash << 5) - hash) + char
      hash &= hash
    }
    return Math.abs(hash).toString(16)
  }

  const safeId = hashCode(track.video_id)
  const filename = `track_${safeId}.m4a`
  const cacheDir = `${FileSystem.documentDirectory}music_cache/`
  const fileUri = `${cacheDir}${filename}`

  try {
    const dirInfo = await FileSystem.getInfoAsync(cacheDir)
    if (!dirInfo.exists) {
      await FileSystem.makeDirectoryAsync(cacheDir, { intermediates: true })
    }

    setDownloading(0)

    const backendBaseUrl = 'https://api.vibegram.io'
    const videoIdForBackend = track.video_id.length === 11 ? track.video_id : safeId
    const backendStreamUrl = `${backendBaseUrl}/api/music/stream/${videoIdForBackend}`

    let downloadUrl = backendStreamUrl
    let authHeaders: Record<string, string> = {}
    try {
      const AuthManager = require('../AuthManager').default
      const auth = AuthManager.getInstance().getSession()
      authHeaders = auth?.loginToken ? { Authorization: `Bearer ${auth.loginToken}` } : {}

      const checkRes = await fetch(`${backendBaseUrl}/api/music/info/${videoIdForBackend}`, {
        method: 'GET',
        headers: { 'ngrok-skip-browser-warning': 'true', ...authHeaders },
      })
      const info = await checkRes.json()
      if (!info.cached) {
        downloadUrl = originalUrl
      }
    } catch {
      downloadUrl = originalUrl
    }

    const downloadResumable = FileSystem.createDownloadResumable(
      downloadUrl,
      fileUri,
      { headers: { 'ngrok-skip-browser-warning': 'true', ...authHeaders } },
      (downloadProgress) => {
        const total = Math.max(downloadProgress.totalBytesExpectedToWrite, 1)
        setDownloading(downloadProgress.totalBytesWritten / total)
      },
    )

    const result = await downloadResumable.downloadAsync()
    if (result?.uri) {
      cacheTrack({
        video_id: track.video_id,
        title: track.title,
        artist: track.artist,
        album: track.album,
        duration: track.duration,
        duration_seconds: track.duration_seconds,
        cover: track.cover,
        stream_url: track.stream_url,
        preview_url: track.preview_url,
        local_uri: result.uri,
        links: track.links,
      })
      setDownloading(null)
      return result.uri
    }
  } catch (error) {
    console.error('Download failed:', error)
  }

  setDownloading(null)
  return null
}

export const useMediaCacheStore = create<MediaCacheState>()(
  persist(
    (set, get) => ({
      tracks: {},
      recentlyPlayed: [],
      favorites: [],
      settings: {
        maxCacheSize: 100,
        cacheExpiryDays: 7,
        autoPlayNext: true,
        streamQuality: 'high',
      },
      downloadingTracks: {},

      cacheTrack: (track) => {
        const nativeModule = getNativeMusicPlayerModule()
        const optimisticTrack = {
          ...track,
          cached_at: Date.now(),
          play_count: 0,
        }

        if (nativeModule) {
          try {
            const nativeResult = nativeModule.cacheTrack(toNativePayload(optimisticTrack))
            const normalized = normalizeCachedTrack(nativeResult) ?? optimisticTrack
            set((state) => ({
              tracks: {
                ...state.tracks,
                [normalized.video_id]: mergeLocalTrack(state.tracks[normalized.video_id], normalized),
              },
            }))
            return
          } catch {
            // Fall through to local merge.
          }
        }

        set((state) => ({
          tracks: {
            ...state.tracks,
            [optimisticTrack.video_id]: mergeLocalTrack(
              state.tracks[optimisticTrack.video_id],
              optimisticTrack,
            ),
          },
        }))
      },

      downloadTrack: async (track) => {
        const state = get()
        if (state.tracks[track.video_id]?.local_uri) {
          return state.tracks[track.video_id].local_uri || null
        }

        if (state.downloadingTracks[track.video_id] !== undefined) {
          return null
        }

        const nativeModule = getNativeMusicPlayerModule()
        if (nativeModule) {
          set((s) => ({
            downloadingTracks: { ...s.downloadingTracks, [track.video_id]: 0 },
          }))
          try {
            const result = await nativeModule.downloadTrack(toNativePayload(track))
            const normalized = normalizeCachedTrack(isRecord(result) ? result.track : result)
            set((s) => {
              const nextDownloading = { ...s.downloadingTracks }
              delete nextDownloading[track.video_id]
              return {
                downloadingTracks: nextDownloading,
                tracks: normalized
                  ? {
                    ...s.tracks,
                    [normalized.video_id]: mergeLocalTrack(s.tracks[normalized.video_id], normalized),
                  }
                  : s.tracks,
              }
            })
            if (isRecord(result)) {
              return asString(result.localUri) ?? normalized?.local_uri ?? null
            }
            return normalized?.local_uri ?? null
          } catch (error) {
            console.error('Native download failed:', error)
            set((s) => {
              const nextDownloading = { ...s.downloadingTracks }
              delete nextDownloading[track.video_id]
              return { downloadingTracks: nextDownloading }
            })
            return null
          }
        }

        return downloadTrackFallback(
          track,
          (progress) => {
            set((s) => {
              const nextDownloading = { ...s.downloadingTracks }
              if (progress == null) {
                delete nextDownloading[track.video_id]
              } else {
                nextDownloading[track.video_id] = progress
              }
              return { downloadingTracks: nextDownloading }
            })
          },
          get().cacheTrack,
        )
      },

      getTrack: (videoId) => {
        return get().tracks[videoId]
      },

      recordPlay: (videoId) => {
        const now = Date.now()
        set((state) => {
          const track = state.tracks[videoId]
          if (!track) return state

          const updatedTracks = {
            ...state.tracks,
            [videoId]: {
              ...track,
              play_count: track.play_count + 1,
              last_played_at: now,
            },
          }

          const recentlyPlayed = [
            videoId,
            ...state.recentlyPlayed.filter((id) => id !== videoId),
          ].slice(0, 50)

          return { tracks: updatedTracks, recentlyPlayed }
        })
      },

      toggleFavorite: (videoId) => {
        set((state) => {
          const isFav = state.favorites.includes(videoId)
          return {
            favorites: isFav
              ? state.favorites.filter((id) => id !== videoId)
              : [...state.favorites, videoId],
          }
        })
      },

      isFavorite: (videoId) => get().favorites.includes(videoId),

      getRecentlyPlayed: (limit = 10) => {
        const state = get()
        return state.recentlyPlayed
          .slice(0, limit)
          .map((id) => state.tracks[id])
          .filter(Boolean) as CachedTrack[]
      },

      getFavorites: () => {
        const state = get()
        return state.favorites
          .map((id) => state.tracks[id])
          .filter(Boolean) as CachedTrack[]
      },

      clearExpired: () => {
        const now = Date.now()
        const expiryMs = get().settings.cacheExpiryDays * 24 * 60 * 60 * 1000
        const nativeModule = getNativeMusicPlayerModule()

        set((state) => {
          const validTracks: Record<string, CachedTrack> = {}
          const removedIds: string[] = []

          Object.entries(state.tracks).forEach(([id, track]) => {
            const isExpired = now - track.cached_at > expiryMs
            const isFavorite = state.favorites.includes(id)
            const wasPlayedRecently = !!track.last_played_at
              && (now - track.last_played_at < 24 * 60 * 60 * 1000)

            if (!isExpired || isFavorite || wasPlayedRecently) {
              validTracks[id] = track
            } else {
              removedIds.push(id)
            }
          })

          removedIds.forEach((id) => {
            nativeModule?.removeTrack(id)
            const localUri = state.tracks[id]?.local_uri
            if (localUri) {
              FileSystem.deleteAsync(localUri, { idempotent: true }).catch(() => {})
            }
          })

          return {
            tracks: validTracks,
            recentlyPlayed: state.recentlyPlayed.filter((id) => validTracks[id]),
          }
        })
      },

      removeTrack: (videoId) => {
        const nativeModule = getNativeMusicPlayerModule()
        nativeModule?.removeTrack(videoId)

        set((state) => {
          const nextTracks = { ...state.tracks }
          const track = nextTracks[videoId]
          if (track?.local_uri) {
            FileSystem.deleteAsync(track.local_uri, { idempotent: true }).catch(() => {})
          }
          delete nextTracks[videoId]
          return {
            tracks: nextTracks,
            recentlyPlayed: state.recentlyPlayed.filter((id) => id !== videoId),
          }
        })
      },

      clearAll: () => {
        const nativeModule = getNativeMusicPlayerModule()
        const trackIds = Object.keys(get().tracks)
        trackIds.forEach((id) => nativeModule?.removeTrack(id))
        set({ tracks: {}, recentlyPlayed: [], favorites: [], downloadingTracks: {} })
      },

      updateSettings: (newSettings) => {
        set((state) => ({
          settings: { ...state.settings, ...newSettings },
        }))
      },
    }),
    {
      name: 'vibe-media-cache',
      storage: createJSONStorage(() => AsyncStorage),
      partialize: (state) => ({
        tracks: state.tracks,
        recentlyPlayed: state.recentlyPlayed,
        favorites: state.favorites,
        settings: state.settings,
      }),
    },
  ),
)

let nativeMediaCacheBootstrapped = false
let nativeMediaCacheSubscription: { remove: () => void } | null = null

const applyNativeMediaCacheSnapshot = (snapshot: NativeMusicPlayerStateEvent | null | undefined) => {
  if (!snapshot) return
  const nextTracks = normalizeTracksMap(snapshot.tracks)
  const nextDownloading = isRecord(snapshot.downloadingTracks)
    ? Object.entries(snapshot.downloadingTracks).reduce<Record<string, number>>((acc, [key, value]) => {
      const progress = asNumber(value)
      if (progress != null) acc[key] = progress
      return acc
    }, {})
    : {}

  useMediaCacheStore.setState((state) => {
    const byRecentPlayback = Object.values(nextTracks)
      .filter((track) => typeof track.last_played_at === 'number')
      .sort((a, b) => (b.last_played_at ?? 0) - (a.last_played_at ?? 0))
      .map((track) => track.video_id)

    const recentlyPlayed = [
      ...byRecentPlayback,
      ...state.recentlyPlayed.filter((id) => nextTracks[id] && !byRecentPlayback.includes(id)),
    ].slice(0, 50)

    return {
      tracks: nextTracks,
      downloadingTracks: nextDownloading,
      recentlyPlayed,
    }
  })
}

const ensureNativeMediaCacheRuntime = () => {
  if (nativeMediaCacheBootstrapped) return
  const nativeModule = getNativeMusicPlayerModule()
  if (!nativeModule) return

  nativeMediaCacheBootstrapped = true
  try {
    applyNativeMediaCacheSnapshot(nativeModule.getState())
  } catch {
    // Ignore init failures; the JS mirror remains available.
  }
  nativeMediaCacheSubscription = addNativeMusicPlayerListener(applyNativeMediaCacheSnapshot)
}

ensureNativeMediaCacheRuntime()

export const getCacheStats = () => {
  const state = useMediaCacheStore.getState()
  const trackCount = Object.keys(state.tracks).length
  const favoriteCount = state.favorites.length
  const recentCount = state.recentlyPlayed.length

  return {
    trackCount,
    favoriteCount,
    recentCount,
    estimatedSizeKB: trackCount * 2,
  }
}
