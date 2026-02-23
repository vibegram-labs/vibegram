/**
 * WebRTC Service - Handles WebRTC peer connections for voice/video calls
 *
 * Uses dynamic imports to safely handle environments where WebRTC is unavailable
 * (e.g., Expo Go). The service will gracefully degrade when WebRTC is not available.
 *
 * Features:
 * - Dynamic TURN credentials fetched from server API
 * - Forced relay mode for strict-filtered networks (no P2P leaks)
 * - TURN-over-TLS on port 443 (indistinguishable from HTTPS to DPI)
 * - Adaptive video quality with bandwidth monitoring
 */

import { DeviceEventEmitter, NativeModules, Platform } from 'react-native';

// Dynamic module references - populated on first use
let RTCPeerConnection: any = null;
let RTCSessionDescription: any = null;
let RTCIceCandidate: any = null;
let mediaDevices: any = null;
let MediaStream: any = null;
let InCallManager: any = null;
let inCallProximitySub: { remove: () => void } | null = null;

// WebRTC module loading state
let webrtcLoaded = false;
let webrtcAvailable = false;

// --- ICE Server Cache ---
interface CachedIceConfig {
    iceServers: Array<{ urls: string; username?: string; credential?: string }>;
    iceTransportPolicy: 'all' | 'relay';
    fetchedAt: number;
    ttl: number;
}
let cachedIceConfig: CachedIceConfig | null = null;

// Fallback TURN servers — TLS on 443 to bypass DPI
const FALLBACK_ICE_SERVERS = [
    {
        urls: 'turn:openrelay.metered.ca:443?transport=tcp',
        username: 'openrelayproject',
        credential: 'openrelayproject',
    },
    {
        urls: 'turns:openrelay.metered.ca:443?transport=tcp',
        username: 'openrelayproject',
        credential: 'openrelayproject',
    },
];

// --- Adaptive Quality Tiers ---
interface QualityTier {
    label: string;
    maxBitrate: number; // bps
    scaleDown: number;  // 1.0 = full res, 2.0 = half res
    maxFramerate: number;
}

const QUALITY_TIERS: QualityTier[] = [
    { label: '1080p', maxBitrate: 2_500_000, scaleDown: 1.0, maxFramerate: 30 },
    { label: '720p',  maxBitrate: 1_500_000, scaleDown: 1.5, maxFramerate: 30 },
    { label: '480p',  maxBitrate: 800_000,   scaleDown: 2.0, maxFramerate: 24 },
    { label: '360p',  maxBitrate: 400_000,   scaleDown: 3.0, maxFramerate: 15 },
];

class WebRTCService {
    private static instance: WebRTCService;

    private peerConnection: any = null;
    private localStream: any = null;
    private remoteStream: any = null;
    public RTCView: any = null;

    // Callbacks for signaling (set by CallStore/ChatStore)
    public onIceCandidate: ((candidate: any) => void) | null = null;
    public onOffer: ((offer: any) => void) | null = null;
    public onAnswer: ((answer: any) => void) | null = null;
    public onRemoteStream: ((stream: any) => void) | null = null;
    public onConnectionStateChange: ((state: string) => void) | null = null;

    // Bandwidth monitoring
    private bandwidthMonitorInterval: ReturnType<typeof setInterval> | null = null;
    private currentTierIndex: number = 0;
    private lastBytesSent: number = 0;
    private lastBytesTimestamp: number = 0;

    private constructor() { }

    private ensureInCallProximityListener(): void {
        if (inCallProximitySub || Platform.OS === 'web') return;
        try {
            // InCallManager emits "Proximity" even if the app does not actively consume it.
            // Register a no-op listener to avoid React Native warning spam.
            inCallProximitySub = DeviceEventEmitter.addListener('Proximity', () => { });
        } catch {
            inCallProximitySub = null;
        }
    }

    private removeInCallProximityListener(): void {
        try {
            inCallProximitySub?.remove();
        } catch {
            // Ignore
        } finally {
            inCallProximitySub = null;
        }
    }

