/**
 * RelayClient — Connects filtered users to relay nodes
 *
 * This is the counterpart to RelayNode. A filtered user (User B)
 * uses RelayClient to connect to a relay (User A) and route all
 * their Vibe traffic through that relay.
 *
 * Connection methods:
 * 1. Invite code (private relay) — enter VIBE-XXXX-XXXX code
 * 2. Directory browse (public relay) — pick from available relays
 * 3. Deep link / QR code — auto-connect
 *
 * All traffic is E2E encrypted — the relay cannot read anything.
 */

import { Buffer } from 'buffer';
import AsyncStorage from '@react-native-async-storage/async-storage';
import {
    SessionKeys,
    deriveSessionKeys,
    encodeFrame,
    decodeFrame,
    wrapTLS,
    unwrapTLS,
    MessageType,
    VibeNetFrame,
    encodeHTTPRequest,
    decodeHTTPResponse,
    encodeWSFrame,
    decodeWSFrame,
} from './VibeNetProtocol';
import type { BridgeDescriptor } from '../transport/types';
import {
    activateBridgeDescriptor,
    deactivateBridgeTransport,
    resolveBridgeByInviteCode,
} from './RelayBridgeLink';

// ─── Types ────────────────────────────────────────────────────────

export type ConnectionStatus = 'disconnected' | 'connecting' | 'handshaking' | 'connected' | 'reconnecting' | 'error';

export interface RelayInfo {
    relayId: string;
    name: string;
    inviteCode?: string;
    inviteKey?: string;
    isPublic: boolean;
    region?: string;
    latency?: number;
    peerCount?: number;
    maxPeers?: number;
    externalIp?: string;
    bridgeUrl?: string;
    shareLink?: string;
    bridgeDescriptor?: BridgeDescriptor;
}

export interface PendingRequest {
    resolve: (value: any) => void;
    reject: (reason: any) => void;
    timeout: any;
    sequence: number;
}

type ClientEventCallback = (event: string, data: any) => void;

const STORAGE_KEY = 'vibenet_relay_client';
const RECONNECT_DELAYS = [1000, 2000, 5000, 10000, 30000]; // Progressive backoff

// ─── RelayClient Class ───────────────────────────────────────────

class RelayClient {
    private static instance: RelayClient;

    private status: ConnectionStatus = 'disconnected';
    private currentRelay: RelayInfo | null = null;
    private sessionKeys: SessionKeys | null = null;
    private signalingChannel: any = null;
    private socket: any = null;
    private sequence: number = 0;
    private pendingRequests: Map<number, PendingRequest> = new Map();
    private listeners: ClientEventCallback[] = [];
    private reconnectAttempt: number = 0;
    private reconnectTimer: any = null;
    private keepaliveInterval: any = null;
    private savedRelays: RelayInfo[] = [];
    private wsEventHandlers: Map<string, ((data: any) => void)[]> = new Map();
    private bytesSent: number = 0;
    private bytesReceived: number = 0;
    private lastPingSent: number = 0;
    private currentLatency: number | null = null;
    private missedPings: number = 0;
    private connectedViaBridge: boolean = false;

    private constructor() {
        this.loadSavedRelays();
    }

    static getInstance(): RelayClient {
        if (!RelayClient.instance) {
            RelayClient.instance = new RelayClient();
        }
        return RelayClient.instance;
    }

    // ─── State ────────────────────────────────────────────────────

    getStatus(): ConnectionStatus {
        return this.status;
    }

    getCurrentRelay(): RelayInfo | null {
        return this.currentRelay;
    }

    isConnected(): boolean {
        return this.status === 'connected';
    }

    getSavedRelays(): RelayInfo[] {
        return [...this.savedRelays];
    }

    getBytesSent(): number {
        return this.bytesSent;
    }

    getBytesReceived(): number {
        return this.bytesReceived;
    }

    getLatency(): number | null {
        return this.currentLatency;
    }

    // ─── Saved Relays ─────────────────────────────────────────────

    private async loadSavedRelays() {
        try {
            const saved = await AsyncStorage.getItem(STORAGE_KEY);
            if (saved) {
                this.savedRelays = JSON.parse(saved);
            }
        } catch (e) {
            console.warn('[RelayClient] Failed to load saved relays:', e);
        }
    }

