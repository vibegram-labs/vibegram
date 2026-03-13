/**
 * RelayNode — Turns a user's device into a relay bridge
 *
 * When enabled, this device accepts connections from filtered users
 * and forwards their encrypted traffic to the Vibe server.
 *
 * The relay CANNOT read any user data — it just forwards encrypted blobs.
 *
 * Flow:
 * 1. Relay user enables "Become a Relay" in settings
 * 2. RelayNode generates a keypair and registers with the relay directory
 * 3. Filtered users connect via WebRTC data channel (looks like video call to DPI)
 * 4. RelayNode receives VibeNet frames, decrypts transport layer, re-encrypts for server
 * 5. Server responses are relayed back through the same channel
 */

import { Buffer } from 'buffer';
import * as Localization from 'expo-localization';
import {
    SessionKeys,
    deriveSessionKeys,
    generateInviteCode,
    encodeFrame,
    decodeFrame,
    wrapTLS,
    unwrapTLS,
    MessageType,
    VibeNetFrame,
    decodeHTTPRequest,
    encodeHTTPResponse,
    decodeWSFrame,
    encodeWSFrame,
} from './VibeNetProtocol';
import { AppState, AppStateStatus } from 'react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';
import ProxyManager from '../ProxyManager';
import { registerRelayAsBridge } from './RelayBridgeLink';

// ─── Types ────────────────────────────────────────────────────────

export interface RelayConfig {
    enabled: boolean;
    isPublic: boolean;
    maxPeers: number;
    bandwidthLimitMB: number;
    wifiOnly: boolean;
    name: string;
    inviteCode: string | null;
    inviteKey: string | null;
    relayId: string | null;
    bridgeShareLink: string | null;
    bridgeExternalIp: string | null;
}

export interface ConnectedPeer {
    peerId: string;
    sessionKeys: SessionKeys;
    connectedAt: number;
    bytesRelayed: number;
    lastActivity: number;
    sequence: number;
}

export type RelayStatus = 'stopped' | 'starting' | 'running' | 'error';

type RelayEventCallback = (event: string, data: any) => void;

const DEFAULT_CONFIG: RelayConfig = {
    enabled: false,
    isPublic: false,
    maxPeers: 5,
    bandwidthLimitMB: 100,
    wifiOnly: true,
    name: '',
    inviteCode: null,
    inviteKey: null,
    relayId: null,
    bridgeShareLink: null,
    bridgeExternalIp: null,
};

const STORAGE_KEY = 'vibenet_relay_config';

// Timezone → region mapping for relay discovery
function detectRegion(): string {
    try {
        const locales = Localization.getLocales();
        if (locales && locales.length > 0 && locales[0].regionCode) {
            const region = locales[0].regionCode.toLowerCase();
            console.log('[RelayNode] Detected region via expo-localization:', region);
            return region;
        }

        const tz = Intl.DateTimeFormat().resolvedOptions().timeZone || '';
        console.log('[RelayNode] Fallback timezone detection:', tz);
        const lower = tz.toLowerCase();
        // US timezones
        if (lower.includes('new_york') || lower.includes('chicago') || lower.includes('denver') || lower.includes('indiana')) return 'us-east';
        if (lower.includes('los_angeles') || lower.includes('phoenix') || lower.includes('anchorage') || lower.includes('honolulu')) return 'us-west';
        // Canada
        if (lower.includes('toronto') || lower.includes('vancouver') || lower.includes('montreal') || lower.includes('winnipeg') || lower.includes('edmonton')) return 'ca';
        // Americas
        if (lower.includes('sao_paulo') || lower.includes('fortaleza') || lower.includes('bahia')) return 'br';
        if (lower.startsWith('america/')) return 'us';
        // Europe
        if (lower.includes('london')) return 'uk';
        if (lower.includes('berlin') || lower.includes('munich') || lower.includes('vienna') || lower.includes('zurich')) return 'de';
        if (lower.includes('paris')) return 'fr';
        if (lower.includes('amsterdam')) return 'nl';
        if (lower.includes('istanbul')) return 'tr';
        if (lower.startsWith('europe/')) return 'eu';
        // Asia-Pacific
        if (lower.includes('tokyo')) return 'jp';
        if (lower.includes('seoul')) return 'kr';
        if (lower.includes('hong_kong')) return 'hk';
        if (lower.includes('singapore')) return 'sg';
        if (lower.includes('kolkata') || lower.includes('mumbai') || lower.includes('calcutta')) return 'in';
        if (lower.startsWith('australia/') || lower.includes('sydney') || lower.includes('melbourne')) return 'au';
        // Middle East / Africa
        if (lower.includes('dubai') || lower.includes('riyadh') || lower.includes('tehran')) return 'tr';
        if (lower.includes('jerusalem') || lower.includes('tel_aviv')) return 'eu';

        return 'unknown';
    } catch (e) {
        console.warn('[RelayNode] Failed to detect region:', e);
        return 'unknown';
    }
}

