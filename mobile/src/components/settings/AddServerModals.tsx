import React, { useState, useEffect } from 'react';
import { View, Text, StyleSheet, Modal, TouchableOpacity, TextInput, ActivityIndicator, Keyboard, Pressable, Dimensions } from 'react-native';
import Animated, { useSharedValue, useAnimatedStyle, withTiming, Easing, runOnJS, FadeIn, FadeOut } from 'react-native-reanimated';
import { useThemeStore } from '../../lib/stores/theme-store';
import { CheckIcon, CloseIcon } from '../../components/Icons';
import AnimatedGlassButton from '../native/AnimatedGlassButton';
import ParticleVisualizer from '../native/SkiaAnimatedSphere';
import ProxyManager from '../../lib/ProxyManager';
import RelayClient from '../../lib/relay/RelayClient';
import { getPhoenixSocket } from '../../lib/ChatStore';
import * as Haptics from 'expo-haptics';
import * as Clipboard from 'expo-clipboard';
import { Buffer } from 'buffer';
import SafeLiquidGlass from '../native/SafeLiquidGlass';
import { Globe, Server, Shield, Link, ChevronDown, ChevronRight, ArrowLeft } from 'lucide-react-native';
import { importBridgeFromLink, isBridgeLink } from '../../lib/relay/RelayBridgeLink';

// ─── Helper Components ──────────────────────────────────────────────

const SettingRow = ({ label, subLabel, icon: Icon, onPress, isLast, colors, isLight }: any) => (
    <TouchableOpacity
        onPress={onPress}
        activeOpacity={0.7}
        style={{
            flexDirection: 'row',
            alignItems: 'center',
            padding: 16,
            backgroundColor: isLight ? '#FFFFFF' : '#2c2c2e',
            borderBottomWidth: isLast ? 0 : 1,
            borderBottomColor: isLight ? '#f2f2f7' : '#3a3a3c',
        }}
    >
        {Icon && (
            <View style={{ width: 36, height: 36, borderRadius: 10, backgroundColor: isLight ? '#f2f2f7' : '#3a3a3c', alignItems: 'center', justifyContent: 'center', marginRight: 12 }}>
                <Icon size={20} color={onPress ? '#007AFF' : colors.textSecondary} />
            </View>
        )}
        <View style={{ flex: 1 }}>
            <Text style={{ fontSize: 16, fontWeight: '600', color: colors.text }}>{label}</Text>
            {subLabel && <Text style={{ fontSize: 13, color: colors.textSecondary, marginTop: 2 }}>{subLabel}</Text>}
        </View>
        <ChevronRight size={18} color={colors.textSecondary} opacity={0.5} />
    </TouchableOpacity>
);

const SettingGroup = ({ children, isLight }: any) => (
    <View style={{
        width: '100%',
        borderRadius: 20,
        overflow: 'hidden',
        backgroundColor: isLight ? '#FFFFFF' : '#2c2c2e',
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 2 },
        shadowOpacity: 0.05,
        shadowRadius: 10,
        elevation: 2,
    }}>
        {children}
    </View>
);

const { height: SCREEN_HEIGHT } = Dimensions.get('window');
const MODAL_HEIGHT = SCREEN_HEIGHT * 0.94;
const CLOSED_Y = SCREEN_HEIGHT;
const SMOOTH_TIMING = { duration: 400, easing: Easing.bezier(0.25, 0.1, 0.25, 1) };

// Protocols for manual configuration
const PROTOCOLS = ['V2Ray', 'Shadowsocks', 'Trojan', 'HTTPS'];

