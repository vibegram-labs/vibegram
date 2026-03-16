import React, { useEffect, useMemo, useRef, useState } from 'react';
import { View, Text, StyleSheet, Dimensions, TouchableOpacity, TextInput, ActivityIndicator, Keyboard, Image } from 'react-native';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    Easing,
    FadeIn,
} from 'react-native-reanimated';
import { useRouter } from 'expo-router';
import { useThemeStore } from '../../lib/stores/theme-store';
import { useContactStore } from '../../lib/stores/contact-store';
import { useChatStore } from '../../lib/ChatStore';
import { useToastStore } from '../../lib/stores/toast-store';
import SafeLiquidGlass from '../../components/native/SafeLiquidGlass';
import AnimatedGlassButton from '../../components/native/AnimatedGlassButton';
import { interpolate } from 'react-native-reanimated';
import { useAuthStore } from '../../lib/stores/auth-store';
import { X, MessageCircle, Phone, UserCheck, Check, Search, ArrowLeft, ArrowRight, ChevronLeft, ChevronRight, UserPlus, UserMinus } from 'lucide-react-native';
import { ContactsIcon } from '../../components/Icons';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { LayoutAnimation, Platform, UIManager } from 'react-native';
import WallpaperBackground from './WallpaperBackground';

if (Platform.OS === 'android') {
    if (UIManager.setLayoutAnimationEnabledExperimental) {
        UIManager.setLayoutAnimationEnabledExperimental(true);
    }
}

const { width: SCREEN_WIDTH } = Dimensions.get('window');
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PHONE_REGEX = /^\+?[0-9\-\s]{7,15}$/;

const SMOOTH_TIMING = { duration: 400, easing: Easing.bezier(0.25, 0.1, 0.25, 1) };

interface FoundUser {
    id: string;
    userId: string;
    username: string;
    profileImage?: string;
    phoneNumber?: string;
    publicKey?: string;
    isAgent?: boolean;
    agentId?: string;
}

