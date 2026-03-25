/**
 * ProxyManager - Multi-Server Fallback System with V2Ray Support
 *
 * This implements a resilient connection strategy:
 * 1. Detect if user is in filtered region (Iran, China, etc.)
 * 2. For unfiltered regions: Use fast direct connection
 * 3. For filtered regions: Route through V2Ray/proxy
 * 4. Try primary server, then backup servers in rotation
 * 5. Fetch remote list of dynamic servers from BootstrapManager
 */

import BootstrapManager from './BootstrapManager';
import V2RayManager from './V2RayManager';

export interface ServerEndpoint {
    url: string;
    name: string;
    type: 'direct' | 'tunnel' | 'peer' | 'v2ray';
    priority: number;
    lastLatency?: number;
    lastChecked?: number;
    status: 'unknown' | 'online' | 'offline' | 'blocked';
    // V2Ray specific
    v2rayConfigId?: string;
    requiresProxy?: boolean;
}

type ConnectionCallback = (status: string, endpoint: ServerEndpoint | null) => void;

class ProxyManager {
    private static instance: ProxyManager;
    private endpoints: ServerEndpoint[] = [];
    private currentEndpoint: ServerEndpoint | null = null;
    private listeners: ConnectionCallback[] = [];
    private isScanning = false;
    private v2rayManager: V2RayManager;
    private useProxyMode: boolean = false;

    private constructor() {
        this.v2rayManager = V2RayManager.getInstance();
        this.loadEndpoints();
        this.fetchDynamicServers(); // Auto-fetch on startup
        this.initializeSmartRouting();
    }

    /**
     * Initialize smart routing based on region detection
     */
    private async initializeSmartRouting() {
        const regionInfo = await this.v2rayManager.detectRegion();

        if (regionInfo?.isFiltered) {
            console.log('[PROXY] Filtered region detected:', regionInfo.countryCode);
            this.useProxyMode = true;

            // Check if we have V2Ray configs
            const configs = this.v2rayManager.getConfigs();
            if (configs.length > 0) {
                console.log('[PROXY] V2Ray configs available, enabling proxy mode');
                this.v2rayManager.enableProxy();
            } else {
                console.log('[PROXY] No V2Ray configs, will use tunnel fallback');
            }
        } else {
            console.log('[PROXY] Unfiltered region, using direct connection');
            this.useProxyMode = false;
        }
    }

    static getInstance(): ProxyManager {
        if (!ProxyManager.instance) {
            ProxyManager.instance = new ProxyManager();
        }
        return ProxyManager.instance;
    }

    private sanitizeUrl(url: string | null | undefined): string {
        if (!url) return '';
        let clean = url.trim();
        // Remove trailing slash for consistency
        clean = clean.replace(/\/$/, "");

        // 1. Remove /localhost from tunnels (ngrok, railway, etc)
        // This fixes the issue where "ngrok.io/localhost" was persisting
        const isTunnel = clean.includes('ngrok') ||
            clean.includes('railway.app') ||
            clean.includes('trycloudflare.com') ||
            clean.includes('serveo.net') ||
            clean.includes('lhr.life') ||
            clean.includes('localhost.run');

        if (isTunnel) {
            clean = clean.replace(/\/localhost/g, '');
        }

        // 2. Remove :80 from Railway URLs (SSL Protocol Error fix)
        // Railway uses port 443 for HTTPS, but sometimes :80 leaks in from config
        if (clean.includes('railway.app') && clean.includes(':80')) {
            clean = clean.replace(':80', '');
        }

        // 3. Ensure HTTPS for non-localhost
        if (clean.startsWith('http://') && !clean.includes('localhost') && !clean.includes('127.0.0.1')) {
            clean = clean.replace('http://', 'https://');
        }

        return clean;
    }

    private loadEndpoints() {
        const saved = localStorage.getItem('proxy_endpoints');
        if (saved) {
            try {
                this.endpoints = JSON.parse(saved);
                // Upgrade any http:// URLs to https:// (except localhost)
                this.endpoints.forEach(ep => {
                    ep.url = this.sanitizeUrl(ep.url);
                    if (ep.url.startsWith('http://') && !ep.url.includes('localhost') && !ep.url.includes('127.0.0.1')) {
                        ep.url = ep.url.replace('http://', 'https://');
                    }
                });
            } catch {
                this.endpoints = [];
            }
        }

        // Always ensure the branded primary API server is first
        let primaryUrl = this.sanitizeUrl(localStorage.getItem('custom_server_url') || 'https://api.vibegram.io');

        // Upgrade to https if not localhost
        if (primaryUrl.startsWith('http://') && !primaryUrl.includes('localhost') && !primaryUrl.includes('127.0.0.1')) {
            primaryUrl = primaryUrl.replace('http://', 'https://');
        }

        // Add primary server
        if (!this.endpoints.some(e => e.url === primaryUrl)) {
            this.endpoints.unshift({
                url: primaryUrl,
                name: 'Primary Server (Vibegram API)',
                type: 'direct',
                priority: 0,
                status: 'unknown'
            });
        }
    }

