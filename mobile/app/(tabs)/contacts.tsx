
import React, { useState, useCallback, useMemo, useRef, useEffect } from 'react';
import { View, Text, StyleSheet, FlatList, TouchableOpacity, TextInput, Image, Pressable, Alert, ScrollView, ActivityIndicator } from 'react-native';
import { useThemeStore } from '../../src/lib/stores/theme-store';
import { useContactStore } from '../../src/lib/stores/contact-store';
import { useChatStore } from '../../src/lib/ChatStore';
import { Search, User, MessageCircle, X, Trash2, Minus } from 'lucide-react-native';
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useRouter, Stack } from 'expo-router';
import MaskedView from '@react-native-masked-view/masked-view';
import { LinearGradient } from 'expo-linear-gradient';
import { BlurView } from 'expo-blur';
import Animated, {
    useAnimatedScrollHandler,
    useSharedValue,
    useAnimatedStyle,
    interpolate,
    Extrapolate,
    FadeIn,
    FadeOut,
    withTiming,
    Easing,
    runOnJS,
} from 'react-native-reanimated';
import * as Haptics from 'expo-haptics';
import Swipeable from 'react-native-gesture-handler/Swipeable';
import { Animated as RNAnimated } from 'react-native';
import { syncContactsWithServer } from '../../src/lib/contact-sync';
import DefaultAvatar from '../../src/components/avatar/DefaultAvatar';

const withAlpha = (color: string, alpha: number): string => {
    if (!color) return `rgba(127, 127, 127, ${alpha})`;
    if (color.startsWith('#')) {
        const hex = color.replace('#', '');
        const r = parseInt(hex.substring(0, 2), 16);
        const g = parseInt(hex.substring(2, 4), 16);
        const b = parseInt(hex.substring(4, 6), 16);
        return `rgba(${r}, ${g}, ${b}, ${alpha})`;
    }
    return color;
};

interface ContactRowProps {
    contact: any;
    colors: any;
    theme: string;
    onPress: (contact: any) => void;
    onDelete: (contact: any) => void;
    isEditing: boolean;
    isSelected: boolean;
}

const ContactRow = React.memo(({ contact, colors, theme, onPress, onDelete, isEditing, isSelected }: ContactRowProps) => {
    const shiftX = useSharedValue(0);

    useEffect(() => {
        shiftX.value = withTiming(isEditing ? 44 : 0, {
            duration: 250,
            easing: Easing.bezier(0.33, 1, 0.68, 1)
        });
    }, [isEditing]);

    const rStyle = useAnimatedStyle(() => ({
        transform: [{ translateX: shiftX.value }]
    }));

    const renderRightActions = (progress: any, dragX: any) => {
        if (isEditing) return null;
        const trans = dragX.interpolate({
            inputRange: [-80, 0],
            outputRange: [0, 80],
        });
        const iconScale = dragX.interpolate({
            inputRange: [-80, -40, 0],
            outputRange: [1, 0.5, 0.01],
            extrapolate: 'clamp',
        });

        return (
            <RNAnimated.View style={{ width: 80, transform: [{ translateX: trans }] }}>
                <TouchableOpacity
                    onPress={() => onDelete(contact)}
                    style={[styles.swipeAction, { backgroundColor: '#ef4444', flex: 1 }]}
                >
                    <RNAnimated.View style={{ transform: [{ scale: iconScale }] }}>
                        <Trash2 color="white" size={22} />
                    </RNAnimated.View>
                </TouchableOpacity>
            </RNAnimated.View>
        );
    };

    return (
        <View style={{ marginVertical: 1 }}>
            <View style={[StyleSheet.absoluteFill, { justifyContent: 'center', paddingLeft: 16 }]}>
                <TouchableOpacity onPress={() => onDelete(contact)}>
                    <View style={{
                        width: 24, height: 24, borderRadius: 12,
                        backgroundColor: '#ef4444',
                        alignItems: 'center', justifyContent: 'center',
                    }}>
                        <Minus size={14} color="#fff" strokeWidth={3} />
                    </View>
                </TouchableOpacity>
            </View>

            <Animated.View style={[{ flex: 1 }, rStyle]}>
                <Swipeable
                    renderRightActions={renderRightActions}
                    friction={2}
                    rightThreshold={40}
                    onSwipeableWillOpen={() => Haptics.selectionAsync()}
                    containerStyle={{ overflow: 'visible' }}
                    enabled={!isEditing}
                >
                    <Pressable
                        onPress={() => onPress(contact)}
                        style={({ pressed }) => [
                            styles.contactRow,
                            {
                                backgroundColor: pressed ? withAlpha(colors.text, 0.05) : 'transparent',
                                borderBottomColor: withAlpha(colors.text, 0.03),
                            }
                        ]}
                    >
                        <View style={[styles.avatarContainer, { zIndex: 3, elevation: 3 }]}>
                            {contact.profileImage ? (
                                <Image source={{ uri: contact.profileImage }} style={styles.avatarImage} />
                            ) : (
                                <DefaultAvatar seed={contact.id || contact.username} theme={theme} size={60} />
                            )}
                        </View>
                        <View style={styles.contactInfo}>
                            <Text style={[styles.contactName, { color: colors.text }]} numberOfLines={1}>
                                {contact.username}
                            </Text>
                            {contact.phoneNumber && (
                                <Text style={[styles.contactStatus, { color: colors.textSecondary }]} numberOfLines={1}>
                                    {contact.phoneNumber}
                                </Text>
                            )}
                        </View>
                        <View style={styles.accessory}>
                            <MessageCircle size={18} color={withAlpha(colors.text, 0.2)} />
                        </View>
                    </Pressable>
                </Swipeable>
            </Animated.View>
        </View>
    );
});