export const AddServerModal = ({ visible, onClose, onAdded, parentScale, mode = 'relay' }: any) => {
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';

    // Animation States
    const translateY = useSharedValue(CLOSED_Y);
    const backdrop = useSharedValue(0);
    const [isMounted, setIsMounted] = useState(false);

    // Form States
    // Selection state for custom mode
    const [customSubMode, setCustomSubMode] = useState<'none' | 'import' | 'manual'>('none');

    // Relay State
    const [relayCode, setRelayCode] = useState('');

    // Custom Server State (Import)
    const [importUrl, setImportUrl] = useState('');

    // Custom Server State (Manual)
    const [serverName, setServerName] = useState('');
    const [serverHost, setServerHost] = useState('');
    const [serverPort, setServerPort] = useState('');
    const [serverProtocol, setServerProtocol] = useState('V2Ray');
    const [showProtocolDropdown, setShowProtocolDropdown] = useState(false);

    // Saving State
    const [isSaving, setIsSaving] = useState(false);

    // Colors
    const offColor = isLight ? '#E5E5EA' : '#3A3A3C';
    const activeBlue = '#007AFF';
    const glassBg = isLight ? 'rgba(242,242,247,0.8)' : 'rgba(30,30,32,0.6)';

    useEffect(() => {
        if (visible) {
            setIsMounted(true);
            translateY.value = withTiming(0, { duration: 400, easing: Easing.out(Easing.exp) });
            backdrop.value = withTiming(1, { duration: 300 });
            if (parentScale) parentScale.value = withTiming(0.94, SMOOTH_TIMING);
        } else {
            Keyboard.dismiss();
            backdrop.value = withTiming(0, { duration: 250 });
            translateY.value = withTiming(CLOSED_Y, { duration: 300 }, (finished) => {
                if (finished) runOnJS(setIsMounted)(false);
            });
            if (parentScale) parentScale.value = withTiming(1, SMOOTH_TIMING);
        }
    }, [visible]);

    const handleSave = async () => {
        if (isSaving) return;
        setIsSaving(true);
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);

        try {
            if (mode === 'relay') {
                if (!relayCode.trim()) return;
                const trimmed = relayCode.trim();

                // If this is a bridge link (direct or universal), handle it!
                if (isBridgeLink(trimmed) || trimmed.length > 50) {
                    const res = await importBridgeFromLink(trimmed);
                    if (res.success) {
                        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
                        onAdded();
                        onClose();
                        setRelayCode('');
                        return;
                    }
                }

                // Normal relay connection attempt
                const res = await RelayClient.getInstance().connectWithCode(trimmed, getPhoenixSocket());
                if (res.success) {
                    Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
                    onAdded();
                    onClose();
                    setRelayCode('');
                } else {
                    Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
                }
            } else {
                // Handle Custom Server
                let url = '';
                let name = '';
                let protocol: any = 'https';
                let config: any = {};

                if (customSubMode === 'import') {
                    if (!importUrl.trim()) return;
                    // Basic parsing for vmess:// ss:// etc
                    url = importUrl.trim();
                    if (url.startsWith('vmess://')) protocol = 'v2ray';
                    else if (url.startsWith('ss://')) protocol = 'shadowsocks';
                    else if (url.startsWith('trojan://')) protocol = 'trojan';
                    else if (url.startsWith('vless://')) protocol = 'vless';
                    else protocol = 'https'; // Fallback

                    // Try to extract name
                    try {
                        let extractedName = '';
                        if (protocol === 'v2ray') {
                            const b64 = url.substring(8).trim();
                            const decoded = Buffer.from(b64, 'base64').toString('utf-8');
                            const json = JSON.parse(decoded);
                            if (json.ps) extractedName = json.ps;
                            if (json.add) config = { ...config, host: json.add };
                            if (json.port) config = { ...config, port: json.port };
                        } else {
                            const hashIndex = url.lastIndexOf('#');
                            if (hashIndex !== -1) {
                                extractedName = decodeURIComponent(url.substring(hashIndex + 1));
                            }
                            // Extract host/port from URL (ss://, trojan://, vless:// usually have user@host:port)
                            const match = url.match(/@([^/:]+):(\d+)/);
                            if (match) {
                                config = { ...config, host: match[1], port: match[2] };
                            }
                        }
                        name = extractedName || `${protocol.toUpperCase()} Import`;
                    } catch (e) {
                        name = `${protocol.toUpperCase()} Import`;
                    }
                } else if (customSubMode === 'manual') {
                    if (!serverHost.trim() || !serverPort.trim()) return;
                    name = serverName.trim() || `${serverProtocol} Server`;
                    url = `${serverHost.trim()}:${serverPort.trim()}`;
                    protocol = serverProtocol.toLowerCase();
                    config = {
                        host: serverHost.trim(),
                        port: serverPort.trim(),
                        protocol: protocol
                    };
                } else return;

                await ProxyManager.getInstance().addEndpoint(url, name, protocol, config);
                Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
                onAdded();
                onClose();
                // Reset fields
                setImportUrl('');
                setServerName('');
                setServerHost('');
                setServerPort('');
            }
        } catch (e) {
            console.error(e);
            Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
        }
        setIsSaving(false);
    };

    const canSave = () => {
        if (mode === 'relay') return relayCode.trim().length > 0;
        if (customSubMode === 'import') return importUrl.trim().length > 0;
        if (customSubMode === 'manual') return serverHost.trim().length > 0 && serverPort.trim().length > 0;
        return false;
    };

    const panelStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: translateY.value }],
    }));

    const backdropStyle = useAnimatedStyle(() => ({
        opacity: backdrop.value,
    }));

    if (!isMounted && !visible) return null;

    return (
        <Modal transparent visible={true} animationType="none" onRequestClose={onClose}>
            <View style={StyleSheet.absoluteFill}>
                <Animated.View style={[StyleSheet.absoluteFill, { backgroundColor: 'rgba(0,0,0,0.4)' }, backdropStyle]}>
                    <Pressable style={StyleSheet.absoluteFill} onPress={onClose} />
                </Animated.View>

                <Animated.View style={[s.panel, { backgroundColor: isLight ? '#f2f2f7' : '#1c1c1e' }, panelStyle]}>
                    {/* Header */}
                    <View style={s.modalHeader}>
                        <AnimatedGlassButton
                            onPress={customSubMode !== 'none' ? () => setCustomSubMode('none') : onClose}
                            homeIcon={customSubMode !== 'none' ? <ArrowLeft size={22} color={colors.text} /> : <CloseIcon size={22} color={colors.text} />}
                            effectiveTheme={effectiveTheme}
                            size={44}
                            homeBackgroundColor={glassBg}
                        />

                        <Text style={[s.headerTitle, { color: colors.text }]}>
                            {mode === 'relay' ? 'Private Relay' : customSubMode === 'import' ? 'Import URL' : customSubMode === 'manual' ? 'Manual Config' : 'Add Server'}
                        </Text>

                        {canSave() || mode === 'relay' ? (
                            <AnimatedGlassButton
                                onPress={handleSave}
                                disabled={!canSave() || isSaving}
                                homeIcon={
                                    isSaving ? (
                                        <ActivityIndicator color="#fff" size="small" />
                                    ) : (
                                        <CheckIcon size={24} color="#fff" strokeWidth={3} />
                                    )
                                }
                                effectiveTheme={effectiveTheme}
                                size={44}
                                homeBackgroundColor={canSave() ? activeBlue : offColor}
                            />
                        ) : <View style={{ width: 44 }} />}
                    </View>

                    <View style={s.modalContent}>
                        {mode === 'relay' ? (
                            <Animated.View entering={FadeIn.duration(300)} style={{ width: '100%', alignItems: 'center' }}>
                                <View style={s.iconContainer}>
                                    <ParticleVisualizer
                                        state={visible ? 'searching' : 'idle'}
                                        theme={effectiveTheme}
                                        primaryColor={activeBlue}
                                        isVisible={isMounted}
                                        style={{ width: 120, height: 120 }}
                                    />
                                </View>

                                <Text style={[s.sectionTitle, { color: colors.text }]}>Start connection</Text>
                                <View style={[s.iosInputGroup, { backgroundColor: isLight ? '#fff' : '#2c2c2e' }]}>
                                    <TextInput
                                        style={[s.iosInput, { color: colors.text, textAlign: 'center', fontSize: 22, fontWeight: '600', letterSpacing: 1 }]}
                                        placeholder="VIBE-XXXX-XXXX"
                                        placeholderTextColor={isLight ? '#c7c7cc' : '#48484a'}
                                        value={relayCode}
                                        onChangeText={setRelayCode}
                                        autoCapitalize="characters"
                                        autoCorrect={false}
                                    />
                                </View>
                                <Text style={[s.modalDesc, { color: colors.textSecondary }]}>
                                    Enter the invite code provided by the relay owner to join their private network.
                                </Text>
                            </Animated.View>
                        ) : (
                            <Animated.View entering={FadeIn.duration(300)} style={{ width: '100%' }}>
                                {customSubMode === 'none' ? (
                                    <View style={{ gap: 20 }}>
                                        <Text style={{ fontSize: 13, fontWeight: '600', color: colors.textSecondary, textTransform: 'uppercase', letterSpacing: 1, marginLeft: 4 }}>Configuration Method</Text>
                                        <SettingGroup isLight={isLight}>
                                            <SettingRow
                                                label="Import from URL"
                                                subLabel="vmess://, ss://, trojan://"
                                                icon={Link}
                                                colors={colors}
                                                isLight={isLight}
                                                onPress={() => setCustomSubMode('import')}
                                            />
                                            <SettingRow
                                                label="Manual Configuration"
                                                subLabel="Host, Port, and Protocol"
                                                icon={Server}
                                                colors={colors}
                                                isLight={isLight}
                                                onPress={() => setCustomSubMode('manual')}
                                                isLast
                                            />
                                        </SettingGroup>
                                    </View>
                                ) : customSubMode === 'import' ? (
                                    <Animated.View entering={FadeIn} style={{ gap: 16 }}>
                                        <View style={[s.iosInputGroup, { backgroundColor: isLight ? '#fff' : '#2c2c2e', padding: 12 }]}>
                                            <TextInput
                                                style={[s.iosInput, { color: colors.text, height: 120, textAlignVertical: 'top' }]}
                                                placeholder="Paste your server URL here..."
                                                placeholderTextColor={isLight ? '#c7c7cc' : '#48484a'}
                                                value={importUrl}
                                                onChangeText={setImportUrl}
                                                multiline
                                                autoCapitalize="none"
                                                autoCorrect={false}
                                            />
                                            <TouchableOpacity
                                                style={{ position: 'absolute', right: 12, bottom: 12, padding: 8, backgroundColor: activeBlue, borderRadius: 10 }}
                                                onPress={async () => {
                                                    const text = await Clipboard.getStringAsync();
                                                    if (text) setImportUrl(text);
                                                }}
                                            >
                                                <Text style={{ color: '#fff', fontWeight: '600', fontSize: 13 }}>Paste</Text>
                                            </TouchableOpacity>
                                        </View>
                                        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 4 }}>
                                            <Globe size={14} color={colors.textSecondary} />
                                            <Text style={{ fontSize: 13, color: colors.textSecondary }}>Supports vmess, shadowsocks, and trojan links.</Text>
                                        </View>
                                    </Animated.View>
                                ) : (
                                    <Animated.View entering={FadeIn} style={{ gap: 16 }}>
                                        {/* Name */}
                                        <View style={[s.iosInputGroup, { backgroundColor: isLight ? '#fff' : '#2c2c2e' }]}>
                                            <TextInput
                                                style={[s.iosInput, { color: colors.text, paddingHorizontal: 16 }]}
                                                placeholder="Server Name (Optional)"
                                                placeholderTextColor={isLight ? '#c7c7cc' : '#48484a'}
                                                value={serverName}
                                                onChangeText={setServerName}
                                            />
                                        </View>

                                        {/* Protocol Dropdown */}
                                        <View style={{ zIndex: 10 }}>
                                            <TouchableOpacity
                                                onPress={() => setShowProtocolDropdown(!showProtocolDropdown)}
                                                style={[s.iosInputGroup, { backgroundColor: isLight ? '#fff' : '#2c2c2e', flexDirection: 'row', alignItems: 'center', paddingHorizontal: 16, justifyContent: 'space-between' }]}
                                            >
                                                <Text style={{ fontSize: 17, color: colors.text }}>Protocol: <Text style={{ fontWeight: '600' }}>{serverProtocol}</Text></Text>
                                                <ChevronDown size={20} color={colors.textSecondary} />
                                            </TouchableOpacity>

                                            {showProtocolDropdown && (
                                                <View style={{ position: 'absolute', top: 60, left: 0, right: 0, backgroundColor: isLight ? '#fff' : '#252525', borderRadius: 14, shadowColor: '#000', shadowOpacity: 0.2, shadowRadius: 10, elevation: 5, overflow: 'hidden', zIndex: 100 }}>
                                                    {PROTOCOLS.map((p, i) => (
                                                        <TouchableOpacity
                                                            key={p}
                                                            style={{ padding: 16, borderBottomWidth: i === PROTOCOLS.length - 1 ? 0 : 1, borderBottomColor: isLight ? '#eee' : '#333' }}
                                                            onPress={() => { setServerProtocol(p); setShowProtocolDropdown(false); }}
                                                        >
                                                            <Text style={{ fontSize: 16, color: colors.text }}>{p}</Text>
                                                        </TouchableOpacity>
                                                    ))}
                                                </View>
                                            )}
                                        </View>

                                        {/* Host & Port */}
                                        <View style={{ flexDirection: 'row', gap: 12 }}>
                                            <View style={[s.iosInputGroup, { backgroundColor: isLight ? '#fff' : '#2c2c2e', flex: 2 }]}>
                                                <TextInput
                                                    style={[s.iosInput, { color: colors.text, paddingHorizontal: 16 }]}
                                                    placeholder="Host / IP"
                                                    placeholderTextColor={isLight ? '#c7c7cc' : '#48484a'}
                                                    value={serverHost}
                                                    onChangeText={setServerHost}
                                                    autoCapitalize="none"
                                                />
                                            </View>
                                            <View style={[s.iosInputGroup, { backgroundColor: isLight ? '#fff' : '#2c2c2e', flex: 1 }]}>
                                                <TextInput
                                                    style={[s.iosInput, { color: colors.text, paddingHorizontal: 16 }]}
                                                    placeholder="Port"
                                                    placeholderTextColor={isLight ? '#c7c7cc' : '#48484a'}
                                                    value={serverPort}
                                                    onChangeText={setServerPort}
                                                    keyboardType="number-pad"
                                                />
                                            </View>
                                        </View>
                                    </Animated.View>
                                )}
                            </Animated.View>
                        )}
                    </View>
                </Animated.View>
            </View>
        </Modal>
    );
};

