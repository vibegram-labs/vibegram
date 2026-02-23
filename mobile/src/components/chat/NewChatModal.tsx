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
import { useAuthStore } from '../../lib/stores/auth-store';
import { X, MessageCircle, Phone, UserCheck, Check, Search, ArrowLeft, ArrowRight, ChevronLeft, ChevronRight, UserPlus, UserMinus, User } from 'lucide-react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { LayoutAnimation, Platform, UIManager } from 'react-native';

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

export default function NewChatModal({ onClose, onFullClose }: NewChatModalProps) {
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const { colors, effectiveTheme } = useThemeStore();
    const { user: currentUser } = useAuthStore();
    const { upsertContact, isContact } = useContactStore();
    const { chats, setActiveChat, updateChatFriendInfoByFriendId } = useChatStore();
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
    const [isAddingContact, setIsAddingContact] = useState(false);

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

    // Slide to user card page
    const goToCard = () => {
        Keyboard.dismiss();
        if (!foundUser?.userId) return;

        // No longer saving here automatically
        setView('card');
        contentTranslateX.value = withTiming(-SCREEN_WIDTH, SMOOTH_TIMING);
        headerProgress.value = withTiming(1, SMOOTH_TIMING);
    };

    const handleSaveContact = () => {
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

        showToast('Saved to contacts', 'success');
    };

    const goBackToSearch = () => {
        setView('search');
        setIsAddingContact(false); // Reset add contact state
        setFirstName('');
        setLastName('');
        contentTranslateX.value = withTiming(0, SMOOTH_TIMING);
        headerProgress.value = withTiming(0, SMOOTH_TIMING);
    };

    const handleMessage = () => {
        if (!foundUser?.userId) return;

        const friendId = foundUser.userId;
        const friendName = contactDisplayName;
        const friendImage = foundUser.profileImage || '';
        const friendPublicKey = foundUser.publicKey || '';
        const existingChat = chats.find(c => (c.friendId || '').toUpperCase() === friendId.toUpperCase());

        // Close modal first (slide down)
        if (onFullClose) {
            onFullClose();
        } else {
            handleCloseInternal();
        }

        // Wait for animation to finish then navigate
        setTimeout(() => {
            if (existingChat?.chatId) {
                setActiveChat(existingChat.chatId);
                router.push({ pathname: '/chat', params: { id: existingChat.chatId } });
            } else {
                router.push({
                    pathname: '/chat',
                    params: { friendId, friendName, friendImage, friendPublicKey }
                });
            }
        }, 300);
    };

    const sliderStyle = useAnimatedStyle(() => ({
        transform: [{ translateX: contentTranslateX.value }],
    }));

    return (
        <View style={styles.container}>
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
                    style={[styles.glassBtnCircle, { opacity: (view === 'search' && (!foundUser || loading)) ? 0.3 : 1 }]}
                    blurIntensity={15}
                    tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                >
                    <TouchableOpacity
                        onPress={view === 'search' ? goToCard : handleMessage}
                        disabled={view === 'search' && (!foundUser || loading)}
                        style={styles.iconBtnCircle}
                        activeOpacity={0.85}
                    >
                        {view === 'card' ? (
                            <Check size={20} color={colors.primary} strokeWidth={2.5} />
                        ) : (
                            <ArrowRight size={20} color={colors.primary} strokeWidth={2.5} />
                        )}
                    </TouchableOpacity>
                </SafeLiquidGlass>
            </View>

            <View style={styles.contentContainer}>
                <Animated.View style={[styles.slider, sliderStyle]}>
                    {/* --- PAGE 0: SEARCH --- */}
                    <Animated.View entering={FadeIn} style={[styles.page, { width: SCREEN_WIDTH }]}>
                        {/* Search input */}
                        <View style={styles.sectionWrapper}>
                            <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>FIND USER</Text>
                            <View style={styles.sectionContainer}>
                                <SafeLiquidGlass
                                    style={[styles.glassCard, { borderWidth: 1, borderColor: withAlpha(colors.text, 0.05) }]}
                                    blurIntensity={10}
                                    tint={isDark ? 'dark' : 'light'}
                                >
                                    <View style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(colors.card, 0.5) }]} />
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
                                </SafeLiquidGlass>
                            </View>

                            {error ? <Text style={styles.errorText}>{error}</Text> : null}
                        </View>

                        {/* Found User Result */}
                        {!!foundUser && (
                            <Animated.View entering={FadeIn.duration(400)} style={{ marginTop: 32, alignItems: 'center' }}>
                                <View style={[styles.avatar, { backgroundColor: colors.primary, width: 80, height: 80, borderRadius: 40, marginBottom: 16 }]}>
                                    {foundUser.profileImage ? (
                                        <Image source={{ uri: foundUser.profileImage }} style={styles.avatarImg} />
                                    ) : (
                                        <Text style={{ fontSize: 32, fontWeight: '700', color: '#fff' }}>
                                            {(foundUser.username || '?')[0].toUpperCase()}
                                        </Text>
                                    )}
                                </View>
                                <Text style={{ fontSize: 20, fontWeight: '700', color: colors.text, marginBottom: 4 }}>
                                    {foundUser.username}
                                </Text>
                                <View style={styles.inlineFoundBadge}>
                                    <Check size={14} color={colors.primary} strokeWidth={3} />
                                    <Text style={[styles.inlineFoundText, { color: colors.primary }]}>User Available</Text>
                                </View>
                            </Animated.View>
                        )}
                    </Animated.View>

                    {/* --- PAGE 1: USER CARD --- */}
                    <Animated.View entering={FadeIn} style={[styles.page, { width: SCREEN_WIDTH }]}>
                        <View style={{ paddingHorizontal: 16 }}>
                            {!!foundUser ? (
                                <View style={{ paddingTop: 24 }}>
                                    {/* Profile Header */}
                                    <View style={styles.profileHeader}>
                                        <View style={[styles.profileAvatar, { backgroundColor: withAlpha(colors.primary, 0.1) }]}>
                                            {foundUser.profileImage ? (
                                                <Image source={{ uri: foundUser.profileImage }} style={styles.fullImage} />
                                            ) : (
                                                <Text style={[styles.profileAvatarText, { color: colors.primary }]}>
                                                    {(contactDisplayName || '?').substring(0, 1).toUpperCase()}
                                                </Text>
                                            )}
                                        </View>
                                        <Text style={[styles.profileName, { color: colors.text }]} numberOfLines={1}>
                                            {contactDisplayName}
                                        </Text>
                                        <Text style={[styles.tagText, { color: colors.textSecondary }]}>@{foundUser.username}</Text>
                                    </View>

                                    {/* Actions Section */}
                                    <View style={[styles.sectionWrapper, { marginTop: 20 }]}>
                                        <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>ACTIONS</Text>
                                        <View style={styles.sectionContainer}>
                                            <View style={[styles.glassCard, { backgroundColor: colors.card }]}>
                                                <TouchableOpacity onPress={handleMessage} style={styles.settingRow}>
                                                    <View style={[styles.settingIconContainer, { backgroundColor: withAlpha(colors.primary, 0.1) }]}>
                                                        <MessageCircle size={20} color={colors.primary} strokeWidth={2} />
                                                    </View>
                                                    <Text style={[styles.settingLabel, { color: colors.text }]}>Chat</Text>
                                                    <ChevronRight size={18} color={colors.textSecondary} />
                                                </TouchableOpacity>

                                                <View style={[styles.divider, { backgroundColor: withAlpha(colors.text, 0.05) }]} />

                                                <TouchableOpacity onPress={() => showToast('Coming soon!', 'info')} style={styles.settingRow}>
                                                    <View style={[styles.settingIconContainer, { backgroundColor: withAlpha(colors.text, 0.05) }]}>
                                                        <Phone size={20} color={colors.text} strokeWidth={2} />
                                                    </View>
                                                    <Text style={[styles.settingLabel, { color: colors.text }]}>Call</Text>
                                                    <ChevronRight size={18} color={colors.textSecondary} />
                                                </TouchableOpacity>

                                                <View style={[styles.divider, { backgroundColor: withAlpha(colors.text, 0.05) }]} />

                                                {!isAdded && (
                                                    <View>
                                                        <TouchableOpacity
                                                            onPress={() => {
                                                                LayoutAnimation.configureNext(LayoutAnimation.Presets.easeInEaseOut);
                                                                setIsAddingContact(!isAddingContact);
                                                            }}
                                                            style={styles.settingRow}
                                                        >
                                                            <View style={[styles.settingIconContainer, { backgroundColor: withAlpha(colors.text, 0.05) }]}>
                                                                <UserPlus size={20} color={colors.text} strokeWidth={2} />
                                                            </View>
                                                            <Text style={[styles.settingLabel, { color: colors.text }]}>Add to Contacts</Text>
                                                            {isAddingContact ? null : <ChevronRight size={18} color={colors.textSecondary} />}
                                                        </TouchableOpacity>

                                                        {isAddingContact && (
                                                            <View style={{ padding: 16, backgroundColor: withAlpha(colors.background, 0.3) }}>
                                                                <Text style={{ fontSize: 13, color: colors.textSecondary, marginBottom: 8, fontWeight: '600' }}>FIRST NAME</Text>
                                                                <TextInput
                                                                    style={[styles.miniInput, { color: colors.text, backgroundColor: withAlpha(colors.text, 0.05) }]}
                                                                    value={firstName}
                                                                    onChangeText={setFirstName}
                                                                    placeholder="Required"
                                                                    placeholderTextColor={withAlpha(colors.text, 0.3)}
                                                                />
                                                                <Text style={{ fontSize: 13, color: colors.textSecondary, marginBottom: 8, marginTop: 12, fontWeight: '600' }}>LAST NAME</Text>
                                                                <TextInput
                                                                    style={[styles.miniInput, { color: colors.text, backgroundColor: withAlpha(colors.text, 0.05) }]}
                                                                    value={lastName}
                                                                    onChangeText={setLastName}
                                                                    placeholder="Optional"
                                                                    placeholderTextColor={withAlpha(colors.text, 0.3)}
                                                                />
                                                                <TouchableOpacity
                                                                    onPress={handleSaveContact}
                                                                    style={[styles.saveBtn, { backgroundColor: colors.primary }]}
                                                                >
                                                                    <Text style={{ color: '#fff', fontWeight: '600' }}>Save Contact</Text>
                                                                </TouchableOpacity>
                                                            </View>
                                                        )}
                                                    </View>
                                                )}

                                                {isAdded && (
                                                    <View style={styles.settingRow}>
                                                        <View style={[styles.settingIconContainer, { backgroundColor: withAlpha('#22c55e', 0.1) }]}>
                                                            <UserCheck size={20} color="#22c55e" strokeWidth={2} />
                                                        </View>
                                                        <Text style={[styles.settingLabel, { color: colors.text }]}>Already in Contacts</Text>
                                                    </View>
                                                )}
                                            </View>
                                        </View>
                                    </View>

                                    {/* Info section */}
                                    {foundUser.phoneNumber && (
                                        <View style={[styles.sectionWrapper, { marginTop: 20 }]}>
                                            <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>USER INFO</Text>
                                            <View style={styles.sectionContainer}>
                                                <View style={[styles.glassCard, { backgroundColor: colors.card }]}>
                                                    <View style={styles.row}>
                                                        <Text style={[styles.rowLabel, { color: colors.text }]}>Phone</Text>
                                                        <Text style={[styles.rowValue, { color: colors.textSecondary }]} numberOfLines={1}>
                                                            {foundUser.phoneNumber}
                                                        </Text>
                                                    </View>
                                                </View>
                                            </View>
                                        </View>
                                    )}
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
    sectionContainer: { borderRadius: 26, overflow: 'hidden' },
    glassBtnCircle: { width: 44, height: 44, borderRadius: 22, overflow: 'hidden', alignItems: 'center', justifyContent: 'center' },
    iconBtnCircle: { width: 44, height: 44, alignItems: 'center', justifyContent: 'center' },
    glassCard: { width: '100%', borderRadius: 26, overflow: 'hidden' },

    row: { flexDirection: 'row', alignItems: 'center', paddingVertical: 16, paddingHorizontal: 20, minHeight: 58 },
    rowLabel: { fontSize: 16, fontWeight: '500', width: 98 },
    rowInput: { flex: 1, fontSize: 16, fontWeight: '500', paddingVertical: 0 },
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
        height: 44,
        borderRadius: 10,
        paddingHorizontal: 12,
        fontSize: 16,
    },
    saveBtn: {
        marginTop: 8,
        height: 44,
        borderRadius: 10,
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
