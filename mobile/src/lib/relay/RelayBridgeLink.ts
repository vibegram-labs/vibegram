/**
 * RelayBridgeLink — Bridges the relay system with blackout transport
 *
 * When a relay user enables their relay:
 * 1. Their device starts an HTTPS proxy (via the native ChatBlackoutTransport)
 * 2. Their relay info is registered on the server as a bridge descriptor
 * 3. A shareable link/QR is generated: vibe://bridge?d=<base64 descriptor>
 * 4. Blocked users tap the link → auto-imports bridge descriptor → connects
 *
 * This removes the Phoenix signaling dependency during blackout:
 * - Normal mode: relay uses Phoenix channels (existing RelayNode/RelayClient)
 * - Blackout mode: relay user's IP is a bridge in the BridgeBundle
 *   → blocked user connects directly via HTTPS long-poll
 *   → relay user's app forwards to the Vibe backend
 */

import { Buffer } from 'buffer';
import AsyncStorage from '@react-native-async-storage/async-storage';
import ProxyManager from '../ProxyManager';
import { importBridgeBundle } from '../transport/BootstrapStore';
import {
  ensureBlackoutControlReady,
  forceDirectTransportMode,
  recordBridgeTransportConnecting,
} from '../transport/BlackoutState';
import type { BridgeDescriptor, BridgeBundle } from '../transport/types';
import AuthManager from '../AuthManager';

const STORAGE_KEY = 'vibe.relay.bridge.v1';
const LINK_PREFIX = 'vibe://bridge';
const HTTPS_PREFIX = 'https://vibegram.io/bridge';

/**
 * Check if a URL is a bridge import link.
 */
export function isBridgeLink(url: string | null | undefined): boolean {
  if (!url) return false;
  return (
    url.startsWith('vibe://bridge') ||
    url.includes('vibegram.io/bridge') ||
    url.includes('/bridge?d=')
  );
}

export interface RelayBridgeLinkInfo {
  /** The relay user's device IP or reachable host */
  host?: string;
  /** Port (default 443) */
  port?: number;
  /** Relay user's ID */
  relayUserId: string;
  /** Relay ID from RelayNode config */
  relayId: string;
  /** Invite code */
  inviteCode?: string;
  /** Display name */
  name?: string;
  /** When this was registered */
  registeredAt: number;
  /** Server-confirmed external IP */
  externalIp?: string;
}

const getAuthHeaders = (): Record<string, string> => {
  const session = AuthManager.getInstance().getSession();
  if (!session?.loginToken) {
    return {};
  }
  return {
    Authorization: `Bearer ${session.loginToken}`,
  };
};

export async function activateBridgeDescriptor(
  descriptor: BridgeDescriptor,
): Promise<{ success: boolean; descriptor?: BridgeDescriptor; error?: string }> {
  if (!descriptor?.id && !descriptor?.host && !descriptor?.baseUrl) {
    return { success: false, error: 'invalid_bridge_descriptor' };
  }

  const bundle: BridgeBundle = {
    version: 1,
    generatedAt: Date.now(),
    descriptors: [descriptor],
  };

  try {
    await importBridgeBundle(bundle, 'imported');
    await ensureBlackoutControlReady();
    await recordBridgeTransportConnecting(descriptor.id);

    try {
      const chatStore = require('../ChatStore');
      chatStore?.resetSocketConnection?.();
      chatStore?.useChatStore?.getState?.().initSocket?.();
    } catch (error) {
      console.warn('[RelayBridgeLink] Failed to reinitialize chat transport after bridge import:', error);
    }

    return { success: true, descriptor };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : 'bridge_activation_failed',
    };
  }
}

export async function deactivateBridgeTransport(): Promise<void> {
  await ensureBlackoutControlReady();
  await forceDirectTransportMode('manual_bridge_disconnect');
  try {
    const chatStore = require('../ChatStore');
    chatStore?.resetSocketConnection?.();
    chatStore?.useChatStore?.getState?.().initSocket?.();
  } catch (error) {
    console.warn('[RelayBridgeLink] Failed to reinitialize direct transport:', error);
  }
}

/**
 * Register this relay as a bridge on the server.
 * The server stores it and can include it in bridge bundles.
 */
export async function registerRelayAsBridge(
  relayId: string,
  inviteCode: string | null,
  name: string,
): Promise<{ success: boolean; externalIp?: string; bridgeUrl?: string; shareLink?: string; error?: string }> {
  try {
    const proxy = ProxyManager.getInstance();
    const baseUrl = proxy.getBestUrl().trim().replace(/\/$/, '');

    const response = await fetch(`${baseUrl}/api/relay/register-bridge`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json',
        ...getAuthHeaders(),
      },
      body: JSON.stringify({
        relayId,
        inviteCode,
        name,
      }),
    });

    if (!response.ok) {
      const body = await response.text().catch(() => '');
      return { success: false, error: `register_failed:${response.status}:${body.slice(0, 100)}` };
    }

    const data = await response.json();
    const externalIp = data.externalIp || data.external_ip;
    const bridgeUrl = data.bridgeUrl || data.bridge_url;

    // Build the shareable link
    const descriptor: BridgeDescriptor = {
      id: relayId,
      host: externalIp,
      port: 443,
      transport: 'https',
      origin: 'community',
      priority: 50,
      weight: 100,
      baseUrl: bridgeUrl || (externalIp ? `https://${externalIp}` : undefined),
    };

    const shareLink = encodeBridgeLink(descriptor);

    // Persist locally
    const info: RelayBridgeLinkInfo = {
      host: externalIp,
      relayUserId: '', // Will be filled by caller
      relayId,
      inviteCode: inviteCode || undefined,
      name,
      registeredAt: Date.now(),
      externalIp,
    };

    await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(info));

    return { success: true, externalIp, bridgeUrl, shareLink };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : 'register_failed',
    };
  }
}

