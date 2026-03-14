import AsyncStorage from '@react-native-async-storage/async-storage';

import ProxyManager from '../ProxyManager';
import { buildBridgeBaseUrl } from './bridgeBundle';
import { ensureBootstrapStoreReady, getBootstrapSnapshot } from './BootstrapStore';
import { isBlackoutEligibleRegion } from './GeoCheck';
import type { BlackoutCapabilities, BlackoutPhase, BlackoutStateSnapshot, NativeTransportSnapshot, TransportMode } from './types';

const STORAGE_KEY = 'vibe.blackout.state.v1';
const DEFAULT_CAPABILITIES: BlackoutCapabilities = {
  text: true,
  homeSnapshot: true,
  history: true,
  media: false,
  calls: false,
  search: false,
  avatars: false,
};

type PersistedBlackoutState = Omit<BlackoutStateSnapshot, 'ready'>;
type Listener = (snapshot: BlackoutStateSnapshot) => void;

const FAILURE_WINDOW_MS = 60_000;
const DIRECT_FAILURE_THRESHOLD = 3;
const DIRECT_SUCCESS_THRESHOLD = 3;
const BRIDGE_FAILURE_THRESHOLD = 3;
const REPROBE_INTERVAL_MS = 60_000;
const REPROBE_TIMEOUT_MS = 8_000;

const nowMs = (): number => Date.now();

class BlackoutStateController {
  private static instance: BlackoutStateController | null = null;

  private ready = false;
  private blackoutEligible = false; // true only if geo-check says user is in a censored region
  private initPromise: Promise<BlackoutStateSnapshot> | null = null;
  private listeners = new Set<Listener>();
  private reprobeTimer: ReturnType<typeof setInterval> | null = null;
  private reprobeInFlight = false;
  private snapshot: BlackoutStateSnapshot = {
    ready: false,
    phase: 'normal',
    transportMode: 'direct',
    directFailureTimestamps: [],
    directSuccessStreak: 0,
    bridgeFailureCount: 0,
    updatedAt: 0,
  };

  static getInstance(): BlackoutStateController {
    if (!BlackoutStateController.instance) {
      BlackoutStateController.instance = new BlackoutStateController();
    }
    return BlackoutStateController.instance;
  }

  private emit(): void {
    const snapshot = this.getSnapshot();
    this.listeners.forEach((listener) => {
      try {
        listener(snapshot);
      } catch {
        // Ignore listener failures.
      }
    });
  }

