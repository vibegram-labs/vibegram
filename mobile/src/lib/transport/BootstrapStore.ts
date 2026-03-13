import AsyncStorage from '@react-native-async-storage/async-storage';
import Constants from 'expo-constants';
import { Buffer } from 'buffer';

import {
  asRecord,
  asString,
  buildBridgeBaseUrl,
  canonicalizeBridgeBundlePayload,
  coerceBridgeBundle,
} from './bridgeBundle';
import type { BootstrapSnapshot, BridgeBundle, BridgeDescriptor } from './types';

const STORAGE_KEY = 'vibe.blackout.bootstrap.v1';

type PersistedBootstrapPayload = {
  bundle?: BridgeBundle;
  activeBridgeId?: string;
  lastUpdatedAt?: number;
  source?: BootstrapSnapshot['source'];
};

type Listener = (snapshot: BootstrapSnapshot) => void;

const nowMs = (): number => Date.now();

const getBlackoutExtra = (): Record<string, unknown> => {
  const extra = (Constants.expoConfig?.extra || Constants.manifest2?.extra || {}) as Record<string, unknown>;
  const nativeChat = asRecord(extra.nativeChat);
  return asRecord(nativeChat?.blackout) || {};
};

const parseJsonValue = <T>(value: unknown): T | undefined => {
  if (typeof value === 'string') {
    try {
      return JSON.parse(value) as T;
    } catch {
      return undefined;
    }
  }
  return value as T | undefined;
};

const normalizePublicKeyPem = (raw: string): string => {
  if (raw.includes('BEGIN PUBLIC KEY')) return raw;
  const sanitized = raw.replace(/\s+/g, '');
  const chunked = sanitized.match(/.{1,64}/g)?.join('\n') || sanitized;
  return `-----BEGIN PUBLIC KEY-----\n${chunked}\n-----END PUBLIC KEY-----`;
};

const resolveControlPublicKeys = (): string[] => {
  const extra = getBlackoutExtra();
  const raw =
    process.env.EXPO_PUBLIC_BLACKOUT_BRIDGE_CONTROL_KEYS
    ?? extra.controlPublicKeys
    ?? extra.controlKeys;
  const parsed = parseJsonValue<unknown>(raw);
  const list = Array.isArray(parsed) ? parsed : typeof raw === 'string' ? raw.split(',') : [];
  return list
    .map((entry) => asString(entry))
    .filter((entry): entry is string => !!entry)
    .map(normalizePublicKeyPem);
};

const verifyBridgeBundleSignature = async (bundle: BridgeBundle): Promise<boolean> => {
  const controlKeys = resolveControlPublicKeys();
  if (controlKeys.length === 0) {
    return __DEV__;
  }
  if (!bundle.signature) return false;

  let QuickCrypto: any;
  try {
    QuickCrypto = require('react-native-quick-crypto');
    if (QuickCrypto?.default) QuickCrypto = QuickCrypto.default;
  } catch {
    return false;
  }

  if (!QuickCrypto?.verify || !QuickCrypto?.createPublicKey) {
    return false;
  }

  const canonicalPayload = Buffer.from(canonicalizeBridgeBundlePayload(bundle), 'utf8');
  const signature = Buffer.from(bundle.signature, 'base64');
  for (const publicKeyPem of controlKeys) {
    try {
      const key = QuickCrypto.createPublicKey(publicKeyPem);
      if (QuickCrypto.verify(null, canonicalPayload, key, signature)) {
        return true;
      }
    } catch {
      // Try the next control key.
    }
  }
  return false;
};

const isBundleExpired = (bundle: BridgeBundle, ts = nowMs()): boolean => {
  if (!bundle.expiresAt) return false;
  return bundle.expiresAt <= ts;
};

const pickNewerBundle = (current: BridgeBundle | undefined, next: BridgeBundle | undefined): BridgeBundle | undefined => {
  if (!next) return current;
  if (!current) return next;
  const currentRank = current.generatedAt ?? current.version ?? 0;
  const nextRank = next.generatedAt ?? next.version ?? 0;
  return nextRank >= currentRank ? next : current;
};

class BootstrapStore {
  private static instance: BootstrapStore | null = null;

  private ready = false;
  private initPromise: Promise<BootstrapSnapshot> | null = null;
  private listeners = new Set<Listener>();
  private snapshot: BootstrapSnapshot = {
    ready: false,
    verified: false,
  };

