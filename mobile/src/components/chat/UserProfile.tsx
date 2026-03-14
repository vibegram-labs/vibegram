import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
    View,
    Text,
    Image,
    TouchableOpacity,
    Pressable,
    StyleSheet,
    ScrollView,
    Alert,
    Linking,
    Dimensions,
    StatusBar,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import {
    ArrowLeft,
    Phone,
    Video,
    Bell,
    BellOff,
    Ban,
    Trash2,
    MoreHorizontal,
    Search,
} from 'lucide-react-native';
import * as Clipboard from 'expo-clipboard';
import Animated from 'react-native-reanimated';

import SafeLiquidGlass from '../../components/native/SafeLiquidGlass';
import { InlineBadge } from '../../components/shared/BadgeIcon';
import GlassMorphMenu from '../settings/GlassMorphMenu';
import { useThemeStore } from '../../lib/stores/theme-store';
import { useToastStore } from '../../lib/stores/toast-store';
import type { UserTier } from '../../lib/stores/subscription-store';

const { width: SCREEN_W } = Dimensions.get('window');
const GRID_GAP = 3;
const GRID_COLS = 3;
const GRID_ITEM_SIZE = (SCREEN_W - 32 - GRID_GAP * (GRID_COLS - 1)) / GRID_COLS;

export interface UserProfileMediaItem {
    id: string; type: string; mediaUrl: string; caption?: string; timestamp: number;
}
export interface UserProfileFileItem {
    id: string; type: string; fileName: string; fileSize?: number; mediaUrl?: string; timestamp: number;
}
export interface UserProfileLinkItem {
    id: string; url: string; previewText?: string; timestamp: number;
}
export interface UserProfilePinnedItem {
    id: string; type: string; text: string; timestamp: number;
}

interface ProfileProps {
    visible?: boolean;
    onClose?: () => void;
    username: string;
    userId: string;
    chatId?: string;
    tier?: UserTier;
    profileImage?: string | null;
    bio?: string;
    isOnline?: boolean;
    isMuted?: boolean;
    onToggleMute?: () => void;
    onAudioCall?: () => void;
    onVideoCall?: () => void;
    onBlock?: () => void;
    onClearChat?: () => void;
    onDeleteContact?: () => void;
    isContentLoading?: boolean;
    initialTab?: ProfileTab;
    mediaItems?: UserProfileMediaItem[];
    videoItems?: UserProfileMediaItem[];
    imageItems?: UserProfileMediaItem[];
    fileItems?: UserProfileFileItem[];
    linkItems?: UserProfileLinkItem[];
    pinnedItems?: UserProfilePinnedItem[];
}

type ProfileTab = 'media' | 'music' | 'files' | 'links' | 'pinned';

const withAlpha = (color: string, alpha: number): string => {
    if (!color) return `rgba(127,127,127,${alpha})`;
    if (color.startsWith('#')) {
        const h = color.replace('#', '');
        const r = parseInt(h.slice(0, 2), 16);
        const g = parseInt(h.slice(2, 4), 16);
        const b = parseInt(h.slice(4, 6), 16);
        return `rgba(${r},${g},${b},${alpha})`;
    }
    return color;
};

const fmtDate = (ts: number) =>
    Number.isFinite(ts)
        ? new Date(ts).toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' })
        : '';

const fmtSize = (bytes?: number) => {
    if (!bytes) return '';
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
};

const Card = ({ children, style }: { children: React.ReactNode; style?: any }) => {
    const { colors } = useThemeStore();
    return (
        <View style={[
            st.card,
            {
                backgroundColor: withAlpha(colors.card, 0.92),
            },
            style,
        ]}>
            {children}
        </View>
    );
};

const ActionPill = ({
    icon,
    label,
    onPress,
    disabled,
}: {
    icon: React.ReactNode;
    label: string;
    onPress?: () => void;
    disabled?: boolean;
}) => {
    const { colors } = useThemeStore();
    return (
        <TouchableOpacity
            onPress={onPress}
            disabled={disabled || !onPress}
            activeOpacity={0.7}
            style={[st.actionPillWrap, disabled && { opacity: 0.45 }]}
        >
            <View
                style={[st.actionPill, { backgroundColor: withAlpha(colors.card, 0.92) }]}
            >
                <View style={st.actionPillContent}>
                    {React.cloneElement(icon as any, { size: 24, color: colors.text, strokeWidth: 2 })}
                    <Text style={[st.actionPillLabel, { color: colors.text }]}>{label}</Text>
                </View>
            </View>
        </TouchableOpacity>
    );
};