    /**
     * Auto-Fetch the dynamic server list generated by start_tunnel.sh
     */
    public async fetchDynamicServers() {
        try {
            // Use BootstrapManager to get the latest list (from Gist, etc.)
            const bootstrap = BootstrapManager.getInstance();
            const servers = await bootstrap.fetchServers();

            let added = 0;
            servers.forEach(srv => {
                if (!this.endpoints.some(e => e.url === srv.url)) {
                    this.endpoints.push({
                        url: srv.url,
                        name: srv.name || 'Dynamic Server',
                        type: 'tunnel', // Assume dynamic servers are tunnels
                        priority: 10,
                        status: 'unknown'
                    });
                    added++;
                }
            });

            if (added > 0) {
                this.saveEndpoints();
                this.notify('updated', null);
            }
        } catch (e) {
            console.warn('[PROXY] Failed to fetch server list from BootstrapManager');
        }
    }

    private saveEndpoints() {

        localStorage.setItem('proxy_endpoints', JSON.stringify(this.endpoints));
    }

    /**
     * Add a new server endpoint to the rotation
     */
    addEndpoint(url: string, name: string, type: 'direct' | 'tunnel' | 'peer' = 'direct') {
        let cleanUrl = this.sanitizeUrl(url);

        if (cleanUrl.startsWith('http://') && !cleanUrl.includes('localhost') && !cleanUrl.includes('127.0.0.1')) {
            cleanUrl = cleanUrl.replace('http://', 'https://');
        }

        const existing = this.endpoints.find(e => e.url === cleanUrl);
        if (existing) {
            return existing;
        }

        const endpoint: ServerEndpoint = {
            url: cleanUrl,
            name,
            type,
            priority: this.endpoints.length,
            status: 'unknown'
        };

        this.endpoints.push(endpoint);
        this.saveEndpoints();
        return endpoint;
    }

    /**
     * Remove an endpoint
     */
    removeEndpoint(url: string) {
        this.endpoints = this.endpoints.filter(e => e.url !== url);
        this.saveEndpoints();
    }

    /**
     * Get all configured endpoints
     */
    getEndpoints(): ServerEndpoint[] {
        return [...this.endpoints];
    }

    /**
     * Get the current active endpoint
     */
    getCurrentEndpoint(): ServerEndpoint | null {
        return this.currentEndpoint;
    }

    /**
     * Test a single endpoint's latency and availability
     */
    async testEndpoint(endpoint: ServerEndpoint): Promise<number> {
        const start = Date.now();
        try {
            // Ensure HTTPS when page is loaded over HTTPS (prevent mixed content)
            let url = endpoint.url;
            if (typeof window !== 'undefined' && window.location.protocol === 'https:' && url.startsWith('http:')) {
                url = url.replace('http:', 'https:');
            }

            const controller = new AbortController();
            const timeout = setTimeout(() => controller.abort(), 8000);

            const res = await fetch(`${url}/api/vapid-key`, {
                method: 'GET',
                headers: { 'ngrok-skip-browser-warning': 'true' },
                credentials: 'include',
                signal: controller.signal
            });

            clearTimeout(timeout);

            if (!res.ok) {
                endpoint.status = 'offline';
                endpoint.lastLatency = -1;
            } else {
                endpoint.status = 'online';
                endpoint.lastLatency = Date.now() - start;
            }
        } catch (e: any) {
            if (e.name === 'AbortError') {
                endpoint.status = 'blocked';
            } else {
                endpoint.status = 'offline';
            }
            endpoint.lastLatency = -1;
        }

        endpoint.lastChecked = Date.now();
        this.saveEndpoints();
        return endpoint.lastLatency ?? -1;
    }

    /**
     * Scan all endpoints and find the best one
     */
    async scanAllEndpoints(): Promise<ServerEndpoint | null> {
        if (this.isScanning) return this.currentEndpoint;
        this.isScanning = true;
        this.notify('scanning', null);

        // Refresh list first
        await this.fetchDynamicServers();

        const results: { endpoint: ServerEndpoint; latency: number }[] = [];

        await Promise.all(
            this.endpoints.map(async (endpoint) => {
                const latency = await this.testEndpoint(endpoint);
                if (latency > 0) {
                    results.push({ endpoint, latency });
                }
            })
        );

        this.isScanning = false;
        results.sort((a, b) => a.latency - b.latency);

        if (results.length > 0) {
            this.currentEndpoint = results[0].endpoint;
            this.notify('connected', this.currentEndpoint);
            return this.currentEndpoint;
        }

        this.currentEndpoint = null;
        this.notify('all_blocked', null);
        return null;
    }

    /**
     * Find a working endpoint using fallback strategy
     */
    async findWorkingEndpoint(): Promise<ServerEndpoint | null> {
        if (this.currentEndpoint) {
            const latency = await this.testEndpoint(this.currentEndpoint);
            if (latency > 0) {
                this.notify('connected', this.currentEndpoint);
                return this.currentEndpoint;
            }
        }

        const sortedEndpoints = [...this.endpoints].sort((a, b) => a.priority - b.priority);

        for (const endpoint of sortedEndpoints) {
            if (endpoint === this.currentEndpoint) continue;

            this.notify('trying', endpoint);
            const latency = await this.testEndpoint(endpoint);

            if (latency > 0) {
                this.currentEndpoint = endpoint;
                this.notify('connected', endpoint);
                return endpoint;
            }
        }

        // Try one last fetch in case new servers were published
        await this.fetchDynamicServers();

        this.currentEndpoint = null;
        this.notify('all_blocked', null);
        return null;
    }