// ─── RelayNode Class ─────────────────────────────────────────────

class RelayNode {
    private static instance: RelayNode;
    private config: RelayConfig = { ...DEFAULT_CONFIG };
    private peers: Map<string, ConnectedPeer> = new Map();
    private status: RelayStatus = 'stopped';
    private listeners: RelayEventCallback[] = [];
    private signalingChannel: any = null; // Phoenix channel for signaling
    private keepaliveInterval: any = null;
    private lastSocket: any = null; // Cached socket ref for auto-reconnect
    private appStateSubscription: any = null;

    private constructor() {
        this.loadConfig();
        this.setupAppStateListener();
    }

    private setupAppStateListener() {
        this.appStateSubscription = AppState.addEventListener('change', (nextState: AppStateStatus) => {
            if (nextState === 'active') {
                this.handleAppForeground();
            }
        });
    }

    private async handleAppForeground() {
        // If relay was enabled but channel is dead, reconnect
        if (this.config.enabled && this.status !== 'starting') {
            const channelAlive = this.signalingChannel?.state === 'joined';
            if (!channelAlive) {
                console.log('[RelayNode] App foregrounded — relay was enabled, reconnecting...');
                this.status = 'stopped';
                this.peers.clear();
                if (this.lastSocket && this.lastSocket.isConnected?.()) {
                    await this.startRelay(this.lastSocket);
                } else {
                    // Socket not available yet — mark as stopped, UI will see it
                    this.emit('status-changed', 'stopped');
                }
            }
        }
    }

    static getInstance(): RelayNode {
        if (!RelayNode.instance) {
            RelayNode.instance = new RelayNode();
        }
        return RelayNode.instance;
    }

    // ─── Configuration ────────────────────────────────────────────

    private async loadConfig() {
        try {
            const saved = await AsyncStorage.getItem(STORAGE_KEY);
            if (saved) {
                this.config = { ...DEFAULT_CONFIG, ...JSON.parse(saved) };
            }
        } catch (e) {
            console.warn('[RelayNode] Failed to load config:', e);
        }
    }