  private async persist(): Promise<void> {
    const payload: PersistedBlackoutState = {
      phase: this.snapshot.phase,
      transportMode: this.snapshot.transportMode,
      directFailureTimestamps: this.snapshot.directFailureTimestamps,
      directSuccessStreak: this.snapshot.directSuccessStreak,
      bridgeFailureCount: this.snapshot.bridgeFailureCount,
      activeBridgeId: this.snapshot.activeBridgeId,
      lastError: this.snapshot.lastError,
      updatedAt: this.snapshot.updatedAt,
      lastBridgeConnectedAt: this.snapshot.lastBridgeConnectedAt,
      lastDirectSuccessAt: this.snapshot.lastDirectSuccessAt,
    };
    try {
      await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(payload));
    } catch {
      // Best-effort persistence only.
    }
  }

  private setSnapshot(update: Partial<BlackoutStateSnapshot>): BlackoutStateSnapshot {
    this.snapshot = {
      ...this.snapshot,
      ...update,
      ready: true,
      updatedAt: update.updatedAt ?? nowMs(),
    };
    this.ready = true;
    void this.persist();
    this.emit();
    return this.snapshot;
  }

  private startReprobeLoop(): void {
    if (this.reprobeTimer) return;
    this.reprobeTimer = setInterval(() => {
      void this.runDirectReprobe();
    }, REPROBE_INTERVAL_MS);
  }

  private async runDirectReprobe(): Promise<void> {
    if (this.reprobeInFlight) return;
    if (this.snapshot.transportMode === 'direct') return;
    this.reprobeInFlight = true;
    try {
      const proxyManager = ProxyManager.getInstance();
      const baseUrl = proxyManager.getBestUrl().trim().replace(/\/$/, '');
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), REPROBE_TIMEOUT_MS);
      try {
        const response = await fetch(`${baseUrl}/api/ping`, {
          signal: controller.signal,
          headers: { Accept: 'application/json' },
        });
        clearTimeout(timeoutId);
        if (response.ok) {
          await this.recordDirectSuccess('reprobe');
          return;
        }
      } catch (error) {
        clearTimeout(timeoutId);
        this.setSnapshot({
          phase: this.snapshot.transportMode === 'offline' ? 'offline' : 'direct_reprobe',
          lastError: error instanceof Error ? error.message : 'direct_reprobe_failed',
        });
        return;
      }
      this.setSnapshot({
        phase: this.snapshot.transportMode === 'offline' ? 'offline' : 'direct_reprobe',
      });
    } finally {
      this.reprobeInFlight = false;
    }
  }

  private resolveBridgeFallbackState(lastError?: string): Partial<BlackoutStateSnapshot> {
    const bootstrap = getBootstrapSnapshot();
    const bridgeBaseUrl = buildBridgeBaseUrl(
      bootstrap.bridgeBaseUrl,
      bootstrap.bundle,
      bootstrap.activeBridgeId,
    );
    if (bootstrap.bundle && bridgeBaseUrl) {
      return {
        transportMode: 'bridge_text',
        phase: 'bridge_bootstrap',
        directSuccessStreak: 0,
        bridgeFailureCount: 0,
        activeBridgeId: bootstrap.activeBridgeId,
        lastError,
      };
    }
    return {
      transportMode: 'offline',
      phase: 'offline',
      directSuccessStreak: 0,
      bridgeFailureCount: 0,
      activeBridgeId: undefined,
      lastError: lastError || bootstrap.lastError || 'bridge_bootstrap_missing',
    };
  }

  async ensureReady(): Promise<BlackoutStateSnapshot> {
    if (this.ready) return this.getSnapshot();
    if (this.initPromise) return this.initPromise;
    this.initPromise = (async () => {
      await ensureBootstrapStoreReady();
      try {
        const raw = await AsyncStorage.getItem(STORAGE_KEY);
        if (raw) {
          const parsed = JSON.parse(raw) as PersistedBlackoutState;
          this.snapshot = {
            ready: true,
            phase: parsed.phase || 'normal',
            transportMode: parsed.transportMode || 'direct',
            directFailureTimestamps: Array.isArray(parsed.directFailureTimestamps)
              ? parsed.directFailureTimestamps.filter((entry): entry is number => typeof entry === 'number')
              : [],
            directSuccessStreak: typeof parsed.directSuccessStreak === 'number' ? parsed.directSuccessStreak : 0,
            bridgeFailureCount: typeof parsed.bridgeFailureCount === 'number' ? parsed.bridgeFailureCount : 0,
            activeBridgeId: parsed.activeBridgeId,
            lastError: parsed.lastError,
            updatedAt: typeof parsed.updatedAt === 'number' ? parsed.updatedAt : nowMs(),
            lastBridgeConnectedAt: parsed.lastBridgeConnectedAt,
            lastDirectSuccessAt: parsed.lastDirectSuccessAt,
          };
        }
      } catch (error) {
        this.snapshot.lastError = error instanceof Error ? error.message : 'blackout_state_load_failed';
      }

      // ── Geo-IP eligibility check ──
      // Only allow blackout mode in known censored countries.
      // For all other regions, force direct mode regardless of persisted state.
      try {
        const geoResult = await isBlackoutEligibleRegion();
        this.blackoutEligible = geoResult.eligible;
        console.log(`[BlackoutState] geo-check: country=${geoResult.countryCode} eligible=${geoResult.eligible}`);
      } catch {
        // Geo-check failed — default to NOT eligible (safe: use direct)
        this.blackoutEligible = false;
        console.log('[BlackoutState] geo-check failed — defaulting to not eligible');
      }

      if (!this.blackoutEligible) {
        // User is NOT in a censored region → always use direct mode.
        // Clear any stale blackout state from previous sessions.
        if (this.snapshot.transportMode !== 'direct') {
          console.log('[BlackoutState] not in censored region — forcing direct mode (was:', this.snapshot.transportMode, ')');
        }
        this.snapshot = {
          ...this.snapshot,
          ready: true,
          phase: 'normal',
          transportMode: 'direct',
          directFailureTimestamps: [],
          directSuccessStreak: 0,
          bridgeFailureCount: 0,
          lastError: undefined,
          updatedAt: nowMs(),
        };
      } else if (this.snapshot.transportMode !== 'direct') {
        // ── Startup recovery probe (censored region only) ──
        // Even in a censored region, verify the block is real before staying
        // in blackout mode. A single successful probe resets to direct.
        try {
          const proxyManager = ProxyManager.getInstance();
          const baseUrl = proxyManager.getBestUrl().trim().replace(/\/$/, '');
          const probeController = new AbortController();
          const probeTimeout = setTimeout(() => probeController.abort(), REPROBE_TIMEOUT_MS);
          try {
            const response = await fetch(`${baseUrl}/api/ping`, {
              signal: probeController.signal,
              headers: { Accept: 'application/json' },
            });
            clearTimeout(probeTimeout);
            if (response.ok) {
              console.log('[BlackoutState] startup probe succeeded in censored region — resetting to direct');
              this.snapshot = {
                ...this.snapshot,
                ready: true,
                phase: 'normal',
                transportMode: 'direct',
                directFailureTimestamps: [],
                directSuccessStreak: 0,
                bridgeFailureCount: 0,
                lastDirectSuccessAt: nowMs(),
                lastError: undefined,
                updatedAt: nowMs(),
              };
            }
          } catch (_probeErr) {
            clearTimeout(probeTimeout);
            console.log('[BlackoutState] startup probe failed in censored region — keeping blackout mode');
          }
        } catch {
          // ProxyManager or other init issue — keep persisted state.
        }
      }

      this.ready = true;
      // Only run the reprobe loop in censored regions where blackout can activate
      if (this.blackoutEligible) {
        this.startReprobeLoop();
      }
      this.emit();
      return this.getSnapshot();
    })();
    try {
      return await this.initPromise;
    } finally {
      this.initPromise = null;
    }
  }

  getSnapshot(): BlackoutStateSnapshot {
    return { ...this.snapshot };
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  async recordDirectFailure(source: string, error?: string): Promise<BlackoutStateSnapshot> {
    await this.ensureReady();

    // If user is NOT in a censored region, never escalate to blackout.
    // Just log the failure and stay in direct mode.
    if (!this.blackoutEligible) {
      return this.setSnapshot({
        lastError: error || source,
      });
    }

    const ts = nowMs();
    const failures = [...this.snapshot.directFailureTimestamps, ts].filter((entry) => ts - entry <= FAILURE_WINDOW_MS);
    const nextState: Partial<BlackoutStateSnapshot> = {
      directFailureTimestamps: failures,
      directSuccessStreak: 0,
      lastError: error || source,
      phase: this.snapshot.transportMode === 'direct' ? 'suspect_blackout' : this.snapshot.phase,
    };
    if (this.snapshot.transportMode === 'direct' && failures.length >= DIRECT_FAILURE_THRESHOLD) {
      Object.assign(nextState, this.resolveBridgeFallbackState(error || source));
    }
    return this.setSnapshot(nextState);
  }

  async recordDirectSuccess(_source: string): Promise<BlackoutStateSnapshot> {
    await this.ensureReady();
    const ts = nowMs();
    if (this.snapshot.transportMode === 'direct') {
      return this.setSnapshot({
        phase: 'normal',
        directFailureTimestamps: [],
        directSuccessStreak: 0,
        bridgeFailureCount: 0,
        lastDirectSuccessAt: ts,
        lastError: undefined,
      });
    }
    const nextStreak = this.snapshot.directSuccessStreak + 1;
    if (nextStreak >= DIRECT_SUCCESS_THRESHOLD) {
      return this.setSnapshot({
        phase: 'normal',
        transportMode: 'direct',
        directFailureTimestamps: [],
        directSuccessStreak: 0,
        bridgeFailureCount: 0,
        activeBridgeId: this.snapshot.activeBridgeId,
        lastDirectSuccessAt: ts,
        lastError: undefined,
      });
    }
    return this.setSnapshot({
      phase: 'direct_reprobe',
      directFailureTimestamps: [],
      directSuccessStreak: nextStreak,
      lastDirectSuccessAt: ts,
    });
  }

  async recordBridgeConnecting(activeBridgeId?: string): Promise<BlackoutStateSnapshot> {
    await this.ensureReady();
    return this.setSnapshot({
      transportMode: 'bridge_text',
      phase: 'bridge_bootstrap',
      bridgeFailureCount: 0,
      activeBridgeId: activeBridgeId || this.snapshot.activeBridgeId,
    });
  }

  async recordBridgeConnected(activeBridgeId?: string): Promise<BlackoutStateSnapshot> {
    await this.ensureReady();
    return this.setSnapshot({
      transportMode: 'bridge_text',
      phase: 'bridge_active',
      bridgeFailureCount: 0,
      activeBridgeId: activeBridgeId || this.snapshot.activeBridgeId,
      lastBridgeConnectedAt: nowMs(),
      lastError: undefined,
    });
  }

  async recordBridgeFailure(source: string, error?: string): Promise<BlackoutStateSnapshot> {
    await this.ensureReady();
    const nextFailureCount = this.snapshot.bridgeFailureCount + 1;
    if (nextFailureCount >= BRIDGE_FAILURE_THRESHOLD) {
      return this.setSnapshot({
        transportMode: 'offline',
        phase: 'offline',
        bridgeFailureCount: nextFailureCount,
        lastError: error || source,
      });
    }
    return this.setSnapshot({
      transportMode: this.snapshot.transportMode === 'direct' ? 'bridge_text' : this.snapshot.transportMode,
      phase: 'bridge_active',
      bridgeFailureCount: nextFailureCount,
      lastError: error || source,
    });
  }

  getNativeTransportSnapshot(): NativeTransportSnapshot {
    const bootstrap = getBootstrapSnapshot();
    const activeBridgeId = this.snapshot.activeBridgeId || bootstrap.activeBridgeId;
    const bridgeBaseUrl = buildBridgeBaseUrl(bootstrap.bridgeBaseUrl, bootstrap.bundle, activeBridgeId);
    let transportMode: TransportMode = this.snapshot.transportMode;
    if (transportMode === 'bridge_text' && !bridgeBaseUrl) {
      transportMode = 'offline';
    }
    return {
      transportMode,
      bridgeBundle: bootstrap.bundle,
      activeBridgeId,
      bridgeBaseUrl,
      blackoutCapabilities: transportMode === 'direct'
        ? { text: true, media: true, calls: true, search: true, avatars: true }
        : DEFAULT_CAPABILITIES,
      disableRealtime: transportMode === 'offline',
      disableMedia: transportMode !== 'direct',
      disableCalls: transportMode !== 'direct',
      disableRemoteAvatars: transportMode !== 'direct',
    };
  }

  async forceDirectMode(reason?: string): Promise<BlackoutStateSnapshot> {
    await this.ensureReady();
    return this.setSnapshot({
      phase: 'normal',
      transportMode: 'direct',
      directFailureTimestamps: [],
      directSuccessStreak: 0,
      bridgeFailureCount: 0,
      lastError: reason,
    });
  }
}

