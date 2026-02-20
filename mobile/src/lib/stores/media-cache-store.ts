import AsyncStorage from '@react-native-async-storage/async-storage';
import { create } from 'zustand';
import { persist, createJSONStorage } from 'zustand/middleware';
import * as FileSystem from 'expo-file-system/legacy';

export interface CachedTrack {
    video_id: string;
    title: string;
    artist: string;
    album?: string;
    duration?: string;
    duration_seconds?: number;
    cover?: string;
    stream_url?: string;
    preview_url?: string;
    local_uri?: string;
    links?: {
        youtube?: string;
        youtube_music?: string;
        spotify?: string;
        deezer?: string;
    };
    cached_at: number;
    play_count: number;
    last_played_at?: number;
}

export interface MediaCacheState {
    // Cached tracks by video_id
    tracks: Record<string, CachedTrack>;

    // Recently played (ordered list of video_ids)
    recentlyPlayed: string[];

    // Favorites
    favorites: string[];

    // Settings
    settings: {
        maxCacheSize: number; // Max tracks to keep
        cacheExpiryDays: number; // How long to keep tracks
        autoPlayNext: boolean;
        streamQuality: 'low' | 'medium' | 'high';
    };

    // Download State
    downloadingTracks: Record<string, number>; // videoId -> progress (0-1)