const withAlpha = (color: string, alpha: number) => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`
    if (color.startsWith('#')) {
        const hex = color.replace('#', '')
        const r = parseInt(hex.substring(0, 2), 16)
        const g = parseInt(hex.substring(2, 4), 16)
        const b = parseInt(hex.substring(4, 6), 16)
        return `rgba(${r}, ${g}, ${b}, ${alpha})`
    }
    return color;
};

interface NewChatModalProps {
    onClose: () => void;
    onFullClose?: () => void;
}

const ActionPill = ({ icon, label, onPress, disabled, success, successLabel }: any) => {
    const { colors, effectiveTheme } = useThemeStore();
    const progress = useSharedValue(success ? 1 : 0);

    useEffect(() => {
        progress.value = withTiming(success ? 1 : 0, { duration: 300 });
    }, [success]);

    const iconStyle = useAnimatedStyle(() => ({
        transform: [{ scale: interpolate(progress.value, [0, 0.5, 1], [1, 0, 1]) }],
        opacity: interpolate(progress.value, [0, 0.45, 0.55, 1], [1, 0, 0, 1]),
    }));

    const textStyle = useAnimatedStyle(() => ({
        opacity: interpolate(progress.value, [0, 0.45, 0.55, 1], [1, 0, 0, 1]),
    }));

    return (
        <TouchableOpacity
            onPress={onPress}
            disabled={disabled || !onPress || success}
            activeOpacity={0.7}
            style={[{ flex: 1 }, disabled && { opacity: 0.45 }]}
        >
            <SafeLiquidGlass
                blurIntensity={10}
                tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                style={{
                    height: 72,
                    borderRadius: 16,
                    backgroundColor: withAlpha(colors.card, 0.5),
                    alignItems: 'center',
                    justifyContent: 'center',
                    borderWidth: 0,
                    borderColor: 'transparent',
                    gap: 6,
                    overflow: 'hidden'
                }}
            >
                <Animated.View style={[{ alignItems: 'center', justifyContent: 'center' }, iconStyle]}>
                    {success ? (
                        <Check size={24} color={colors.text} strokeWidth={2} />
                    ) : (
                        React.cloneElement(icon, { size: 24, color: colors.text, strokeWidth: 2 })
                    )}
                </Animated.View>
                <Animated.View style={textStyle}>
                    <Text style={{
                        color: colors.text,
                        fontSize: 13,
                        fontWeight: '600',
                        letterSpacing: 0.1
                    }}>
                        {success ? (successLabel || 'Added') : label}
                    </Text>
                </Animated.View>
            </SafeLiquidGlass>
        </TouchableOpacity>
    );
};

export default function NewChatModal({ onClose, onFullClose }: NewChatModalProps) {
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const { colors, effectiveTheme } = useThemeStore();
    const { user: currentUser } = useAuthStore();
    const { upsertContact, isContact } = useContactStore();
    const { chats, setActiveChat, updateChatFriendInfoByFriendId, startChat } = useChatStore();
    const { showToast } = useToastStore();

    // Search state (page 0)
    const [inputValue, setInputValue] = useState('');
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState('');
    const [foundUser, setFoundUser] = useState<FoundUser | null>(null);
    const [inputType, setInputType] = useState<'id' | 'phone' | 'username'>('username');
    const searchTimeout = useRef<NodeJS.Timeout | null>(null);
    const searchSeq = useRef(0);

    // Contact name state (page 1 - user card)
    const [firstName, setFirstName] = useState('');
    const [lastName, setLastName] = useState('');

    // View: 'search' = find user, 'card' = user card with actions
    const [view, setView] = useState<'search' | 'card'>('search');

    const isLight = effectiveTheme === 'light';
    const isDark = effectiveTheme === 'dark';

    // Animation values
    const contentTranslateX = useSharedValue(0);
    const headerProgress = useSharedValue(0);

    // Initial setup
    useEffect(() => {
        setView('search');
        contentTranslateX.value = 0;
        headerProgress.value = 0;
    }, []);

    const resetState = () => {
        setFoundUser(null);
        setInputValue('');
        setFirstName('');
        setLastName('');
        setError('');
        setLoading(false);
        setView('search');
    };

    const handleCloseInternal = () => {
        Keyboard.dismiss();
        onClose();
    };

    // Auto-detect input type
    useEffect(() => {
        const val = inputValue.trim();
        if (UUID_REGEX.test(val)) setInputType('id');
        else if (PHONE_REGEX.test(val) && /[0-9]/.test(val)) setInputType('phone');
        else setInputType('username');
    }, [inputValue]);

    const handleSearch = async (dismissKeyboard = false) => {
        const seq = ++searchSeq.current;
        if (!inputValue.trim()) return;
        setLoading(true);
        setError('');
        setFirstName('');
        setLastName('');
        if (dismissKeyboard) Keyboard.dismiss();

        try {
            const rawInput = inputValue.trim();
            const { apiClient } = require('../../lib/api-client');
            let user: FoundUser | null = null;

            if (inputType === 'id') {
                try {
                    user = await apiClient.findUserByName(rawInput);
                } catch (e) { }
            } else if (inputType === 'phone') {
                user = await apiClient.findUserByPhone(rawInput);
            } else {
                const cleanName = (rawInput.startsWith('@') ? rawInput.substring(1) : rawInput).toLowerCase();
                user = await apiClient.findUserByName(cleanName);
            }

            if (seq !== searchSeq.current) return;

            if (!user) {
                setFoundUser(null);
                setError('User not found');
                setLoading(false);
                return;
            }

            // Filter out current user
            if (user.userId === currentUser?.userId || user.id === currentUser?.userId) {
                setFoundUser(null);
                setError('You cannot chat with yourself');
                setLoading(false);
                return;
            }

            if (!user.userId && user.id) user.userId = user.id;
            setFoundUser(user);

        } catch (e: any) {
            console.error(e);
            if (seq !== searchSeq.current) return;
            setFoundUser(null);
            setError(e.message || 'User not found');
        } finally {
            if (seq !== searchSeq.current) return;
            setLoading(false);
        }
    };

    // Auto-search (debounced)
    useEffect(() => {
        if (view !== 'search') return;

        if (searchTimeout.current) clearTimeout(searchTimeout.current);

        const query = inputValue.trim();
        if (!query) {
            setError('');
            setLoading(false);
            setFoundUser(null);
            return;
        }

        const digitsOnly = query.replace(/[^\d]/g, '');
        const shouldSearch = inputType === 'phone'
            ? digitsOnly.length >= 7
            : query.length >= 3;

        if (!shouldSearch) {
            setError('');
            setLoading(false);
            setFoundUser(null);
            return;
        }

        setError('');
        setFoundUser(null);

        searchTimeout.current = setTimeout(() => {
            handleSearch(false);
        }, 600);

        return () => {
            if (searchTimeout.current) clearTimeout(searchTimeout.current);
        };
    }, [view, inputValue, inputType]);

    const contactDisplayName = useMemo(() => {
        if (!foundUser) return '';
        const name = `${firstName} ${lastName}`.trim();
        return name || foundUser.username || (foundUser as any).name || foundUser.userId || 'User';
    }, [foundUser, firstName, lastName]);

    const isAdded = !!(foundUser && foundUser.userId && isContact(foundUser.userId));

    // Pre-resolve chatId in background as soon as we find a user
    const preResolvedChatIdRef = useRef<string | null>(null);
    const preResolveSeqRef = useRef(0);
    useEffect(() => {
        const seq = ++preResolveSeqRef.current;
        preResolvedChatIdRef.current = null;
        if (!foundUser?.userId) return;

        const friendId = foundUser.userId;
        const existing = chats.find(c => (c.friendId || '').toUpperCase() === friendId.toUpperCase());
        if (existing?.chatId) {
            preResolvedChatIdRef.current = existing.chatId;
            return;
        }

        // Fire startChat in background so the chatId is ready when user taps "Chat"
        startChat(friendId, {
            username: foundUser.username,
            profileImage: foundUser.profileImage,
            publicKey: foundUser.publicKey,
        }).then(chatId => {
            if (seq === preResolveSeqRef.current) {
                preResolvedChatIdRef.current = chatId;
            }
        }).catch(() => { });
    }, [foundUser?.userId]);

    // Slide to user card page
    const goToCard = () => {
        Keyboard.dismiss();
        if (!foundUser?.userId) return;

        setView('card');
        contentTranslateX.value = withTiming(-SCREEN_WIDTH, SMOOTH_TIMING);
        headerProgress.value = withTiming(1, SMOOTH_TIMING);
    };

    const handleSaveContact = (silent = false) => {
        if (!foundUser?.userId) return;

        upsertContact({
            id: foundUser.userId,
            username: contactDisplayName,
            phoneNumber: foundUser.phoneNumber,
            profileImage: foundUser.profileImage
        });

        updateChatFriendInfoByFriendId(foundUser.userId, {
            friendName: contactDisplayName,
            friendImage: foundUser.profileImage
        });

        if (!silent) {
            showToast('Saved to contacts', 'success');
        }
    };

    const goBackToSearch = () => {
        setView('search');
        contentTranslateX.value = withTiming(0, SMOOTH_TIMING);
        headerProgress.value = withTiming(0, SMOOTH_TIMING);
    };

    const handleMessage = () => {
        if (!foundUser?.userId) return;

        // Auto-save contact if info was provided
        if (firstName.trim()) {
            handleSaveContact(true);
        }

        const friendId = foundUser.userId;
        const friendName = contactDisplayName;
        const friendImage = foundUser.profileImage || '';
        const friendPublicKey = foundUser.publicKey || '';

        // Close modal (slide down)
        if (onFullClose) {
            onFullClose();
        } else {
            handleCloseInternal();
        }

        // Use pre-resolved chatId if available (background fetch started when user appeared),
        // existing chat, or fall back to friendId params for the chat screen to resolve.
        const resolvedChatId =
            preResolvedChatIdRef.current
            || chats.find(c => (c.friendId || '').toUpperCase() === friendId.toUpperCase())?.chatId
            || null;

        if (resolvedChatId) {
            setActiveChat(resolvedChatId);
            router.push({ pathname: '/chat', params: { id: resolvedChatId } });
        } else {
            router.push({
                pathname: '/chat',
                params: { friendId, friendName, friendImage, friendPublicKey }
            });
        }
    };

    const sliderStyle = useAnimatedStyle(() => ({
        transform: [{ translateX: contentTranslateX.value }],
    }));

    return (
        <View style={styles.container}>
            {/* Wallpaper background - covers full modal, only visible on card view */}
            {view === 'card' && (
                <View style={StyleSheet.absoluteFill} pointerEvents="none">
                    <WallpaperBackground />
                </View>
            )}

            {/* Handle */}
            <View style={styles.handleContainer}>
                <View style={[styles.handle, { backgroundColor: withAlpha(colors.text, 0.15) }]} />
            </View>

            {/* Header */}
            <View style={styles.header}>
                <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={15} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                    <TouchableOpacity
                        onPress={view === 'card' ? goBackToSearch : handleCloseInternal}
                        style={styles.iconBtnCircle}
                        activeOpacity={0.85}
                    >
                        {view === 'card' ? (
                            <ArrowLeft size={20} color={colors.text} strokeWidth={2} />
                        ) : (
                            <X size={20} color={colors.text} strokeWidth={2} />
                        )}
                    </TouchableOpacity>
                </SafeLiquidGlass>

                <Text style={[styles.title, { color: colors.text }]} numberOfLines={1}>
                    {view === 'card' ? 'User Profile' : 'Find Person'}
                </Text>

                <SafeLiquidGlass
                    style={[
                        styles.glassBtnCircle,
                        {
                            opacity: (view === 'search' && (!foundUser || loading)) ? 0.3 : 1,
                            backgroundColor: (view === 'search' && (!foundUser || loading)) ? 'transparent' : colors.primary
                        }
                    ]}
                    blurIntensity={15}
                    tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                >
                    <TouchableOpacity
                        onPress={view === 'search' ? goToCard : () => { if (!isAdded) handleSaveContact(false); }}
                        disabled={(view === 'search' && (!foundUser || loading)) || (view === 'card' && isAdded)}
                        style={styles.iconBtnCircle}
                        activeOpacity={0.85}
                    >
                        {view === 'card' ? (
                            isAdded ? (
                                <UserCheck size={20} color="#fff" strokeWidth={2.5} />
                            ) : (
                                <UserPlus size={20} color="#fff" strokeWidth={2.5} />
                            )
                        ) : (
                            <ArrowRight
                                size={20}
                                color={(view === 'search' && (!foundUser || loading)) ? colors.text : "#fff"}
                                strokeWidth={2.5}
                            />
                        )}
                    </TouchableOpacity>
                </SafeLiquidGlass>
            </View>
            <View style={styles.contentContainer}>
                <Animated.View style={[styles.slider, sliderStyle]}>
                    {/* --- PAGE 0: SEARCH --- */}
                    <Animated.View entering={FadeIn} style={[styles.page, { width: SCREEN_WIDTH }]}>
                        {/* Search input section */}
                        <View style={styles.sectionWrapper}>
                            <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>FIND USER</Text>
                            <View style={[styles.sectionContainer, { backgroundColor: withAlpha(colors.card, 1) }]}>
                                <View style={styles.row}>
                                    <Search size={18} color={colors.textSecondary} style={{ marginRight: 12 }} />
                                    <TextInput
                                        style={[styles.rowInput, { color: colors.text }]}
                                        placeholder="Search by username, phone, or ID"
                                        placeholderTextColor={withAlpha(colors.text, 0.35)}
                                        value={inputValue}
                                        onChangeText={(t) => {
                                            setInputValue(t);
                                            setError('');
                                        }}
                                        autoCapitalize="none"
                                        autoCorrect={false}
                                        autoFocus
                                        onSubmitEditing={() => handleSearch(true)}
                                    />
                                    {loading ? (
                                        <ActivityIndicator size="small" color={colors.primary} />
                                    ) : inputValue ? (
                                        <TouchableOpacity
                                            onPress={() => { setInputValue(''); setFoundUser(null); setError(''); }}
                                            style={{ padding: 6 }}
                                        >
                                            <X size={16} color={colors.textSecondary} />
                                        </TouchableOpacity>
                                    ) : null}
                                </View>
                            </View>
                        </View>

                        {/* Search results & Add Contact info */}
                        {!!foundUser && (
                            <Animated.View entering={FadeIn.delay(50)} style={{ marginTop: 24 }}>
                                <View style={[styles.sectionContainer, { backgroundColor: withAlpha(colors.card, 1) }]}>
                                    <TouchableOpacity
                                        onPress={goToCard}
                                        style={{ flexDirection: 'row', alignItems: 'center', paddingVertical: 12, paddingHorizontal: 20 }}
                                        activeOpacity={0.7}
                                    >
                                        <View style={{ width: 44, height: 44, borderRadius: 22, backgroundColor: withAlpha(colors.cyan, 0.12), overflow: 'hidden', alignItems: 'center', justifyContent: 'center' }}>
                                            {foundUser.profileImage ? (
                                                <Image source={{ uri: foundUser.profileImage }} style={{ width: 44, height: 44 }} />
                                            ) : (
                                                <ContactsIcon size={22} color={colors.cyan} focused />
                                            )}
                                        </View>
                                        <View style={{ flex: 1, marginLeft: 12 }}>
                                            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                                                <Text style={{ fontSize: 16, fontWeight: '600', color: colors.text }}>{foundUser.username}</Text>
                                                {foundUser.isAgent ? (
                                                    <View style={{ paddingHorizontal: 8, paddingVertical: 3, borderRadius: 999, backgroundColor: withAlpha(colors.primary, 0.14) }}>
                                                        <Text style={{ fontSize: 11, fontWeight: '700', color: colors.primary }}>AGENT</Text>
                                                    </View>
                                                ) : null}
                                            </View>
                                            <Text style={{ fontSize: 14, color: colors.textSecondary }}>
                                                {foundUser.phoneNumber ? foundUser.phoneNumber : `@${foundUser.username}`}
                                            </Text>
                                        </View>
                                        <ChevronRight size={20} color={colors.textSecondary} />
                                    </TouchableOpacity>
                                </View>

                                {!isAdded && (
                                    <View style={{ marginTop: 24 }}>
                                        <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>SAVE CONTACT NAME</Text>
                                        <View style={[styles.sectionContainer, { backgroundColor: withAlpha(colors.card, 1) }]}>
                                            <View style={styles.row}>
                                                <Text style={[styles.rowLabel, { color: colors.text }]}>First Name</Text>
                                                <TextInput
                                                    style={[styles.rowInput, { color: colors.text }]}
                                                    value={firstName}
                                                    onChangeText={setFirstName}
                                                    placeholder="Required"
                                                    placeholderTextColor={withAlpha(colors.text, 0.3)}
                                                />
                                            </View>
                                            <View style={[styles.divider, { backgroundColor: withAlpha(colors.text, 0.06) }]} />
                                            <View style={styles.row}>
                                                <Text style={[styles.rowLabel, { color: colors.text }]}>Last Name</Text>
                                                <TextInput
                                                    style={[styles.rowInput, { color: colors.text }]}
                                                    value={lastName}
                                                    onChangeText={setLastName}
                                                    placeholder="Optional"
                                                    placeholderTextColor={withAlpha(colors.text, 0.3)}
                                                />
                                            </View>
                                        </View>
                                    </View>
                                )}
                            </Animated.View>
                        )}

                        {error ? <Text style={styles.errorText}>{error}</Text> : null}
                    </Animated.View>

                    {/* --- PAGE 1: USER CARD --- */}
                    <Animated.View entering={FadeIn} style={[styles.page, { width: SCREEN_WIDTH }]}>
                        <View style={{ paddingHorizontal: 16 }}>
                            {!!foundUser ? (
                                <View style={{ paddingTop: 20 }}>
                                    {/* Profile Header (Modern) */}
                                    <View style={{ alignItems: 'center', marginBottom: 24 }}>
                                        <SafeLiquidGlass
                                            blurIntensity={20}
                                            style={{ width: 118, height: 118, borderRadius: 59, backgroundColor: withAlpha(colors.cyan, 0.12), overflow: 'hidden', alignItems: 'center', justifyContent: 'center', marginBottom: 16 }}
                                        >
                                            {foundUser.profileImage ? (
                                                <Image source={{ uri: foundUser.profileImage }} style={{ width: 118, height: 118 }} />
                                            ) : (
                                                <ContactsIcon size={58} color={colors.cyan} focused />
                                            )}
                                        </SafeLiquidGlass>

                                        <Text style={{ fontSize: 30, fontWeight: '700', letterSpacing: -0.6, color: colors.text }}>
                                            {contactDisplayName}
                                        </Text>

                                        <Text style={{ fontSize: 18, fontWeight: '500', color: colors.primary, marginTop: 4 }}>
                                            @{foundUser.username}
                                        </Text>

                                        {foundUser.isAgent ? (
                                            <View style={{ marginTop: 10, paddingHorizontal: 10, paddingVertical: 5, borderRadius: 999, backgroundColor: withAlpha(colors.primary, 0.14) }}>
                                                <Text style={{ fontSize: 12, fontWeight: '700', color: colors.primary }}>
                                                    Agent{foundUser.agentId ? ` • ${foundUser.agentId.slice(0, 8)}` : ''}
                                                </Text>
                                            </View>
                                        ) : null}

                                        {foundUser.phoneNumber && (
                                            <Text style={{ fontSize: 14, color: colors.textSecondary, marginTop: 10 }}>
                                                {foundUser.phoneNumber}
                                            </Text>
                                        )}
                                    </View>

                                    {/* Action Pills */}
                                    <View style={{ flexDirection: 'row', gap: 8, marginBottom: 20 }}>
                                        <ActionPill
                                            icon={<MessageCircle />}
                                            label="Message"
                                            onPress={handleMessage}
                                        />
                                        <ActionPill
                                            icon={<Phone />}
                                            label="Call"
                                            onPress={() => showToast('Coming soon!', 'info')}
                                        />
                                        {/* Added UserPlus Action Pill for Contact Addition */}
                                        <ActionPill
                                            icon={<UserPlus />}
                                            label="Add Contact"
                                            success={isAdded}
                                            successLabel="Added"
                                            onPress={() => handleSaveContact(false)}
                                        />
                                    </View>
                                </View>
                            ) : (
                                <View style={{ paddingTop: 30, alignItems: 'center' }}>
                                    <Text style={{ color: colors.textSecondary }}>No user selected</Text>
                                </View>
                            )}
                        </View>
                    </Animated.View>
                </Animated.View>
            </View>
        </View>
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
        width: '100%',
    },
    handleContainer: {
        width: '100%',
        alignItems: 'center',
        paddingTop: 16,
        paddingBottom: 8,
    },
    handle: {
        width: 40,
        height: 5,
        borderRadius: 3,
    },
    header: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 16,
        paddingBottom: 16,
    },
    title: {
        fontSize: 18,
        fontWeight: '700',
        letterSpacing: -0.3,
    },
    headerGlassBtn: {
        paddingHorizontal: 14,
        paddingVertical: 8,
        borderRadius: 14,
        overflow: 'hidden',
        justifyContent: 'center',
        alignItems: 'center',
    },
    headerBtnText: {
        fontSize: 16,
        fontWeight: '700',
    },
    contentContainer: { flex: 1, overflow: 'hidden' },
    slider: { flexDirection: 'row', width: SCREEN_WIDTH * 2 },
    page: { width: SCREEN_WIDTH, paddingBottom: 24, paddingHorizontal: 16 },

    sectionWrapper: { marginTop: 14 },
    sectionHeader: { fontSize: 13, fontWeight: '600', marginBottom: 8, marginLeft: 12, opacity: 0.6, letterSpacing: 0.5, textTransform: 'uppercase' },
    sectionContainer: { borderRadius: 23, overflow: 'hidden' },
    glassBtnCircle: { width: 44, height: 44, borderRadius: 22, overflow: 'hidden', alignItems: 'center', justifyContent: 'center' },
    iconBtnCircle: { width: 44, height: 44, alignItems: 'center', justifyContent: 'center' },
    glassCard: { width: '100%', borderRadius: 23, overflow: 'hidden' },

    row: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 20, height: 46 },
    rowLabel: { fontSize: 16, fontWeight: '500', width: 98 },
    rowInput: { flex: 1, fontSize: 16, fontWeight: '500', paddingVertical: 0, height: '100%' },
    rowValue: { flex: 1, fontSize: 15, fontWeight: '500', textAlign: 'right' },
    divider: { height: 1, marginLeft: 20 },

    errorText: {
        color: '#ff4b4b',
        marginTop: 12,
        marginLeft: 12,
        fontWeight: '600'
    },
    avatar: {
        width: 52,
        height: 52,
        borderRadius: 26,
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'hidden',
    },
    avatarImg: {
        width: '100%',
        height: '100%',
    },
    inlineFoundBadge: {
        flexDirection: 'row',
        alignItems: 'center',
        backgroundColor: 'rgba(43, 112, 255, 0.1)',
        paddingHorizontal: 12,
        paddingVertical: 6,
        borderRadius: 16,
        gap: 6,
        marginTop: 8,
    },
    inlineFoundText: {
        fontSize: 14,
        fontWeight: '700',
    },

    profileHeader: {
        alignItems: 'center',
        marginBottom: 8,
    },
    profileAvatar: {
        width: 90,
        height: 90,
        borderRadius: 45,
        alignItems: 'center',
        justifyContent: 'center',
        marginBottom: 16,
        overflow: 'hidden',
    },
    fullImage: {
        width: '100%',
        height: '100%',
    },
    profileAvatarText: {
        fontSize: 36,
        fontWeight: '700',
    },
    profileName: {
        fontSize: 24,
        fontWeight: '700',
        marginBottom: 4,
    },
    tagText: {
        fontSize: 15,
        fontWeight: '500',
    },

    settingRow: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingVertical: 14,
        paddingHorizontal: 16,
        minHeight: 52,
    },
    settingIconContainer: {
        width: 32,
        height: 32,
        borderRadius: 8,
        alignItems: 'center',
        justifyContent: 'center',
        marginRight: 12
    },
    settingLabel: {
        fontSize: 16,
        fontWeight: '500',
        flex: 1,
    },
    miniInput: {
        height: 46,
        borderRadius: 23,
        paddingHorizontal: 12,
        fontSize: 16,
    },
    saveBtn: {
        marginTop: 8,
        height: 46,
        borderRadius: 23,
        alignItems: 'center',
        justifyContent: 'center'
    },
    onlineIndicator: {
        width: 10,
        height: 10,
        borderRadius: 5,
    },

    // Additional styles
    tagBadge: { marginTop: 4 },
    nameSection: { alignItems: 'center' },
    newActionGrid: { flexDirection: 'row', gap: 10 },
    gridActionBtn: { alignItems: 'center' },
    gridActionInner: { width: 40, height: 40, borderRadius: 20 },
    gridActionLabel: { fontSize: 12 },
});