const controller = BlackoutStateController.getInstance();

export const ensureBlackoutStateReady = (): Promise<BlackoutStateSnapshot> => controller.ensureReady();
export const getBlackoutStateSnapshot = (): BlackoutStateSnapshot => controller.getSnapshot();
export const getBlackoutTransportSnapshot = (): NativeTransportSnapshot => controller.getNativeTransportSnapshot();
export const subscribeBlackoutState = (listener: Listener): (() => void) => controller.subscribe(listener);
export const recordDirectTransportFailure = (source: string, error?: string): Promise<BlackoutStateSnapshot> =>
  controller.recordDirectFailure(source, error);
export const recordDirectTransportSuccess = (source: string): Promise<BlackoutStateSnapshot> =>
  controller.recordDirectSuccess(source);
export const recordBridgeTransportConnecting = (activeBridgeId?: string): Promise<BlackoutStateSnapshot> =>
  controller.recordBridgeConnecting(activeBridgeId);
export const recordBridgeTransportConnected = (activeBridgeId?: string): Promise<BlackoutStateSnapshot> =>
  controller.recordBridgeConnected(activeBridgeId);
export const recordBridgeTransportFailure = (source: string, error?: string): Promise<BlackoutStateSnapshot> =>
  controller.recordBridgeFailure(source, error);
export const forceDirectTransportMode = (reason?: string): Promise<BlackoutStateSnapshot> =>
  controller.forceDirectMode(reason);
export const ensureBlackoutControlReady = async (): Promise<void> => {
  await ensureBootstrapStoreReady();
  await ensureBlackoutStateReady();
};