    // Actions
    cacheTrack: (track: Omit<CachedTrack, 'cached_at' | 'play_count'>) => void;
    downloadTrack: (track: CachedTrack) => Promise<string | null>;
    getTrack: (videoId: string) => CachedTrack | undefined;
    recordPlay: (videoId: string) => void;
    toggleFavorite: (videoId: string) => void;
    isFavorite: (videoId: string) => boolean;
    getRecentlyPlayed: (limit?: number) => CachedTrack[];
    getFavorites: () => CachedTrack[];
    removeTrack: (videoId: string) => void;
    clearExpired: () => void;
    clearAll: () => void;
    updateSettings: (settings: Partial<MediaCacheState['settings']>) => void;
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
                set((state) => {
                    const now = Date.now();
                    const existing = state.tracks[track.video_id];
                    const normalizedLocalUri = track.local_uri;
                    const shouldPersistLocalUri =
                        typeof normalizedLocalUri === 'string' &&
                        normalizedLocalUri.length > 0 &&
                        !normalizedLocalUri.includes('/tmp/');

                    return {
                        tracks: {
                            ...state.tracks,
                            [track.video_id]: {
                                ...track,
                                local_uri: shouldPersistLocalUri ? normalizedLocalUri : existing?.local_uri,
                                cached_at: existing?.cached_at || now,
                                play_count: existing?.play_count || 0,
                                last_played_at: existing?.last_played_at,
                            },
                        },
                    };
                });
            },

            downloadTrack: async (track): Promise<string | null> => {
                const state = get();
                if (state.tracks[track.video_id]?.local_uri) {
                    return state.tracks[track.video_id].local_uri || null;
                }

                if (state.downloadingTracks[track.video_id] !== undefined) {
                    return null; // Already downloading
                }

                const originalUrl = track.preview_url || track.stream_url;
                if (!originalUrl) return null;

                // If it's already a local file:// URI, just cache it directly without downloading
                if (originalUrl.startsWith('file://')) {
                    if (originalUrl.includes('/tmp/')) {
                        console.log('[MediaCache] Local temp file detected, skipping persistent cache entry');
                        return originalUrl;
                    }
                    console.log('[MediaCache] Local file detected, caching directly');
                    state.cacheTrack({
                        ...track,
                        local_uri: originalUrl
                    });
                    return originalUrl;
                }

                // Generate a short, deterministic filename from the video_id (which might be a long URL)
                const hashCode = (str: string) => {
                    let hash = 0;
                    for (let i = 0; i < str.length; i++) {
                        const char = str.charCodeAt(i);
                        hash = ((hash << 5) - hash) + char;
                        hash = hash & hash; // Convert to 32bit integer
                    }
                    return Math.abs(hash).toString(16);
                };

                const safeId = hashCode(track.video_id);
                const filename = `track_${safeId}.m4a`;
                const cacheDir = `${FileSystem.documentDirectory}music_cache/`;
                const fileUri = `${cacheDir}${filename}`;

                // Ensure directory exists
                try {
                    const dirInfo = await FileSystem.getInfoAsync(cacheDir);
                    if (!dirInfo.exists) {
                        await FileSystem.makeDirectoryAsync(cacheDir, { intermediates: true });
                    }

                    set(s => ({ downloadingTracks: { ...s.downloadingTracks, [track.video_id]: 0 } }));

                    // Prefer backend streaming URL for faster downloads (bypasses YouTube CDN throttling)
                    // Backend URL format: /api/music/stream/{video_id}
                    const backendBaseUrl = 'https://modest-recreation-production-8329.up.railway.app';
                    const videoIdForBackend = track.video_id.length === 11 ? track.video_id : safeId;
                    const backendStreamUrl = `${backendBaseUrl}/api/music/stream/${videoIdForBackend}`;

                    // Try backend first, fallback to direct URL
                    let downloadUrl = backendStreamUrl;
                    let authHeaders: Record<string, string> = {};
                    try {
                        const AuthManager = require('../AuthManager').default;
                        const auth = AuthManager.getInstance().getSession();
                        authHeaders = auth?.loginToken ? { Authorization: `Bearer ${auth.loginToken}` } : {};

                        // Quick request to check if backend has it cached
                        const checkRes = await fetch(`${backendBaseUrl}/api/music/info/${videoIdForBackend}`, {
                            method: 'GET',
                            headers: { 'ngrok-skip-browser-warning': 'true', ...authHeaders }
                        });
                        const info = await checkRes.json();
                        if (info.cached) {
                            console.log('[MediaCache] Using cached backend stream');
                            downloadUrl = backendStreamUrl;
                        } else {
                            console.log('[MediaCache] Backend not cached, using direct URL');
                            downloadUrl = originalUrl;
                        }
                    } catch (e) {
                        console.log('[MediaCache] Backend check failed, using direct URL');
                        downloadUrl = originalUrl;
                    }

                    const downloadResumable = FileSystem.createDownloadResumable(
                        downloadUrl,
                        fileUri,
                        { headers: { 'ngrok-skip-browser-warning': 'true', ...authHeaders } },
                        (downloadProgress) => {
                            const progress = downloadProgress.totalBytesWritten / downloadProgress.totalBytesExpectedToWrite;
                            set(s => ({ downloadingTracks: { ...s.downloadingTracks, [track.video_id]: progress } }));
                        }
                    );

                    const result = await downloadResumable.downloadAsync();

                    if (result?.uri) {
                        state.cacheTrack({
                            ...track,
                            local_uri: result.uri
                        });

                        set(s => {
                            const newDownloads = { ...s.downloadingTracks };
                            delete newDownloads[track.video_id];
                            return { downloadingTracks: newDownloads };
                        });

                        return result.uri;
                    }
                } catch (e) {
                    console.error("Download failed:", e);
                    set(s => {
                        const newDownloads = { ...s.downloadingTracks };
                        delete newDownloads[track.video_id];
                        return { downloadingTracks: newDownloads };
                    });
                }
                return null;
            },

            getTrack: (videoId) => {
                return get().tracks[videoId];
            },

            recordPlay: (videoId) => {
                const now = Date.now();
                set((state) => {
                    const track = state.tracks[videoId];
                    if (!track) return state;

                    // Update play count and last played
                    const updatedTracks = {
                        ...state.tracks,
                        [videoId]: {
                            ...track,
                            play_count: track.play_count + 1,
                            last_played_at: now,
                        },
                    };

                    // Update recently played (move to front, limit 50)
                    const recentlyPlayed = [
                        videoId,
                        ...state.recentlyPlayed.filter((id) => id !== videoId),
                    ].slice(0, 50);

                    return { tracks: updatedTracks, recentlyPlayed };
                });
            },

            toggleFavorite: (videoId) => {
                set((state) => {
                    const isFav = state.favorites.includes(videoId);
                    return {
                        favorites: isFav
                            ? state.favorites.filter((id) => id !== videoId)
                            : [...state.favorites, videoId],
                    };
                });
            },

            isFavorite: (videoId) => {
                return get().favorites.includes(videoId);
            },

            getRecentlyPlayed: (limit = 10) => {
                const state = get();
                return state.recentlyPlayed
                    .slice(0, limit)
                    .map((id) => state.tracks[id])
                    .filter(Boolean) as CachedTrack[];
            },

            getFavorites: () => {
                const state = get();
                return state.favorites
                    .map((id) => state.tracks[id])
                    .filter(Boolean) as CachedTrack[];
            },

            clearExpired: () => {
                const now = Date.now();
                const expiryMs = get().settings.cacheExpiryDays * 24 * 60 * 60 * 1000;

                set((state) => {
                    const validTracks: Record<string, CachedTrack> = {};

                    Object.entries(state.tracks).forEach(([id, track]) => {
                        // Keep if: not expired, OR is a favorite, OR was played recently
                        const isExpired = now - track.cached_at > expiryMs;
                        const isFavorite = state.favorites.includes(id);
                        const wasPlayedRecently = track.last_played_at &&
                            (now - track.last_played_at < 24 * 60 * 60 * 1000);

                        if (!isExpired || isFavorite || wasPlayedRecently) {
                            validTracks[id] = track;
                        }
                    });

                    // Also clean up recentlyPlayed references
                    const recentlyPlayed = state.recentlyPlayed.filter(
                        (id) => validTracks[id]
                    );

                    return { tracks: validTracks, recentlyPlayed };
                });
            },

            removeTrack: (videoId) => {
                set((state) => {
                    const newTracks = { ...state.tracks };
                    const track = newTracks[videoId];
                    // Try to delete the local file if it exists
                    if (track?.local_uri) {
                        FileSystem.deleteAsync(track.local_uri, { idempotent: true }).catch(() => { });
                    }
                    delete newTracks[videoId];
                    return {
                        tracks: newTracks,
                        recentlyPlayed: state.recentlyPlayed.filter(id => id !== videoId),
                    };
                });
            },

            clearAll: () => {
                set({ tracks: {}, recentlyPlayed: [], favorites: [] });
            },

            updateSettings: (newSettings) => {
                set((state) => ({
                    settings: { ...state.settings, ...newSettings },
                }));
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
                // Don't persist downloading state
            }),
        }
    )
);

// Helper to get cache stats
export const getCacheStats = () => {
    const state = useMediaCacheStore.getState();
    const trackCount = Object.keys(state.tracks).length;
    const favoriteCount = state.favorites.length;
    const recentCount = state.recentlyPlayed.length;

    return {
        trackCount,
        favoriteCount,
        recentCount,
        estimatedSizeKB: trackCount * 2, // Rough estimate: 2KB per track metadata
    };
};
