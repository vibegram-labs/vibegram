/**
 * VibeNet Relay Network
 *
 * A censorship-resistant peer relay network inspired by MTProto, Snowflake, and Tor.
 *
 * Architecture:
 * ┌─────────────────────────────────────────────────────┐
 * │                    VibeNet Protocol                   │
 * │  Custom binary protocol with encryption & obfuscation│
 * ├─────────────────────────────────────────────────────┤
 * │                                                       │
 * │  RelayNode (User A)        RelayClient (User B)      │
 * │  ├─ Becomes a bridge       ├─ Connects to bridge     │
 * │  ├─ Forwards traffic       ├─ Routes all traffic     │
 * │  └─ Can't read content     └─ E2E encrypted          │
 * │                                                       │
 * │  RelayDirectory                                       │
 * │  ├─ Server directory (Phoenix channel)                │
 * │  ├─ DNS discovery (DoH via Cloudflare)                │
 * │  ├─ Bootstrap list (hardcoded)                        │
 * │  └─ Peer sharing (invite codes)                       │
 * │                                                       │
 * │  Transport Obfuscation                                │
 * │  ├─ TLS mimicry (looks like HTTPS)                    │
 * │  ├─ Random padding (defeats traffic analysis)         │
 * │  └─ HMAC verification (detects tampering)             │
 * │                                                       │
 * └─────────────────────────────────────────────────────┘
 *
 * Security:
 * - All app data is E2E encrypted (relay can't read)
 * - Transport layer uses AES-256-CTR + HMAC-SHA256
 * - Session keys derived via HKDF from shared secret
 * - Traffic wrapped in TLS records (invisible to DPI)
 * - Relay nodes are "dumb pipes" — encrypted in, encrypted out
 */

export { default as RelayNode } from './RelayNode';
export { default as RelayClient } from './RelayClient';
export { default as RelayDirectory } from './RelayDirectory';
export {
    registerRelayAsBridge,
    encodeBridgeLink,
    encodeBridgeHttpsLink,
    decodeBridgeLink,
    importBridgeFromLink,
    encodeBridgeText,
    decodeBridgeText,
    getRelayBridgeInfo,
} from './RelayBridgeLink';

export {
    // Protocol
    MessageType,
    deriveSessionKeys,
    generateRelayKey,
    generateInviteCode,
    encodeFrame,
    decodeFrame,
    wrapTLS,
    unwrapTLS,
    encodeHTTPRequest,
    decodeHTTPRequest,
    encodeHTTPResponse,
    decodeHTTPResponse,
    encodeWSFrame,
    decodeWSFrame,
} from './VibeNetProtocol';

export type {
    SessionKeys,
    VibeNetFrame,
} from './VibeNetProtocol';

export type {
    RelayConfig,
    ConnectedPeer,
    RelayStatus,
} from './RelayNode';

export type {
    ConnectionStatus,
    RelayInfo,
} from './RelayClient';

export type {
    DirectoryRelay,
    DirectoryStatus,
} from './RelayDirectory';