    static getInstance(): WebRTCService {
        if (!WebRTCService.instance) {
            WebRTCService.instance = new WebRTCService();
        }
        return WebRTCService.instance;
    }

    /**
     * Dynamically load WebRTC modules
     * Returns true if WebRTC is available
     */
    private async loadWebRTC(): Promise<boolean> {
        if (webrtcLoaded) return webrtcAvailable;

        try {
            // Dynamic import to prevent crashes in Expo Go
            if (Platform.OS !== 'web') {
                // Check if native module exists before trying to import the library
                // The library initialization invokes native methods immediately, which causes crashes in Expo Go
                const { WebRTCModule } = NativeModules;
                if (!WebRTCModule) {
                    throw new Error('WebRTC native module not found. Are you running in Expo Go?');
                }
            }

            const webrtc = await import('react-native-webrtc');

            RTCPeerConnection = webrtc.RTCPeerConnection;
            RTCSessionDescription = webrtc.RTCSessionDescription;
            RTCIceCandidate = webrtc.RTCIceCandidate;
            mediaDevices = webrtc.mediaDevices;
            MediaStream = webrtc.MediaStream;
            this.RTCView = webrtc.RTCView;

            webrtcAvailable = true;
        } catch (e) {
            webrtcAvailable = false;
        }

        // Try to load InCallManager for audio routing (optional)
        try {
            if (Platform.OS !== 'web') {
                const { InCallManager: InCallManagerNative } = NativeModules;
                if (!InCallManagerNative) {
                    throw new Error('InCallManager native module not found');
                }
            }
            const incallManager = await import('react-native-incall-manager');
            InCallManager = incallManager.default;
        } catch (e) {
            // InCallManager not available
        }

        webrtcLoaded = true;
        return webrtcAvailable;
    }

    /**
     * Check if WebRTC is available in this environment
     */
    async isAvailable(): Promise<boolean> {
        return this.loadWebRTC();
    }

    /**
     * Fetch TURN/ICE server credentials from the backend API.
     * Caches the result for the TTL period. Falls back to built-in TURN-TLS-443.
     */
    async fetchIceServers(): Promise<void> {
        // Use cache if still valid
        if (cachedIceConfig && (Date.now() - cachedIceConfig.fetchedAt) < cachedIceConfig.ttl * 1000) {
            return;
        }

        try {
            const { apiClient } = require('../api-client');
            const result = await apiClient.getTurnCredentials();

            if (result && result.iceServers && result.iceServers.length > 0) {
                cachedIceConfig = {
                    iceServers: result.iceServers,
                    iceTransportPolicy: result.iceTransportPolicy || 'all',
                    fetchedAt: Date.now(),
                    ttl: result.ttl || 3600,
                };
                return;
            }
        } catch (e) {
            console.warn('[WebRTC] Failed to fetch TURN credentials, using fallback:', e);
        }

        // Fallback — use built-in TURN-over-TLS
        cachedIceConfig = {
            iceServers: FALLBACK_ICE_SERVERS,
            iceTransportPolicy: 'all',
            fetchedAt: Date.now(),
            ttl: 300, // retry sooner since this is fallback
        };
    }

    /**
     * Build the ICE configuration for a peer connection.
     * @param forceRelay - If true, forces iceTransportPolicy to 'relay' (no P2P, no STUN)
     */
    private getIceConfig(forceRelay: boolean): any {
        const servers = cachedIceConfig?.iceServers || FALLBACK_ICE_SERVERS;
        const serverPolicy = cachedIceConfig?.iceTransportPolicy || 'all';
        const policy = forceRelay ? 'relay' : serverPolicy;

        return {
            iceServers: servers,
            iceTransportPolicy: policy,
            bundlePolicy: 'max-bundle',
            rtcpMuxPolicy: 'require',
            iceCandidatePoolSize: 10,
        };
    }