    private async saveSavedRelays() {
        try {
            await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(this.savedRelays));
        } catch (e) {
            console.warn('[RelayClient] Failed to save relays:', e);
        }
    }

    async addSavedRelay(relay: RelayInfo) {
        const index = this.savedRelays.findIndex(r => r.relayId === relay.relayId);
        if (index >= 0) {
            this.savedRelays[index] = { ...this.savedRelays[index], ...relay };
        } else {
            this.savedRelays.push(relay);
        }
        await this.saveSavedRelays();
    }

    async removeSavedRelay(relayId: string) {
        this.savedRelays = this.savedRelays.filter(r => r.relayId !== relayId);
        await this.saveSavedRelays();
    }

    // ─── Connection ───────────────────────────────────────────────

    /**
     * Connect to a relay using an invite code
     */
    async connectWithCode(inviteCode: string, socket: any): Promise<{ success: boolean; error?: string; mode?: 'relay' | 'bridge' }> {
        if (this.status === 'connected' || this.status === 'connecting') {
            await this.disconnect();
        }

        this.status = 'connecting';
        this.socket = socket;
        this.emit('status-changed', this.status);

        try {
            // Normalize code
            const code = inviteCode.toUpperCase().replace(/[^A-Z0-9-]/g, '');

            const bridgeResolution = await resolveBridgeByInviteCode(code);
            if (bridgeResolution.success && bridgeResolution.descriptor) {
                const bridgeResult = await this.connectToRelay({
                    relayId: bridgeResolution.descriptor.id || code,
                    name: bridgeResolution.descriptor.id || 'Relay Bridge',
                    inviteCode: code,
                    isPublic: false,
                    bridgeDescriptor: bridgeResolution.descriptor,
                    bridgeUrl: bridgeResolution.descriptor.baseUrl,
                    externalIp: bridgeResolution.descriptor.host,
                }, socket, true);
                if (bridgeResult.success || !socket) {
                    return bridgeResult;
                }
            }

            if (!socket) {
                this.status = 'error';
                this.emit('status-changed', this.status);
                return {
                    success: false,
                    error: bridgeResolution.error || 'Phoenix socket not connected',
                };
            }

            // Connect to the signaling channel to find the relay
            const lookupChannel = socket.channel('relay:lookup', { invite_code: code });

            return new Promise((resolve) => {
                lookupChannel.join()
                    .receive('ok', (response: any) => {
                        const { relay_id, name, invite_key, is_public, region } = response;

                        const relayInfo: RelayInfo = {
                            relayId: relay_id,
                            name,
                            inviteCode: code,
                            inviteKey: invite_key,
                            isPublic: is_public,
                            region: region || undefined,
                            externalIp: response.external_ip || undefined,
                            bridgeUrl: response.bridge_url || undefined,
                            shareLink: response.share_link || undefined,
                            bridgeDescriptor: response.bridge_descriptor || undefined,
                        };

                        // Now connect to the actual relay
                        lookupChannel.leave();
                        this.connectToRelay(relayInfo, socket, true)
                            .then(resolve)
                            .catch(e => resolve({ success: false, error: e.message }));
                    })
                    .receive('error', (err: any) => {
                        lookupChannel.leave();
                        this.status = 'error';
                        this.emit('status-changed', this.status);
                        resolve({ success: false, error: err.reason || 'Relay not found' });
                    });
            });

        } catch (e: any) {
            this.status = 'error';
            this.emit('status-changed', this.status);
            return { success: false, error: e.message };
        }
    }

    /**
     * Connect to a relay from the directory (public relay)
     */
    async connectToRelay(
        relay: RelayInfo,
        socket?: any,
        save: boolean = true,
    ): Promise<{ success: boolean; error?: string; mode?: 'relay' | 'bridge' }> {
        if (this.status === 'connected' || this.status === 'handshaking' || this.status === 'connecting') {
            await this.disconnect();
        }

        const bridgeDescriptor =
            relay.bridgeDescriptor
            || this.buildBridgeDescriptor(relay);
        const resolvedRelay: RelayInfo = bridgeDescriptor
            ? {
                ...relay,
                bridgeDescriptor,
                bridgeUrl: bridgeDescriptor.baseUrl || relay.bridgeUrl,
                externalIp: bridgeDescriptor.host || relay.externalIp,
            }
            : relay;

        if (bridgeDescriptor) {
            this.status = 'handshaking';
            this.currentRelay = resolvedRelay;
            this.emit('status-changed', this.status);

            const activation = await activateBridgeDescriptor(bridgeDescriptor);
            if (!activation.success) {
                const fallbackSocket = socket || this.socket;
                if (!fallbackSocket || !fallbackSocket.isConnected()) {
                    this.status = 'error';
                    this.emit('status-changed', this.status);
                    return { success: false, error: activation.error };
                }
                console.warn('[RelayClient] Bridge activation failed, falling back to Phoenix relay:', activation.error);
            }
            else {
                this.connectedViaBridge = true;
                this.sessionKeys = null;
                this.signalingChannel = null;
                this.status = 'connected';
                this.currentLatency = null;
                this.emit('status-changed', this.status);
                if (save && this.currentRelay) {
                    await this.addSavedRelay(this.currentRelay);
                }
                return { success: true, mode: 'bridge' };
            }
        }

        if (socket) this.socket = socket;
        this.connectedViaBridge = false;
        this.status = 'handshaking';
        this.currentRelay = resolvedRelay;
        this.emit('status-changed', this.status);

        try {
            if (!this.socket || !this.socket.isConnected()) {
                throw new Error('Phoenix socket not connected');
            }

            // Generate shared secret for this session
            const sharedSecretBytes = Buffer.alloc(32);
            if (relay.inviteKey) {
                // Derive from invite key — convert base64url back to standard base64
                const standardB64 = relay.inviteKey.replace(/-/g, '+').replace(/_/g, '/');
                const keyBuf = Buffer.from(standardB64, 'base64');
                keyBuf.copy(sharedSecretBytes, 0, 0, Math.min(keyBuf.length, 32));
            } else {
                // Random shared secret (for public relays, exchanged via signaling)
                let random: Buffer;
                try {
                    const { default: ExpoConstants, ExecutionEnvironment } = require('expo-constants');
                    if (ExpoConstants.executionEnvironment === ExecutionEnvironment.StoreClient) throw new Error('Expo Go');
                    const QC = require('react-native-quick-crypto');
                    random = Buffer.from((QC.default || QC).randomBytes(32));
                } catch {
                    // Fallback to forge
                    const forge = require('node-forge');
                    random = Buffer.from(forge.random.getBytesSync(32), 'binary');
                }
                random.copy(sharedSecretBytes);
            }

            // Derive session keys (we are the initiator)
            this.sessionKeys = deriveSessionKeys(sharedSecretBytes, true);
            this.sequence = 0;

            // Join the relay's signaling channel
            this.signalingChannel = this.socket.channel(`relay:${relay.relayId}`, {
                role: 'client',
                shared_secret: sharedSecretBytes.toString('base64'),
                invite_code: relay.inviteCode || undefined,
            });

            return new Promise((resolve) => {
                this.signalingChannel.join()
                    .receive('ok', () => {
                        console.log('[RelayClient] Connected to relay:', relay.relayId);

                        // Listen for relay data (responses)
                        this.signalingChannel.on('peer_data', (payload: any) => {
                            this.handleRelayData(payload);
                        });

                        // Listen for relay disconnect
                        this.signalingChannel.on('relay_closed', () => {
                            console.log('[RelayClient] Relay closed connection');
                            this.handleDisconnect();
                        });

                        // Handshake state tracking
                        let resolved = false;
                        const handshakeStart = Date.now();

                        const cleanupAndResolve = (result: { success: boolean; error?: string }) => {
                            if (resolved) return;
                            resolved = true;
                            clearInterval(checkConnected);
                            if (!result.success) {
                                this.signalingChannel?.leave();
                                this.signalingChannel = null;
                                this.sessionKeys = null;
                                this.status = 'error';
                                this.emit('status-changed', this.status);
                            }
                            resolve(result);
                        };

                        // Listen for accepted confirmation
                        this.signalingChannel.on('peer_accepted', (payload: any) => {
                            console.log('[RelayClient] peer_accepted received:', payload);
                            this.status = 'connected';
                            this.reconnectAttempt = 0;

                            // Measure latency from handshake round-trip
                            const measuredLatency = Date.now() - handshakeStart;
                            console.log('[RelayClient] Handshake latency:', measuredLatency, 'ms');
                            if (this.currentRelay) {
                                this.currentRelay.latency = measuredLatency;
                            }
                            this.currentLatency = measuredLatency;

                            this.emit('status-changed', this.status);

                            // Save this relay
                            if (save) {
                                this.addSavedRelay(this.currentRelay || resolvedRelay);
                            }

                            // Start keepalive
                            this.startKeepalive();
                        });

                        // Listen for rejection
                        this.signalingChannel.on('peer_rejected', (payload: any) => {
                            console.log('[RelayClient] peer_rejected:', payload);
                            cleanupAndResolve({ success: false, error: payload.reason || 'Rejected by relay' });
                        });

                        // Send handshake
                        console.log('[RelayClient] Sending peer_connect to relay:', relay.relayId);
                        this.signalingChannel.push('peer_connect', {
                            shared_secret: sharedSecretBytes.toString('base64'),
                        });

                        // Poll for connected status
                        const checkConnected = setInterval(() => {
                            if (this.status === 'connected' && !resolved) {
                                resolved = true;
                                clearInterval(checkConnected);
                            resolve({ success: true, mode: 'relay' });
                            }
                        }, 100);

                        // Timeout after 30s (increased for VPN/high latency)
                        setTimeout(() => {
                            if (!resolved && this.status === 'handshaking') {
                                console.log('[RelayClient] Handshake timed out after 30s for relay:', relay.relayId);
                                cleanupAndResolve({ success: false, error: 'Handshake timeout' });
                            }
                        }, 30000);
                    })
                    .receive('error', (err: any) => {
                        this.status = 'error';
                        this.emit('status-changed', this.status);
                        resolve({ success: false, error: err.reason || 'Failed to connect' });
                    });
            });

        } catch (e: any) {
            this.status = 'error';
            this.emit('status-changed', this.status);
            return { success: false, error: e.message };
        }
    }

    async disconnect() {
        if (this.keepaliveInterval) {
            clearInterval(this.keepaliveInterval);
            this.keepaliveInterval = null;
        }
        if (this.reconnectTimer) {
            clearTimeout(this.reconnectTimer);
            this.reconnectTimer = null;
        }

        // Reject all pending requests
        this.pendingRequests.forEach(req => {
            clearTimeout(req.timeout);
            req.reject(new Error('Disconnected'));
        });
        this.pendingRequests.clear();

        if (this.signalingChannel) {
            this.signalingChannel.leave();
            this.signalingChannel = null;
        }

        if (this.connectedViaBridge) {
            try {
                await deactivateBridgeTransport();
            } catch (error) {
                console.warn('[RelayClient] Failed to deactivate bridge transport:', error);
            }
        }

        this.sessionKeys = null;
        this.connectedViaBridge = false;
        this.status = 'disconnected';
        this.currentRelay = null;
        this.sequence = 0;
        this.bytesSent = 0;
        this.bytesReceived = 0;
        this.currentLatency = null;
        this.lastPingSent = 0;
        this.missedPings = 0;
        this.emit('status-changed', this.status);
    }

    private buildBridgeDescriptor(relay: RelayInfo): BridgeDescriptor | null {
        if (relay.bridgeDescriptor) return relay.bridgeDescriptor;
        if (!relay.bridgeUrl && !relay.externalIp) return null;
        return {
            id: relay.relayId || relay.inviteCode || relay.bridgeUrl || relay.externalIp || 'relay_bridge',
            host: relay.externalIp,
            port: 443,
            transport: 'https',
            origin: 'community',
            priority: 50,
            weight: 100,
            baseUrl: relay.bridgeUrl || undefined,
        };
    }

    // ─── HTTP Proxying ────────────────────────────────────────────

    /**
     * Send an HTTP request through the relay
     * This is the main API — replaces direct fetch() calls
     */
    async fetch(path: string, options: RequestInit = {}): Promise<Response> {
        if (!this.isConnected() || !this.sessionKeys) {
            throw new Error('Not connected to relay');
        }

        const method = (options.method || 'GET').toUpperCase();
        const headers: Record<string, string> = {};
        if (options.headers) {
            if (options.headers instanceof Headers) {
                options.headers.forEach((v, k) => headers[k] = v);
            } else if (Array.isArray(options.headers)) {
                options.headers.forEach(([k, v]) => headers[k] = v);
            } else {
                Object.assign(headers, options.headers);
            }
        }

        const body = options.body ? String(options.body) : undefined;
        const payload = encodeHTTPRequest(method, path, headers, body);

        const seq = ++this.sequence;

        // Handle absolute URLs by stripping the base if it matches known patterns, 
        // or passing it through if the relay supports arbitrary proxying (future)
        // For now, we assume the path is relative to the relay's target server
        let finalPath = path;
        if (path.startsWith('http')) {
            try {
                const urlObj = new URL(path);
                finalPath = urlObj.pathname + urlObj.search;
            } catch (e) {
                // If URL parsing fails, stick to original path
            }
        }

        const frame: VibeNetFrame = {
            type: MessageType.DATA,
            payload: encodeHTTPRequest(method, finalPath, headers, body),
            sessionId: this.sessionKeys.sessionId,
            sequence: seq,
        };

        // Encode, encrypt, and wrap in TLS mimicry
        const encoded = encodeFrame(frame, this.sessionKeys);
        const wrapped = wrapTLS(encoded);

        // Send through signaling channel
        return new Promise((resolve, reject) => {
            const timeout = setTimeout(() => {
                this.pendingRequests.delete(seq);
                reject(new Error('Relay request timeout'));
            }, 40000);

            this.pendingRequests.set(seq, {
                resolve: (responseData: any) => {
                    // Build a Response object from the relay response
                    const res = new Response(responseData.body, {
                        status: responseData.status,
                        headers: responseData.headers,
                    });
                    resolve(res);
                },
                reject,
                timeout,
                sequence: seq,
            });

            const b64 = wrapped.toString('base64');
            this.bytesSent += wrapped.length;
            this.emit('data-transferred', { bytesSent: this.bytesSent, bytesReceived: this.bytesReceived });
            this.signalingChannel?.push('peer_data', { data: b64 });
        });
    }

    // ─── WebSocket Proxying ───────────────────────────────────────

    /**
     * Send a WebSocket-like message through the relay
     */
    pushWS(topic: string, event: string, payload: any, ref?: string) {
        if (!this.isConnected() || !this.sessionKeys) return;

        const wsPayload = encodeWSFrame(topic, event, payload, ref);
        const seq = ++this.sequence;
        const frame: VibeNetFrame = {
            type: MessageType.RELAY_REQUEST,
            payload: wsPayload,
            sessionId: this.sessionKeys.sessionId,
            sequence: seq,
        };

        const encoded = encodeFrame(frame, this.sessionKeys);
        const wrapped = wrapTLS(encoded);

        this.bytesSent += wrapped.length;
        this.emit('data-transferred', { bytesSent: this.bytesSent, bytesReceived: this.bytesReceived });
        this.signalingChannel?.push('peer_data', {
            data: wrapped.toString('base64'),
        });
    }

    /**
     * Register a handler for WebSocket events coming back through the relay
     */
    onWS(event: string, handler: (data: any) => void) {
        if (!this.wsEventHandlers.has(event)) {
            this.wsEventHandlers.set(event, []);
        }
        this.wsEventHandlers.get(event)!.push(handler);
    }

    offWS(event: string, handler: (data: any) => void) {
        const handlers = this.wsEventHandlers.get(event);
        if (handlers) {
            this.wsEventHandlers.set(event, handlers.filter(h => h !== handler));
        }
    }

    // ─── Incoming Data Handling ───────────────────────────────────

    private handleRelayData(payload: any) {
        if (!this.sessionKeys) return;

        try {
            const rawData = Buffer.from(payload.data, 'base64');
            this.bytesReceived += rawData.length;
            this.emit('data-transferred', { bytesSent: this.bytesSent, bytesReceived: this.bytesReceived });
            const unwrapped = unwrapTLS(rawData) || rawData;
            const frame = decodeFrame(unwrapped, this.sessionKeys);
            if (!frame) return;

            switch (frame.type) {
                case MessageType.DATA: {
                    // HTTP response
                    const response = decodeHTTPResponse(frame.payload);
                    if (response) {
                        // Find matching pending request (by sequence — responses come in order)
                        // For now, resolve the oldest pending request
                        const oldest = this.findOldestPendingRequest();
                        if (oldest) {
                            clearTimeout(oldest.timeout);
                            this.pendingRequests.delete(oldest.sequence);
                            oldest.resolve(response);
                        }
                    }
                    break;
                }
                case MessageType.RELAY_RESPONSE: {
                    // WebSocket event from server via relay
                    const wsData = decodeWSFrame(frame.payload);
                    if (wsData) {
                        const handlers = this.wsEventHandlers.get(wsData.event) || [];
                        handlers.forEach(h => h(wsData.payload));

                        // Also emit generic event
                        this.emit('ws-message', wsData);
                    }
                    break;
                }
                case MessageType.KEEPALIVE:
                    // Keep connection alive
                    break;
            }
        } catch (e) {
            console.error('[RelayClient] Error handling relay data:', e);
        }
    }

    private findOldestPendingRequest(): PendingRequest | null {
        let oldest: PendingRequest | null = null;
        let minSeq = Infinity;
        this.pendingRequests.forEach((req, seq) => {
            if (seq < minSeq) {
                minSeq = seq;
                oldest = req;
            }
        });
        return oldest;
    }

    // ─── Reconnection ─────────────────────────────────────────────

    private handleDisconnect() {
        this.status = 'reconnecting';
        this.emit('status-changed', this.status);

        // Reject pending requests
        this.pendingRequests.forEach(req => {
            clearTimeout(req.timeout);
            req.reject(new Error('Relay disconnected'));
        });
        this.pendingRequests.clear();

        this.attemptReconnect();
    }

    private attemptReconnect() {
        // If socket is completely dead/null, we can't reconnect
        if (!this.socket) {
            this.status = 'error';
            this.emit('status-changed', this.status);
            return;
        }

        // If socket is not connected, wait for it indefinitely (network issue)
        if (!this.socket.isConnected()) {
            console.log('[RelayClient] Socket disconnected, waiting for network...');
            this.status = 'reconnecting'; // Ensure UI shows reconnecting

            if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
            this.reconnectTimer = setTimeout(() => this.attemptReconnect(), 2000);
            return;
        }

        if (this.reconnectAttempt >= RECONNECT_DELAYS.length) {
            this.status = 'error';
            this.emit('status-changed', this.status);
            this.emit('reconnect-failed', { attempts: this.reconnectAttempt });
            return;
        }

        const delay = RECONNECT_DELAYS[this.reconnectAttempt];
        console.log(`[RelayClient] Reconnecting in ${delay}ms (attempt ${this.reconnectAttempt + 1})`);

        this.reconnectTimer = setTimeout(async () => {
            if (this.currentRelay && this.socket) {
                // Determine disconnect is network or fatal logic could go here

                this.reconnectAttempt++;
                const result = await this.connectToRelay(this.currentRelay);
                if (!result.success) {
                    // connection failed (e.g. handshake), loop again
                    this.attemptReconnect();
                } else {
                    // Success is handled in connectToRelay event listeners (peer_accepted)
                }
            }
        }, delay);
    }

    private startKeepalive() {
        if (this.keepaliveInterval) clearInterval(this.keepaliveInterval);
        this.missedPings = 0;

        this.keepaliveInterval = setInterval(() => {
            if (!this.isConnected() || !this.sessionKeys) return;

            // Check for missed pings (no pong received)
            if (this.lastPingSent > 0 && this.missedPings >= 3) {
                console.log('[RelayClient] 3 missed pings — connection lost');
                this.currentLatency = null;
                this.emit('latency-updated', null);
                this.handleDisconnect();
                return;
            }

            // Send keepalive frame
            const frame: VibeNetFrame = {
                type: MessageType.KEEPALIVE,
                payload: Buffer.alloc(0),
                sessionId: this.sessionKeys.sessionId,
                sequence: ++this.sequence,
            };

            const encoded = encodeFrame(frame, this.sessionKeys);
            this.bytesSent += encoded.length;
            this.emit('data-transferred', { bytesSent: this.bytesSent, bytesReceived: this.bytesReceived });

            // Measure ping via push reply
            this.lastPingSent = Date.now();
            this.missedPings++;
            this.signalingChannel?.push('peer_data', {
                data: encoded.toString('base64'),
            })
                .receive('ok', () => {
                    // Server acknowledged — measure round-trip
                    const latency = Date.now() - this.lastPingSent;
                    this.currentLatency = latency;
                    this.missedPings = 0;
                    if (this.currentRelay) {
                        this.currentRelay.latency = latency;
                    }
                    this.emit('latency-updated', latency);
                });
        }, 10000); // Ping every 10s for responsive latency updates
    }

    // ─── Event System ─────────────────────────────────────────────

    subscribe(callback: ClientEventCallback): () => void {
        this.listeners.push(callback);
        return () => {
            this.listeners = this.listeners.filter(l => l !== callback);
        };
    }

    private emit(event: string, data: any) {
        this.listeners.forEach(cb => cb(event, data));
    }
}

export default RelayClient;
