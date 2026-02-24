import { Audio, InterruptionModeIOS, InterruptionModeAndroid } from 'expo-av';

type SoundType = 'sent' | 'received' | 'socketReady';

class SoundManager {
    private static instance: SoundManager;
    private soundAssets: Record<SoundType, any> = {
        sent: require('../../assets/sounds/sent.mp3'),
        received: require('../../assets/sounds/received.mp3'),
        socketReady: require('../../assets/sounds/socket-ready.mp3'),
    };

    // Pre-loaded sound pools for instant playback
    private soundPools: Record<SoundType, Audio.Sound[]> = {
        sent: [],
        received: [],
        socketReady: [],
    };

    private callRingAsset = require('../../assets/sounds/call-ring.mp3');
    private callRingSound: Audio.Sound | null = null;
    private callRingActive = false;
    private callRingBusy: Promise<void> | null = null;
    private lastSocketReadyCueAt = 0;

    private poolSize = 4;

    private constructor() {
        this.initialize();
    }

    public static getInstance(): SoundManager {
        if (!SoundManager.instance) {
            SoundManager.instance = new SoundManager();
        }
        return SoundManager.instance;
    }

    private async initialize() {
        // console.log('[SoundManager] Starting initialization...');
        try {
            await Audio.setAudioModeAsync({
                playsInSilentModeIOS: true,
                staysActiveInBackground: false,
                interruptionModeIOS: InterruptionModeIOS.MixWithOthers,
                interruptionModeAndroid: InterruptionModeAndroid.DuckOthers,
                shouldDuckAndroid: true,
                playThroughEarpieceAndroid: false,
            });

            // Pre-load sound pools in parallel
            await Promise.all([
                this.fillPool('sent'),
                this.fillPool('received'),
                this.fillPool('socketReady'),
            ]);

            /*
            console.log('[SoundManager] Initialized! Pools:', {
                sent: this.soundPools.sent.length,
                received: this.soundPools.received.length
            });
            */
        } catch (e) {
            console.warn('[SoundManager] Init failed:', e);
        }
    }

    private async fillPool(type: SoundType) {
        const pool = this.soundPools[type];
        const promises: Promise<void>[] = [];

        for (let i = pool.length; i < this.poolSize; i++) {
            promises.push(
                Audio.Sound.createAsync(this.soundAssets[type])
                    .then(({ sound }) => {
                        pool.push(sound);
                    })
                    .catch(e => console.warn(`[SoundManager] Failed to pre-load ${type}:`, e))
            );
        }

        await Promise.all(promises);
        // console.log(`[SoundManager] Pool ${type} ready: ${pool.length}`);
    }

    private createAndAddToPool(type: SoundType) {
        Audio.Sound.createAsync(this.soundAssets[type])
            .then(({ sound }) => {
                this.soundPools[type].push(sound);
            })
            .catch(() => { });
    }

    public play(type: SoundType) {
        const start = Date.now();
        const pool = this.soundPools[type];

        // console.log(`[SoundManager] Play ${type}, pool size: ${pool.length}`);

        const playSound = async (sound: Audio.Sound, isFallback = false) => {
            try {
                // Reset status update listener just in case
                sound.setOnPlaybackStatusUpdate(null);

                // Set up the completion listener BEFORE playing
                sound.setOnPlaybackStatusUpdate(async (status) => {
                    if (status.isLoaded && status.didJustFinish) {
                        // console.log(`[SoundManager] Finished playing ${type} (duration: ${Date.now() - start}ms)`);

                        // Clean up
                        sound.setOnPlaybackStatusUpdate(null);

                        if (isFallback) {
                            await sound.unloadAsync();
                        } else {
                            // Reset and return to pool
                            // We don't need to stopAsync as it just finished, but good practice to ensure state
                            await sound.stopAsync();
                            pool.push(sound);
                        }
                    }
                });

                await sound.setPositionAsync(0);
                await sound.playAsync();
                // console.log(`[SoundManager] played ${type} ${isFallback ? '(fallback) ' : ''}latency: ${Date.now() - start}ms`);

                // Replenish pool if getting low (only if not fallback)
                if (!isFallback && pool.length < 2) {
                    this.createAndAddToPool(type);
                }

            } catch (error) {
                console.warn(`[SoundManager] Error playing ${type}:`, error);
                // If it fails, try to return to pool anyway logic could go here, 
                // but usually better to let garbage collection handle broken sounds or reload them.
            }
        };

        const sound = pool.shift();

        if (sound) {
            playSound(sound, false);
        } else {
            // console.log(`[SoundManager] Pool empty, fallback`);
            Audio.Sound.createAsync(this.soundAssets[type], { shouldPlay: false })
                .then(({ sound: newSound }) => {
                    playSound(newSound, true);
                })
                .catch(console.warn);
        }
    }

    private async ensureCallRingSound(): Promise<Audio.Sound | null> {
        if (this.callRingSound) return this.callRingSound;
        try {
            const { sound } = await Audio.Sound.createAsync(this.callRingAsset, {
                isLooping: true,
                shouldPlay: false,
                volume: 1.0,
            });
            this.callRingSound = sound;
            return sound;
        } catch (e) {
            console.warn('[SoundManager] Failed to load callRing:', e);
            return null;
        }
    }

    public async startCallRingLoop(delayMs: number = 900) {
        this.callRingActive = true;
        if (this.callRingBusy) {
            await this.callRingBusy;
            return;
        }

        this.callRingBusy = (async () => {
            if (delayMs > 0) {
                await new Promise((resolve) => setTimeout(resolve, delayMs));
            }
            const sound = await this.ensureCallRingSound();
            if (!sound || !this.callRingActive) return;
            try {
                await sound.setPositionAsync(0);
                await sound.playAsync();
            } catch (e) {
                console.warn('[SoundManager] Failed to start callRing loop:', e);
            }
        })();

        try {
            await this.callRingBusy;
        } finally {
            this.callRingBusy = null;
        }
    }

    public async stopCallRingLoop() {
        this.callRingActive = false;
        const sound = this.callRingSound;
        if (!sound) return;
        try {
            const status = await sound.getStatusAsync();
            if (status.isLoaded && status.isPlaying) {
                await sound.stopAsync();
            }
            if (status.isLoaded) {
                await sound.setPositionAsync(0);
            }
        } catch {
            // ignore
        }
    }

    public playSocketReadyCue() {
        const now = Date.now();
        if (now - this.lastSocketReadyCueAt < 900) return;
        this.lastSocketReadyCueAt = now;
        this.play('socketReady');
    }
}

export default SoundManager.getInstance();