  static getInstance(): BootstrapStore {
    if (!BootstrapStore.instance) {
      BootstrapStore.instance = new BootstrapStore();
    }
    return BootstrapStore.instance;
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

  private setSnapshot(snapshot: Partial<BootstrapSnapshot>): BootstrapSnapshot {
    this.snapshot = {
      ...this.snapshot,
      ...snapshot,
      ready: true,
    };
    this.ready = true;
    this.emit();
    return this.snapshot;
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  getSnapshot(): BootstrapSnapshot {
    return { ...this.snapshot };
  }

  private getBakedInBundle(): BridgeBundle | undefined {
    const extra = getBlackoutExtra();
    const raw = process.env.EXPO_PUBLIC_BLACKOUT_BRIDGE_BUNDLE ?? extra.bridgeBundle;
    return coerceBridgeBundle(parseJsonValue(raw));
  }

  private async validateBundle(bundle: BridgeBundle | undefined): Promise<{ bundle?: BridgeBundle; verified: boolean; error?: string }> {
    if (!bundle) {
      return { verified: false, error: 'bundle_missing' };
    }
    if (bundle.descriptors.length === 0) {
      return { verified: false, error: 'bundle_empty' };
    }
    if (isBundleExpired(bundle)) {
      return { verified: false, error: 'bundle_expired' };
    }
    const verified = await verifyBridgeBundleSignature(bundle);
    if (!verified) {
      return { verified: false, error: 'bundle_signature_invalid' };
    }
    return { bundle, verified: true };
  }

  async ensureReady(): Promise<BootstrapSnapshot> {
    if (this.ready) return this.getSnapshot();
    if (this.initPromise) return this.initPromise;
    this.initPromise = (async () => {
      let storedBundle: BridgeBundle | undefined;
      let storedActiveBridgeId: string | undefined;
      let storedSource: BootstrapSnapshot['source'];
      let storedUpdatedAt: number | undefined;

      try {
        const raw = await AsyncStorage.getItem(STORAGE_KEY);
        if (raw) {
          const parsed = JSON.parse(raw) as PersistedBootstrapPayload;
          storedBundle = coerceBridgeBundle(parsed.bundle);
          storedActiveBridgeId = asString(parsed.activeBridgeId);
          storedSource = parsed.source;
          storedUpdatedAt = typeof parsed.lastUpdatedAt === 'number' ? parsed.lastUpdatedAt : undefined;
        }
      } catch (error) {
        this.snapshot.lastError = error instanceof Error ? error.message : 'bootstrap_load_failed';
      }

      const bakedInBundle = this.getBakedInBundle();
      const storedValidation = await this.validateBundle(storedBundle);
      const bakedInValidation = await this.validateBundle(bakedInBundle);
      const selectedBundle = pickNewerBundle(storedValidation.bundle, bakedInValidation.bundle);
      const validation =
        selectedBundle === storedValidation.bundle
          ? storedValidation
          : bakedInValidation;
      const activeBridgeId = storedActiveBridgeId
        || validation.bundle?.descriptors
          ?.slice()
          .sort((left, right) => (left.priority ?? 999) - (right.priority ?? 999))[0]?.id;
      const bridgeBaseUrl = buildBridgeBaseUrl(undefined, validation.bundle, activeBridgeId);

      return this.setSnapshot({
        bundle: validation.bundle,
        activeBridgeId,
        bridgeBaseUrl,
        source:
          validation.bundle === storedValidation.bundle
            ? (storedSource || 'stored')
            : validation.bundle === bakedInValidation.bundle
              ? 'baked_in'
              : undefined,
        verified: validation.verified,
        lastUpdatedAt: storedUpdatedAt ?? nowMs(),
        lastError: validation.error || storedValidation.error || bakedInValidation.error,
      });
    })();
    try {
      return await this.initPromise;
    } finally {
      this.initPromise = null;
    }
  }

  async importBundle(bundleInput: unknown, source: BootstrapSnapshot['source'] = 'imported'): Promise<BootstrapSnapshot> {
    const bundle = coerceBridgeBundle(bundleInput);
    if (!bundle || bundle.descriptors.length === 0) {
      throw new Error('bundle_invalid');
    }
    // For 'imported' bundles (relay links, QR codes), skip signature check —
    // the user explicitly chose to trust this source.
    if (source !== 'imported') {
      const validation = await this.validateBundle(bundle);
      if (!validation.bundle || !validation.verified) {
        throw new Error(validation.error || 'bundle_invalid');
      }
    }
    const activeBridgeId =
      bundle.descriptors
        .slice()
        .sort((left: BridgeDescriptor, right: BridgeDescriptor) => (left.priority ?? 999) - (right.priority ?? 999))[0]?.id;
    const payload: PersistedBootstrapPayload = {
      bundle,
      activeBridgeId,
      source,
      lastUpdatedAt: nowMs(),
    };
    await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(payload));
    return this.setSnapshot({
      bundle,
      activeBridgeId,
      bridgeBaseUrl: buildBridgeBaseUrl(undefined, bundle, activeBridgeId),
      source,
      verified: true,
      lastUpdatedAt: payload.lastUpdatedAt,
      lastError: undefined,
    });
  }

  async refreshFromBridge(baseUrl: string, authToken?: string): Promise<BootstrapSnapshot> {
    const trimmedBaseUrl = baseUrl.trim().replace(/\/$/, '');
    const request = await fetch(`${trimmedBaseUrl}/bridge/v1/bundle`, {
      headers: authToken ? { Authorization: `Bearer ${authToken}` } : undefined,
    });
    if (!request.ok) {
      throw new Error(`bridge_bundle_refresh_failed:${request.status}`);
    }
    const body = await request.json();
    return this.importBundle(body, 'remote');
  }
}

const store = BootstrapStore.getInstance();

export const ensureBootstrapStoreReady = (): Promise<BootstrapSnapshot> => store.ensureReady();
export const getBootstrapSnapshot = (): BootstrapSnapshot => store.getSnapshot();
export const subscribeBootstrapSnapshot = (listener: Listener): (() => void) => store.subscribe(listener);
export const importBridgeBundle = (bundleInput: unknown, source?: BootstrapSnapshot['source']) =>
  store.importBundle(bundleInput, source);
export const refreshBridgeBundleFromBaseUrl = (baseUrl: string, authToken?: string) =>
  store.refreshFromBridge(baseUrl, authToken);
