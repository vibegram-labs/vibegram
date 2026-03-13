import React, { useState, useEffect, useCallback, useRef } from 'react';
import {
    View, Text, StyleSheet, Platform, TouchableOpacity, ScrollView,
    Switch, TextInput, Alert, Share, ActivityIndicator, Dimensions,
} from 'react-native';
import { useRouter } from 'expo-router';
import {
    X, Globe, Shield, Radio, Users, Wifi, WifiOff, Copy, QrCode,
    ChevronRight, Server, Signal, Plus, Trash2, RefreshCw, ArrowLeft,
    Eye, EyeOff, Zap, Check, AlertTriangle, Share2,
} from 'lucide-react-native';
import { useThemeStore } from '../../src/lib/stores/theme-store';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass';
import * as Clipboard from 'expo-clipboard';
import * as Haptics from 'expo-haptics';
import Animated, { FadeIn, FadeOut, SlideInDown, SlideInRight } from 'react-native-reanimated';
import RelayNode from '../../src/lib/relay/RelayNode';
import RelayClient from '../../src/lib/relay/RelayClient';
import RelayDirectory from '../../src/lib/relay/RelayDirectory';
import type { DirectoryRelay } from '../../src/lib/relay/RelayDirectory';
import type { RelayStatus } from '../../src/lib/relay/RelayNode';
import type { ConnectionStatus } from '../../src/lib/relay/RelayClient';
import { getPhoenixSocket } from '../../src/lib/ChatStore';

const { width: SCREEN_WIDTH } = Dimensions.get('window');

const withAlpha = (color: string, alpha: number): string => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`;
    if (color.startsWith('#')) {
        const hex = color.replace('#', '');
        const r = parseInt(hex.substring(0, 2), 16);
        const g = parseInt(hex.substring(2, 4), 16);
        const b = parseInt(hex.substring(4, 6), 16);
        return `rgba(${r}, ${g}, ${b}, ${alpha})`;
    }
    return color;
};

const formatBytes = (bytes: number): string => {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / 1048576).toFixed(1)} MB`;
};

type TabType = 'connect' | 'relay' | 'directory';

