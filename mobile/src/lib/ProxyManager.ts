
import AsyncStorage from '@react-native-async-storage/async-storage';
import RelayClient from './relay/RelayClient';

export interface ServerEndpoint {
    url: string;
    name: string;
    type: 'direct' | 'tunnel' | 'peer';
    protocol?: 'https' | 'v2ray' | 'shadowsocks' | 'trojan';
    config?: any;
    priority: number;
    lastLatency?: number;
    lastChecked?: number;
    status: 'unknown' | 'online' | 'offline' | 'blocked';
}

type ConnectionCallback = (status: string, endpoint: ServerEndpoint | null) => void;
type ConnectionMode = 'direct' | 'relay';

class ProxyManager {
    private static instance: ProxyManager;
    private endpoints: ServerEndpoint[] = [];
    private currentEndpoint: ServerEndpoint | null = null;
    private listeners: ConnectionCallback[] = [];
    private isScanning = false;
    private initialized = false;
    private connectionMode: ConnectionMode = 'direct';

    private constructor() {
        this.init();
    }

    static getInstance(): ProxyManager {
        if (!ProxyManager.instance) {
            ProxyManager.instance = new ProxyManager();
        }
        return ProxyManager.instance;
    }

    private async init() {
        await this.loadEndpoints();
        this.initialized = true;
        this.notify('ready', this.currentEndpoint);
    }

    private async loadEndpoints() {
        try {
            const saved = await AsyncStorage.getItem('proxy_endpoints');
            if (saved) {
                this.endpoints = JSON.parse(saved);
                // Clean up URLs
                this.endpoints.forEach(ep => {
                    if (ep.url.startsWith('http://') && !ep.url.includes('localhost') && !ep.url.includes('10.0.2.2')) {
                        ep.url = ep.url.replace('http://', 'https://');
                    }
                });
            }
        } catch (e) {
            console.warn('Failed to load endpoints', e);
        }

        const primaryUrl = await AsyncStorage.getItem('custom_server_url');
        if (primaryUrl && !this.endpoints.some(e => e.url === primaryUrl)) {
            this.endpoints.unshift({
                url: primaryUrl,
                name: 'Custom Server',
                type: 'direct',
                protocol: 'https',
                priority: 0,
                status: 'unknown'
            });
        }

        if (this.endpoints.length === 0) {
            // Default fallback to the primary Vibegram API domain
            this.endpoints.push({
                url: 'https://api.vibegram.io',
                name: 'Main Server (Vibegram API)',
                type: 'direct',
                protocol: 'https',
                priority: 1,
                status: 'unknown'
            });
        }
    }

    private async saveEndpoints() {
        await AsyncStorage.setItem('proxy_endpoints', JSON.stringify(this.endpoints));
    }

    public async addEndpoint(url: string, name: string, protocol: 'https' | 'v2ray' | 'shadowsocks' | 'trojan' = 'https', config: any = {}) {
        let cleanUrl = url.trim().replace(/\/$/, "");
        if (protocol === 'https' && cleanUrl.startsWith('http://') && !cleanUrl.includes('localhost') && !cleanUrl.includes('10.0.2.2')) {
            cleanUrl = cleanUrl.replace('http://', 'https://');
        }

        const existing = this.endpoints.find(e => e.url === cleanUrl);
        if (existing) {
            existing.name = name;
            existing.protocol = protocol;
            existing.config = config;
            await this.saveEndpoints();
            return existing;
        }

        const endpoint: ServerEndpoint = {
            url: cleanUrl,
            name,
            type: protocol === 'https' ? 'direct' : 'tunnel', // Treat Custom as tunnel for now
            protocol,
            config,
            priority: this.endpoints.length,
            status: 'unknown'
        };

        this.endpoints.push(endpoint);
        await this.saveEndpoints();
        return endpoint;
    }

    public getEndpoints() {
        return [...this.endpoints];
    }