const TabPill = ({
    label,
    active,
    onPress,
}: {
    label: string;
    active: boolean;
    onPress: () => void;
}) => {
    const { colors, effectiveTheme } = useThemeStore();
    return (
        <TouchableOpacity
            onPress={onPress}
            activeOpacity={0.8}
            style={[
                st.tabPill,
                active
                    ? { backgroundColor: withAlpha(colors.text, effectiveTheme === 'dark' ? 0.18 : 0.1) }
                    : { backgroundColor: 'transparent' },
            ]}
        >
            <Text style={[st.tabPillText, { color: active ? colors.text : colors.textSecondary }]}>{label}</Text>
        </TouchableOpacity>
    );
};

const ListRow = ({
    title,
    subtitle,
    valueColor,
    onPress,
    last = false,
}: {
    title: string;
    subtitle?: string;
    valueColor?: string;
    onPress?: () => void;
    last?: boolean;
}) => {
    const { colors } = useThemeStore();
    return (
        <Pressable
            onPress={onPress}
            disabled={!onPress}
            style={({ pressed }) => [
                st.row,
                { borderBottomColor: last ? 'transparent' : withAlpha(colors.text, 0.08) },
                pressed && onPress && { backgroundColor: withAlpha(colors.text, 0.04) },
            ]}
        >
            <Text style={[st.rowTitle, { color: valueColor || colors.text }]} numberOfLines={1}>{title}</Text>
            {!!subtitle && <Text style={[st.rowSub, { color: colors.textSecondary }]} numberOfLines={1}>{subtitle}</Text>}
        </Pressable>
    );
};