// Also export RelayModal for backward compatibility if needed, but we'll update ConnectionModal to use AddServerModal
export const RelayModal = AddServerModal;

const s = StyleSheet.create({
    panel: {
        position: 'absolute',
        bottom: 0, left: 0, right: 0,
        height: MODAL_HEIGHT,
        borderTopLeftRadius: 45,
        borderTopRightRadius: 45,
        overflow: 'hidden',
    },
    modalHeader: {
        flexDirection: 'row',
        justifyContent: 'space-between',
        alignItems: 'center',
        paddingHorizontal: 20,
        paddingTop: 25,
    },
    headerTitle: {
        fontSize: 17,
        fontWeight: '600'
    },
    modalContent: {
        flex: 1,
        alignItems: 'center',
        paddingHorizontal: 24,
        paddingTop: 20,
    },
    tabContainer: {
        flexDirection: 'row',
        padding: 4,
        borderRadius: 16,
    },
    tab: {
        flex: 1,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        paddingVertical: 10,
        borderRadius: 12,
        gap: 8,
    },
    tabText: {
        fontSize: 14,
        fontWeight: '600',
    },
    iconContainer: {
        alignItems: 'center',
        justifyContent: 'center',
        marginBottom: 20,
    },
    sectionTitle: {
        fontSize: 22,
        fontWeight: '700',
        marginBottom: 24,
        textAlign: 'center',
    },
    iosInputGroup: {
        width: '100%',
        borderRadius: 14,
        overflow: 'hidden',
        minHeight: 52,
    },
    iosInput: {
        flex: 1,
        fontSize: 17,
        height: 52,
        paddingHorizontal: 10,
    },
    modalDesc: {
        fontSize: 14,
        textAlign: 'center',
        marginTop: 24,
        lineHeight: 20,
        opacity: 0.6,
        paddingHorizontal: 20,
    }
});