    public getCurrentEndpoint() {
        return this.currentEndpoint;
    }

    public async setPrimaryEndpoint(url: string) {
        await AsyncStorage.setItem('custom_server_url', url);
        await this.addEndpoint(url, 'Primary');
        const ep = this.endpoints.find(e => e.url === url);
        if (ep) {
            this.currentEndpoint = ep;
            this.notify('connected', ep);
        }
    }

    async testEndpoint(endpoint: ServerEndpoint): Promise<number> {
        const start = Date.now();
        try {
            const controller = new AbortController();
            const timeout = setTimeout(() => controller.abort(), 8000);

            // Fetch check
            const res = await fetch(`${endpoint.url}/api/vapid-key`, {
                signal: controller.signal as any
            });

            clearTimeout(timeout);

            if (!res.ok) {
                endpoint.status = 'offline';
                return -1;
            } else {
                endpoint.status = 'online';
                endpoint.lastLatency = Date.now() - start;
                return endpoint.lastLatency;
            }
        } catch (e) {
            endpoint.status = 'offline';
            return -1;
        }
    }

    subscribe(callback: ConnectionCallback): () => void {
        this.listeners.push(callback);
        return () => {
            this.listeners = this.listeners.filter(l => l !== callback);
        };
    }

    private notify(status: string, endpoint: ServerEndpoint | null) {
        this.listeners.forEach(cb => cb(status, endpoint));
    }

    getBestUrl(): string {
        return this.currentEndpoint?.url || this.endpoints[0]?.url || 'https://api.vibegram.io';
    }

    // ─── Relay Integration ────────────────────────────────────────

    /**
     * Get the current connection mode (direct or relay)
     */
    getConnectionMode(): ConnectionMode {
        return this.connectionMode;
    }

    /**
     * Check if traffic is being routed through a relay
     */
    isRelayActive(): boolean {
        return this.connectionMode === 'relay' && RelayClient.getInstance().isConnected();
    }

    /**
     * Switch to relay mode — all traffic goes through the connected relay
     */
    setRelayMode() {
        this.connectionMode = 'relay';
        this.notify('relay-active', null);
    }

    /**
     * Switch back to direct mode
     */
    setDirectMode() {
        this.connectionMode = 'direct';
        this.notify('direct-active', this.currentEndpoint);
    }

    /**
     * Relay-aware fetch — routes through relay if in relay mode,
     * otherwise uses direct connection
     */
    async relayFetch(path: string, options: RequestInit = {}): Promise<Response> {
        if (this.isRelayActive()) {
            return RelayClient.getInstance().fetch(path, options);
        }
        // Direct mode — standard fetch
        const baseUrl = this.getBestUrl();
        return fetch(`${baseUrl}${path}`, {
            ...options,
            headers: {
                ...options.headers as Record<string, string>,
                'ngrok-skip-browser-warning': 'true',
            },
        });
    }

    /**
     * Scan all direct endpoints and fall back to relay if all are blocked
     */
    async scanAndFallback(): Promise<{ mode: ConnectionMode; endpoint?: ServerEndpoint }> {
        this.isScanning = true;
        this.notify('scanning', null);

        // Test all direct endpoints
        for (const ep of this.endpoints) {
            const latency = await this.testEndpoint(ep);
            if (latency > 0) {
                this.currentEndpoint = ep;
                this.connectionMode = 'direct';
                this.isScanning = false;
                this.notify('connected', ep);
                return { mode: 'direct', endpoint: ep };
            }
        }

        // All direct endpoints blocked — check if relay is available
        if (RelayClient.getInstance().isConnected()) {
            this.connectionMode = 'relay';
            this.isScanning = false;
            this.notify('relay-active', null);
            return { mode: 'relay' };
        }

        this.isScanning = false;
        this.notify('all-blocked', null);
        return { mode: 'direct' }; // No connection available
    }
}

export default ProxyManager;
