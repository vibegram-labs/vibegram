import React, { useState, useEffect, useRef, useCallback, forwardRef, useImperativeHandle } from 'react';
import { View, Text, StyleSheet, Dimensions, Pressable, TouchableOpacity, ActivityIndicator, Switch, Platform, Modal, ScrollView, Alert, Share, TextInput } from 'react-native';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    runOnJS,
    Easing,
    SharedValue,
    FadeIn,
    FadeOut,
} from 'react-native-reanimated';
import { RelayModal as AddRelayModal } from './AddServerModals';
import HostSettingsModal from './RelayModal';
import { Gesture, GestureDetector, GestureHandlerRootView } from 'react-native-gesture-handler';
import { useThemeStore } from '../../lib/stores/theme-store';
import SafeLiquidGlass from '../native/SafeLiquidGlass';
import * as Clipboard from 'expo-clipboard';
import { Buffer } from 'buffer';
import ProxyManager, { ServerEndpoint } from '../../lib/ProxyManager';
import RelayClient from '../../lib/relay/RelayClient';
import RelayDirectory, { DirectoryRelay } from '../../lib/relay/RelayDirectory';
import { getPhoenixSocket } from '../../lib/ChatStore';
import {
    ChevronRight, Server, Zap, Globe, ArrowLeft, Link, ArrowUp, ArrowDown,
    ChevronDown, ChevronUp, X, Check, Shield, Activity, RefreshCw, Users, Settings, Copy, Wifi, Share2, Plus
} from 'lucide-react-native';
import * as Haptics from 'expo-haptics';
import MaskedView from '@react-native-masked-view/masked-view';
import { BlurView } from 'expo-blur';
import { LinearGradient } from 'expo-linear-gradient';

import AnimatedGlassButton from '../native/AnimatedGlassButton';
import ParticleVisualizer from '../native/SkiaAnimatedSphere'; // Actually ParticleVisualizer now


import RelayNode, { RelayStatus } from '../../lib/relay/RelayNode';
import { deriveSessionKeys, encodeFrame, decodeFrame, MessageType } from '../../lib/relay/VibeNetProtocol';
import { encodeBridgeLink, encodeBridgeHttpsLink } from '../../lib/relay/RelayBridgeLink';

const MaskedViewAny = MaskedView as any;
const AnimatedView = Animated.View as any;
const GestureHandlerRootViewAny = GestureHandlerRootView as any;
const { height: SCREEN_HEIGHT, width: SCREEN_WIDTH } = Dimensions.get('window');

const MODAL_HEIGHT = SCREEN_HEIGHT * 0.93;
const CLOSED_Y = SCREEN_HEIGHT;
const SMOOTH_TIMING = { duration: 400, easing: Easing.bezier(0.25, 0.1, 0.25, 1) };

const withAlpha = (color: string, alpha: number): string => {
    if (!color) return `rgba(255,255,255,${alpha})`;
    if (color.startsWith('#')) {
        const hex = color.replace('#', '');
        const r = parseInt(hex.substring(0, 2), 16);
        const g = parseInt(hex.substring(2, 4), 16);
        const b = parseInt(hex.substring(4, 6), 16);
        return `rgba(${r},${g},${b},${alpha})`;
    }
    return color;
};

// ─── Region Mapping ──────────────────────────────────────────────────

const REGION_MAP: Record<string, { flag: string; country: string; sortOrder: number }> = {
    'us-east': { flag: '🇺🇸', country: 'United States', sortOrder: 1 },
    'us-west': { flag: '🇺🇸', country: 'United States', sortOrder: 1 },
    'us': { flag: '🇺🇸', country: 'United States', sortOrder: 1 },
    'eu-west': { flag: '🇪🇺', country: 'Europe', sortOrder: 2 },
    'eu-central': { flag: '🇩🇪', country: 'Germany', sortOrder: 3 },
    'eu': { flag: '🇪🇺', country: 'Europe', sortOrder: 2 },
    'de': { flag: '🇩🇪', country: 'Germany', sortOrder: 3 },
    'uk': { flag: '🇬🇧', country: 'United Kingdom', sortOrder: 4 },
    'gb': { flag: '🇬🇧', country: 'United Kingdom', sortOrder: 4 },
    'nl': { flag: '🇳🇱', country: 'Netherlands', sortOrder: 5 },
    'fr': { flag: '🇫🇷', country: 'France', sortOrder: 6 },
    'jp': { flag: '🇯🇵', country: 'Japan', sortOrder: 7 },
    'sg': { flag: '🇸🇬', country: 'Singapore', sortOrder: 8 },
    'au': { flag: '🇦🇺', country: 'Australia', sortOrder: 9 },
    'br': { flag: '🇧🇷', country: 'Brazil', sortOrder: 10 },
    'ca': { flag: '🇨🇦', country: 'Canada', sortOrder: 11 },
    'in': { flag: '🇮🇳', country: 'India', sortOrder: 12 },
    'kr': { flag: '🇰🇷', country: 'South Korea', sortOrder: 13 },
    'hk': { flag: '🇭🇰', country: 'Hong Kong', sortOrder: 14 },
    'tr': { flag: '🇹🇷', country: 'Turkey', sortOrder: 15 },
    'unknown': { flag: '', country: 'Auto', sortOrder: 99 },
};

function getRegionInfo(region: string): { flag: string; country: string } {
    if (!region) return { flag: '🌐', country: 'Unknown' };
    const exact = REGION_MAP[region.toLowerCase()];
    if (exact) return exact;
    const prefix = Object.keys(REGION_MAP).find(k => region.toLowerCase().startsWith(k));
    if (prefix) return REGION_MAP[prefix];
    return { flag: '🌐', country: region };
}

function getLatencyColor(latency: number | null): string {
    if (latency === null) return '#6b7280';
    if (latency < 100) return '#22c55e';
    if (latency < 300) return '#f59e0b';
    return '#ef4444';
}

// ─── Types ───────────────────────────────────────────────────────────

type VPNConnectionState = 'disconnected' | 'searching' | 'peer_found' | 'handshaking' | 'connecting' | 'connected' | 'disconnecting' | 'peer_not_found' | 'error';

interface LocationInfo {
    type: 'relay' | 'server';
    id: string;
    name: string;
    region: string;
    flag: string;
    country: string;
    latency: number | null;
    relay?: DirectoryRelay;
    endpoint?: ServerEndpoint;
}

interface LocationGroup {
    country: string;
    flag: string;
    locations: LocationInfo[];
    bestLatency: number | null;
    serverCount: number;
}

function buildLocations(relays: DirectoryRelay[], endpoints: ServerEndpoint[]): LocationInfo[] {
    const locations: LocationInfo[] = [];
    for (const r of relays) {
        const info = getRegionInfo(r.region);
        locations.push({
            type: 'relay',
            id: r.relayId,
            name: r.name || 'Relay',
            region: r.region,
            flag: info.flag,
            country: info.country,
            latency: r.latency,
            relay: r,
        });
    }
    for (const ep of endpoints) {
        // Filter out the built-in default server and empty custom server entries
        if (
            ep.name === 'Main Server (Railway)' ||
            ep.name === 'Main Server (Vibegram API)' ||
            ep.name === 'Custom Server'
        ) continue;
        if (ep.url.includes('railway.app')) continue;

        const info = getRegionInfo('unknown');
        locations.push({
            type: 'server',
            id: ep.url,
            name: ep.name || ep.url.replace('https://', '').replace('http://', ''),
            region: 'unknown',
            flag: info.flag,
            country: info.country,
            latency: ep.lastLatency ?? null,
            endpoint: ep,
        });
    }
    return locations;
}

function groupByCountry(locations: LocationInfo[]): LocationGroup[] {
    const groups = new Map<string, LocationInfo[]>();
    for (const loc of locations) {
        const key = loc.country;
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key)!.push(loc);
    }
    return Array.from(groups.entries()).map(([country, locs]) => ({
        country,
        flag: locs[0].flag,
        locations: locs.sort((a, b) => (a.latency ?? 999) - (b.latency ?? 999)),
        bestLatency: locs.some(l => l.latency !== null) ? Math.min(...locs.filter(l => l.latency !== null).map(l => l.latency!)) : null,
        serverCount: locs.length,
    })).sort((a, b) => (a.bestLatency ?? 999) - (b.bestLatency ?? 999));
}

function formatDuration(ms: number): string {
    const secs = Math.floor(ms / 1000);
    const m = Math.floor(secs / 60);
    const s = secs % 60;
    if (m > 0) return `${m}:${s.toString().padStart(2, '0')}`;
    return `0:${s.toString().padStart(2, '0')}`;
}