    /**
     * Initialize local media stream (microphone + optional camera)
     * Uses adaptive constraints — ideal 1080p, min 480p
     */
    async initializeMedia(withVideo: boolean = false): Promise<boolean> {
        const available = await this.loadWebRTC();
        if (!available || !mediaDevices) return false;

        try {
            const constraints = {
                audio: true,
                video: withVideo ? {
                    facingMode: 'user',
                    width: { ideal: 1920, min: 640 },
                    height: { ideal: 1080, min: 480 },
                    frameRate: { ideal: 30, min: 15 },
                } : false,
            };

            this.localStream = await mediaDevices.getUserMedia(constraints);

            // Start InCallManager for proper audio routing
            if (InCallManager) {
                this.ensureInCallProximityListener();
                InCallManager.start({ media: withVideo ? 'video' : 'audio' });
                InCallManager.setForceSpeakerphoneOn(false);
            }

            return true;
        } catch (e) {
            console.error('[WebRTC] Failed to get user media:', e);
            return false;
        }
    }

    hasLocalVideoTrack(): boolean {
        try {
            return !!this.localStream && (this.localStream.getVideoTracks?.().length ?? 0) > 0;
        } catch {
            return false;
        }
    }

    /**
     * Lazily add a local camera track to an active audio call so the call can be upgraded.
     * Returns true when a video track exists and is enabled locally.
     */
    async ensureLocalVideoTrack(): Promise<boolean> {
        const available = await this.loadWebRTC();
        if (!available || !mediaDevices) return false;

        try {
            if (!this.localStream) {
                return this.initializeMedia(true);
            }

            const existingTracks = this.localStream.getVideoTracks?.() ?? [];
            if (existingTracks.length > 0) {
                existingTracks.forEach((track: any) => {
                    track.enabled = true;
                });
                return true;
            }

            const videoOnlyStream = await mediaDevices.getUserMedia({
                audio: false,
                video: {
                    facingMode: 'user',
                    width: { ideal: 1920, min: 640 },
                    height: { ideal: 1080, min: 480 },
                    frameRate: { ideal: 30, min: 15 },
                },
            });

            const newVideoTracks = videoOnlyStream?.getVideoTracks?.() ?? [];
            if (newVideoTracks.length === 0) return false;

            for (const track of newVideoTracks) {
                track.enabled = true;
                this.localStream.addTrack?.(track);
                if (this.peerConnection) {
                    this.peerConnection.addTrack(track, this.localStream);
                }
            }

            if (InCallManager) {
                try {
                    InCallManager.start({ media: 'video' });
                } catch {
                    // Ignore InCallManager upgrade issues.
                }
            }

            return true;
        } catch (e) {
            console.error('[WebRTC] Failed to add local video track:', e);
            return false;
        }
    }

    /**
     * Create peer connection and add local tracks.
     * @param forceRelay - Force all media through TURN relay (for filtered networks)
     */
    async createPeerConnection(forceRelay: boolean = false): Promise<boolean> {
        if (!RTCPeerConnection) return false;

        try {
            // Ensure we have ICE credentials
            await this.fetchIceServers();

            const config = this.getIceConfig(forceRelay);

            this.peerConnection = new RTCPeerConnection(config);

            // Add local tracks to connection
            if (this.localStream) {
                this.localStream.getTracks().forEach((track: any) => {
                    this.peerConnection.addTrack(track, this.localStream);
                });
            }

            // Apply initial bitrate limits for video
            this.applyBitrateLimit(QUALITY_TIERS[0]);

            // Handle remote tracks
            this.peerConnection.ontrack = (event: any) => {
                if (event.streams && event.streams[0]) {
                    this.remoteStream = event.streams[0];
                    this.onRemoteStream?.(this.remoteStream);
                }
            };

            // Handle ICE candidates
            this.peerConnection.onicecandidate = (event: any) => {
                if (event.candidate) {
                    this.onIceCandidate?.(event.candidate);
                }
            };

            // Handle connection state changes
            this.peerConnection.onconnectionstatechange = () => {
                const state = this.peerConnection?.connectionState;
                this.onConnectionStateChange?.(state);
            };

            this.peerConnection.oniceconnectionstatechange = () => {
                // ICE state tracking for debugging
            };

            return true;
        } catch (e) {
            console.error('[WebRTC] Failed to create peer connection:', e);
            return false;
        }
    }

