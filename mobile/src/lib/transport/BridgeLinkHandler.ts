/**
 * BridgeLinkHandler — Handles incoming bridge deep links
 *
 * Listens for:
 *   vibe://bridge?d=<base64url>
 *   https://vibegram.io/bridge?d=<base64url>
 *
 * When a blocked user taps such a link, this:
 * 1. Parses the bridge descriptor from the URL
 * 2. Imports it into BootstrapStore
 * 3. Triggers the BlackoutState to switch to bridge_text mode
 * 4. Shows a confirmation toast
 */

import { Linking, Alert, Platform } from 'react-native';
import { importBridgeFromLink, decodeBridgeLink, isBridgeLink as checkIsBridgeLink } from '../relay/RelayBridgeLink';

let _registered = false;

/**
 * Check if a URL is a bridge import link.
 */
export function isBridgeLink(url: string | null | undefined): boolean {
  if (!url) return false;
  return checkIsBridgeLink(url);
}

/**
 * Handle a bridge link — import the descriptor and connect.
 * Returns true if the URL was handled, false otherwise.
 */
export async function handleBridgeLink(url: string): Promise<boolean> {
  if (!isBridgeLink(url)) return false;

  const descriptor = decodeBridgeLink(url);
  if (!descriptor) {
    Alert.alert('Invalid Link', 'This bridge link is not valid or has expired.');
    return true;
  }

  try {
    const result = await importBridgeFromLink(url);
    if (result.success && result.descriptor) {
      const name = result.descriptor.id || result.descriptor.host || 'Unknown';
      Alert.alert(
        '✅ Bridge Connected',
        `You're now connected through relay "${name}". Messages will be sent in text-only mode.`,
        [{ text: 'OK' }],
      );
    } else {
      Alert.alert('Connection Failed', result.error || 'Could not import bridge configuration.');
    }
  } catch (error) {
    console.error('[BridgeLinkHandler] import failed:', error);
    Alert.alert('Error', 'Failed to import bridge. Please try again.');
  }

  return true;
}

/**
 * Register the deep link listener.
 * Call this once from the app's root component (e.g. _layout.tsx).
 */
export function registerBridgeLinkHandler(): () => void {
  if (_registered) return () => {};
  _registered = true;

  // Handle links received while the app is open
  const subscription = Linking.addEventListener('url', async ({ url }) => {
    if (isBridgeLink(url)) {
      await handleBridgeLink(url);
    }
  });

  // Handle the initial URL if the app was launched from a link
  Linking.getInitialURL()
    .then(async (url) => {
      if (url && isBridgeLink(url)) {
        // Small delay to let the app initialize
        setTimeout(() => handleBridgeLink(url), 1000);
      }
    })
    .catch((err) => {
      console.warn('[BridgeLinkHandler] getInitialURL error:', err);
    });

  return () => {
    subscription.remove();
    _registered = false;
  };
}