// ─── Shared UI Components ─────────────────────────────────────────────

const SettingRow = ({
    label,
    value,
    onPress,
    right,
    showArrow = true,
    isLast = false,
    labelStyle = {},
}: {
    label: string,
    value?: string,
    onPress?: () => void,
    right?: React.ReactNode,
    showArrow?: boolean,
    isLast?: boolean,
    labelStyle?: any,
}) => {
    const { colors } = useThemeStore();
    return (
        <View style={{ width: '100%' }}>
            <TouchableOpacity
                style={[s.settingRow, { minHeight: 58, paddingVertical: 16, paddingHorizontal: 20 }]}
                onPress={onPress}
                disabled={!onPress}
                activeOpacity={0.7}
            >
                <View style={{ flex: 1, justifyContent: 'center' }}>
                    <Text style={[s.settingLabel, { color: colors.text }, labelStyle]}>{label}</Text>
                </View>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, marginLeft: 8 }}>
                    {value && <Text style={[s.settingValue, { color: colors.textSecondary }]}>{value}</Text>}
                    {right}
                    {onPress && showArrow && <ChevronRight size={16} color={colors.textSecondary} style={{ opacity: 0.5 }} />}
                </View>
            </TouchableOpacity>
            {!isLast && <View style={[s.divider, { backgroundColor: withAlpha(colors.text, 0.05), marginLeft: 16 }]} />}
        </View>
    );
};

const SettingGroup = ({ children }: { children: React.ReactNode }) => {
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';
    return (
        <View style={[s.sectionContainer, {
            backgroundColor: isLight ? '#ffffff' : colors.card,
            marginBottom: 20,
            borderRadius: 28,
        }]}>
            {children}
        </View>
    );
};

// ─── Stat Pill ──────────────────────────────────────────────────────

const StatPill = ({ icon: Icon, label, value, color }: { icon: any; label: string; value: string; color: string }) => {
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';
    return (
        <View style={[s.statPill, { backgroundColor: isLight ? '#ffffff' : withAlpha(colors.text, 0.06) }]}>
            <Icon size={14} color={color} />
            <View style={{ gap: 1 }}>
                <Text style={[s.statLabel, { color: colors.textSecondary }]}>{label}</Text>
                <Text style={[s.statValue, { color: colors.text }]}>{value}</Text>
            </View>
        </View>
    );
};

const MetricBox = ({ label, value, icon: Icon, color }: { label: string; value: string; icon: any; color: string }) => {
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';
    return (
        <View style={{
            flex: 1,
            backgroundColor: isLight ? '#ffffff' : colors.card,
            borderRadius: 28,
            padding: 16,
            minHeight: 88,
            justifyContent: 'center',
            gap: 6
        }}>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                <View style={{ width: 24, height: 24, borderRadius: 8, backgroundColor: withAlpha(color, 0.1), alignItems: 'center', justifyContent: 'center' }}>
                    <Icon size={14} color={color} />
                </View>
                <Text style={{ fontSize: 13, color: colors.textSecondary, fontWeight: '500' }}>{label}</Text>
            </View>
            <Text style={{ fontSize: 17, color: colors.text, fontWeight: '600', marginLeft: 2 }}>{value}</Text>
        </View>
    );
};

// ─── Servers Content (Child View) ───────────────────────────────────

const ServersContent = ({
    onClose,
    locations,
    selectedLocation,
    onSelect,
    onSelectFastest,
    isRefreshing,
    onRefresh,
    onAddServer,
    activeHeader,
}: {
    onClose: () => void;
    locations: LocationInfo[];
    selectedLocation: LocationInfo | null;
    onSelect: (loc: LocationInfo) => void;
    onSelectFastest: () => void;
    isRefreshing: boolean;
    onRefresh: () => void;
    onAddServer: (mode: 'relay' | 'custom') => void;
    activeHeader: SharedValue<number>;
}) => {
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';
    const bg = isLight ? '#f5f5f5' : colors.background;

    const [expandedCountries, setExpandedCountries] = useState<Set<string>>(new Set());
    const groups = groupByCountry(locations);

    const toggleCountry = (country: string) => {
        setExpandedCountries(prev => {
            const next = new Set(prev);
            if (next.has(country)) next.delete(country);
            else next.add(country);
            return next;
        });
    };

    return (
        <View style={{ flex: 1 }}>
            {/* Header Blur */}
            <View style={s.headerBlur}>
                <MaskedViewAny
                    style={StyleSheet.absoluteFill}
                    maskElement={
                        <LinearGradient
                            colors={['rgba(0,0,0,1)', 'rgba(0,0,0,0.8)', 'rgba(0,0,0,0)']}
                            locations={[0, 0.5, 1]}
                            style={StyleSheet.absoluteFill}
                        />
                    }
                >
                    <View style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(bg, 0.95) }]} />
                    <BlurView style={StyleSheet.absoluteFill} intensity={12} tint={isLight ? 'light' : 'dark'} />
                </MaskedViewAny>
            </View>

            {/* Title & Actions - Matched with RelayModal style */}
            <View style={[s.header, { position: 'absolute', top: 20, left: 0, right: 0, zIndex: 120, justifyContent: 'space-between', alignItems: 'center', paddingHorizontal: 15 }]}>
                <AnimatedGlassButton
                    onPress={onClose}
                    progress={activeHeader}
                    showPanelIcon={false}
                    effectiveTheme={effectiveTheme}
                    size={40}
                    homeIcon={<X size={20} color={colors.text} strokeWidth={2.5} />}
                    panelIcon={<View />}
                    homeBackgroundColor={isLight ? '#FFFFFF' : withAlpha(colors.text, 0.1)}
                />

                <Text style={[s.headerTitle, { color: colors.text }]}>Servers</Text>

                <View style={{ flexDirection: 'row', gap: 8 }}>
                    <AnimatedGlassButton
                        onPress={() => onAddServer('custom')}
                        progress={activeHeader}
                        showPanelIcon={false}
                        effectiveTheme={effectiveTheme}
                        size={40}
                        homeIcon={<Plus size={20} color={colors.text} strokeWidth={2.5} />}
                        panelIcon={<View />}
                        homeBackgroundColor={isLight ? '#FFFFFF' : withAlpha(colors.text, 0.1)}
                    />
                    <AnimatedGlassButton
                        onPress={onRefresh}
                        progress={activeHeader}
                        showPanelIcon={false}
                        effectiveTheme={effectiveTheme}
                        size={40}
                        homeIcon={isRefreshing ? <ActivityIndicator size="small" color={colors.text} /> : <RefreshCw size={20} color={colors.text} strokeWidth={1.5} />}
                        panelIcon={<View />}
                        homeBackgroundColor={isLight ? '#FFFFFF' : withAlpha(colors.text, 0.1)}
                    />
                </View>
            </View>

            <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={[s.container, { paddingTop: 100, paddingBottom: 150 }]}>
                <SettingGroup>
                    <SettingRow
                        label="Auto-Select Server"
                        right={
                            <Switch
                                value={!selectedLocation}
                                onValueChange={(val) => {
                                    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
                                    if (val) {
                                        onSelectFastest();
                                    }
                                    // When val is false, we just stay with the current selectedLocation (which keeps user selection)
                                }}
                                trackColor={{ false: '#3a3a3c', true: '#34c759' }}
                                thumbColor="#fff"
                            />
                        }
                        showArrow={false}
                        isLast
                    />
                </SettingGroup>

                {/* Relays Section */}
                {locations.filter(l => l.type === 'relay').length > 0 && (
                    <View>
                        <View style={s.groupHeader}>
                            <Text style={[s.groupTitle, { color: colors.textSecondary }]}>Private Relays</Text>
                        </View>
                        <SettingGroup>
                            {locations.filter(l => l.type === 'relay').map((loc, idx, arr) => {
                                const isSelected = selectedLocation?.id === loc.id;
                                // User requested just ID on left side
                                return (
                                    <SettingRow
                                        key={loc.id}
                                        label={loc.id} // Invite code as main label
                                        value=""      // No value on right (ping is separate prop)
                                        labelStyle={{ color: isSelected ? '#007AFF' : colors.text, fontFamily: Platform.OS === 'ios' ? 'Courier' : 'monospace', fontSize: 13, letterSpacing: 0.5 }}
                                        onPress={() => {
                                            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
                                            onSelect(loc);
                                        }}
                                        showArrow={false}
                                        isLast={idx === arr.length - 1}
                                        right={loc.latency !== null ? <Text style={{ fontSize: 13, fontWeight: '600', color: getLatencyColor(loc.latency) }}>{loc.latency}ms</Text> : undefined}
                                    />
                                );
                            })}
                        </SettingGroup>
                    </View>
                )}

                {/* Custom Servers Section */}
                {locations.filter(l => l.type === 'server').length > 0 && (
                    <View>
                        <View style={s.groupHeader}>
                            <Text style={[s.groupTitle, { color: colors.textSecondary }]}>Custom Servers</Text>
                        </View>
                        <SettingGroup>
                            {locations.filter(l => l.type === 'server').map((loc, idx, arr) => {
                                const isSelected = selectedLocation?.id === loc.id;
                                // Display logic: Host as label, Protocol as value
                                const protocol = loc.endpoint?.protocol?.toUpperCase() || 'HTTPS';
                                let host = loc.endpoint?.config?.host;

                                console.log('[ConnectionModal] Rendering server:', loc.id, 'Config:', loc.endpoint?.config);

                                if (!host) {
                                    // Try to extract from URL if config empty (robust parse)
                                    try {
                                        if (loc.id.startsWith('vmess://')) {
                                            // Decode vmess for existing servers saved without config
                                            const b64 = loc.id.substring(8).trim();
                                            const decoded = Buffer.from(b64, 'base64').toString('utf-8');
                                            const json = JSON.parse(decoded);
                                            if (json.add) host = json.add;
                                        } else {
                                            // SS/Trojan etc
                                            const match = loc.id.match(/@([^/:]+)/);
                                            if (match) host = match[1];
                                        }
                                    } catch (e) {
                                        console.log('[ConnectionModal] Failed to parse host from URL:', e);
                                    }
                                }

                                const displayLabel = host || loc.name;

                                return (
                                    <SettingRow
                                        key={loc.id}
                                        label={displayLabel}
                                        labelStyle={{ color: isSelected ? '#007AFF' : colors.text }}
                                        value={protocol}
                                        onPress={() => {
                                            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
                                            onSelect(loc);
                                        }}
                                        showArrow={false}
                                        isLast={idx === arr.length - 1}
                                        right={loc.latency !== null ? <Text style={{ fontSize: 13, fontWeight: '600', color: getLatencyColor(loc.latency) }}>{loc.latency}ms</Text> : undefined}
                                    />
                                );
                            })}
                        </SettingGroup>
                    </View>
                )}

                {locations.length === 0 && (
                    <View style={s.emptyState}>
                        <Globe size={40} color={withAlpha(colors.text, 0.2)} />
                        <Text style={[s.emptyTitle, { color: colors.text }]}>No Servers Available</Text>
                        <Text style={[s.emptySub, { color: colors.textSecondary }]}>
                            Searching for relays in the network...
                        </Text>
                    </View>
                )}
            </ScrollView>
        </View>
    );
};

