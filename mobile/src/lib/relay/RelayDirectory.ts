/**
 * RelayDirectory — Discovers and manages public relay nodes
 *
 * Discovery methods:
 * 1. Server directory — query Phoenix server for public relays (when server reachable)
 * 2. Bootstrap list — hardcoded list of known relays embedded in app
 * 3. DNS discovery — relay list stored in DNS TXT records (very hard to block)
 * 4. Peer sharing — users share relay codes via other apps (Telegram, SMS, etc.)
 *
 * The directory maintains a local cache of known relays and their status.
 */

import AsyncStorage from '@react-native-async-storage/async-storage';
import { Buffer } from 'buffer';
import type { BridgeDescriptor } from '../transport/types';

// ─── Types ────────────────────────────────────────────────────────

export interface DirectoryRelay {
    relayId: string;
    name: string;
    region: string;
    isPublic: boolean;
    currentPeers: number;
    maxPeers: number;
    latency: number | null;
    lastSeen: number;
    uptime: number; // percentage
    inviteCode?: string;
    inviteKey?: string;
    externalIp?: string;
    bridgeUrl?: string;
    shareLink?: string;
    bridgeDescriptor?: BridgeDescriptor;
    tags: string[];
}

export type DirectoryStatus = 'idle' | 'fetching' | 'error';

type DirectoryEventCallback = (event: string, data: any) => void;

const STORAGE_KEY = 'vibenet_relay_directory';
const CACHE_TTL = 5 * 60 * 1000; // 5 minutes

// Bootstrap relays — hardcoded so filtered users can always find at least one relay
// These would be maintained by the Vibe team or trusted community members
const BOOTSTRAP_RELAYS: DirectoryRelay[] = [
    // Empty for now — these would be added as the network grows
    // Example:
    // {
    //     relayId: 'bootstrap_us_1',
    //     name: 'Vibe US Bridge',
    //     region: 'us-east',
    //     isPublic: true,
    //     currentPeers: 0,
    //     maxPeers: 50,
    //     latency: null,
    //     lastSeen: Date.now(),
    //     uptime: 99,
    //     tags: ['official', 'fast'],
    // }
];

// DNS TXT record domains for relay discovery
// Spread across multiple domains so blocking one doesn't kill discovery
const DNS_DISCOVERY_DOMAINS = [
    // These would be real domains in production
    // '_viberelay.example1.com',
    // '_viberelay.example2.com',
];

// ─── RelayDirectory Class ─────────────────────────────────────────

class RelayDirectory {
    private static instance: RelayDirectory;

    private relays: DirectoryRelay[] = [];
    private status: DirectoryStatus = 'idle';
    private lastFetch: number = 0;
    private listeners: DirectoryEventCallback[] = [];
    private signalingChannel: any = null;

    private constructor() {
        this.loadCache();
    }

    static getInstance(): RelayDirectory {
        if (!RelayDirectory.instance) {
            RelayDirectory.instance = new RelayDirectory();
        }
        return RelayDirectory.instance;
    }

    // ─── State ────────────────────────────────────────────────────

    getRelays(): DirectoryRelay[] {
        return [...this.relays].sort((a, b) => {
            // Sort by: available slots > latency > uptime
            const aAvail = a.maxPeers - a.currentPeers;
            const bAvail = b.maxPeers - b.currentPeers;
            if (aAvail !== bAvail) return bAvail - aAvail;
            if (a.latency && b.latency) return a.latency - b.latency;
            return b.uptime - a.uptime;
        });
    }

    getAvailableRelays(): DirectoryRelay[] {
        return this.getRelays().filter(r => r.currentPeers < r.maxPeers);
    }

    getStatus(): DirectoryStatus {
        return this.status;
    }

    getRelayCount(): number {
        return this.relays.length;
    }

    // ─── Cache ────────────────────────────────────────────────────