export default function ContactsScreen() {
    const { colors, effectiveTheme } = useThemeStore();
    const { contacts, removeContact } = useContactStore();
    const { startChat, setActiveChat } = useChatStore();
    const insets = useSafeAreaInsets();
    const router = useRouter();

    const [searchQuery, setSearchQuery] = useState('');
    const [isSearchActive, setIsSearchActive] = useState(false);
    const [isEditing, setIsEditing] = useState(false);
    const [isSyncingContacts, setIsSyncingContacts] = useState(false);

    const scrollY = useSharedValue(0);
    const searchFocusProgress = useSharedValue(0);
    const searchInputRef = useRef<TextInput>(null);

    const scrollHandler = useAnimatedScrollHandler((event) => {
        scrollY.value = event.contentOffset.y;
    });

    const filtered = useMemo(() => {
        const q = searchQuery.toLowerCase().trim();
        if (!q) return contacts;
        return contacts.filter(c =>
            c.username.toLowerCase().includes(q) ||
            (c.phoneNumber && c.phoneNumber.includes(q))
        );
    }, [contacts, searchQuery]);

    const handleSearchFocus = () => {
        setIsSearchActive(true);
        Haptics.selectionAsync();
        searchFocusProgress.value = withTiming(1, {
            duration: 350,
            easing: Easing.bezier(0.33, 1, 0.68, 1)
        });
        setTimeout(() => searchInputRef.current?.focus(), 50);
    };

    const handleSearchClose = () => {
        searchFocusProgress.value = withTiming(0, { duration: 250 }, () => {
            runOnJS(setIsSearchActive)(false);
        });
        searchInputRef.current?.blur();
        setSearchQuery('');
    };

    const handleContactPress = async (contact: any) => {
        if (isEditing) return;
        try {
            const { chats } = useChatStore.getState();
            const existingChat = chats.find(c => c.friendId === contact.id);
            if (existingChat) {
                setActiveChat(existingChat.chatId);
                router.push('/chat');
            } else {
                const chatId = await startChat(contact.id, {
                    username: contact.username,
                    profileImage: contact.profileImage
                });
                if (chatId) {
                    setActiveChat(chatId);
                    router.push('/chat');
                }
            }
        } catch (e) {
            console.error('[ContactsScreen] Failed to start chat:', e);
        }
    };

    const handleDeleteContact = (contact: any) => {
        Alert.alert('Delete Contact', `Remove ${contact.username}?`, [
            { text: 'Cancel', style: 'cancel' },
            { text: 'Delete', style: 'destructive', onPress: () => removeContact(contact.id) }
        ]);
    };

    const handleSyncContacts = async () => {
        if (isSyncingContacts) return;
        setIsSyncingContacts(true);
        try {
            const result = await syncContactsWithServer({ force: true, requestPermission: true });

            if (result.status === 'no_permission') {
                Alert.alert('Permission needed', 'Allow contacts access to discover friends automatically.');
                return;
            }

            if (result.status === 'no_phone_contacts') {
                Alert.alert('No phone contacts', 'No valid phone numbers were found in your contacts.');
                return;
            }

            if (result.status === 'ok') {
                Alert.alert('Contacts synced', `Scanned ${result.scanned} numbers and matched ${result.matched} users.`);
                return;
            }

            Alert.alert('Contacts', 'No sync was needed right now.');
        } catch (e: any) {
            Alert.alert('Sync failed', e?.message || 'Unable to sync contacts right now.');
        } finally {
            setIsSyncingContacts(false);
        }
    };

    const searchInputOverlayStyle = useAnimatedStyle(() => {
        const targetY = insets.top + 10;
        const opacity = interpolate(searchFocusProgress.value, [0, 0.15], [0, 1], Extrapolate.CLAMP);
        return {
            position: 'absolute',
            top: 0, left: 0, right: 0,
            transform: [{ translateY: interpolate(searchFocusProgress.value, [0, 1], [targetY - 20, targetY], Extrapolate.CLAMP) }],
            height: 44, opacity,
            paddingHorizontal: 20,
            zIndex: 4000,
        };
    });

    const searchOverlayStyle = useAnimatedStyle(() => ({
        opacity: searchFocusProgress.value,
        pointerEvents: isSearchActive ? 'auto' : 'none',
    }));

    const headerContentStyle = useAnimatedStyle(() => ({
        opacity: interpolate(searchFocusProgress.value, [0, 0.2], [1, 0], Extrapolate.CLAMP),
        transform: [{ translateY: interpolate(searchFocusProgress.value, [0, 1], [0, -10], Extrapolate.CLAMP) }]
    }));

    return (
        <View style={{ flex: 1, backgroundColor: colors.background }}>
            <Stack.Screen options={{ headerShown: false }} />

            {/* Search Overlay Result List */}
            <Animated.View style={[StyleSheet.absoluteFill, { backgroundColor: colors.background, zIndex: 3000 }, searchOverlayStyle]}>
                <View style={{ flex: 1, paddingTop: insets.top + 70 }}>
                    {searchQuery === '' && filtered.length > 0 && (
                        <View style={{ paddingHorizontal: 20, marginBottom: 15 }}>
                            <Text style={{ color: colors.textSecondary, fontSize: 13, textTransform: 'uppercase', letterSpacing: 0.5, marginBottom: 10 }}>Recent</Text>
                            <ScrollView horizontal showsHorizontalScrollIndicator={false}>
                                {filtered.slice(0, 5).map(c => (
                                    <TouchableOpacity key={c.id} style={{ marginRight: 15, alignItems: 'center' }} onPress={() => handleContactPress(c)}>
                                        {c.profileImage ? (
                                            <Image source={{ uri: c.profileImage }} style={styles.recentAvatarImage} />
                                        ) : (
                                            <DefaultAvatar
                                                seed={c.id || c.username}
                                                theme={effectiveTheme}
                                                size={60}
                                                style={styles.recentAvatarPlaceholder}
                                            />
                                        )}
                                        <Text style={{ color: colors.text, fontSize: 11, marginTop: 4, maxWidth: 60 }} numberOfLines={1}>{c.username}</Text>
                                    </TouchableOpacity>
                                ))}
                            </ScrollView>
                        </View>
                    )}
                    <FlatList
                        data={filtered}
                        keyExtractor={(item) => item.id}
                        renderItem={({ item }) => (
                            <ContactRow contact={item} colors={colors} theme={effectiveTheme} onPress={handleContactPress} onDelete={handleDeleteContact} isEditing={false} isSelected={false} />
                        )}
                        contentContainerStyle={{ paddingBottom: 100 }}
                        keyboardShouldPersistTaps="handled"
                    />
                </View>
            </Animated.View>

            {/* Fixed Search Input Overlay */}
            <Animated.View style={searchInputOverlayStyle}>
                <View style={{ flexDirection: 'row', alignItems: 'center', height: 44 }}>
                    <SafeLiquidGlass style={[styles.searchBar, { flex: 1 }]} blurIntensity={15} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                        <Search size={18} color={colors.textSecondary} style={{ marginLeft: 12 }} />
                        <TextInput ref={searchInputRef} style={[styles.searchInput, { color: colors.text }]} placeholder="Search contacts..." placeholderTextColor={colors.textSecondary} value={searchQuery} onChangeText={setSearchQuery} />
                        {searchQuery.length > 0 && (
                            <TouchableOpacity onPress={() => setSearchQuery('')} style={{ padding: 10 }}><X size={16} color={colors.textSecondary} /></TouchableOpacity>
                        )}
                    </SafeLiquidGlass>
                    <TouchableOpacity onPress={handleSearchClose} style={{ marginLeft: 10, height: '100%', justifyContent: 'center' }}>
                        <Text style={{ color: colors.primary, fontWeight: '600' }}>Cancel</Text>
                    </TouchableOpacity>
                </View>
            </Animated.View>

            {/* Header Overlay */}
            <View style={[styles.headerMaskContainer, { height: insets.top + 60 }]}>
                <MaskedView style={StyleSheet.absoluteFill} maskElement={<LinearGradient colors={['rgba(0,0,0,1)', 'rgba(0,0,0,0)']} locations={[0.8, 1]} style={StyleSheet.absoluteFill} />}>
                    <BlurView intensity={30} tint={effectiveTheme === 'dark' ? 'dark' : 'light'} style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(colors.background, 0.85) }]} />
                </MaskedView>
            </View>

            {/* Header Buttons */}
            <Animated.View style={[styles.headerContentContainer, { height: insets.top + 60, paddingTop: insets.top }, headerContentStyle]}>
                <SafeLiquidGlass style={styles.glassBtnRow} blurIntensity={15} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                    <TouchableOpacity onPress={handleSearchFocus} style={styles.iconBtnCircle}>
                        <Search size={20} color={colors.text} />
                    </TouchableOpacity>
                    <View style={{ width: 1, height: 18, backgroundColor: withAlpha(colors.text, 0.1) }} />
                    <TouchableOpacity onPress={() => setIsEditing(!isEditing)} style={styles.textBtnTouchPadding}>
                        <Text style={[styles.headerTextBtn, { color: colors.text }]}>{isEditing ? 'Done' : 'Edit'}</Text>
                    </TouchableOpacity>
                </SafeLiquidGlass>

                <Text style={[styles.headerTitle, { color: colors.text }]}>Contacts</Text>

                <SafeLiquidGlass style={styles.glassBtnSmall} blurIntensity={15} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                    <TouchableOpacity style={styles.textBtnTouch} onPress={handleSyncContacts} disabled={isSyncingContacts}>
                        {isSyncingContacts ? (
                            <ActivityIndicator size="small" color={colors.text} />
                        ) : (
                            <Text style={[styles.headerTextBtn, { color: colors.text }]}>Sync</Text>
                        )}
                    </TouchableOpacity>
                </SafeLiquidGlass>
            </Animated.View>

            <Animated.ScrollView onScroll={scrollHandler} scrollEventThrottle={16} contentContainerStyle={{ paddingTop: insets.top + 60, paddingBottom: 100 }} showsVerticalScrollIndicator={false}>
                <View style={styles.listContainer}>
                    {filtered.map((contact) => (
                        <ContactRow key={contact.id} contact={contact} colors={colors} theme={effectiveTheme} onPress={handleContactPress} onDelete={handleDeleteContact} isEditing={isEditing} isSelected={false} />
                    ))}
                    {filtered.length === 0 && (
                        <View style={styles.empty}>
                            <User size={48} color={colors.textSecondary} style={{ opacity: 0.3 }} />
                            <Text style={[styles.emptyText, { color: colors.textSecondary }]}>{searchQuery ? 'No matches found' : 'No contacts yet'}</Text>
                        </View>
                    )}
                </View>
            </Animated.ScrollView>
        </View>
    );
}