// ─── VPN Main Content (with Connect / Host tabs) ─────────────────────

const mapVpnStateToVisualizerState = (vpnState: VPNConnectionState, isHost: boolean, relayStatus: RelayStatus): 'idle' | 'searching' | 'connecting' | 'connected' | 'hosting' | 'hosting_active' | 'disconnecting' | 'error' => {
    if (isHost) {
        if (relayStatus === 'running') return 'hosting_active';
        if (relayStatus === 'starting') return 'connecting';
        return 'hosting';
    }
    switch (vpnState) {
        case 'searching':
        case 'peer_found':
            return 'searching';
        case 'connecting':
        case 'handshaking':
            return 'connecting';
        case 'connected': return 'connected';
        case 'disconnecting': return 'disconnecting';
        case 'error':
        case 'peer_not_found':
            return 'error';
        default: return 'idle';
    }
};

const ConnectionMainVPN = ({
    onOpenServers: onOpenLocations,
    vpnState,
    selectedLocation,
    currentLatency,
    sessionStart,
    onConnect,
    onDisconnect,
    showHostSettings,
    setShowHostSettings,
    settingsButtonProgress,
    parentScale,
    onOpenAddServer,
    endpoints,
    refreshLocations: refreshServers,
}: {
    onOpenServers: () => void;
    vpnState: VPNConnectionState;
    selectedLocation: LocationInfo | null;
    currentLatency: number | null;
    sessionStart: number | null;
    onConnect: () => void;
    onDisconnect: () => void;
    showHostSettings: boolean;
    setShowHostSettings: (v: boolean) => void;
    settingsButtonProgress: SharedValue<number>;
    parentScale: SharedValue<number>;
    onOpenAddServer: (mode: 'relay' | 'custom') => void;
    endpoints: ServerEndpoint[];
    refreshLocations: () => void;
}) => {
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';

    const formatBytes = (bytes: number) => {
        if (bytes === 0) return '0 B';
        const k = 1024;
        const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
        const i = Math.floor(Math.log(bytes) / Math.log(k));
        return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
    };

    // Tab state: Connect (VPN client) vs Host (relay node)
    const [mainTab, setMainTab] = useState<'connect' | 'host'>('connect');
    const tabIndicatorX = useSharedValue(0);

    const handleTabSwitch = (tab: 'connect' | 'host') => {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);

        // If tapping the already selected tab, toggle the state
        if (mainTab === tab) {
            if (tab === 'connect') {
                if (isActive) onDisconnect();
                else onConnect();
            } else {
                handleToggleRelay(!relayEnabled);
            }
            return;
        }

        setMainTab(tab);
        tabIndicatorX.value = withTiming(tab === 'connect' ? 0 : 1, { duration: 300, easing: Easing.bezier(0.25, 0.1, 0.25, 1) });
        settingsButtonProgress.value = withTiming(tab === 'host' ? 1 : 0, { duration: 300, easing: Easing.bezier(0.25, 0.1, 0.25, 1) });
    };

    const indicatorStyle = useAnimatedStyle(() => ({
        left: `${tabIndicatorX.value * 50}%` as any,
    }));

    const isActive = vpnState === 'connected';
    const isLoading = vpnState === 'connecting' || vpnState === 'disconnecting' || vpnState === 'searching' || vpnState === 'peer_found' || vpnState === 'handshaking';

    // Host State
    const [relayEnabled, setRelayEnabled] = useState(false);
    const [relayStatus, setRelayStatus] = useState<RelayStatus>('stopped');
    const [peerCount, setPeerCount] = useState(0);
    const [bytesRelayed, setBytesRelayed] = useState(0);
    const [relayConfig, setRelayConfig] = useState<any>(null);
    const [idCopied, setIdCopied] = useState(false);

    // Client data transfer stats
    const [clientBytesSent, setClientBytesSent] = useState(0);
    const [clientBytesReceived, setClientBytesReceived] = useState(0);

    useEffect(() => {
        const client = RelayClient.getInstance();
        setClientBytesSent(client.getBytesSent());
        setClientBytesReceived(client.getBytesReceived());
        const unsubClient = client.subscribe((ev: string, d: any) => {
            if (ev === 'data-transferred') {
                setClientBytesSent(d.bytesSent);
                setClientBytesReceived(d.bytesReceived);
            }
        });
        return () => unsubClient();
    }, []);

    useEffect(() => {
        const node = RelayNode.getInstance();
        const config = node.getConfig();
        setRelayEnabled(config.enabled);
        setRelayConfig(config);
        setRelayStatus(node.getStatus());
        setPeerCount(node.getPeerCount());
        setBytesRelayed(node.getTotalBytesRelayed());

        const unsub = node.subscribe((ev, d) => {
            if (ev === 'status-changed') setRelayStatus(d);
            if (ev === 'config-changed') { setRelayEnabled(d.enabled); setRelayConfig(d); }
            if (ev === 'peer-connected' || ev === 'peer-disconnected') setPeerCount(d.peerCount);
            if (ev === 'data-relayed') setBytesRelayed(d);
        });
        return () => unsub();
    }, []);

    const handleCopyRelayId = () => {
        if (relayConfig?.inviteCode) {
            Clipboard.setStringAsync(relayConfig.inviteCode);
            Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
            setIdCopied(true);
            setTimeout(() => setIdCopied(false), 2000);
        }
    };

    const handleShareRelay = async () => {
        if (!relayConfig?.inviteCode) return;

        const inviteCode = relayConfig.inviteCode;
        const bridgeLink = relayConfig.bridgeShareLink; // This is vibe://
        const httpsLink = encodeBridgeHttpsLink({
            id: relayConfig.relayId || '',
            host: relayConfig.bridgeExternalIp || undefined,
            port: 443,
            transport: 'https',
            origin: 'community',
        });

        let message = `Join my private relay on Vibe!\n\nInvite Code: ${inviteCode}`;
        if (bridgeLink) {
            message += `\n\nIf you're in a blocked region, tap this link to connect:\n${httpsLink}\n\n(If the link isn't clickable, copy it and paste it into the Invite Code field in Vibe)`;
        }

        try {
            await Share.share({
                message,
                title: 'Share Vibe Relay',
            });
        } catch (error) {
            console.log('[ConnectionModal] Share error:', error);
        }
    };

    const handleToggleRelay = async (val: boolean) => {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
        const node = RelayNode.getInstance();
        if (val) {
            const res = await node.startRelay(getPhoenixSocket());
            if (res.success) {
                setRelayEnabled(true);
                setRelayConfig(node.getConfig());
            }
            else Alert.alert('Error', res.error || 'Failed to start');
        } else {
            await node.stopRelay();
            setRelayEnabled(false);
            setRelayConfig(node.getConfig());
        }
    };

    // Shared Animations
    const isHost = mainTab === 'host';
    const activeColor = isHost ? '#8b5cf6' : '#22c55e'; // Purple for host, Green for connect

    // Status Logic
    const getConnectStatusText = (): string => {
        switch (vpnState) {
            case 'searching': return 'Searching...';
            case 'peer_found': return 'Found';
            case 'handshaking': return 'Handshaking...';
            case 'connecting': return 'Connecting...';
            case 'connected': return 'Connected';
            case 'disconnecting': return 'Disconnecting...';
            case 'peer_not_found': return 'No Server Found';
            case 'error': return 'Failed';
            default: return 'Tap to Connect';
        }
    };

    const statusText = isHost
        ? (relayStatus === 'running' ? 'Active' : relayStatus === 'starting' ? 'Starting...' : 'Off')
        : getConnectStatusText();

    const getConnectSubtext = (): string => {
        switch (vpnState) {
            case 'searching': return 'Looking for available servers...';
            case 'handshaking': return 'Exchanging keys...';
            case 'connecting': return 'Establishing connection...';
            case 'connected': return selectedLocation?.name || 'Connected';
            case 'peer_not_found': return 'Use an invite code or try again later';
            case 'error': return 'Could not connect. Try again later';
            default: return '';
        }
    };

    const statusSubtext = isHost
        ? (relayStatus === 'running' ? `${peerCount} peers connected` : '')
        : getConnectSubtext();

    // Dynamic Colors - light theme uses richer/darker tones for visibility on white bg
    const primaryColor = isHost
        ? (relayEnabled
            ? (isLight ? '#9b1dcc' : '#c026d3')   // Host active
            : (isLight ? '#7c3aed' : '#a855f7'))   // Host idle
        : (isActive
            ? (isLight ? '#047857' : '#22c55e')    // Client connected
            : (isLight ? '#b45309' : '#f59e0b'));   // Client idle

    const secondaryColor = isHost
        ? (isLight ? '#6d28d9' : '#9333ea')        // Host
        : (isActive
            ? (isLight ? '#0c4a6e' : '#0ea5e9')   // Client connected
            : (isLight ? '#991b1b' : '#ef4444'));   // Client idle

    // Calculate Visualizer State
    const visualizerState = mapVpnStateToVisualizerState(vpnState, isHost, relayStatus);

    // Button Handlers
    const handleSphereTap = () => {
        if (isLoading) return;
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Heavy);

        if (isHost) {
            handleToggleRelay(!relayEnabled);
        } else if (isActive) {
            onDisconnect();
        } else {
            // Connect (works from disconnected, peer_not_found, error — all non-active/non-loading states)
            onConnect();
        }
    };

    return (
        <View style={{ flex: 1 }}>
            <ScrollView
                style={{ flex: 1 }}
                contentContainerStyle={{ paddingTop: 100, paddingBottom: 100 }}
                showsVerticalScrollIndicator={false}
            >
                {/* Segmented Toggle — Glass & Smaller */}
                <View style={{ paddingHorizontal: 40, alignItems: 'center', zIndex: 10, marginBottom: 16 }}>
                    <SafeLiquidGlass style={{ borderRadius: 20, overflow: 'hidden', width: '100%', maxWidth: 280 }} blurIntensity={20}>
                        <View style={[s.segmentedControl, { backgroundColor: isLight ? 'rgba(255,255,255,0.4)' : 'rgba(0,0,0,0.2)' }]}>
                            <AnimatedView style={[indicatorStyle, { position: 'absolute', width: '50%', height: '100%', padding: 4 }]}>
                                <View style={{
                                    flex: 1,
                                    backgroundColor: isLight ? withAlpha(colors.primary, 0.15) : withAlpha(colors.primary, 0.25),
                                    borderRadius: 17,
                                }} />
                            </AnimatedView>
                            <TouchableOpacity
                                style={s.segmentTab}
                                onPress={() => handleTabSwitch('connect')}
                                activeOpacity={0.7}
                            >
                                <Text style={[s.segmentLabel, {
                                    color: mainTab === 'connect' ? colors.primary : colors.textSecondary,
                                    fontWeight: mainTab === 'connect' ? '600' : '500',
                                }]}>Connect</Text>
                            </TouchableOpacity>
                            <TouchableOpacity
                                style={s.segmentTab}
                                onPress={() => handleTabSwitch('host')}
                                activeOpacity={0.7}
                            >
                                <Text style={[s.segmentLabel, {
                                    color: mainTab === 'host' ? colors.primary : colors.textSecondary,
                                    fontWeight: mainTab === 'host' ? '600' : '500',
                                }]}>Host</Text>
                            </TouchableOpacity>
                        </View>
                    </SafeLiquidGlass>
                </View>
                {/* Visualizer Sphere */}
                <View style={s.statusContainer}>
                    <TouchableOpacity
                        onPress={handleSphereTap}
                        activeOpacity={0.8}
                        disabled={isLoading}
                    >
                        <ParticleVisualizer
                            state={visualizerState}
                            theme={effectiveTheme}
                            primaryColor={primaryColor}
                            secondaryColor={secondaryColor}
                            style={{ width: 140, height: 140 }}
                        />
                    </TouchableOpacity>

                    <Animated.Text
                        key={statusText}
                        entering={FadeIn.duration(200)}
                        exiting={FadeOut.duration(200)}
                        style={[s.statusText, {
                            color: ((!isHost && isActive) || (isHost && relayStatus === 'running'))
                                ? primaryColor
                                : (vpnState === 'peer_not_found' || vpnState === 'error' ? '#ef4444' : colors.text)
                        }]}
                    >
                        {statusText}
                    </Animated.Text>

                    {statusSubtext ? <Text style={[s.statusSubtext, { color: colors.textSecondary, fontSize: 12 }]}>{statusSubtext}</Text> : null}
                </View>

                {/* Primary Switch / Relay Settings */}
                <View style={{ paddingHorizontal: 16, marginTop: 24 }}>
                    <SettingGroup>
                        {isHost ? (
                            <View
                                style={[s.settingRow, {
                                    minHeight: 30,
                                    paddingVertical: 10,
                                    paddingHorizontal: 20,
                                }]}
                            >
                                <View style={{ flex: 1 }}>
                                    <Text style={[s.settingLabel, { color: colors.text, fontWeight: '600' }]}>
                                        Relay Hosting
                                    </Text>
                                </View>
                                <View style={{ marginLeft: 8 }}>
                                    <Switch
                                        value={relayEnabled}
                                        onValueChange={handleToggleRelay}
                                        trackColor={{ true: '#ec4899', false: '#3a3a3c' }}
                                        ios_backgroundColor="#3a3a3c"
                                        disabled={isLoading}
                                    />
                                </View>
                            </View>
                        ) : (
                            <>
                                <SettingRow
                                    label="Server"
                                    value={selectedLocation?.name || 'Auto'}
                                    onPress={onOpenLocations}
                                    right={currentLatency !== null && isActive ? (
                                        <Text style={{ fontSize: 13, fontWeight: '600', color: getLatencyColor(currentLatency) }}>{currentLatency}ms</Text>
                                    ) : undefined}
                                />
                                <SettingRow
                                    label="Private Relay"
                                    onPress={() => onOpenAddServer('relay')}
                                    isLast
                                />
                            </>
                        )}
                    </SettingGroup>
                </View>

                {/* Tab Specific Content */}
                <View style={{ flex: 1, paddingHorizontal: 16, marginTop: 24 }}>
                    {isHost ? (
                        <View>
                            {/* Invite Code - Standard Row */}
                            <SettingGroup>
                                <SettingRow
                                    label="Invite Code"
                                    value={relayConfig?.inviteCode || 'OFFLINE'}
                                    onPress={handleCopyRelayId}
                                    isLast={!relayConfig?.bridgeShareLink}
                                />
                                {relayConfig?.bridgeShareLink && (
                                    <SettingRow
                                        label="Share Bridge Link"
                                        onPress={handleShareRelay}
                                        right={<Share2 size={16} color={primaryColor} />}
                                        isLast
                                    />
                                )}
                            </SettingGroup>

                            <View style={[s.groupHeader, { marginTop: 24 }]}>
                                <Text style={[s.groupTitle, { color: colors.textSecondary }]}>Node Metrics</Text>
                            </View>

                            {/* Metrics Grid */}
                            <View style={{ flexDirection: 'row', gap: 12, marginBottom: 12 }}>
                                <MetricBox
                                    label="Peers"
                                    value={peerCount.toString()}
                                    icon={Users}
                                    color="#8b5cf6"
                                />
                                <MetricBox
                                    label="Status"
                                    value={relayStatus === 'running' ? 'Live' : 'Off'}
                                    icon={Activity}
                                    color={relayStatus === 'running' ? '#10b981' : '#f59e0b'}
                                />
                            </View>
                            <View style={{ flexDirection: 'row', gap: 12 }}>
                                <MetricBox
                                    label="Data Relayed"
                                    value={formatBytes(bytesRelayed)}
                                    icon={Wifi}
                                    color="#ec4899"
                                />
                            </View>

                        </View>
                    ) : (
                        <View>
                            {isActive && (
                                <View style={{ marginTop: 0 }}>
                                    {/* Connected Server Info */}
                                    {selectedLocation && (
                                        <View style={{ marginBottom: 16 }}>
                                            <SettingGroup>
                                                <View style={[s.settingRow, { minHeight: 58, paddingVertical: 16, paddingHorizontal: 20 }]}>
                                                    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10, flex: 1 }}>
                                                        <Text style={{ fontSize: 20 }}>{selectedLocation.flag}</Text>
                                                        <View>
                                                            <Text style={[s.settingLabel, { color: colors.text }]}>{selectedLocation.name}</Text>
                                                            <Text style={{ fontSize: 12, color: colors.textSecondary, marginTop: 2 }}>{selectedLocation.country}</Text>
                                                        </View>
                                                    </View>
                                                    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
                                                        <View style={{ width: 8, height: 8, borderRadius: 4, backgroundColor: '#22c55e' }} />
                                                        <Text style={{ fontSize: 14, fontWeight: '600', color: getLatencyColor(currentLatency) }}>
                                                            {currentLatency !== null ? `${currentLatency}ms` : '--'}
                                                        </Text>
                                                    </View>
                                                </View>
                                            </SettingGroup>
                                        </View>
                                    )}

                                    <View style={s.groupHeader}>
                                        <Text style={[s.groupTitle, { color: colors.textSecondary }]}>Connection Data</Text>
                                    </View>
                                    <View style={{ flexDirection: 'row', gap: 12, marginBottom: 12 }}>
                                        <MetricBox
                                            label="Ping"
                                            value={currentLatency !== null ? `${currentLatency}ms` : '--'}
                                            icon={Zap}
                                            color="#6366f1"
                                        />
                                        <MetricBox
                                            label="Upload"
                                            value={formatBytes(clientBytesSent)}
                                            icon={ArrowUp}
                                            color="#f59e0b"
                                        />
                                    </View>
                                    <View style={{ flexDirection: 'row', gap: 12 }}>
                                        <MetricBox
                                            label="Download"
                                            value={formatBytes(clientBytesReceived)}
                                            icon={ArrowDown}
                                            color="#3b82f6"
                                        />
                                    </View>
                                </View>
                            )}
                        </View>
                    )}
                </View>
            </ScrollView>
        </View>
    );
};