    /**
     * Apply bitrate and resolution limits to the video sender.
     * Uses RTCRtpSender.setParameters() for real-time quality adaptation.
     */
    private applyBitrateLimit(tier: QualityTier): void {
        if (!this.peerConnection) return;

        try {
            const senders = this.peerConnection.getSenders?.();
            if (!senders) return;

            for (const sender of senders) {
                if (sender.track?.kind !== 'video') continue;

                const params = sender.getParameters?.();
                if (!params) continue;

                if (!params.encodings || params.encodings.length === 0) {
                    params.encodings = [{}];
                }

                params.encodings[0].maxBitrate = tier.maxBitrate;
                params.encodings[0].maxFramerate = tier.maxFramerate;
                if (tier.scaleDown > 1.0) {
                    params.encodings[0].scaleResolutionDownBy = tier.scaleDown;
                } else {
                    delete params.encodings[0].scaleResolutionDownBy;
                }

                sender.setParameters?.(params);
            }
        } catch (e) {
            // setParameters not supported in all RN WebRTC versions — fail silently
        }
    }

    /**
     * Start monitoring bandwidth and adapting quality.
     * Polls getStats() every 4 seconds and adjusts bitrate tier.
     */
    startBandwidthMonitor(): void {
        this.stopBandwidthMonitor();
        this.currentTierIndex = 0;
        this.lastBytesSent = 0;
        this.lastBytesTimestamp = 0;

        this.bandwidthMonitorInterval = setInterval(async () => {
            if (!this.peerConnection) return;

            try {
                const stats = await this.peerConnection.getStats();
                if (!stats) return;

                let totalBytesSent = 0;
                stats.forEach((report: any) => {
                    if (report.type === 'outbound-rtp' && report.kind === 'video') {
                        totalBytesSent += report.bytesSent || 0;
                    }
                });

                const now = Date.now();
                if (this.lastBytesTimestamp > 0 && totalBytesSent > this.lastBytesSent) {
                    const elapsed = (now - this.lastBytesTimestamp) / 1000;
                    const bps = ((totalBytesSent - this.lastBytesSent) * 8) / elapsed;

                    // Determine target tier based on measured throughput
                    let targetTier = QUALITY_TIERS.length - 1; // worst case
                    for (let i = 0; i < QUALITY_TIERS.length; i++) {
                        // Allow headroom: if throughput is at least 80% of tier's max, use that tier
                        if (bps >= QUALITY_TIERS[i].maxBitrate * 0.8) {
                            targetTier = i;
                            break;
                        }
                    }

                    if (targetTier !== this.currentTierIndex) {
                        this.currentTierIndex = targetTier;
                        this.applyBitrateLimit(QUALITY_TIERS[targetTier]);
                    }
                }

                this.lastBytesSent = totalBytesSent;
                this.lastBytesTimestamp = now;
            } catch (e) {
                // getStats may fail — ignore
            }
        }, 4000);
    }

    /**
     * Stop bandwidth monitoring.
     */
    stopBandwidthMonitor(): void {
        if (this.bandwidthMonitorInterval) {
            clearInterval(this.bandwidthMonitorInterval);
            this.bandwidthMonitorInterval = null;
        }
    }

    /**
     * Create an SDP offer (caller side)
     */
    async createOffer(forceRelay: boolean = false): Promise<any | null> {
        const created = await this.createPeerConnection(forceRelay);
        if (!created || !this.peerConnection) return null;

        try {
            const offer = await this.peerConnection.createOffer({
                offerToReceiveAudio: true,
                offerToReceiveVideo: true,
            });

            await this.peerConnection.setLocalDescription(offer);

            // Notify that offer is ready to send
            this.onOffer?.(this.peerConnection.localDescription);

            return this.peerConnection.localDescription;
        } catch (e) {
            console.error('[WebRTC] Failed to create offer:', e);
            return null;
        }
    }