const styles = StyleSheet.create({
    headerMaskContainer: { position: 'absolute', top: 0, left: 0, right: 0, zIndex: 100 },
    headerContentContainer: { position: 'absolute', top: 0, left: 0, right: 0, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 16, zIndex: 110 },
    headerTitle: { fontSize: 17, fontWeight: '700', flex: 1, textAlign: 'center' },
    glassBtnSmall: { borderRadius: 20, overflow: 'hidden', height: 38, minWidth: 60 },
    glassBtnRow: { flexDirection: 'row', alignItems: 'center', borderRadius: 20, overflow: 'hidden', height: 38, paddingHorizontal: 4 },
    iconBtnCircle: { width: 34, height: 34, alignItems: 'center', justifyContent: 'center' },
    textBtnTouchPadding: { paddingHorizontal: 10, justifyContent: 'center' },
    textBtnTouch: { flex: 1, paddingHorizontal: 12, alignItems: 'center', justifyContent: 'center' },
    headerTextBtn: { fontSize: 15, fontWeight: '600' },
    searchBar: { flexDirection: 'row', alignItems: 'center', height: 44, borderRadius: 18, backgroundColor: 'rgba(127,127,127,0.1)', overflow: 'hidden' },
    searchInput: { flex: 1, height: '100%', paddingHorizontal: 10, justifyContent: 'center', fontSize: 16 },
    listContainer: { marginTop: 4 },
    contactRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 14, paddingHorizontal: 16 },
    avatarContainer: { marginRight: 14, width: 60, height: 60, borderRadius: 30, overflow: 'hidden' },
    avatarImage: { width: '100%', height: '100%', borderRadius: 30 },
    avatarPlaceholder: { width: '100%', height: '100%', alignItems: 'center', justifyContent: 'center', borderRadius: 30 },
    recentAvatarImage: { width: 60, height: 60, borderRadius: 30 },
    recentAvatarPlaceholder: { width: 60, height: 60, borderRadius: 30, alignItems: 'center', justifyContent: 'center' },
    contactInfo: { flex: 1 },
    contactName: { fontSize: 17, fontWeight: '600' },
    contactStatus: { fontSize: 13, marginTop: 1, opacity: 0.8 },
    accessory: { marginLeft: 10, opacity: 0.5 },
    empty: { alignItems: 'center', justifyContent: 'center', paddingTop: 100, gap: 16 },
    emptyText: { fontSize: 16, fontWeight: '500' },
    swipeAction: { alignItems: 'center', justifyContent: 'center' },
});