/**
 * Encode a bridge descriptor into a shareable link.
 * Blocked users can tap this to auto-import the bridge.
 *
 * Format: vibe://bridge?d=<base64url encoded descriptor JSON>
 * Also: https://vibegram.io/bridge?d=<base64url> (for universal links)
 */
export function encodeBridgeLink(descriptor: BridgeDescriptor): string {
  const json = JSON.stringify(descriptor);
  const b64 = Buffer.from(json, 'utf8').toString('base64url');
  return `${LINK_PREFIX}?d=${b64}`;
}

/**
 * Encode as an HTTPS universal link (works even without the app installed)
 */
export function encodeBridgeHttpsLink(descriptor: BridgeDescriptor): string {
  const json = JSON.stringify(descriptor);
  const b64 = Buffer.from(json, 'utf8').toString('base64url');
  return `${HTTPS_PREFIX}?d=${b64}`;
}

/**
 * Decode a bridge link received from a relay user.
 * Returns the bridge descriptor.
 */
export function decodeBridgeLink(url: string): BridgeDescriptor | null {
  try {
    const parsed = new URL(url);
    const d = parsed.searchParams.get('d');
    if (!d) return null;

    const json = Buffer.from(d, 'base64url').toString('utf8');
    const descriptor = JSON.parse(json) as BridgeDescriptor;

    if (!descriptor.id && !descriptor.host && !descriptor.baseUrl) return null;
    if (!descriptor.id) descriptor.id = descriptor.host || descriptor.baseUrl || 'imported';

    return descriptor;
  } catch {
    return null;
  }
}

/**
 * Import a bridge from a link/QR code and connect.
 * This is called when a blocked user taps a relay share link.
 */
export async function importBridgeFromLink(url: string): Promise<{
  success: boolean;
  descriptor?: BridgeDescriptor;
  error?: string;
}> {
  const descriptor = decodeBridgeLink(url);
  if (!descriptor) {
    return { success: false, error: 'invalid_bridge_link' };
  }
  return activateBridgeDescriptor(descriptor);
}

/**
 * Generate a compact text representation for sharing via SMS/chat.
 * Even more compact than a link — just the base64 descriptor.
 */
export function encodeBridgeText(descriptor: BridgeDescriptor): string {
  // Minimal descriptor for compact sharing
  const minimal: Record<string, unknown> = {};
  if (descriptor.baseUrl) minimal.u = descriptor.baseUrl;
  else if (descriptor.host) minimal.h = descriptor.host;
  if (descriptor.port && descriptor.port !== 443) minimal.p = descriptor.port;
  if (descriptor.id) minimal.i = descriptor.id;

  return Buffer.from(JSON.stringify(minimal), 'utf8').toString('base64url');
}

/**
 * Decode a compact text bridge descriptor.
 */
export function decodeBridgeText(text: string): BridgeDescriptor | null {
  try {
    const json = Buffer.from(text.trim(), 'base64url').toString('utf8');
    const minimal = JSON.parse(json) as Record<string, unknown>;

    const baseUrl = (minimal.u as string) || undefined;
    const host = (minimal.h as string) || undefined;
    const port = (minimal.p as number) || 443;
    const id = (minimal.i as string) || host || baseUrl || 'imported';

    if (!baseUrl && !host) return null;

    return {
      id,
      host,
      port,
      baseUrl,
      transport: 'https',
      origin: 'community',
      priority: 50,
      weight: 100,
    };
  } catch {
    return null;
  }
}

export async function resolveBridgeByInviteCode(inviteCode: string): Promise<{
  success: boolean;
  descriptor?: BridgeDescriptor;
  error?: string;
}> {
  const trimmed = inviteCode.trim().toUpperCase().replace(/[^A-Z0-9-]/g, '');
  if (!trimmed) {
    return { success: false, error: 'invalid_invite_code' };
  }

  try {
    const proxy = ProxyManager.getInstance();
    const baseUrl = proxy.getBestUrl().trim().replace(/\/$/, '');
    const url = `${baseUrl}/api/relay/resolve-bridge?inviteCode=${encodeURIComponent(trimmed)}`;
    const response = await fetch(url, {
      method: 'GET',
      headers: {
        Accept: 'application/json',
        ...getAuthHeaders(),
      },
    });

    if (!response.ok) {
      const body = await response.text().catch(() => '');
      return {
        success: false,
        error: `resolve_bridge_failed:${response.status}:${body.slice(0, 100)}`,
      };
    }

    const data = await response.json();
    const descriptor = (data.descriptor || data.bridgeDescriptor || data.bridge_descriptor) as BridgeDescriptor | undefined;
    if (!descriptor || (!descriptor.id && !descriptor.host && !descriptor.baseUrl)) {
      return { success: false, error: 'bridge_descriptor_missing' };
    }
    return { success: true, descriptor };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : 'resolve_bridge_failed',
    };
  }
}

/**
 * Get the stored relay bridge info (for relay host to see their status)
 */
export async function getRelayBridgeInfo(): Promise<RelayBridgeLinkInfo | null> {
  try {
    const raw = await AsyncStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    return JSON.parse(raw) as RelayBridgeLinkInfo;
  } catch {
    return null;
  }
}