export default function RelayNetworkScreen() {
    const router = useRouter();
    const { colors } = useThemeStore();
    const insets = useSafeAreaInsets();
    const [activeTab, setActiveTab] = useState<TabType>('connect');

    // Relay Node state (becoming a relay)
    const [relayEnabled, setRelayEnabled] = useState(false);
    const [relayStatus, setRelayStatus] = useState<RelayStatus>('stopped');
    const [relayPublic, setRelayPublic] = useState(false);
    const [relayName, setRelayName] = useState('');
    const [maxPeers, setMaxPeers] = useState(5);
    const [wifiOnly, setWifiOnly] = useState(true);
    const [inviteCode, setInviteCode] = useState<string | null>(null);
    const [peerCount, setPeerCount] = useState(0);
    const [bytesRelayed, setBytesRelayed] = useState(0);
    const [codeCopied, setCodeCopied] = useState(false);

    // Relay Client state (connecting to a relay)
    const [clientStatus, setClientStatus] = useState<ConnectionStatus>('disconnected');
    const [connectCode, setConnectCode] = useState('');
    const [isConnecting, setIsConnecting] = useState(false);
    const [connectedRelayName, setConnectedRelayName] = useState<string | null>(null);

    // Directory state
    const [publicRelays, setPublicRelays] = useState<DirectoryRelay[]>([]);
    const [isRefreshing, setIsRefreshing] = useState(false);

    // Load initial state
    useEffect(() => {
        const node = RelayNode.getInstance();
        const client = RelayClient.getInstance();
        const dir = RelayDirectory.getInstance();

        const config = node.getConfig();
        setRelayEnabled(config.enabled);
        setRelayPublic(config.isPublic);
        setRelayName(config.name);
        setMaxPeers(config.maxPeers);
        setWifiOnly(config.wifiOnly);
        setInviteCode(config.inviteCode);
        setRelayStatus(node.getStatus());
        setPeerCount(node.getPeerCount());
        setBytesRelayed(node.getTotalBytesRelayed());

        setClientStatus(client.getStatus());
        const currentRelay = client.getCurrentRelay();
        if (currentRelay) setConnectedRelayName(currentRelay.name);

        setPublicRelays(dir.getRelays());

        // Subscribe to events
        const unsubNode = node.subscribe((event, data) => {
            switch (event) {
                case 'status-changed': setRelayStatus(data); break;
                case 'peer-connected': setPeerCount(data.peerCount); break;
                case 'peer-disconnected': setPeerCount(data.peerCount); break;
                case 'config-changed': break;
            }
            setBytesRelayed(node.getTotalBytesRelayed());
        });

        const unsubClient = client.subscribe((event, data) => {
            if (event === 'status-changed') setClientStatus(data);
        });

        const unsubDir = dir.subscribe((event, data) => {
            if (event === 'relays-updated') setPublicRelays(data);
        });

        return () => { unsubNode(); unsubClient(); unsubDir(); };
    }, []);

    // ─── Relay Node Actions ──────────────────────────────────────

    const toggleRelay = async (enabled: boolean) => {
        const node = RelayNode.getInstance();
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);

        if (enabled) {
            await node.updateConfig({ name: relayName, isPublic: relayPublic, maxPeers, wifiOnly });
            // Note: In production, pass the actual Phoenix socket here
            const result = await node.startRelay(null);
            if (result.success) {
                setRelayEnabled(true);
                setInviteCode(result.inviteCode || null);
            } else {
                Alert.alert('Error', result.error || 'Failed to start relay');
            }
        } else {
            await node.stopRelay();
            setRelayEnabled(false);
        }
    };

    const copyInviteCode = async () => {
        if (inviteCode) {
            await Clipboard.setStringAsync(inviteCode);
            Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
            setCodeCopied(true);
            setTimeout(() => setCodeCopied(false), 2000);
        }
    };

    const shareInviteCode = async () => {
        if (inviteCode) {
            await Share.share({
                message: `Connect to my Vibe relay: ${inviteCode}\n\nOpen Vibe → Settings → Relay Network → Enter this code to connect.`,
            });
        }
    };

    // ─── Client Actions ──────────────────────────────────────────

    const connectToRelay = async () => {
        if (!connectCode.trim()) return;
        setIsConnecting(true);
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);

        const client = RelayClient.getInstance();
        const result = await client.connectWithCode(connectCode.trim(), getPhoenixSocket());

        setIsConnecting(false);
        if (result.success) {
            Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
            const relay = client.getCurrentRelay();
            setConnectedRelayName(relay?.name || 'Relay');
        } else {
            Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
            Alert.alert('Connection Failed', result.error || 'Could not connect to relay');
        }
    };

    const disconnectFromRelay = async () => {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
        await RelayClient.getInstance().disconnect();
        setConnectedRelayName(null);
    };

    // ─── Directory Actions ───────────────────────────────────────

    const refreshDirectory = async () => {
        setIsRefreshing(true);
        const dir = RelayDirectory.getInstance();
        await dir.refresh();
        await dir.testAllLatencies();
        setPublicRelays(dir.getRelays());
        setIsRefreshing(false);
    };

    const connectToPublicRelay = async (relay: DirectoryRelay) => {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
        const client = RelayClient.getInstance();
        const result = await client.connectToRelay({
            relayId: relay.relayId,
            name: relay.name,
            inviteCode: relay.inviteCode,
            inviteKey: relay.inviteKey,
            externalIp: relay.externalIp,
            bridgeUrl: relay.bridgeUrl,
            shareLink: relay.shareLink,
            bridgeDescriptor: relay.bridgeDescriptor,
            isPublic: true,
        }, getPhoenixSocket());

        if (result.success) {
            setConnectedRelayName(relay.name);
            setActiveTab('connect');
        } else {
            Alert.alert('Connection Failed', result.error || 'Could not connect');
        }
    };

    // ─── Status Helpers ──────────────────────────────────────────

    const getStatusColor = (status: string) => {
        switch (status) {
            case 'connected': case 'running': return '#22c55e';
            case 'connecting': case 'handshaking': case 'starting': case 'reconnecting': return '#f59e0b';
            case 'error': return '#ef4444';
            default: return colors.textSecondary;
        }
    };

    const getStatusText = (status: string) => {
        switch (status) {
            case 'connected': return 'Connected';
            case 'connecting': return 'Connecting...';
            case 'handshaking': return 'Handshaking...';
            case 'reconnecting': return 'Reconnecting...';
            case 'running': return 'Running';
            case 'starting': return 'Starting...';
            case 'error': return 'Error';
            case 'stopped': return 'Stopped';
            default: return 'Disconnected';
        }
    };

    // ─── Render ──────────────────────────────────────────────────

    return (
        <View style={[styles.container, { backgroundColor: colors.background, paddingTop: insets.top }]}>
            {/* Header */}
            <View style={styles.header}>
                <TouchableOpacity onPress={() => router.back()} style={styles.headerBtn}>
                    <ArrowLeft size={24} color={colors.text} />
                </TouchableOpacity>
                <Text style={[styles.headerTitle, { color: colors.text }]}>Relay Network</Text>
                <View style={styles.headerBtn} />
            </View>

            {/* Tabs */}
            <View style={[styles.tabBar, { borderBottomColor: withAlpha(colors.text, 0.08) }]}>
                {(['connect', 'relay', 'directory'] as TabType[]).map(tab => (
                    <TouchableOpacity
                        key={tab}
                        onPress={() => { setActiveTab(tab); Haptics.selectionAsync(); }}
                        style={[styles.tab, activeTab === tab && { borderBottomColor: colors.primary, borderBottomWidth: 2 }]}
                    >
                        <Text style={[
                            styles.tabText,
                            { color: activeTab === tab ? colors.primary : colors.textSecondary }
                        ]}>
                            {tab === 'connect' ? 'Connect' : tab === 'relay' ? 'Be a Relay' : 'Directory'}
                        </Text>
                    </TouchableOpacity>
                ))}
            </View>

            <ScrollView contentContainerStyle={styles.content} showsVerticalScrollIndicator={false}>

                {/* ═══ CONNECT TAB ═══ */}
                {activeTab === 'connect' && (
                    <Animated.View entering={FadeIn.duration(200)}>
                        {/* Connection Status */}
                        <SafeLiquidGlass style={styles.card} blurIntensity={15} tint="default">
                            <View style={styles.statusRow}>
                                <View style={[styles.statusDot, { backgroundColor: getStatusColor(clientStatus) }]} />
                                <View style={{ flex: 1 }}>
                                    <Text style={[styles.cardTitle, { color: colors.text }]}>
                                        {clientStatus === 'connected' ? connectedRelayName || 'Connected' : 'Relay Connection'}
                                    </Text>
                                    <Text style={[styles.cardSub, { color: colors.textSecondary }]}>
                                        {getStatusText(clientStatus)}
                                    </Text>
                                </View>
                                {clientStatus === 'connected' && (
                                    <TouchableOpacity onPress={disconnectFromRelay} style={[styles.disconnectBtn, { borderColor: '#ef4444' }]}>
                                        <Text style={{ color: '#ef4444', fontSize: 13, fontWeight: '600' }}>Disconnect</Text>
                                    </TouchableOpacity>
                                )}
                            </View>
                        </SafeLiquidGlass>

                        {/* Enter Invite Code */}
                        {clientStatus !== 'connected' && (
                            <>
                                <Text style={[styles.sectionTitle, { color: colors.textSecondary }]}>CONNECT WITH CODE</Text>
                                <SafeLiquidGlass style={styles.card} blurIntensity={15} tint="default">
                                    <Text style={[styles.cardSub, { color: colors.textSecondary, marginBottom: 12 }]}>
                                        Enter an invite code shared by a relay provider
                                    </Text>
                                    <View style={styles.codeInputRow}>
                                        <TextInput
                                            style={[styles.codeInput, {
                                                color: colors.text,
                                                borderColor: withAlpha(colors.text, 0.15),
                                                backgroundColor: withAlpha(colors.text, 0.03),
                                            }]}
                                            placeholder="VIBE-XXXX-XXXX"
                                            placeholderTextColor={withAlpha(colors.text, 0.3)}
                                            value={connectCode}
                                            onChangeText={setConnectCode}
                                            autoCapitalize="characters"
                                            autoCorrect={false}
                                        />
                                        <TouchableOpacity
                                            onPress={connectToRelay}
                                            disabled={!connectCode.trim() || isConnecting}
                                            style={[styles.connectBtn, {
                                                backgroundColor: connectCode.trim() ? colors.primary : withAlpha(colors.text, 0.1),
                                            }]}
                                        >
                                            {isConnecting ? (
                                                <ActivityIndicator size="small" color="#fff" />
                                            ) : (
                                                <Zap size={18} color="#fff" />
                                            )}
                                        </TouchableOpacity>
                                    </View>
                                </SafeLiquidGlass>

                                {/* Saved Relays */}
                                {RelayClient.getInstance().getSavedRelays().length > 0 && (
                                    <>
                                        <Text style={[styles.sectionTitle, { color: colors.textSecondary }]}>SAVED RELAYS</Text>
                                        <SafeLiquidGlass style={styles.card} blurIntensity={15} tint="default">
                                            {RelayClient.getInstance().getSavedRelays().map((relay, i) => (
                                                <TouchableOpacity
                                                    key={relay.relayId}
                                                    style={[styles.relayRow, i > 0 && { borderTopWidth: 1, borderTopColor: withAlpha(colors.text, 0.06) }]}
                                                    onPress={() => {
                                                        RelayClient.getInstance().connectToRelay(relay, getPhoenixSocket());
                                                    }}
                                                >
                                                    <Server size={18} color={colors.primary} />
                                                    <View style={{ flex: 1, marginLeft: 12 }}>
                                                        <Text style={[styles.relayName, { color: colors.text }]}>{relay.name}</Text>
                                                        <Text style={[styles.relaySub, { color: colors.textSecondary }]}>
                                                            {relay.inviteCode || relay.relayId}
                                                        </Text>
                                                    </View>
                                                    <ChevronRight size={16} color={colors.textSecondary} />
                                                </TouchableOpacity>
                                            ))}
                                        </SafeLiquidGlass>
                                    </>
                                )}
                            </>
                        )}

                        {/* Info */}
                        <View style={[styles.infoBox, { backgroundColor: withAlpha(colors.text, 0.03) }]}>
                            <Shield size={16} color={colors.primary} style={{ marginRight: 8, marginTop: 2 }} />
                            <Text style={[styles.infoText, { color: colors.textSecondary }]}>
                                Your messages stay end-to-end encrypted. The relay node cannot read your data — it only forwards encrypted traffic.
                            </Text>
                        </View>
                    </Animated.View>
                )}

                {/* ═══ BE A RELAY TAB ═══ */}
                {activeTab === 'relay' && (
                    <Animated.View entering={FadeIn.duration(200)}>
                        {/* Relay Status */}
                        <SafeLiquidGlass style={styles.card} blurIntensity={15} tint="default">
                            <View style={styles.statusRow}>
                                <View style={[styles.bigIcon, { backgroundColor: withAlpha(relayEnabled ? '#22c55e' : colors.text, 0.1) }]}>
                                    <Radio size={24} color={relayEnabled ? '#22c55e' : colors.textSecondary} />
                                </View>
                                <View style={{ flex: 1 }}>
                                    <Text style={[styles.cardTitle, { color: colors.text }]}>Relay Mode</Text>
                                    <Text style={[styles.cardSub, { color: colors.textSecondary }]}>
                                        {relayEnabled ? `${peerCount} connected peers` : 'Help others bypass filters'}
                                    </Text>
                                </View>
                                <Switch
                                    value={relayEnabled}
                                    onValueChange={toggleRelay}
                                    trackColor={{ false: '#767577', true: '#22c55e' }}
                                    thumbColor={Platform.OS === 'ios' ? '#fff' : (relayEnabled ? '#22c55e' : '#f4f3f4')}
                                />
                            </View>
                        </SafeLiquidGlass>

                        {relayEnabled && (
                            <Animated.View entering={SlideInDown.duration(300)}>
                                {/* Stats */}
                                <View style={styles.statsRow}>
                                    <SafeLiquidGlass style={[styles.statCard, { flex: 1 }]} blurIntensity={15} tint="default">
                                        <Users size={20} color={colors.primary} />
                                        <Text style={[styles.statValue, { color: colors.text }]}>{peerCount}</Text>
                                        <Text style={[styles.statLabel, { color: colors.textSecondary }]}>Peers</Text>
                                    </SafeLiquidGlass>
                                    <SafeLiquidGlass style={[styles.statCard, { flex: 1 }]} blurIntensity={15} tint="default">
                                        <Zap size={20} color={colors.primary} />
                                        <Text style={[styles.statValue, { color: colors.text }]}>{formatBytes(bytesRelayed)}</Text>
                                        <Text style={[styles.statLabel, { color: colors.textSecondary }]}>Relayed</Text>
                                    </SafeLiquidGlass>
                                </View>

                                {/* Invite Code */}
                                {inviteCode && (
                                    <>
                                        <Text style={[styles.sectionTitle, { color: colors.textSecondary }]}>INVITE CODE</Text>
                                        <SafeLiquidGlass style={styles.card} blurIntensity={15} tint="default">
                                            <Text style={[styles.inviteCode, { color: colors.text }]}>{inviteCode}</Text>
                                            <Text style={[styles.cardSub, { color: colors.textSecondary, marginTop: 4, marginBottom: 12 }]}>
                                                Share this code with users who need to connect through your relay
                                            </Text>
                                            <View style={styles.codeActions}>
                                                <TouchableOpacity
                                                    onPress={copyInviteCode}
                                                    style={[styles.codeActionBtn, { backgroundColor: withAlpha(colors.primary, 0.1) }]}
                                                >
                                                    {codeCopied ? <Check size={16} color={colors.primary} /> : <Copy size={16} color={colors.primary} />}
                                                    <Text style={[styles.codeActionText, { color: colors.primary }]}>
                                                        {codeCopied ? 'Copied' : 'Copy'}
                                                    </Text>
                                                </TouchableOpacity>
                                                <TouchableOpacity
                                                    onPress={shareInviteCode}
                                                    style={[styles.codeActionBtn, { backgroundColor: withAlpha(colors.primary, 0.1) }]}
                                                >
                                                    <Share2 size={16} color={colors.primary} />
                                                    <Text style={[styles.codeActionText, { color: colors.primary }]}>Share</Text>
                                                </TouchableOpacity>
                                            </View>
                                        </SafeLiquidGlass>
                                    </>
                                )}
                            </Animated.View>
                        )}

                        {/* Settings */}
                        <Text style={[styles.sectionTitle, { color: colors.textSecondary }]}>RELAY SETTINGS</Text>
                        <SafeLiquidGlass style={styles.card} blurIntensity={15} tint="default">
                            {/* Name */}
                            <View style={styles.settingRow}>
                                <Text style={[styles.settingLabel, { color: colors.text }]}>Relay Name</Text>
                                <TextInput
                                    style={[styles.settingInput, { color: colors.text, borderColor: withAlpha(colors.text, 0.1) }]}
                                    placeholder="My Relay"
                                    placeholderTextColor={withAlpha(colors.text, 0.3)}
                                    value={relayName}
                                    onChangeText={(text) => {
                                        setRelayName(text);
                                        RelayNode.getInstance().updateConfig({ name: text });
                                    }}
                                />
                            </View>

                            <View style={[styles.divider, { backgroundColor: withAlpha(colors.text, 0.06) }]} />

                            {/* Public Toggle */}
                            <View style={styles.settingRow}>
                                <View style={{ flex: 1 }}>
                                    <Text style={[styles.settingLabel, { color: colors.text }]}>Public Relay</Text>
                                    <Text style={[styles.cardSub, { color: colors.textSecondary }]}>
                                        Listed in the public directory
                                    </Text>
                                </View>
                                <Switch
                                    value={relayPublic}
                                    onValueChange={(val) => {
                                        setRelayPublic(val);
                                        RelayNode.getInstance().updateConfig({ isPublic: val });
                                    }}
                                    trackColor={{ false: '#767577', true: colors.primary }}
                                />
                            </View>

                            <View style={[styles.divider, { backgroundColor: withAlpha(colors.text, 0.06) }]} />

                            {/* Max Peers */}
                            <View style={styles.settingRow}>
                                <Text style={[styles.settingLabel, { color: colors.text }]}>Max Peers</Text>
                                <View style={styles.stepperRow}>
                                    <TouchableOpacity
                                        onPress={() => {
                                            const val = Math.max(1, maxPeers - 1);
                                            setMaxPeers(val);
                                            RelayNode.getInstance().updateConfig({ maxPeers: val });
                                        }}
                                        style={[styles.stepperBtn, { backgroundColor: withAlpha(colors.text, 0.08) }]}
                                    >
                                        <Text style={[styles.stepperText, { color: colors.text }]}>-</Text>
                                    </TouchableOpacity>
                                    <Text style={[styles.stepperValue, { color: colors.text }]}>{maxPeers}</Text>
                                    <TouchableOpacity
                                        onPress={() => {
                                            const val = Math.min(20, maxPeers + 1);
                                            setMaxPeers(val);
                                            RelayNode.getInstance().updateConfig({ maxPeers: val });
                                        }}
                                        style={[styles.stepperBtn, { backgroundColor: withAlpha(colors.text, 0.08) }]}
                                    >
                                        <Text style={[styles.stepperText, { color: colors.text }]}>+</Text>
                                    </TouchableOpacity>
                                </View>
                            </View>

                            <View style={[styles.divider, { backgroundColor: withAlpha(colors.text, 0.06) }]} />

                            {/* WiFi Only */}
                            <View style={styles.settingRow}>
                                <View style={{ flex: 1 }}>
                                    <Text style={[styles.settingLabel, { color: colors.text }]}>WiFi Only</Text>
                                    <Text style={[styles.cardSub, { color: colors.textSecondary }]}>
                                        Don't relay on cellular data
                                    </Text>
                                </View>
                                <Switch
                                    value={wifiOnly}
                                    onValueChange={(val) => {
                                        setWifiOnly(val);
                                        RelayNode.getInstance().updateConfig({ wifiOnly: val });
                                    }}
                                    trackColor={{ false: '#767577', true: colors.primary }}
                                />
                            </View>
                        </SafeLiquidGlass>

                        {/* Security Info */}
                        <View style={[styles.infoBox, { backgroundColor: withAlpha(colors.text, 0.03) }]}>
                            <Shield size={16} color={colors.primary} style={{ marginRight: 8, marginTop: 2 }} />
                            <Text style={[styles.infoText, { color: colors.textSecondary }]}>
                                As a relay, you cannot read any user data. All traffic is end-to-end encrypted. Your ISP sees WebSocket traffic — it cannot see what's inside.
                            </Text>
                        </View>
                    </Animated.View>
                )}

                {/* ═══ DIRECTORY TAB ═══ */}
                {activeTab === 'directory' && (
                    <Animated.View entering={FadeIn.duration(200)}>
                        {/* Refresh */}
                        <View style={styles.dirHeader}>
                            <Text style={[styles.dirTitle, { color: colors.text }]}>Public Relays</Text>
                            <TouchableOpacity onPress={refreshDirectory} disabled={isRefreshing}>
                                <RefreshCw size={20} color={colors.primary} style={isRefreshing ? { opacity: 0.5 } : undefined} />
                            </TouchableOpacity>
                        </View>

                        {isRefreshing && (
                            <View style={styles.loadingRow}>
                                <ActivityIndicator size="small" color={colors.primary} />
                                <Text style={[styles.loadingText, { color: colors.textSecondary }]}>Searching for relays...</Text>
                            </View>
                        )}

                        {publicRelays.length === 0 && !isRefreshing && (
                            <SafeLiquidGlass style={styles.card} blurIntensity={15} tint="default">
                                <View style={{ alignItems: 'center', paddingVertical: 24 }}>
                                    <Globe size={40} color={colors.textSecondary} style={{ opacity: 0.4, marginBottom: 12 }} />
                                    <Text style={[styles.cardTitle, { color: colors.textSecondary, textAlign: 'center' }]}>
                                        No public relays available
                                    </Text>
                                    <Text style={[styles.cardSub, { color: colors.textSecondary, textAlign: 'center', marginTop: 4 }]}>
                                        Ask someone to share their invite code, or become a relay yourself!
                                    </Text>
                                </View>
                            </SafeLiquidGlass>
                        )}

                        {publicRelays.map((relay, i) => {
                            const available = relay.maxPeers - relay.currentPeers;
                            const isFull = available <= 0;
                            const pingColor = relay.latency ? (relay.latency < 100 ? '#22c55e' : relay.latency < 300 ? '#f59e0b' : '#ef4444') : colors.textSecondary;

                            return (
                                <Animated.View key={relay.relayId} entering={SlideInRight.delay(i * 50)}>
                                    <SafeLiquidGlass style={[styles.card, { marginBottom: 8 }]} blurIntensity={15} tint="default">
                                        <TouchableOpacity
                                            style={styles.dirRelayRow}
                                            disabled={isFull}
                                            onPress={() => connectToPublicRelay(relay)}
                                        >
                                            <View style={[styles.relayIcon, {
                                                backgroundColor: withAlpha(isFull ? '#ef4444' : '#22c55e', 0.1)
                                            }]}>
                                                <Server size={20} color={isFull ? '#ef4444' : '#22c55e'} />
                                            </View>
                                            <View style={{ flex: 1 }}>
                                                <Text style={[styles.relayName, { color: colors.text }]}>{relay.name}</Text>
                                                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 4 }}>
                                                    <Text style={[styles.relaySub, { color: colors.textSecondary }]}>
                                                        {relay.region}
                                                    </Text>
                                                    <Text style={{ color: colors.textSecondary, fontSize: 11 }}>|</Text>
                                                    <View style={{ flexDirection: 'row', alignItems: 'center' }}>
                                                        <Users size={11} color={colors.textSecondary} />
                                                        <Text style={[styles.relaySub, { color: colors.textSecondary, marginLeft: 4 }]}>
                                                            {relay.currentPeers}/{relay.maxPeers}
                                                        </Text>
                                                    </View>
                                                    {relay.latency && (
                                                        <>
                                                            <Text style={{ color: colors.textSecondary, fontSize: 11 }}>|</Text>
                                                            <View style={{ flexDirection: 'row', alignItems: 'center' }}>
                                                                <Signal size={11} color={pingColor} />
                                                                <Text style={[styles.relaySub, { color: pingColor, marginLeft: 4 }]}>
                                                                    {relay.latency}ms
                                                                </Text>
                                                            </View>
                                                        </>
                                                    )}
                                                </View>
                                            </View>
                                            {!isFull ? (
                                                <Zap size={18} color={colors.primary} />
                                            ) : (
                                                <Text style={{ color: '#ef4444', fontSize: 11, fontWeight: '600' }}>FULL</Text>
                                            )}
                                        </TouchableOpacity>
                                    </SafeLiquidGlass>
                                </Animated.View>
                            );
                        })}

                        {/* How it works */}
                        <View style={[styles.infoBox, { backgroundColor: withAlpha(colors.text, 0.03), marginTop: 16 }]}>
                            <Globe size={16} color={colors.primary} style={{ marginRight: 8, marginTop: 2 }} />
                            <Text style={[styles.infoText, { color: colors.textSecondary }]}>
                                Public relays are run by volunteers. Your traffic is encrypted — relays cannot read your messages. Connect to the relay with the lowest latency and available slots.
                            </Text>
                        </View>
                    </Animated.View>
                )}

                <View style={{ height: insets.bottom + 40 }} />
            </ScrollView>
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1 },
    header: {
        flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
        paddingHorizontal: 16, paddingVertical: 12,
    },
    headerBtn: { width: 40, height: 40, alignItems: 'center', justifyContent: 'center' },
    headerTitle: { fontSize: 18, fontWeight: '700' },

    tabBar: {
        flexDirection: 'row', borderBottomWidth: 1, paddingHorizontal: 16,
    },
    tab: { flex: 1, paddingVertical: 12, alignItems: 'center' },
    tabText: { fontSize: 14, fontWeight: '600' },

    content: { padding: 16, gap: 16 },

    card: { padding: 16, borderRadius: 16, overflow: 'hidden' },
    cardTitle: { fontSize: 16, fontWeight: '600' },
    cardSub: { fontSize: 13 },

    sectionTitle: {
        fontSize: 12, fontWeight: '700', letterSpacing: 1,
        marginLeft: 4, marginTop: 8, marginBottom: -8,
    },

    statusRow: { flexDirection: 'row', alignItems: 'center', gap: 12 },
    statusDot: { width: 10, height: 10, borderRadius: 5 },
    bigIcon: { width: 48, height: 48, borderRadius: 24, alignItems: 'center', justifyContent: 'center' },

    disconnectBtn: { borderWidth: 1, borderRadius: 8, paddingHorizontal: 12, paddingVertical: 6 },

    codeInputRow: { flexDirection: 'row', gap: 8 },
    codeInput: {
        flex: 1, height: 48, borderWidth: 1, borderRadius: 12, paddingHorizontal: 14,
        fontSize: 16, fontWeight: '600', letterSpacing: 2, fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace',
    },
    connectBtn: {
        width: 48, height: 48, borderRadius: 12, alignItems: 'center', justifyContent: 'center',
    },

    relayRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 12 },
    relayName: { fontSize: 15, fontWeight: '600' },
    relaySub: { fontSize: 12 },

    inviteCode: {
        fontSize: 24, fontWeight: '800', letterSpacing: 3, textAlign: 'center',
        fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace',
    },
    codeActions: { flexDirection: 'row', gap: 8, justifyContent: 'center' },
    codeActionBtn: { flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 16, paddingVertical: 8, borderRadius: 8 },
    codeActionText: { fontSize: 14, fontWeight: '600' },

    statsRow: { flexDirection: 'row', gap: 8 },
    statCard: { padding: 16, borderRadius: 16, overflow: 'hidden', alignItems: 'center', gap: 4 },
    statValue: { fontSize: 22, fontWeight: '800' },
    statLabel: { fontSize: 11, fontWeight: '600' },

    settingRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 12 },
    settingLabel: { fontSize: 15, fontWeight: '500', flex: 1 },
    settingInput: {
        borderWidth: 1, borderRadius: 8, paddingHorizontal: 10, paddingVertical: 6,
        fontSize: 14, width: 140, textAlign: 'right',
    },
    divider: { height: 1, marginLeft: 0 },

    stepperRow: { flexDirection: 'row', alignItems: 'center', gap: 12 },
    stepperBtn: { width: 32, height: 32, borderRadius: 8, alignItems: 'center', justifyContent: 'center' },
    stepperText: { fontSize: 18, fontWeight: '700' },
    stepperValue: { fontSize: 18, fontWeight: '700', minWidth: 24, textAlign: 'center' },

    infoBox: { flexDirection: 'row', padding: 12, borderRadius: 12, alignItems: 'flex-start' },
    infoText: { fontSize: 12, flex: 1, lineHeight: 18 },

    dirHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: -8 },
    dirTitle: { fontSize: 18, fontWeight: '700' },
    dirRelayRow: { flexDirection: 'row', alignItems: 'center', gap: 12 },
    relayIcon: { width: 44, height: 44, borderRadius: 12, alignItems: 'center', justifyContent: 'center' },

    loadingRow: { flexDirection: 'row', alignItems: 'center', gap: 8, paddingVertical: 12 },
    loadingText: { fontSize: 13 },
});