    /**
     * Subscribe to connection status changes
     */
    subscribe(callback: ConnectionCallback): () => void {
        this.listeners.push(callback);
        return () => {
            this.listeners = this.listeners.filter(l => l !== callback);
        };
    }

    private notify(status: string, endpoint: ServerEndpoint | null) {
        this.listeners.forEach(cb => cb(status, endpoint));
    }

    /**
     * Get the best working URL for API calls
     */
    getBestUrl(): string {
        // DEFAULT FALLBACK if everything fails
        const FALLBACK_SERVER = 'https://vibe.ngrok.io';

        let url = this.currentEndpoint?.url || this.endpoints[0]?.url;

        // If no endpoints, and we are on a static host, DO NOT use origin
        if (!url) {
            const isStaticHost = window.location.hostname.includes('github.io') ||
                window.location.hostname.includes('vercel.app') ||
                window.location.hostname.includes('pages.dev');

            if (isStaticHost) {
                url = FALLBACK_SERVER;
            } else {
                url = window.location.origin;
            }
        }

        // Sanitize final URL
        return this.sanitizeUrl(url || FALLBACK_SERVER);
    }

    // ========== V2RAY / PROXY INTEGRATION ==========

    /**
     * Check if proxy mode is enabled
     */
    isProxyModeEnabled(): boolean {
        return this.useProxyMode;
    }

    /**
     * Enable proxy mode (for filtered regions)
     */
    enableProxyMode(): void {
        this.useProxyMode = true;
        this.v2rayManager.enableProxy();
        this.notify('proxy_enabled', null);
    }

    /**
     * Disable proxy mode (direct connection)
     */
    disableProxyMode(): void {
        this.useProxyMode = false;
        this.v2rayManager.disableProxy();
        this.notify('proxy_disabled', null);
    }

    /**
     * Get V2Ray manager instance
     */
    getV2RayManager(): V2RayManager {
        return this.v2rayManager;
    }

    /**
     * Add a V2Ray config and create an endpoint for it
     */
    addV2RayConfig(configUrl: string, name?: string): ServerEndpoint | null {
        const config = this.v2rayManager.addConfigFromUrl(configUrl, name);
        if (!config) return null;

        // Create a virtual endpoint for this V2Ray config
        const endpoint: ServerEndpoint = {
            url: `v2ray://${config.id}`,
            name: config.name,
            type: 'v2ray',
            priority: 5, // Higher priority than regular tunnels
            status: 'unknown',
            v2rayConfigId: config.id,
            requiresProxy: true
        };

        this.endpoints.push(endpoint);
        this.saveEndpoints();
        return endpoint;
    }

    /**
     * Get region info from V2Ray manager
     */
    async getRegionInfo() {
        return this.v2rayManager.detectRegion();
    }

    /**
     * Check if user is in a filtered region
     */
    isInFilteredRegion(): boolean {
        return this.v2rayManager.isInFilteredRegion();
    }

    /**
     * Smart connection: tries direct first, then proxy if in filtered region
     */
    async smartConnect(): Promise<ServerEndpoint | null> {
        // First, try direct connection (fast for unfiltered users)
        const directEndpoints = this.endpoints.filter(e => e.type === 'direct' || e.type === 'tunnel');

        for (const endpoint of directEndpoints.slice(0, 2)) { // Try first 2 direct endpoints
            const latency = await this.testEndpoint(endpoint);
            if (latency > 0 && latency < 3000) { // Under 3 seconds = good connection
                this.currentEndpoint = endpoint;
                this.useProxyMode = false;
                this.notify('connected', endpoint);
                return endpoint;
            }
        }

        // Direct connection slow or blocked, check if we're in filtered region
        if (this.v2rayManager.isInFilteredRegion()) {
            console.log('[PROXY] Direct connection failed, trying V2Ray proxy...');
            this.useProxyMode = true;

            const bestProxy = await this.v2rayManager.findBestProxy();
            if (bestProxy) {
                // Find or create endpoint for this proxy
                let proxyEndpoint = this.endpoints.find(e => e.v2rayConfigId === bestProxy.id);
                if (!proxyEndpoint) {
                    proxyEndpoint = {
                        url: `v2ray://${bestProxy.id}`,
                        name: bestProxy.name,
                        type: 'v2ray',
                        priority: 5,
                        status: 'online',
                        v2rayConfigId: bestProxy.id,
                        requiresProxy: true
                    };
                    this.endpoints.push(proxyEndpoint);
                }
                this.currentEndpoint = proxyEndpoint;
                this.notify('connected_via_proxy', proxyEndpoint);
                return proxyEndpoint;
            }
        }

        // Fall back to regular endpoint rotation
        return this.findWorkingEndpoint();
    }
}

export default ProxyManager;