    private async loadCache() {
        try {
            const saved = await AsyncStorage.getItem(STORAGE_KEY);
            if (saved) {
                const data = JSON.parse(saved);
                this.relays = data.relays || [];
                this.lastFetch = data.lastFetch || 0;
            }
        } catch (e) {
            console.warn('[RelayDirectory] Failed to load cache:', e);
        }

        // Always include bootstrap relays
        this.mergeBootstrapRelays();
    }

    private async saveCache() {
        try {
            await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify({
                relays: this.relays,
                lastFetch: this.lastFetch,
            }));
        } catch (e) {
            console.warn('[RelayDirectory] Failed to save cache:', e);
        }
    }

    private mergeBootstrapRelays() {
        for (const bootstrap of BOOTSTRAP_RELAYS) {
            const exists = this.relays.find(r => r.relayId === bootstrap.relayId);
            if (!exists) {
                this.relays.push(bootstrap);
            }
        }
    }

    // ─── Fetching ─────────────────────────────────────────────────

    /**
     * Fetch public relays from all available sources
     */
    async refresh(socket?: any): Promise<DirectoryRelay[]> {
        // Don't refetch too quickly
        if (Date.now() - this.lastFetch < 10000 && this.relays.length > 0) {
            return this.getRelays();
        }

        this.status = 'fetching';
        this.emit('status-changed', this.status);

        const results: DirectoryRelay[][] = [];

        // Method 1: Phoenix server directory
        let serverRelayIds: Set<string> | null = null;
        if (socket && socket.isConnected()) {
            try {
                const serverRelays = await this.fetchFromServer(socket);
                results.push(serverRelays);
                // Track which relays the server knows about — anything else is stale
                serverRelayIds = new Set(serverRelays.map(r => r.relayId));
            } catch (e) {
                console.warn('[RelayDirectory] Server fetch failed:', e);
            }
        }

        // Method 2: DNS discovery (fallback when server is blocked)
        try {
            const dnsRelays = await this.fetchFromDNS();
            results.push(dnsRelays);
        } catch (e) {
            // DNS might not work on all platforms
        }

        // If server gave us a definitive list, remove cached relays not on it
        if (serverRelayIds && serverRelayIds.size > 0) {
            const before = this.relays.length;
            this.relays = this.relays.filter(r =>
                serverRelayIds!.has(r.relayId) ||
                BOOTSTRAP_RELAYS.some(b => b.relayId === r.relayId)
            );
            if (this.relays.length < before) {
                console.log(`[RelayDirectory] Removed ${before - this.relays.length} stale cached relays`);
            }
        }

        // Merge all results
        const allRelays = results.flat();
        this.mergeRelays(allRelays);
        this.mergeBootstrapRelays();
        this.lastFetch = Date.now();

        await this.saveCache();

        this.status = 'idle';
        this.emit('status-changed', this.status);
        this.emit('relays-updated', this.getRelays());

        return this.getRelays();
    }

    /**
     * Fetch relays from Phoenix server via channel
     */
    private fetchFromServer(socket: any): Promise<DirectoryRelay[]> {
        return new Promise((resolve, reject) => {
            // If we already have a directory channel open, leave it first to avoid duplicates
            if (this.signalingChannel) {
                try { this.signalingChannel.leave(); } catch {}
                this.signalingChannel = null;
            }

            const channel = socket.channel('relay:directory', {});

            const timeout = setTimeout(() => {
                channel.leave();
                reject(new Error('Directory fetch timeout'));
            }, 10000);

            channel.join()
                .receive('ok', (response: any) => {
                    clearTimeout(timeout);

                    console.log('[RelayDirectory] Server response:', JSON.stringify(response));
                    const rawRelays = response.relays || response || [];
                    const relayList = Array.isArray(rawRelays) ? rawRelays : [];
                    console.log('[RelayDirectory] Parsed', relayList.length, 'relays from server');

                    const relays: DirectoryRelay[] = relayList.map((r: any) => ({
                        relayId: r.relay_id,
                        name: r.name || 'Unnamed Relay',
                        region: r.region || 'unknown',
                        isPublic: true,
                        currentPeers: r.current_peers || 0,
                        maxPeers: r.max_peers || 5,
                        latency: null,
                        lastSeen: Date.now(),
                        uptime: r.uptime || 0,
                        inviteCode: r.invite_code || undefined,
                        inviteKey: r.invite_key || undefined,
                        externalIp: r.external_ip || undefined,
                        bridgeUrl: r.bridge_url || undefined,
                        shareLink: r.share_link || undefined,
                        bridgeDescriptor: r.bridge_descriptor || undefined,
                        tags: r.tags || [],
                    }));
                    if (relays.length > 0) {
                        console.log('[RelayDirectory] First relay:', relays[0].relayId, 'code:', relays[0].inviteCode, 'hasKey:', !!relays[0].inviteKey);
                    }

                    // Subscribe to directory updates
                    channel.on('relay_updated', (payload: any) => {
                        this.handleRelayUpdate(payload);
                    });

                    channel.on('relay_added', (payload: any) => {
                        this.handleRelayAdded(payload);
                    });

                    channel.on('relay_removed', (payload: any) => {
                        this.handleRelayRemoved(payload);
                    });

                    this.signalingChannel = channel;
                    resolve(relays);
                })
                .receive('error', (err: any) => {
                    clearTimeout(timeout);
                    channel.leave();
                    reject(err);
                });
        });
    }

    /**
     * Fetch relays from DNS TXT records
     * This is a fallback when the server is completely blocked
     */
    private async fetchFromDNS(): Promise<DirectoryRelay[]> {
        const relays: DirectoryRelay[] = [];

        for (const domain of DNS_DISCOVERY_DOMAINS) {
            try {
                // DNS over HTTPS (DoH) — uses Cloudflare DNS which is very hard to block
                const response = await fetch(`https://cloudflare-dns.com/dns-query?name=${domain}&type=TXT`, {
                    headers: { 'Accept': 'application/dns-json' },
                });

                if (response.ok) {
                    const data = await response.json();
                    const answers = data.Answer || [];

                    for (const answer of answers) {
                        try {
                            // TXT records contain base64-encoded relay info
                            const txt = answer.data.replace(/"/g, '');
                            const decoded = Buffer.from(txt, 'base64').toString('utf-8');
                            const relayData = JSON.parse(decoded);

                            relays.push({
                                relayId: relayData.id,
                                name: relayData.n || 'DNS Relay',
                                region: relayData.r || 'unknown',
                                isPublic: true,
                                currentPeers: 0,
                                maxPeers: relayData.m || 10,
                                latency: null,
                                lastSeen: Date.now(),
                                uptime: 0,
                                inviteCode: relayData.c,
                                inviteKey: relayData.k,
                                tags: ['dns-discovered'],
                            });
                        } catch {
                            // Skip invalid records
                        }
                    }
                }
            } catch {
                // DNS fetch failed, try next domain
            }
        }

        return relays;
    }

    /**
     * Test latency to a relay
     */
    async testLatency(relay: DirectoryRelay): Promise<number | null> {
        try {
            const start = Date.now();

            // We can't directly ping the relay, but we can measure
            // the time it takes to get a response through the signaling server
            if (this.signalingChannel) {
                return new Promise((resolve) => {
                    const timeout = setTimeout(() => resolve(null), 5000);

                    this.signalingChannel.push('ping_relay', { relay_id: relay.relayId })
                        .receive('ok', () => {
                            clearTimeout(timeout);
                            const latency = Date.now() - start;
                            // Update relay latency
                            const idx = this.relays.findIndex(r => r.relayId === relay.relayId);
                            if (idx >= 0) {
                                this.relays[idx].latency = latency;
                                this.emit('relays-updated', this.getRelays());
                            }
                            resolve(latency);
                        })
                        .receive('error', () => {
                            clearTimeout(timeout);
                            resolve(null);
                        });
                });
            }

            return null;
        } catch {
            return null;
        }
    }

    /**
     * Test latency to all relays
     */
    async testAllLatencies(): Promise<void> {
        const promises = this.relays.map(r => this.testLatency(r));
        await Promise.allSettled(promises);
    }

    // ─── Live Updates ─────────────────────────────────────────────

    private handleRelayUpdate(payload: any) {
        const idx = this.relays.findIndex(r => r.relayId === payload.relay_id);
        if (idx >= 0) {
            this.relays[idx] = {
                ...this.relays[idx],
                currentPeers: payload.current_peers ?? this.relays[idx].currentPeers,
                name: payload.name || this.relays[idx].name,
                inviteCode: payload.invite_code || this.relays[idx].inviteCode,
                inviteKey: payload.invite_key || this.relays[idx].inviteKey,
                externalIp: payload.external_ip || this.relays[idx].externalIp,
                bridgeUrl: payload.bridge_url || this.relays[idx].bridgeUrl,
                shareLink: payload.share_link || this.relays[idx].shareLink,
                bridgeDescriptor: payload.bridge_descriptor || this.relays[idx].bridgeDescriptor,
                lastSeen: Date.now(),
            };
            this.emit('relays-updated', this.getRelays());
        }
    }

    private handleRelayAdded(payload: any) {
        const exists = this.relays.find(r => r.relayId === payload.relay_id);
        if (!exists) {
            this.relays.push({
                relayId: payload.relay_id,
                name: payload.name || 'New Relay',
                region: payload.region || 'unknown',
                isPublic: true,
                currentPeers: payload.current_peers || 0,
                maxPeers: payload.max_peers || 5,
                latency: null,
                lastSeen: Date.now(),
                uptime: 0,
                inviteCode: payload.invite_code || undefined,
                inviteKey: payload.invite_key || undefined,
                externalIp: payload.external_ip || undefined,
                bridgeUrl: payload.bridge_url || undefined,
                shareLink: payload.share_link || undefined,
                bridgeDescriptor: payload.bridge_descriptor || undefined,
                tags: payload.tags || [],
            });
            this.emit('relays-updated', this.getRelays());
        }
    }

    private handleRelayRemoved(payload: any) {
        this.relays = this.relays.filter(r => r.relayId !== payload.relay_id);
        this.emit('relays-updated', this.getRelays());
    }

    // ─── Merge Logic ──────────────────────────────────────────────

    private mergeRelays(newRelays: DirectoryRelay[]) {
        for (const newRelay of newRelays) {
            const idx = this.relays.findIndex(r => r.relayId === newRelay.relayId);
            if (idx >= 0) {
                // Update existing
                this.relays[idx] = {
                    ...this.relays[idx],
                    ...newRelay,
                    latency: this.relays[idx].latency, // Keep measured latency
                };
            } else {
                this.relays.push(newRelay);
            }
        }

        // Remove stale relays (not seen in 24 hours, except bootstrap)
        const staleThreshold = Date.now() - 24 * 60 * 60 * 1000;
        this.relays = this.relays.filter(r =>
            r.lastSeen > staleThreshold ||
            BOOTSTRAP_RELAYS.some(b => b.relayId === r.relayId)
        );
    }

    // ─── Cleanup ──────────────────────────────────────────────────

    disconnect() {
        if (this.signalingChannel) {
            this.signalingChannel.leave();
            this.signalingChannel = null;
        }
    }

    // ─── Event System ─────────────────────────────────────────────

    subscribe(callback: DirectoryEventCallback): () => void {
        this.listeners.push(callback);
        return () => {
            this.listeners = this.listeners.filter(l => l !== callback);
        };
    }

    private emit(event: string, data: any) {
        this.listeners.forEach(cb => cb(event, data));
    }
}

export default RelayDirectory;