// ─── Modal Shell ─────────────────────────────────────────────────

export interface ConnectionModalRef {
    present: () => void;
    dismiss: () => void;
}

interface ConnectionModalProps {
    onClose?: () => void;
    parentScale: SharedValue<number>;
    visible?: boolean;
}

const ConnectionModal = forwardRef<ConnectionModalRef, ConnectionModalProps>(({ onClose, parentScale, visible }, ref) => {
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';
    const bg = isLight ? '#f5f5f5' : colors.background;

    const isOpen = useSharedValue(0);
    const [isMounted, setIsMounted] = useState(false);

    // Sync visible prop
    useEffect(() => {
        if (visible !== undefined) {
            if (visible) {
                setIsMounted(true);
            } else if (isMounted) {
                handleCloseFull();
            }
        }
    }, [visible]);

    // View navigation
    const [activeView, setActiveView] = useState<'main' | 'servers'>('main');

    // VPN state
    const [vpnState, setVpnState] = useState<VPNConnectionState>('disconnected');
    const [selectedLocation, setSelectedLocation] = useState<LocationInfo | null>(null);
    const [availableLocations, setAvailableLocations] = useState<LocationInfo[]>([]);
    const [currentLatency, setCurrentLatency] = useState<number | null>(null);
    const [sessionStart, setSessionStart] = useState<number | null>(null);

    const [relayModalMode, setRelayModalMode] = useState<'relay' | 'custom'>('relay');

    // Legacy state (for advanced view)
    const [endpoints, setEndpoints] = useState(ProxyManager.getInstance().getEndpoints());
    const [proxyEnabled, setProxyEnabled] = useState(true);
    const [isRefreshing, setIsRefreshing] = useState(false);

    // Animation values
    const translateY = useSharedValue(CLOSED_Y);
    const backdrop = useSharedValue(0);
    const mainScale = useSharedValue(1);
    const childTranslateY = useSharedValue(SCREEN_HEIGHT);
    const childBackdrop = useSharedValue(0);
    const activeHeader = useSharedValue(0);
    const settingsButtonProgress = useSharedValue(0);

    // Host Settings
    // Host Settings
    const [showHostSettings, setShowHostSettings] = useState(false);

    // Sub-modals hoisted state
    const [showRelayCode, setShowRelayCode] = useState(false);

    // ─── Auto-discovery ──────────────────────────────────────────

    // Helper to map RelayInfo to DirectoryRelay
    const mapRelayInfoToDirectoryRelay = (r: any): DirectoryRelay => ({
        relayId: r.relayId,
        name: r.name,
        region: r.region || 'unknown',
        isPublic: r.isPublic,
        currentPeers: r.peerCount || 0,
        maxPeers: r.maxPeers || 5,
        latency: r.latency || null,
        lastSeen: Date.now(),
        uptime: 0,
        inviteCode: r.inviteCode,
        inviteKey: r.inviteKey,
        externalIp: r.externalIp,
        bridgeUrl: r.bridgeUrl,
        shareLink: r.shareLink,
        bridgeDescriptor: r.bridgeDescriptor,
        tags: [],
    });

    const refreshLocations = useCallback(async () => {
        setIsRefreshing(true);
        try {
            const directory = RelayDirectory.getInstance();
            const client = RelayClient.getInstance();
            const socket = getPhoenixSocket();

            // Refresh directory in background for Auto mode
            if (socket) directory.refresh(socket).catch(() => { });

            // For the UI List: Only show Saved Relays + Current Relay
            const savedRelays = client.getSavedRelays();
            const currentRelay = client.getCurrentRelay();

            // Merge current if not in saved
            let relaysDisplay = [...savedRelays];
            if (currentRelay && !savedRelays.find(r => r.relayId === currentRelay.relayId)) {
                relaysDisplay.push(currentRelay as any);
            }

            const eps = ProxyManager.getInstance().getEndpoints();
            setEndpoints(eps);
            const locs = buildLocations(relaysDisplay.map(mapRelayInfoToDirectoryRelay), eps);
            setAvailableLocations(locs);

            // Test latencies for displayed items
            directory.testAllLatencies().then(() => {
                // effective update happens via listener
            });
        } catch { }
        setIsRefreshing(false);
    }, []);

    useEffect(() => {
        if (!isMounted) return;
        refreshLocations();

        // Subscribe to relay directory updates
        const directory = RelayDirectory.getInstance();
        const unsub = directory.subscribe((event: string) => {
            if (event === 'relays-updated') {
                const client = RelayClient.getInstance();
                const savedRelays = client.getSavedRelays();
                const currentRelay = client.getCurrentRelay();

                let relaysDisplay = [...savedRelays];
                if (currentRelay && !savedRelays.find(r => r.relayId === currentRelay.relayId)) {
                    relaysDisplay.push(currentRelay as any);
                }

                const eps = ProxyManager.getInstance().getEndpoints();
                const locs = buildLocations(relaysDisplay.map(mapRelayInfoToDirectoryRelay), eps);
                setAvailableLocations(locs);
            }
        });

        // Subscribe to relay client status changes
        const client = RelayClient.getInstance();
        const unsubClient = client.subscribe((event: string, data: any) => {
            if (event === 'latency-updated') {
                setCurrentLatency(data);
                return;
            }
            if (event === 'reconnect-failed') {
                // Relay went offline — try to auto-switch to another node
                console.log('[Connect] Reconnect failed — attempting auto-switch...');
                setCurrentLatency(null);
                ProxyManager.getInstance().setDirectMode();
                // Auto-switch: find another relay
                (async () => {
                    try {
                        const directory = RelayDirectory.getInstance();
                        const sock = getPhoenixSocket();
                        if (sock) await directory.refresh(sock);
                        const relays = directory.getAvailableRelays();
                        const currentId = client.getCurrentRelay()?.relayId;
                        const others = relays.filter(r => r.relayId !== currentId);
                        if (others.length > 0) {
                            const best = others[0];
                            console.log('[Connect] Auto-switching to:', best.relayId, best.name);
                            setVpnState('searching');
                            const info = getRegionInfo(best.region);
                            setSelectedLocation({
                                type: 'relay', id: best.relayId, name: best.name,
                                region: best.region, flag: info.flag, country: info.country,
                                latency: best.latency, relay: best,
                            });
                            setVpnState('handshaking');
                            const result = await client.connectToRelay({
                                relayId: best.relayId, name: best.name,
                                isPublic: best.isPublic, region: best.region,
                                inviteCode: best.inviteCode, inviteKey: best.inviteKey,
                                externalIp: best.externalIp,
                                bridgeUrl: best.bridgeUrl,
                                shareLink: best.shareLink,
                                bridgeDescriptor: best.bridgeDescriptor,
                            }, getPhoenixSocket());
                            if (result.success) {
                                if (result.mode !== 'bridge') {
                                    ProxyManager.getInstance().setRelayMode();
                                }
                                setCurrentLatency(best.latency ?? null);
                                setVpnState('connected');
                                setSessionStart(Date.now());
                            } else {
                                setVpnState('peer_not_found');
                                setSessionStart(null);
                            }
                        } else {
                            setVpnState('peer_not_found');
                            setSessionStart(null);
                        }
                    } catch {
                        setVpnState('peer_not_found');
                        setSessionStart(null);
                    }
                })();
                return;
            }
            if (event === 'status-changed') {
                if (data === 'connected') {
                    setVpnState('connected');
                    setSessionStart(Date.now());
                    // Sync relay info for country/latency display
                    const relay = client.getCurrentRelay();
                    if (relay) {
                        const info = getRegionInfo(relay.region || 'unknown');
                        setSelectedLocation({
                            type: 'relay',
                            id: relay.relayId,
                            name: relay.name,
                            region: relay.region || 'unknown',
                            flag: info.flag,
                            country: info.country,
                            latency: relay.latency ?? null,
                        });
                        setCurrentLatency(relay.latency ?? null);
                    }
                } else if (data === 'disconnected') {
                    setVpnState('disconnected');
                    setSessionStart(null);
                    setCurrentLatency(null);
                    ProxyManager.getInstance().setDirectMode();
                } else if (data === 'handshaking') {
                    setVpnState('handshaking');
                } else if (data === 'connecting' || data === 'reconnecting') {
                    setVpnState('connecting');
                } else if (data === 'error') {
                    setVpnState('error');
                    setSessionStart(null);
                    setCurrentLatency(null);
                    ProxyManager.getInstance().setDirectMode();
                }
            }
        });

        // Sync initial state
        if (client.isConnected()) {
            setVpnState('connected');
            const relay = client.getCurrentRelay();
            if (relay) {
                const info = getRegionInfo(relay.region || 'unknown');
                setSelectedLocation({
                    type: 'relay',
                    id: relay.relayId,
                    name: relay.name,
                    region: relay.region || 'unknown',
                    flag: info.flag,
                    country: info.country,
                    latency: relay.latency ?? null,
                });
                // Use live latency if available, otherwise fall back to relay.latency
                setCurrentLatency(client.getLatency() ?? relay.latency ?? null);
            }
        }

        return () => { unsub(); unsubClient(); };
    }, [isMounted]);

    // ─── Connect / Disconnect ────────────────────────────────────

    const handleConnect = async () => {
        // Don't connect if already connected or in progress
        const client = RelayClient.getInstance();
        if (client.isConnected() || vpnState === 'connected' || vpnState === 'connecting' || vpnState === 'handshaking' || vpnState === 'searching') {
            console.log('[Connect] Skipping — already connected or in progress:', vpnState);
            return;
        }
        setVpnState('searching');
        try {
            if (selectedLocation?.type === 'relay' && selectedLocation.relay) {
                console.log('[Connect] Using selected relay:', selectedLocation.relay.relayId, 'inviteCode:', selectedLocation.relay.inviteCode, 'inviteKey:', !!selectedLocation.relay.inviteKey);
                setVpnState('handshaking');
                const client = RelayClient.getInstance();
                const result = await client.connectToRelay({
                    relayId: selectedLocation.relay.relayId,
                    name: selectedLocation.relay.name,
                    isPublic: selectedLocation.relay.isPublic,
                    region: selectedLocation.relay.region,
                    inviteCode: selectedLocation.relay.inviteCode,
                    inviteKey: selectedLocation.relay.inviteKey,
                    externalIp: selectedLocation.relay.externalIp,
                    bridgeUrl: selectedLocation.relay.bridgeUrl,
                    shareLink: selectedLocation.relay.shareLink,
                    bridgeDescriptor: selectedLocation.relay.bridgeDescriptor,
                }, getPhoenixSocket());
                console.log('[Connect] connectToRelay result:', result);
                if (result.success) {
                    if (result.mode !== 'bridge') {
                        ProxyManager.getInstance().setRelayMode();
                    }
                    setCurrentLatency(selectedLocation.latency);
                    setVpnState('connected');
                    setSessionStart(Date.now());
                } else {
                    console.log('[Connect] Failed:', result.error);
                    setVpnState('peer_not_found');
                }
            } else if (selectedLocation?.type === 'server' && selectedLocation.endpoint) {
                setVpnState('connecting');
                await ProxyManager.getInstance().setPrimaryEndpoint(selectedLocation.endpoint.url);
                setCurrentLatency(selectedLocation.latency);
                setVpnState('connected');
                setSessionStart(Date.now());
            } else {
                // Auto mode: pick fastest relay
                console.log('[Connect] Auto mode — refreshing directory...');
                const directory = RelayDirectory.getInstance();
                const socket = getPhoenixSocket();
                if (socket) await directory.refresh(socket);
                const relays = directory.getAvailableRelays();
                console.log('[Connect] Directory returned', relays.length, 'relays:', relays.map(r => ({ id: r.relayId, name: r.name, code: r.inviteCode, hasKey: !!r.inviteKey })));
                if (relays.length > 0) {
                    const best = relays[0];
                    const info = getRegionInfo(best.region);
                    const loc: LocationInfo = {
                        type: 'relay', id: best.relayId, name: best.name,
                        region: best.region, flag: info.flag, country: info.country,
                        latency: best.latency, relay: best,
                    };
                    setSelectedLocation(loc);
                    setVpnState('handshaking');
                    console.log('[Connect] Connecting to best relay:', best.relayId, 'inviteCode:', best.inviteCode, 'inviteKey:', !!best.inviteKey);
                    const client = RelayClient.getInstance();
                    const result = await client.connectToRelay({
                        relayId: best.relayId, name: best.name,
                        isPublic: best.isPublic, region: best.region,
                        inviteCode: best.inviteCode, inviteKey: best.inviteKey,
                        externalIp: best.externalIp,
                        bridgeUrl: best.bridgeUrl,
                        shareLink: best.shareLink,
                        bridgeDescriptor: best.bridgeDescriptor,
                    }, getPhoenixSocket(), false);
                    console.log('[Connect] connectToRelay result:', result);
                    if (result.success) {
                        if (result.mode !== 'bridge') {
                            ProxyManager.getInstance().setRelayMode();
                        }
                        setCurrentLatency(best.latency);
                        setVpnState('connected');
                        setSessionStart(Date.now());
                    } else {
                        console.log('[Connect] Failed:', result.error);
                        setVpnState('peer_not_found');
                    }
                } else {
                    console.log('[Connect] No relays found in directory');
                    setVpnState('peer_not_found');
                }
            }
        } catch (e) {
            console.error('[Connect] Error:', e);
            setVpnState('error');
        }
    };

    const handleDisconnect = async () => {
        setVpnState('disconnecting');
        try {
            const client = RelayClient.getInstance();
            if (client.isConnected()) {
                await client.disconnect();
            }
            ProxyManager.getInstance().setDirectMode();
        } catch { }
        setVpnState('disconnected');
        setSessionStart(null);
        setCurrentLatency(null);
    };

    // ─── Modal Animations ─────────────────────────────────────────

    useImperativeHandle(ref, () => ({
        present: () => {
            isOpen.value = 1;
            translateY.value = CLOSED_Y;
            backdrop.value = 0;
            setIsMounted(true);
        },
        dismiss: () => {
            handleCloseFull();
        }
    }));

    useEffect(() => {
        if (isMounted) {
            translateY.value = withTiming(0, { duration: 350, easing: Easing.out(Easing.exp) });
            backdrop.value = withTiming(1, { duration: 250 });
            parentScale.value = withTiming(0.94, SMOOTH_TIMING);
        }
    }, [isMounted]);

    const handleCloseFull = () => {
        if (activeView !== 'main') {
            closeChild();
            return;
        }
        isOpen.value = 0;
        backdrop.value = withTiming(0, { duration: 200 });
        translateY.value = withTiming(CLOSED_Y, { duration: 250 }, () => {
            runOnJS(setIsMounted)(false);
            if (onClose) runOnJS(onClose)();
            runOnJS(setActiveView)('main');
        });
        parentScale.value = withTiming(1, SMOOTH_TIMING);
    };

    const openView = (view: 'servers') => {
        setActiveView(view);
        mainScale.value = withTiming(0.94, SMOOTH_TIMING);
        childTranslateY.value = withTiming(0, { duration: 350, easing: Easing.out(Easing.exp) });
        childBackdrop.value = withTiming(1, { duration: 300 });
    };

    const closeChild = () => {
        mainScale.value = withTiming(1, SMOOTH_TIMING);
        childTranslateY.value = withTiming(SCREEN_HEIGHT, { duration: 250 }, () => runOnJS(setActiveView)('main'));
        childBackdrop.value = withTiming(0, { duration: 200 });
    };

    const panelStyle = useAnimatedStyle(() => ({
        transform: [
            { translateY: translateY.value },
            { scale: mainScale.value }
        ]
    }));
    const childPanelStyle = useAnimatedStyle(() => ({ transform: [{ translateY: childTranslateY.value }] }));
    const overlayStyle = useAnimatedStyle(() => ({ opacity: backdrop.value, backgroundColor: 'rgba(0,0,0,0.6)' }));
    const childOverlayStyle = useAnimatedStyle(() => ({ opacity: childBackdrop.value, backgroundColor: 'rgba(0,0,0,0.3)' }));

    // Settings button scale animation (0 -> 1)
    const settingsButtonStyle = useAnimatedStyle(() => ({
        transform: [{ scale: settingsButtonProgress.value }]
    }));

    const pan = Gesture.Pan()
        .onChange((e) => {
            if (activeView === 'main' && e.changeY > 0) {
                translateY.value += e.changeY;
            }
        })
        .onEnd((e) => {
            if (activeView === 'main') {
                if (translateY.value > 100 || e.velocityY > 500) {
                    runOnJS(handleCloseFull)();
                } else {
                    translateY.value = withTiming(0, SMOOTH_TIMING);
                }
            }
        });

    return (
        <Modal
            transparent
            visible={isMounted}
            animationType="none"
            onRequestClose={handleCloseFull}
            statusBarTranslucent
        >
            <GestureHandlerRootViewAny style={[StyleSheet.absoluteFill, { zIndex: 9999 }]}>
                <AnimatedView style={[StyleSheet.absoluteFill, overlayStyle]}>
                    <Pressable style={StyleSheet.absoluteFill} onPress={handleCloseFull} />
                </AnimatedView>

                <GestureDetector gesture={pan}>
                    <AnimatedView style={[s.panel, panelStyle, { backgroundColor: bg }]}>
                        {/* Header Blur */}
                        <View style={s.headerBlur}>
                            <MaskedViewAny
                                style={StyleSheet.absoluteFill}
                                maskElement={
                                    <LinearGradient
                                        colors={['rgba(0,0,0,1)', 'rgba(0,0,0,0.8)', 'rgba(0,0,0,0)']}
                                        locations={[0, 0.5, 1]}
                                        style={StyleSheet.absoluteFill}
                                    />
                                }
                            >
                                <View style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(bg, 0.95) }]} />
                                <BlurView style={StyleSheet.absoluteFill} intensity={12} tint={isLight ? 'light' : 'dark'} />
                            </MaskedViewAny>
                        </View>

                        {/* Title & Actions */}
                        <View style={[s.header, { position: 'absolute', top: 20, left: 0, right: 0, zIndex: 120, justifyContent: 'space-between', alignItems: 'center', paddingHorizontal: 16 }]}>
                            {/* Close Button on Left */}
                            <AnimatedGlassButton
                                onPress={handleCloseFull}
                                progress={activeHeader}
                                showPanelIcon={false}
                                effectiveTheme={effectiveTheme}
                                size={40}
                                homeIcon={<X size={20} color={colors.text} strokeWidth={2.5} />}
                                panelIcon={<View />}
                                homeBackgroundColor={isLight ? 'rgba(0,0,0,0.05)' : 'rgba(255,255,255,0.1)'}
                            />
                            {/* Title */}
                            <Text style={[s.headerTitle, { color: colors.text }]}>Connection</Text>
                            {/* Settings Button on Right - Shows on Host Tab */}
                            <AnimatedView style={settingsButtonStyle}>
                                <AnimatedGlassButton
                                    onPress={() => setShowHostSettings(true)}
                                    progress={settingsButtonProgress}
                                    showPanelIcon={false}
                                    effectiveTheme={effectiveTheme}
                                    size={40}
                                    homeIcon={<View />}
                                    panelIcon={<Settings size={20} color={colors.text} strokeWidth={2.5} />}
                                    homeBackgroundColor={'transparent'}
                                    panelBackgroundColor={isLight ? 'rgba(0,0,0,0.05)' : 'rgba(255,255,255,0.1)'}
                                />
                            </AnimatedView>
                        </View>

                        <ConnectionMainVPN
                            onOpenServers={() => openView('servers')}
                            vpnState={vpnState}
                            selectedLocation={selectedLocation}
                            currentLatency={currentLatency}
                            sessionStart={sessionStart}
                            onConnect={handleConnect}
                            onDisconnect={handleDisconnect}
                            showHostSettings={showHostSettings}
                            setShowHostSettings={setShowHostSettings}
                            settingsButtonProgress={settingsButtonProgress}
                            parentScale={parentScale}
                            onOpenAddServer={(mode) => {
                                setRelayModalMode(mode);
                                setShowRelayCode(true);
                            }}
                            endpoints={endpoints}
                            refreshLocations={refreshLocations}
                        />
                    </AnimatedView>
                </GestureDetector>

                {/* Nested Panels */}
                {activeView !== 'main' && (
                    <>
                        <AnimatedView style={[StyleSheet.absoluteFill, childOverlayStyle]}>
                            <Pressable style={StyleSheet.absoluteFill} onPress={closeChild} />
                        </AnimatedView>
                        <AnimatedView style={[s.panel, childPanelStyle, { backgroundColor: bg }]}>
                            {activeView === 'servers' ? (
                                <ServersContent
                                    onClose={closeChild}
                                    locations={availableLocations}
                                    selectedLocation={selectedLocation}
                                    onSelect={(loc) => {
                                        setSelectedLocation(loc);
                                    }}
                                    onSelectFastest={() => {
                                        setSelectedLocation(null);
                                    }}
                                    isRefreshing={isRefreshing}
                                    onRefresh={refreshLocations}
                                    activeHeader={activeHeader}
                                    onAddServer={(mode) => {
                                        setRelayModalMode(mode);
                                        setShowRelayCode(true);
                                    }}
                                />
                            ) : null}
                        </AnimatedView>
                    </>
                )}

                {/* Host Settings Modal - Rendered as separate modal */}
                {/* Host Settings Modal - Rendered as separate modal */}
                <HostSettingsModal visible={showHostSettings} onClose={() => setShowHostSettings(false)} parentScale={mainScale} />
                <AddRelayModal
                    visible={showRelayCode}
                    onClose={() => setShowRelayCode(false)}
                    onAdded={refreshLocations}
                    parentScale={mainScale}
                    mode={relayModalMode}
                />
            </GestureHandlerRootViewAny>
        </Modal>
    );
});