export default function UserProfile({
    onClose,
    username,
    userId,
    chatId,
    profileImage,
    tier,
    bio,
    isOnline,
    isMuted = false,
    onToggleMute,
    onAudioCall,
    onVideoCall,
    onBlock,
    onClearChat,
    onDeleteContact,
    initialTab,
    mediaItems = [],
    videoItems = [],
    imageItems = [],
    fileItems = [],
    linkItems = [],
    pinnedItems = [],
}: ProfileProps) {
    const insets = useSafeAreaInsets();
    const router = require('expo-router').useRouter();
    const { colors, effectiveTheme } = useThemeStore();
    const { showToast } = useToastStore();
    const isDark = effectiveTheme === 'dark';

    const [activeTab, setActiveTab] = useState<ProfileTab>(initialTab || 'media');
    const [menuOpen, setMenuOpen] = useState(false);
    const appliedInitialTabRef = useRef<ProfileTab | null>(null);

    const allMedia = useMemo(
        () => [...imageItems, ...videoItems].sort((a, b) => b.timestamp - a.timestamp),
        [imageItems, videoItems]
    );

    const musicItems = useMemo(
        () => fileItems.filter((item) => (item.type || '').toLowerCase() === 'music'),
        [fileItems]
    );

    const docItems = useMemo(
        () => fileItems.filter((item) => (item.type || '').toLowerCase() !== 'music'),
        [fileItems]
    );

    const tabs = useMemo(() => {
        const defs: Array<{ key: ProfileTab; label: string; count: number }> = [
            { key: 'media', label: `Media ${allMedia.length}`, count: allMedia.length },
            { key: 'music', label: `Music ${musicItems.length}`, count: musicItems.length },
            { key: 'files', label: `Files ${docItems.length}`, count: docItems.length },
            { key: 'links', label: `Links ${linkItems.length}`, count: linkItems.length },
            { key: 'pinned', label: `Pinned ${pinnedItems.length}`, count: pinnedItems.length },
        ];
        return defs.filter((item) => item.count > 0);
    }, [allMedia.length, musicItems.length, docItems.length, linkItems.length, pinnedItems.length]);

    useEffect(() => {
        if (tabs.length === 0) return;
        const activeStillAvailable = tabs.some((item) => item.key === activeTab);
        if (!activeStillAvailable) {
            setActiveTab(tabs[0].key);
        }
    }, [tabs, activeTab]);

    useEffect(() => {
        if (!initialTab) return;
        if (appliedInitialTabRef.current === initialTab) return;
        if (!tabs.some((item) => item.key === initialTab)) return;
        appliedInitialTabRef.current = initialTab;
        setActiveTab(initialTab);
    }, [initialTab, tabs]);

    const handleBack = () => {
        if (onClose) onClose();
        else router.back();
    };

    const copyUsername = async () => {
        await Clipboard.setStringAsync(`@${username}`);
        showToast('Username copied to clipboard', 'info');
    };

    const openSearchInChat = () => {
        const routeParams: Record<string, string> = { openSearch: '1' };
        if (chatId) {
            routeParams.id = chatId;
        } else {
            routeParams.friendId = userId;
            routeParams.friendName = username;
            routeParams.friendImage = profileImage || '';
        }
        router.push({ pathname: '/chat', params: routeParams });
    };

    const openUrl = async (url?: string) => {
        if (!url) return;
        try {
            await Linking.openURL(url);
        } catch {
            Alert.alert('Error', 'Could not open link.');
        }
    };

    const menuItems = useMemo(() => {
        const items: { id: string; label: string; icon: any; destructive?: boolean }[] = [
            { id: 'search', label: 'Search in Chat', icon: Search },
        ];

        if (onToggleMute) items.push({ id: 'mute', label: isMuted ? 'Unmute' : 'Mute', icon: isMuted ? Bell : BellOff });
        if (onClearChat) items.push({ id: 'clear', label: 'Clear Chat', icon: Trash2, destructive: true });
        if (onBlock) items.push({ id: 'block', label: 'Block User', icon: Ban, destructive: true });
        if (onDeleteContact) items.push({ id: 'delete', label: 'Delete Contact', icon: Trash2, destructive: true });
        return items;
    }, [isMuted, onToggleMute, onClearChat, onBlock, onDeleteContact]);

    const handleMenuSelect = (id: string) => {
        setMenuOpen(false);
        if (id === 'search') openSearchInChat();
        if (id === 'mute') onToggleMute?.();
        if (id === 'clear') onClearChat?.();
        if (id === 'block') onBlock?.();
        if (id === 'delete') onDeleteContact?.();
    };

    const renderMedia = () => (
        <View style={st.grid}>
            {allMedia.map((item) => (
                <TouchableOpacity
                    key={item.id}
                    style={[st.gridCell, { backgroundColor: withAlpha(colors.text, 0.06) }]}
                    onPress={() => openUrl(item.mediaUrl)}
                    activeOpacity={0.82}
                >
                    {!!item.mediaUrl && <Image source={{ uri: item.mediaUrl }} style={StyleSheet.absoluteFill} resizeMode="cover" />}
                    {item.type === 'video' && (
                        <View style={st.videoBadge}>
                            <Text style={st.videoBadgeText}>VIDEO</Text>
                        </View>
                    )}
                </TouchableOpacity>
            ))}
        </View>
    );

    const renderMusic = () => (
        <Card>
            {musicItems.map((item, idx) => (
                <ListRow
                    key={item.id}
                    title={item.fileName}
                    subtitle={[fmtSize(item.fileSize), fmtDate(item.timestamp)].filter(Boolean).join(' · ')}
                    onPress={() => openUrl(item.mediaUrl)}
                    last={idx === musicItems.length - 1}
                />
            ))}
        </Card>
    );

    const renderFiles = () => (
        <Card>
            {docItems.map((item, idx) => (
                <ListRow
                    key={item.id}
                    title={item.fileName}
                    subtitle={[fmtSize(item.fileSize), fmtDate(item.timestamp)].filter(Boolean).join(' · ')}
                    onPress={() => openUrl(item.mediaUrl)}
                    last={idx === docItems.length - 1}
                />
            ))}
        </Card>
    );

    const renderLinks = () => (
        <Card>
            {linkItems.map((item, idx) => (
                <ListRow
                    key={item.id}
                    title={item.url}
                    subtitle={item.previewText || fmtDate(item.timestamp)}
                    valueColor={colors.primary}
                    onPress={() => openUrl(item.url)}
                    last={idx === linkItems.length - 1}
                />
            ))}
        </Card>
    );

    const renderPinned = () => (
        <Card>
            {pinnedItems.map((item, idx) => (
                <ListRow
                    key={item.id}
                    title={item.text || item.type}
                    subtitle={fmtDate(item.timestamp)}
                    last={idx === pinnedItems.length - 1}
                />
            ))}
        </Card>
    );

    const renderTabContent = () => {
        if (activeTab === 'media') return renderMedia();
        if (activeTab === 'music') return renderMusic();
        if (activeTab === 'files') return renderFiles();
        if (activeTab === 'links') return renderLinks();
        return renderPinned();
    };

    return (
        <View style={[st.root, { backgroundColor: colors.background }]}>
            <StatusBar barStyle={isDark ? 'light-content' : 'dark-content'} />

            <View style={[st.header, { paddingTop: insets.top, height: insets.top + 54 }]}>
                <View style={StyleSheet.absoluteFill}>

                </View>

                <View style={st.headerRow}>
                    <SafeLiquidGlass
                        style={st.headerButtonGlass}
                        blurIntensity={20}
                        tint={isDark ? 'dark' : 'light'}
                    >
                        <TouchableOpacity onPress={handleBack} style={st.headerIconBtn} hitSlop={8}>
                            <ArrowLeft size={22} color={colors.text} strokeWidth={2.4} />
                        </TouchableOpacity>
                    </SafeLiquidGlass>



                    <View style={{ width: 42, height: 42 }}>
                        <GlassMorphMenu
                            items={menuItems}
                            onSelect={handleMenuSelect}
                            open={menuOpen}
                            onOpenChange={setMenuOpen}
                            anchor="top-right"
                            menuWidth={210}
                            collapsedSize={42}
                            customIcon={<MoreHorizontal size={22} color={colors.text} strokeWidth={2.2} />}
                        />
                    </View>
                </View>
            </View>

            <Animated.ScrollView
                showsVerticalScrollIndicator={false}
                contentContainerStyle={{ paddingTop: insets.top + 54, paddingBottom: insets.bottom + 42 }}
            >
                <View style={st.hero}>
                    <View style={st.avatarWrap}>
                        {profileImage ? (
                            <Image source={{ uri: profileImage }} style={st.avatar} />
                        ) : (
                            <View style={[st.avatarFallback, { backgroundColor: withAlpha(colors.text, 0.14) }]}>
                                <Text style={[st.avatarInitial, { color: colors.text }]}>{username[0]?.toUpperCase() ?? '?'}</Text>
                            </View>
                        )}
                        {isOnline !== undefined && (
                            <View
                                style={[
                                    st.onlineDot,
                                    {
                                        backgroundColor: isOnline ? colors.success : withAlpha(colors.text, 0.2),
                                        borderColor: colors.background,
                                    },
                                ]}
                            />
                        )}
                    </View>

                    <View style={st.heroNameRow}>
                        <Text style={[st.heroName, { color: colors.text }]}>{username}</Text>
                        {tier && <InlineBadge tier={tier} size={18} />}
                    </View>
                    <TouchableOpacity onPress={copyUsername} activeOpacity={0.75}>
                        <Text style={[st.heroHandle, { color: colors.primary }]}>@{username}</Text>
                    </TouchableOpacity>
                    {bio ? <Text style={[st.heroBio, { color: colors.textSecondary }]}>{bio}</Text> : null}
                </View>

                <View style={st.actionsRow}>
                    <ActionPill icon={<Bell />} label={isMuted ? 'Unmute' : 'Mute'} onPress={onToggleMute} disabled={!onToggleMute} />
                    <ActionPill icon={<Search />} label="Search" onPress={openSearchInChat} />
                    <ActionPill icon={<Phone />} label="Call" onPress={onAudioCall} disabled={!onAudioCall} />
                    <ActionPill icon={<Video />} label="Video" onPress={onVideoCall} disabled={!onVideoCall} />
                </View>

                <View style={st.section}>
                    <Card>
                        <ListRow title="Username" subtitle={`@${username}`} valueColor={colors.primary} onPress={copyUsername} last={!bio} />
                        {bio ? <ListRow title="Bio" subtitle={bio} last /> : null}
                    </Card>
                </View>

                <View style={st.section}>
                    {tabs.length > 0 ? (
                        <>
                            <View style={st.tabsContainerWrap}>
                                <View style={[st.tabsContainer, { backgroundColor: withAlpha(colors.card, 0.92) }]}>
                                    <ScrollView
                                        horizontal
                                        showsHorizontalScrollIndicator={false}
                                        contentContainerStyle={st.tabsScroll}
                                    >
                                        {tabs.map((tab) => (
                                            <TabPill
                                                key={tab.key}
                                                label={tab.label}
                                                active={activeTab === tab.key}
                                                onPress={() => setActiveTab(tab.key)}
                                            />
                                        ))}
                                    </ScrollView>
                                </View>
                            </View>

                            <View style={{ marginTop: 14 }}>
                                {renderTabContent()}
                            </View>
                        </>
                    ) : null}
                </View>
            </Animated.ScrollView>
        </View>
    );
}