    private async saveConfig() {
        try {
            await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(this.config));
        } catch (e) {
            console.warn('[RelayNode] Failed to save config:', e);
        }
    }

    getConfig(): RelayConfig {
        return { ...this.config };
    }

    getStatus(): RelayStatus {
        return this.status;
    }

    getPeers(): ConnectedPeer[] {
        return Array.from(this.peers.values());
    }

    getPeerCount(): number {
        return this.peers.size;
    }

    getTotalBytesRelayed(): number {
        let total = 0;
        this.peers.forEach(p => total += p.bytesRelayed);
        return total;
    }

    // ─── Relay Lifecycle ──────────────────────────────────────────

    async updateConfig(updates: Partial<RelayConfig>) {
        const wasPublic = this.config.isPublic;
        this.config = { ...this.config, ...updates };
        await this.saveConfig();
        this.emit('config-changed', this.config);

        // If the relay is running and visibility changed, re-join channel with updated params
        if (this.status === 'running' && this.signalingChannel && this.lastSocket) {
            if (this.config.isPublic !== wasPublic || this.config.isPublic) {
                // Re-join channel with correct is_public param so server sees it
                const socket = this.lastSocket;
                if (socket && socket.isConnected()) {
                    const region = detectRegion();
                    try { this.signalingChannel.leave(); } catch { }
                    this.signalingChannel = socket.channel(`relay:${this.config.relayId}`, {
                        invite_code: this.config.inviteCode,
                        invite_key: this.config.inviteKey,
                        is_public: this.config.isPublic,
                        name: this.config.name || 'Relay Node',
                        max_peers: this.config.maxPeers,
                        region,
                    });
                    this.signalingChannel.join()
                        .receive('ok', () => {
                            console.log('[RelayNode] Re-joined channel with is_public:', this.config.isPublic, 'region:', region);
                            // Re-announce if public
                            if (this.config.isPublic) {
                                this.signalingChannel.push('announce', {
                                    relay_id: this.config.relayId,
                                    name: this.config.name || 'Relay Node',
                                    max_peers: this.config.maxPeers,
                                    current_peers: this.peers.size,
                                    invite_code: this.config.inviteCode,
                                    invite_key: this.config.inviteKey,
                                    region,
                                })
                                    .receive('ok', () => console.log('[RelayNode] Announce accepted'))
                                    .receive('error', (e: any) => console.warn('[RelayNode] Announce failed:', e));
                            }
                        })
                        .receive('error', (err: any) => console.error('[RelayNode] Re-join failed:', err));

                    // Re-attach event listeners
                    this.signalingChannel.on('peer_connect', (payload: any) => this.handlePeerConnect(payload));
                    this.signalingChannel.on('peer_data', (payload: any) => this.handlePeerData(payload));
                    this.signalingChannel.on('peer_disconnect', (payload: any) => this.handlePeerDisconnect(payload));
                }
            }
        }
    }

    async startRelay(socket: any): Promise<{ success: boolean; inviteCode?: string; shareLink?: string; error?: string }> {
        if (this.status === 'running' || this.status === 'starting') {
            return { success: true, inviteCode: this.config.inviteCode || undefined };
        }

        // Cache socket for auto-reconnect on app foreground
        if (socket) this.lastSocket = socket;

        this.status = 'starting';
        this.emit('status-changed', this.status);

        try {
            // Generate invite code if none exists
            if (!this.config.inviteCode) {
                const { code, key } = generateInviteCode();
                this.config.inviteCode = code;
                this.config.inviteKey = key;
                this.config.relayId = 'relay_' + Date.now().toString(36) + Math.random().toString(36).substring(2, 8);
                await this.saveConfig();
            }

            // Join signaling channel on Phoenix server
            if (socket && socket.isConnected()) {
                // Clean up any existing channel first
                if (this.signalingChannel) {
                    try { this.signalingChannel.leave(); } catch { }
                    this.signalingChannel = null;
                }

                const region = detectRegion();
                this.signalingChannel = socket.channel(`relay:${this.config.relayId}`, {
                    invite_code: this.config.inviteCode,
                    invite_key: this.config.inviteKey,
                    is_public: this.config.isPublic,
                    name: this.config.name || 'Relay Node',
                    max_peers: this.config.maxPeers,
                    region,
                });

                this.signalingChannel.join()
                    .receive('ok', () => {
                        console.log('[RelayNode] Joined signaling channel, region:', region);
                    })
                    .receive('error', (err: any) => {
                        console.error('[RelayNode] Failed to join signaling channel:', err);
                    });

                // Listen for incoming peer connections
                this.signalingChannel.on('peer_connect', (payload: any) => {
                    this.handlePeerConnect(payload);
                });

                // Listen for peer data (relay traffic)
                this.signalingChannel.on('peer_data', (payload: any) => {
                    this.handlePeerData(payload);
                });

                // Listen for peer disconnection
                this.signalingChannel.on('peer_disconnect', (payload: any) => {
                    this.handlePeerDisconnect(payload);
                });

                // Announce to relay directory if public
                if (this.config.isPublic) {
                    this.signalingChannel.push('announce', {
                        relay_id: this.config.relayId,
                        name: this.config.name || 'Relay Node',
                        max_peers: this.config.maxPeers,
                        current_peers: 0,
                        invite_code: this.config.inviteCode,
                        invite_key: this.config.inviteKey,
                        region,
                    });
                }
            }

            // Start keepalive
            this.keepaliveInterval = setInterval(() => {
                this.sendKeepalives();
            }, 30000);

            this.config.enabled = true;
            this.status = 'running';
            await this.saveConfig();
            this.emit('status-changed', this.status);

            // Register as a bridge on the server (async, non-blocking)
            this.registerAsBridge();

            return {
                success: true,
                inviteCode: this.config.inviteCode || undefined,
                shareLink: this.config.bridgeShareLink || undefined,
            };

        } catch (e: any) {
            this.status = 'error';
            this.emit('status-changed', this.status);
            return { success: false, error: e.message };
        }
    }

    getShareLink(): string | null {
        return this.config.bridgeShareLink;
    }

    getExternalIp(): string | null {
        return this.config.bridgeExternalIp;
    }

    private async registerAsBridge() {
        try {
            const result = await registerRelayAsBridge(
                this.config.relayId || '',
                this.config.inviteCode,
                this.config.name || 'Relay Node',
            );

            if (result.success) {
                this.config.bridgeShareLink = result.shareLink || null;
                this.config.bridgeExternalIp = result.externalIp || null;
                await this.saveConfig();
                this.emit('config-changed', this.config);
                this.emit('bridge-registered', {
                    shareLink: result.shareLink,
                    externalIp: result.externalIp,
                    bridgeUrl: result.bridgeUrl,
                });
                console.log('[RelayNode] Registered as bridge. Share link:', result.shareLink);
            } else {
                console.warn('[RelayNode] Bridge registration failed:', result.error);
            }
        } catch (e) {
            console.warn('[RelayNode] Bridge registration error:', e);
        }
    }

    async stopRelay() {
        if (this.keepaliveInterval) {
            clearInterval(this.keepaliveInterval);
            this.keepaliveInterval = null;
        }

        // Disconnect all peers
        this.peers.forEach((peer, peerId) => {
            if (this.signalingChannel) {
                this.signalingChannel.push('peer_kicked', { peer_id: peerId });
            }
        });
        this.peers.clear();

        // Leave signaling channel
        if (this.signalingChannel) {
            this.signalingChannel.leave();
            this.signalingChannel = null;
        }

        this.config.enabled = false;
        this.status = 'stopped';
        await this.saveConfig();
        this.emit('status-changed', this.status);
    }

    // ─── Peer Handling ────────────────────────────────────────────

    private handlePeerConnect(payload: any) {
        console.log('[RelayNode] handlePeerConnect received:', { peer_id: payload.peer_id, hasSecret: !!payload.shared_secret });
        const { peer_id, shared_secret } = payload;

        if (this.peers.size >= this.config.maxPeers) {
            console.log('[RelayNode] Max peers reached, rejecting:', peer_id);
            this.signalingChannel?.push('peer_rejected', {
                peer_id,
                reason: 'max_peers',
            });
            return;
        }

        // Derive session keys from the shared secret
        const secret = Buffer.from(shared_secret, 'base64');
        const sessionKeys = deriveSessionKeys(secret, false); // Relay is responder

        const peer: ConnectedPeer = {
            peerId: peer_id,
            sessionKeys,
            connectedAt: Date.now(),
            bytesRelayed: 0,
            lastActivity: Date.now(),
            sequence: 0,
        };

        this.peers.set(peer_id, peer);
        this.emit('peer-connected', { peerId: peer_id, peerCount: this.peers.size });

        // Send handshake response
        this.signalingChannel?.push('peer_accepted', {
            peer_id,
            session_id: sessionKeys.sessionId,
        });

        // Update directory
        if (this.config.isPublic) {
            this.signalingChannel?.push('update_status', {
                current_peers: this.peers.size,
            });
        }

        console.log(`[RelayNode] Peer connected: ${peer_id} (${this.peers.size}/${this.config.maxPeers})`);
    }

    private async handlePeerData(payload: any) {
        const { peer_id, data: encodedData } = payload;
        const peer = this.peers.get(peer_id);
        if (!peer) return;

        peer.lastActivity = Date.now();

        try {
            // Decode the incoming frame
            const rawData = Buffer.from(encodedData, 'base64');

            // Unwrap TLS mimicry if present
            const unwrapped = unwrapTLS(rawData) || rawData;

            // Decode VibeNet frame
            const frame = decodeFrame(unwrapped, peer.sessionKeys);
            if (!frame) {
                console.warn('[RelayNode] Failed to decode frame from peer:', peer_id);
                return;
            }

            peer.bytesRelayed += rawData.length;
            this.emit('data-relayed', this.getTotalBytesRelayed());

            // Handle different frame types
            switch (frame.type) {
                case MessageType.DATA:
                    await this.relayHTTPRequest(peer, frame);
                    break;
                case MessageType.RELAY_REQUEST:
                    await this.relayWSFrame(peer, frame);
                    break;
                case MessageType.KEEPALIVE:
                    // Just update lastActivity
                    break;
                default:
                    console.warn('[RelayNode] Unknown frame type:', frame.type);
            }
        } catch (e) {
            console.error('[RelayNode] Error handling peer data:', e);
        }
    }

    /**
     * Relay an HTTP request from a peer to the Vibe server
     * The relay CANNOT read the application-layer content (E2E encrypted)
     * It only sees the URL path and forwards the request
     */
    private async relayHTTPRequest(peer: ConnectedPeer, frame: VibeNetFrame) {
        const request = decodeHTTPRequest(frame.payload);
        if (!request) return;

        const baseUrl = ProxyManager.getInstance().getBestUrl();
        const url = `${baseUrl}${request.path}`;

        try {
            const controller = new AbortController();
            const timeout = setTimeout(() => controller.abort(), 30000);

            const response = await fetch(url, {
                method: request.method,
                headers: {
                    ...request.headers,
                    'ngrok-skip-browser-warning': 'true',
                },
                body: request.body || undefined,
                signal: controller.signal,
            });

            clearTimeout(timeout);

            const responseBody = await response.text();
            const responseHeaders: Record<string, string> = {};
            response.headers.forEach((value, key) => {
                responseHeaders[key] = value;
            });

            // Encode response and send back to peer
            const responsePayload = encodeHTTPResponse(response.status, responseHeaders, responseBody);
            const responseFrame: VibeNetFrame = {
                type: MessageType.DATA,
                payload: responsePayload,
                sessionId: peer.sessionKeys.sessionId,
                sequence: ++peer.sequence,
            };

            const encoded = encodeFrame(responseFrame, peer.sessionKeys);
            const wrapped = wrapTLS(encoded);

            this.signalingChannel?.push('peer_data', {
                peer_id: peer.peerId,
                data: wrapped.toString('base64'),
            });

            peer.bytesRelayed += wrapped.length;
            this.emit('data-relayed', this.getTotalBytesRelayed());
        } catch (e: any) {
            console.error('[RelayNode] HTTP relay error:', e.message);
            // Send error response
            const errorPayload = encodeHTTPResponse(502, {}, JSON.stringify({ error: 'relay_error' }));
            const errorFrame: VibeNetFrame = {
                type: MessageType.DATA,
                payload: errorPayload,
                sessionId: peer.sessionKeys.sessionId,
                sequence: ++peer.sequence,
            };
            const encoded = encodeFrame(errorFrame, peer.sessionKeys);
            this.signalingChannel?.push('peer_data', {
                peer_id: peer.peerId,
                data: encoded.toString('base64'),
            });
        }
    }

    /**
     * Relay a WebSocket frame from a peer
     */
    private async relayWSFrame(peer: ConnectedPeer, frame: VibeNetFrame) {
        const wsData = decodeWSFrame(frame.payload);
        if (!wsData) return;

        // Forward through the relay's own connection to the server
        // The actual WebSocket messages are E2E encrypted — relay can't read them
        this.emit('relay-ws', { peerId: peer.peerId, ...wsData });
    }

    private handlePeerDisconnect(payload: any) {
        const { peer_id } = payload;
        const peer = this.peers.get(peer_id);
        if (peer) {
            this.peers.delete(peer_id);
            this.emit('peer-disconnected', {
                peerId: peer_id,
                bytesRelayed: peer.bytesRelayed,
                peerCount: this.peers.size,
            });

            // Update directory
            if (this.config.isPublic && this.signalingChannel) {
                this.signalingChannel.push('update_status', {
                    current_peers: this.peers.size,
                });
            }

            console.log(`[RelayNode] Peer disconnected: ${peer_id} (relayed ${formatBytes(peer.bytesRelayed)})`);
        }
    }

    private sendKeepalives() {
        this.peers.forEach((peer) => {
            const now = Date.now();
            // Disconnect inactive peers (5 minutes)
            if (now - peer.lastActivity > 300000) {
                this.handlePeerDisconnect({ peer_id: peer.peerId });
                return;
            }

            const keepaliveFrame: VibeNetFrame = {
                type: MessageType.KEEPALIVE,
                payload: Buffer.alloc(0),
                sessionId: peer.sessionKeys.sessionId,
                sequence: ++peer.sequence,
            };

            const encoded = encodeFrame(keepaliveFrame, peer.sessionKeys);
            this.signalingChannel?.push('peer_data', {
                peer_id: peer.peerId,
                data: encoded.toString('base64'),
            });
        });
    }

    // ─── Event System ─────────────────────────────────────────────

    subscribe(callback: RelayEventCallback): () => void {
        this.listeners.push(callback);
        return () => {
            this.listeners = this.listeners.filter(l => l !== callback);
        };
    }

    private emit(event: string, data: any) {
        this.listeners.forEach(cb => cb(event, data));
    }
}

// ─── Helpers ──────────────────────────────────────────────────────

const formatBytes = (bytes: number): string => {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / 1048576).toFixed(1)} MB`;
};

export default RelayNode;