const s = StyleSheet.create({
    panel: {
        position: 'absolute',
        bottom: 0, left: 0, right: 0,
        height: MODAL_HEIGHT,
        borderTopLeftRadius: 40,
        borderTopRightRadius: 40,
        overflow: 'hidden',
    },


    headerBlur: { position: 'absolute', top: 0, left: 0, right: 0, height: 60, zIndex: 5 },
    header: { flexDirection: 'row', paddingHorizontal: 0 },
    headerTitle: { fontSize: 17, fontWeight: '600' },
    headerAction: { width: 40, height: 40, borderRadius: 20, alignItems: 'center', justifyContent: 'center' },

    container: { paddingHorizontal: 16, paddingBottom: 60 },

    // Shared settings styles
    sectionContainer: { borderRadius: 28, overflow: 'hidden', marginBottom: 20 },
    settingRowContainer: { overflow: 'hidden', marginBottom: 20, borderRadius: 28 },

    // Segmented Control
    segmentedControl: {
        flexDirection: 'row',
        width: '100%',
        height: 40,
        borderRadius: 20,
        position: 'relative',
        alignItems: 'center',
    },
    segmentTab: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
        height: '100%',
        zIndex: 1,
    },
    segmentLabel: {
        fontSize: 14,
        fontWeight: '500',
        textAlign: 'center',
    },

    // Settings Rows
    settingRow: {
        flexDirection: 'row',
        alignItems: 'center',
    },
    settingIconContainer: {
        width: 26,
        height: 26,
        borderRadius: 6,
        alignItems: 'center',
        justifyContent: 'center',

    },
    settingLabel: {
        fontSize: 15,
        fontWeight: '500',
    },
    settingValue: {
        fontSize: 15,
        opacity: 0.7,
    },
    divider: {
        height: 1,
        marginLeft: 0,
    },
    rowSub: {
        fontSize: 13,
        marginTop: 2,
        opacity: 0.7,
    },

    groupHeader: {
        marginTop: 20,
        marginBottom: 8,
        paddingHorizontal: 16,
    },
    groupTitle: {
        fontSize: 13,
        fontWeight: '500',
        color: '#8e8e93',
        marginBottom: 8,
    },

    // Locations / Servers
    fastestCard: {
        borderRadius: 20, padding: 16, marginBottom: 16,
        borderWidth: 1.5, flexDirection: 'row', alignItems: 'center', gap: 14,
    },
    fastestIcon: {
        width: 40, height: 40, borderRadius: 12,
        alignItems: 'center', justifyContent: 'center',
    },
    fastestTitle: { fontSize: 16, fontWeight: '600' },
    fastestSub: { fontSize: 12, marginTop: 2, opacity: 0.5 },

    countryGroup: { borderRadius: 20, overflow: 'hidden', marginBottom: 12 },
    countryHeader: {
        flexDirection: 'row', alignItems: 'center',
        paddingVertical: 14, paddingHorizontal: 16,
    },
    flagText: { fontSize: 22, marginRight: 12 },
    countryName: { fontSize: 16, fontWeight: '600' },
    countryMeta: { fontSize: 13, opacity: 0.6 },

    locationRow: {
        flexDirection: 'row', alignItems: 'center',
        paddingVertical: 12, paddingHorizontal: 16, paddingLeft: 56,
    },
    locationDot: { width: 8, height: 8, borderRadius: 4, marginRight: 12 },
    locationName: { fontSize: 15, fontWeight: '500' },
    locationType: { fontSize: 11, marginTop: 1, opacity: 0.5 },
    locationLatency: { fontSize: 13, fontWeight: '600' },

    emptyState: { alignItems: 'center', paddingVertical: 60, gap: 12 },
    emptyTitle: { fontSize: 17, fontWeight: '600' },
    emptySub: { fontSize: 14, textAlign: 'center', opacity: 0.6, paddingHorizontal: 32 },

    serverGroup: { borderRadius: 20, overflow: 'hidden', marginVertical: 10 },
    serverRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 14, paddingHorizontal: 16, gap: 16 },
    serverInfo: { flex: 1 },
    serverName: { fontSize: 16, fontWeight: '500' },
    serverProtocol: { fontSize: 12, marginTop: 2, opacity: 0.5 },
    serverLatency: { fontSize: 13, fontWeight: '600' },
    serverDivider: { height: 1, marginLeft: 16 },

    // Status Section (Sphere)
    statusContainer: {
        alignItems: 'center',
        justifyContent: 'center',
        marginBottom: 10,
    },
    statusText: {
        fontSize: 13,
        fontWeight: '600',
        marginTop: 16,
    },
    statusSubtext: {
        fontSize: 14,
        marginTop: 4,
        opacity: 0.7,
    },
    connectArea: {
        alignItems: 'center',
        justifyContent: 'center',
        marginVertical: 30,
        height: 120,
    },
    connectButton: {
        width: 80,
        height: 80,
        borderRadius: 40,
        alignItems: 'center',
        justifyContent: 'center',
        shadowColor: "#000",
        shadowOffset: { width: 0, height: 8 },
        shadowOpacity: 0.2,
        shadowRadius: 10,
        elevation: 8,
    },
    pulseRing: {
        position: 'absolute',
        width: 140,
        height: 140,
        borderRadius: 70,
        borderWidth: 2,
    },
    statsRow: {
        flexDirection: 'row',
        justifyContent: 'center',
        gap: 12,
        marginBottom: 20,
    },
    statPill: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 12,
        paddingVertical: 8,
        borderRadius: 12,
        gap: 6,
    },
    statLabel: {
        fontSize: 10,
        fontWeight: '600',
        textTransform: 'uppercase',
        opacity: 0.6,
    },
    statValue: {
        fontSize: 13,
        fontWeight: '700',
    },
    description: {
        fontSize: 14,
        lineHeight: 20,
        opacity: 0.6,
        paddingHorizontal: 12,
    },

    // Relay Box Styles
    relayParentBox: {
        borderRadius: 20,
        borderWidth: 1,
        marginBottom: 20,
        overflow: 'hidden',
    },
    relayIdMain: {
        flexDirection: 'row',
        alignItems: 'center',
        padding: 16,
    },
    relayBoxLabel: {
        fontSize: 11,
        fontWeight: '700',
        textTransform: 'uppercase',
        letterSpacing: 0.5,
        marginBottom: 4,
    },
    relayBoxValue: {
        fontSize: 18,
        fontWeight: '700',
        letterSpacing: 1.5,
        fontFamily: Platform.OS === 'ios' ? 'Courier' : 'monospace',
    },
    copyBadge: {
        width: 32,
        height: 32,
        borderRadius: 8,
        alignItems: 'center',
        justifyContent: 'center',
    },
    relayDivider: {
        height: 1,
        width: '100%',
    },
    relayMiniStats: {
        flexDirection: 'row',
        padding: 16,
        justifyContent: 'space-between',
    },
    miniStatItem: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 8,
    },
    miniStatValue: {
        fontSize: 14,
        fontWeight: '700',
    },
    miniStatLabel: {
        fontSize: 10,
        fontWeight: '600',
        textTransform: 'uppercase',
        opacity: 0.6,
    },
    inviteInputRow: {
        flexDirection: 'row',
        alignItems: 'center',
        borderRadius: 14,
        borderWidth: 1,
        paddingHorizontal: 14,
        paddingVertical: 4,
        gap: 10,
        marginBottom: 16,
    },
    inviteInput: {
        flex: 1,
        fontSize: 15,
        fontWeight: '600',
        letterSpacing: 1,
        height: 44,
        fontFamily: Platform.OS === 'ios' ? 'Courier' : 'monospace',
    },
    inviteGoBtn: {
        width: 30,
        height: 30,
        borderRadius: 15,
        alignItems: 'center',
        justifyContent: 'center',
    },

});

export default ConnectionModal;
