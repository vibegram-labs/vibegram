import { create } from 'zustand';
import { MusicTrack } from '../agent/types';

interface MusicPlayerState {
    currentTrack: MusicTrack | null;
    isPlaying: boolean;
    queue: MusicTrack[];
    isExpanded: boolean; // For full screen modal
    progress: number; // 0-1 or milliseconds
    duration: number; // milliseconds
    playbackRate: number; // 1, 1.5, 2

    setTrack: (track: MusicTrack) => void;
    setQueue: (tracks: MusicTrack[]) => void;
    setIsPlaying: (isPlaying: boolean) => void;
    setIsExpanded: (isExpanded: boolean) => void;
    setProgress: (progress: number) => void;
    setDuration: (duration: number) => void;
    setPlaybackRate: (rate: number) => void;
    playNext: () => void;
    playPrev: () => void;
    reset: () => void;
}

export const useMusicPlayerStore = create<MusicPlayerState>((set, get) => ({
    currentTrack: null,
    isPlaying: false,
    queue: [],
    isExpanded: false,
    progress: 0,
    duration: 0,
    playbackRate: 1,

    setTrack: (track) => {
        //If same track, just toggle expand? No, usually setTrack means play this.
        const current = get().currentTrack;
        const isSameTrack =
            current?.preview_url === track.preview_url
            && current?.id === track.id
            && current?.source === track.source;
        if (isSameTrack) {
            set({ isPlaying: true });
        } else {
            // Reset progress when switching tracks
            set({ currentTrack: track, isPlaying: true, progress: 0, playbackRate: 1 });
        }
    },
    setQueue: (queue) => set({ queue }),
    setIsPlaying: (isPlaying) => set({ isPlaying }),
    setIsExpanded: (isExpanded) => set({ isExpanded }),
    setProgress: (progress) => set({ progress }),
    setDuration: (duration) => set({ duration }),
    setPlaybackRate: (rate) => set({ playbackRate: rate }),

    playNext: () => {
        const { queue, currentTrack } = get();
        if (!currentTrack || queue.length === 0) return;
        const idx = queue.findIndex(t => t.preview_url === currentTrack.preview_url);
        if (idx > -1 && idx < queue.length - 1) {
            set({ currentTrack: queue[idx + 1], isPlaying: true, progress: 0 });
        }
    },
    playPrev: () => {
        const { queue, currentTrack } = get();
        if (!currentTrack || queue.length === 0) return;
        const idx = queue.findIndex(t => t.preview_url === currentTrack.preview_url);
        if (idx > 0) {
            set({ currentTrack: queue[idx - 1], isPlaying: true, progress: 0 });
        }
    },
    reset: () => set({ currentTrack: null, isPlaying: false, queue: [], progress: 0, duration: 0, isExpanded: false, playbackRate: 1 })
}));