const st = StyleSheet.create({
    root: { flex: 1 },
    header: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        zIndex: 120,
        overflow: 'visible',
    },
    headerRow: {
        flex: 1,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 16,
    },
    headerIconBtn: {
        width: 42,
        height: 42,
        alignItems: 'center',
        justifyContent: 'center',
    },
    headerButtonGlass: {
        width: 42,
        height: 42,
        borderRadius: 21,
        overflow: 'hidden',
    },
    headerCentre: {
        flex: 1,
        alignItems: 'center',
    },
    headerName: {
        fontSize: 15,
        fontWeight: '700',
        letterSpacing: -0.2,
    },
    headerStatus: {
        marginTop: 1,
        fontSize: 12,
        fontWeight: '500',
    },
    headerSep: {
        position: 'absolute',
        left: 0,
        right: 0,
        bottom: 0,
        height: StyleSheet.hairlineWidth,
    },

    hero: {
        alignItems: 'center',
        paddingTop: 30,
        paddingHorizontal: 24,
        paddingBottom: 18,
    },
    avatarWrap: {
        position: 'relative',
        marginBottom: 16,
    },
    avatar: {
        width: 118,
        height: 118,
        borderRadius: 59,
    },
    avatarFallback: {
        width: 118,
        height: 118,
        borderRadius: 59,
        alignItems: 'center',
        justifyContent: 'center',
    },
    avatarInitial: {
        fontSize: 44,
        fontWeight: '700',
    },
    onlineDot: {
        position: 'absolute',
        right: 4,
        bottom: 4,
        width: 20,
        height: 20,
        borderRadius: 10,
        borderWidth: 3,
    },
    heroNameRow: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 6,
    },
    heroName: {
        fontSize: 30,
        fontWeight: '700',
        letterSpacing: -0.6,
    },
    heroHandle: {
        fontSize: 18,
        fontWeight: '500',
        marginTop: 2,
    },
    heroBio: {
        marginTop: 10,
        fontSize: 14,
        lineHeight: 20,
        textAlign: 'center',
        maxWidth: 310,
    },

    actionsRow: {
        flexDirection: 'row',
        paddingHorizontal: 16,
        gap: 8,
        marginBottom: 20,
    },
    actionPillWrap: {
        flex: 1,
    },
    actionPill: {
        height: 64,
        borderRadius: 16,
        overflow: 'hidden',
    },
    actionPillContent: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
        gap: 6,
    },
    actionPillLabel: {
        fontSize: 13,
        fontWeight: '500',
        letterSpacing: 0.2,
    },

    section: {
        paddingHorizontal: 16,
        marginBottom: 18,
    },
    card: {
        borderRadius: 24,
        overflow: 'hidden',
    },
    row: {
        paddingHorizontal: 18,
        paddingVertical: 14,
        borderBottomWidth: StyleSheet.hairlineWidth,
    },
    rowTitle: {
        fontSize: 16,
        fontWeight: '500',
    },
    rowSub: {
        marginTop: 3,
        fontSize: 14,
    },

    tabsContainerWrap: {
        paddingHorizontal: 16,
    },
    tabsContainer: {
        borderRadius: 20,
        overflow: 'hidden',
    },
    tabsScroll: {
        paddingHorizontal: 6,
        paddingVertical: 6,
        gap: 6,
        alignItems: 'center',
    },
    tabPill: {
        paddingHorizontal: 16,
        paddingVertical: 8,
        borderRadius: 18,
    },
    tabPillText: {
        fontSize: 16,
        fontWeight: '500',
    },

    grid: {
        flexDirection: 'row',
        flexWrap: 'wrap',
        gap: GRID_GAP,
    },
    gridCell: {
        width: GRID_ITEM_SIZE,
        height: GRID_ITEM_SIZE,
        borderRadius: 3,
        overflow: 'hidden',
    },
    videoBadge: {
        position: 'absolute',
        right: 6,
        bottom: 6,
        backgroundColor: 'rgba(0,0,0,0.55)',
        borderRadius: 7,
        paddingHorizontal: 6,
        paddingVertical: 2,
    },
    videoBadgeText: {
        color: '#fff',
        fontSize: 10,
        fontWeight: '600',
        letterSpacing: 0.3,
    },

});
