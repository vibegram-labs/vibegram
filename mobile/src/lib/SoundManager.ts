import { Audio, InterruptionModeIOS, InterruptionModeAndroid } from 'expo-av';

type SoundType = 'sent' | 'received';

class SoundManager {
    private static instance: SoundManager;
    private soundAssets: Record<SoundType, any> = {
        sent: require('../../assets/sounds/sent.mp3'),
        received: require('../../assets/sounds/received.mp3')
    };

    // Pre-loaded sound pools for instant playback
    private soundPools: Record<SoundType, Audio.Sound[]> = {
        sent: [],
        received: []
    };

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
                this.fillPool('received')
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
}

export default SoundManager.getInstance();
