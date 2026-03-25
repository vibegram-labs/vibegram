/**
 * BootstrapManager - Dynamic Server Discovery System
 * 
 * This solves the critical problem of changing tunnel URLs:
 * 1. Uses stable "bootstrap" URLs to fetch current server list
 * 2. Bootstrap can be: GitHub Gist, Vercel, Cloudflare Workers, Pastebin
 * 3. When tunnel URL changes, just update the bootstrap - no app update needed
 * 4. Falls back to P2P if all servers are blocked
 */

export interface ServerInfo {
    url: string;
    name: string;
    type: 'primary' | 'tunnel' | 'backup';
    region?: string;
    addedAt: number;
    expiresAt?: number;
}

export interface BootstrapResponse {
    version: number;
    servers: ServerInfo[];
    message?: string;
    emergency?: {
        enabled: boolean;
        p2pOnly: boolean;
        message: string;
    };
}

// Multiple bootstrap sources for redundancy
// These should be stable URLs that are hard to block
// Users should configure their own GitHub Gist URL in localStorage or bootstrap-servers.json
const BOOTSTRAP_SOURCES = [
    // Local fallback is now handled dynamically in loadBootstrapUrls
    // to ensure correct base path resolution

    // API endpoint on any working server (self-discovery)
    // removed '/api/servers' as it causes 404s on static hosting

    // Known working server API (Primary branded fallback)
    'https://api.vibegram.io/api/servers',

    // Official Vibe Source Gist
    'https://gist.githubusercontent.com/Vibe-source/37d1709f5dbacb24a669ac0c04f4929d/raw/servers.json'

    // User should add their own GitHub Gist URL via:
    // localStorage.setItem('bootstrap_urls', JSON.stringify(['https://gist.githubusercontent.com/YOUR_USERNAME/GIST_ID/raw/servers.json']))
    // Or configure in /public/bootstrap-servers.json
];

class BootstrapManager {
    private static instance: BootstrapManager;
    private servers: ServerInfo[] = [];
    private lastFetch: number = 0;
    private fetchInterval: number = 5 * 60 * 1000; // 5 minutes
    private bootstrapUrls: string[] = [];
    private listeners: ((servers: ServerInfo[]) => void)[] = [];

    private constructor() {
        // Initialize bootstrap URLs and start refresh
        this.initialize();
    }

    /**
     * Async initialization
     */
    private async initialize() {
        await this.loadBootstrapUrls();
        this.startAutoRefresh();
    }

    static getInstance(): BootstrapManager {
        if (!BootstrapManager.instance) {
            BootstrapManager.instance = new BootstrapManager();
        }
        return BootstrapManager.instance;
    }

    /**
     * Load bootstrap URLs from localStorage and config file
     */
    private async loadBootstrapUrls() {
        // First, load from localStorage (user overrides)
        const saved = localStorage.getItem('bootstrap_urls');
        if (saved) {
            try {
                this.bootstrapUrls = JSON.parse(saved);
            } catch {
                this.bootstrapUrls = [];
            }
        }

        // Then, load from config file (contains GitHub Gist URL)
        try {
            // Determine base URL dynamically or use Vite env
            let baseUrl = import.meta.env.BASE_URL || '/';

            // Hard fallback for GitHub Pages if env var didn't propagate
            if (typeof window !== 'undefined' && window.location.pathname.startsWith('/Vibe')) {
                baseUrl = '/Vibe/';
            }

            const configUrl = baseUrl.endsWith('/')
                ? `${baseUrl}bootstrap-servers.json`
                : `${baseUrl}/bootstrap-servers.json`;

            console.log(`[BOOTSTRAP] Fetching config from: ${configUrl} (Base: ${baseUrl})`);

            // Try fetching from constructed path
            let response = await fetch(configUrl);

            // Fallback: If 404 and we are in a subdirectory (like /Vibe/), try root
            if (!response.ok && baseUrl !== '/') {
                const rootUrl = '/bootstrap-servers.json';
                console.warn(`[BOOTSTRAP] Failed to load from ${configUrl}, trying root: ${rootUrl}`);
                const responseRoot = await fetch(rootUrl);
                if (responseRoot.ok) {
                    response = responseRoot;
                    console.log(`[BOOTSTRAP] Successfully loaded config from root: ${rootUrl}`);
                }
            }

            if (response.ok) {
                const config = await response.json();

                // Add this valid config source to our list of places to fetch servers from
                // We typically don't add the config file itself as a server source, 
                // but if the config *contains* a list of bootstrap URLs, we add those.

                if (config.bootstrapUrls && Array.isArray(config.bootstrapUrls)) {
                    this.bootstrapUrls = [...this.bootstrapUrls, ...config.bootstrapUrls];
                }
            } else {
                console.warn(`[BOOTSTRAP] Failed to load config from ${configUrl} (Status: ${response.status})`);
            }
        } catch (e) {
            console.warn('[BOOTSTRAP] Could not load config file:', e);
        }

        // Merge with default sources (defaults at end as fallback)
        const allUrls = [...this.bootstrapUrls, ...BOOTSTRAP_SOURCES];
        this.bootstrapUrls = [...new Set(allUrls)]; // Remove duplicates

        console.log('[BOOTSTRAP] Loaded', this.bootstrapUrls.length, 'bootstrap URLs');
    }