    /**
     * Create a renegotiation offer on an existing peer connection (e.g., voice -> video upgrade).
     */
    async createRenegotiationOffer(): Promise<any | null> {
        if (!this.peerConnection) return null;

        try {
            const offer = await this.peerConnection.createOffer({
                offerToReceiveAudio: true,
                offerToReceiveVideo: true,
            });
            await this.peerConnection.setLocalDescription(offer);
            this.onOffer?.(this.peerConnection.localDescription);
            return this.peerConnection.localDescription;
        } catch (e) {
            console.error('[WebRTC] Failed to create renegotiation offer:', e);
            return null;
        }
    }

    /**
     * Handle incoming offer and create answer (callee side)
     */
    async handleOffer(offer: any, forceRelay: boolean = false): Promise<any | null> {
        if (!this.peerConnection) {
            const created = await this.createPeerConnection(forceRelay);
            if (!created) return null;
        }
        if (!this.peerConnection || !RTCSessionDescription) return null;

        try {
            await this.peerConnection.setRemoteDescription(
                new RTCSessionDescription(offer)
            );

            const answer = await this.peerConnection.createAnswer();
            await this.peerConnection.setLocalDescription(answer);

            // Notify that answer is ready to send
            this.onAnswer?.(this.peerConnection.localDescription);

            return this.peerConnection.localDescription;
        } catch (e) {
            console.error('[WebRTC] Failed to handle offer:', e);
            return null;
        }
    }

    /**
     * Handle incoming answer (caller side)
     */
    async handleAnswer(answer: any): Promise<boolean> {
        if (!this.peerConnection || !RTCSessionDescription) return false;

        try {
            await this.peerConnection.setRemoteDescription(
                new RTCSessionDescription(answer)
            );
            return true;
        } catch (e) {
            console.error('[WebRTC] Failed to handle answer:', e);
            return false;
        }
    }

    /**
     * Add ICE candidate from remote peer
     */
    async handleIceCandidate(candidate: any): Promise<boolean> {
        if (!this.peerConnection || !RTCIceCandidate) return false;

        try {
            await this.peerConnection.addIceCandidate(
                new RTCIceCandidate(candidate)
            );
            return true;
        } catch (e) {
            console.error('[WebRTC] Failed to add ICE candidate:', e);
            return false;
        }
    }

    /**
     * Get local media stream for UI rendering
     */
    getLocalStream(): any {
        return this.localStream;
    }

    /**
     * Get remote media stream for UI rendering
     */
    getRemoteStream(): any {
        return this.remoteStream;
    }

    /**
     * Toggle microphone
     */
    setAudioEnabled(enabled: boolean): void {
        if (this.localStream) {
            this.localStream.getAudioTracks().forEach((track: any) => {
                track.enabled = enabled;
            });
        }
    }

    /**
     * Toggle camera
     */
    setVideoEnabled(enabled: boolean): void {
        if (this.localStream) {
            this.localStream.getVideoTracks().forEach((track: any) => {
                track.enabled = enabled;
            });
        }
    }

    /**
     * Switch between front/back camera
     */
    flipCamera(): void {
        if (this.localStream) {
            this.localStream.getVideoTracks().forEach((track: any) => {
                if (track._switchCamera) {
                    track._switchCamera();
                }
            });
        }
    }

    /**
     * Toggle speaker (via InCallManager if available)
     */
    setSpeakerEnabled(enabled: boolean): void {
        if (InCallManager) {
            InCallManager.setForceSpeakerphoneOn(enabled);
        }
    }

    /**
     * Clean up all resources
     */
    cleanup(): void {
        this.stopBandwidthMonitor();

        // Stop local tracks
        if (this.localStream) {
            this.localStream.getTracks().forEach((track: any) => track.stop());
            this.localStream = null;
        }

        // Close peer connection
        if (this.peerConnection) {
            this.peerConnection.close();
            this.peerConnection = null;
        }

        this.remoteStream = null;
        this.currentTierIndex = 0;
        this.lastBytesSent = 0;
        this.lastBytesTimestamp = 0;

        // Stop InCallManager
        if (InCallManager) {
            try {
                InCallManager.stop();
            } catch (e) {
                // Ignore
            }
        }
        this.removeInCallProximityListener();
    }
}

export default WebRTCService.getInstance();