    /**
     * Add a custom bootstrap URL
     */
    addBootstrapUrl(url: string) {
        if (!this.bootstrapUrls.includes(url)) {
            this.bootstrapUrls.unshift(url); // Add to front (highest priority)
            localStorage.setItem('bootstrap_urls', JSON.stringify(this.bootstrapUrls));
        }
    }

    /**
     * Fetch servers from all bootstrap sources
     */
    async fetchServers(force = false): Promise<ServerInfo[]> {
        // Skip if recently fetched (unless forced)
        if (!force && Date.now() - this.lastFetch < this.fetchInterval && this.servers.length > 0) {
            return this.servers;
        }

        console.log('[BOOTSTRAP] Fetching server list from bootstrap sources...');

        for (const url of this.bootstrapUrls) {
            try {
                const servers = await this.fetchFromSource(url);
                if (servers && servers.length > 0) {
                    console.log(`[BOOTSTRAP] Got ${servers.length} servers from ${url}`);
                    this.servers = servers;
                    this.lastFetch = Date.now();
                    this.saveServersLocally();
                    this.notifyListeners();
                    return servers;
                }
            } catch (e) {
                console.warn(`[BOOTSTRAP] Failed to fetch from ${url}:`, e);
            }
        }

        // If all bootstrap sources failed, use cached servers
        console.warn('[BOOTSTRAP] All sources failed. Using cached servers.');
        return this.loadCachedServers();
    }

    /**
     * Fetch from a single bootstrap source
     */
    private async fetchFromSource(url: string): Promise<ServerInfo[] | null> {
        try {
            const controller = new AbortController();
            const timeout = setTimeout(() => controller.abort(), 10000);

            // Simple GET - no custom headers to avoid CORS preflight on Gist URLs
            const response = await fetch(url, {
                method: 'GET',
                signal: controller.signal
            });

            clearTimeout(timeout);

            if (!response.ok) return null;

            const data: BootstrapResponse = await response.json();

            // Handle emergency mode
            if (data.emergency?.enabled) {
                console.warn('[BOOTSTRAP] Emergency mode:', data.emergency.message);
                if (data.emergency.p2pOnly) {
                    // Signal to app to use P2P only
                    localStorage.setItem('emergency_p2p_mode', 'true');
                }
            } else {
                localStorage.removeItem('emergency_p2p_mode');
            }

            return data.servers || [];
        } catch (e) {
            return null;
        }
    }

    /**
     * Save servers to localStorage for offline/fallback use
     */
    private saveServersLocally() {
        localStorage.setItem('cached_servers', JSON.stringify({
            servers: this.servers,
            timestamp: Date.now()
        }));
    }

    /**
     * Load cached servers from localStorage
     */
    private loadCachedServers(): ServerInfo[] {
        try {
            const saved = localStorage.getItem('cached_servers');
            if (saved) {
                const data = JSON.parse(saved);
                this.servers = data.servers || [];
                return this.servers;
            }
        } catch {
            // Ignore parse errors
        }
        return [];
    }

    /**
     * Start auto-refresh of server list
     */
    private startAutoRefresh() {
        // Initial fetch
        this.fetchServers();

        // Periodic refresh
        setInterval(() => {
            this.fetchServers();
        }, this.fetchInterval);

        // Also refresh when app becomes visible
        if (typeof document !== 'undefined') {
            document.addEventListener('visibilitychange', () => {
                if (document.visibilityState === 'visible') {
                    this.fetchServers();
                }
            });
        }
    }

    /**
     * Get the current list of servers
     */
    getServers(): ServerInfo[] {
        if (this.servers.length === 0) {
            return this.loadCachedServers();
        }
        return this.servers;
    }

    /**
     * Get the best server URL to try first
     */
    getBestServerUrl(): string | null {
        const servers = this.getServers();
        if (servers.length === 0) return null;

        // Priority: primary > tunnel > backup
        const primary = servers.find(s => s.type === 'primary');
        if (primary) return primary.url;

        const tunnel = servers.find(s => s.type === 'tunnel');
        if (tunnel) return tunnel.url;

        return servers[0]?.url || null;
    }

    /**
     * Subscribe to server list updates
     */
    subscribe(callback: (servers: ServerInfo[]) => void): () => void {
        this.listeners.push(callback);
        callback(this.servers);
        return () => {
            this.listeners = this.listeners.filter(l => l !== callback);
        };
    }

    private notifyListeners() {
        this.listeners.forEach(cb => cb(this.servers));
    }

    /**
     * Check if we're in emergency P2P-only mode
     */
    isEmergencyMode(): boolean {
        return localStorage.getItem('emergency_p2p_mode') === 'true';
    }
}

export default BootstrapManager;
