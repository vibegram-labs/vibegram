
import React, { useState, useCallback, useMemo, useRef, useEffect } from 'react';
import { View, Text, StyleSheet, TouchableOpacity, FlatList, Image, TextInput, Pressable, Alert, ScrollView } from 'react-native';
import { useThemeStore } from '../../src/lib/stores/theme-store';
import { useCallStore, CallHistoryRecord } from '../../src/lib/stores/CallStore';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { BlurView } from 'expo-blur';
import MaskedView from '@react-native-masked-view/masked-view';
import { LinearGradient } from 'expo-linear-gradient';
import { Search, Phone, Video, PhoneIncoming, PhoneOutgoing, PhoneMissed, X, Trash2, Minus } from 'lucide-react-native';
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
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass';
import LottieView from 'lottie-react-native';
import Swipeable from 'react-native-gesture-handler/Swipeable';
import { Animated as RNAnimated } from 'react-native';
import { Stack } from 'expo-router';

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

const formatCallTime = (timestamp: number): string => {
    const date = new Date(timestamp);
    return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) + ' - ' + date.toLocaleDateString([], { month: 'short', day: 'numeric' });
};

const formatDuration = (seconds: number): string => {
    if (seconds <= 0) return '';
    const mins = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return mins > 0 ? `${mins}m ${secs}s` : `${secs}s`;
};

const dedupeCallHistory = (records: CallHistoryRecord[]): CallHistoryRecord[] => {
    const unique: CallHistoryRecord[] = [];
    const seen = new Set<string>();
    for (const record of records) {
        const id = typeof record.id === 'string' ? record.id.trim() : '';
        if (!id) {
            unique.push(record);
            continue;
        }
        if (seen.has(id)) continue;
        seen.add(id);
        unique.push(record);
    }
    return unique;
};

const callRecordKey = (record: CallHistoryRecord, index: number): string => {
    const id = typeof record.id === 'string' ? record.id.trim() : '';
    if (id.length > 0) return `${id}_${index}`;
    const ts = Number.isFinite(record.timestamp) ? record.timestamp : 0;
    const remoteId = (record.remoteUser?.userId || 'unknown').trim();
    return `call_${remoteId}_${ts}_${index}`;
};

interface CallRowProps {
    record: CallHistoryRecord;
    colors: any;
    theme: string;
    isEditing: boolean;
    onDelete: (id: string) => void;
}

const CallRow = React.memo(({ record, colors, theme, isEditing, onDelete }: CallRowProps) => {
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
            outputRange: [1, 1, 0],
            extrapolate: 'clamp',
        });

        return (
            <RNAnimated.View style={{ width: 80, transform: [{ translateX: trans }] }}>
                <TouchableOpacity
                    onPress={() => onDelete(record.id)}
                    style={[styles.swipeAction, { backgroundColor: '#ef4444', flex: 1 }]}
                >
                    <RNAnimated.View style={{ transform: [{ scale: iconScale }] }}>
                        <Trash2 color="white" size={22} />
                    </RNAnimated.View>
                </TouchableOpacity>
            </RNAnimated.View>
        );
    };

    const DirectionIcon = record.status === 'missed' ? PhoneMissed : record.direction === 'incoming' ? PhoneIncoming : PhoneOutgoing;
    const directionColor = record.status === 'missed' ? '#ef4444' : record.direction === 'incoming' ? '#34d399' : colors.primary;

    return (
        <View style={{ marginVertical: 1 }}>
            <View style={[StyleSheet.absoluteFill, { justifyContent: 'center', paddingLeft: 16 }]}>
                <TouchableOpacity onPress={() => onDelete(record.id)}>
                    <View style={{ width: 24, height: 24, borderRadius: 12, backgroundColor: '#ef4444', alignItems: 'center', justifyContent: 'center' }}>
                        <Minus size={14} color="#fff" strokeWidth={3} />
                    </View>
                </TouchableOpacity>
            </View>

            <Animated.View style={[{ flex: 1 }, rStyle]}>
                <Swipeable renderRightActions={renderRightActions} friction={2} rightThreshold={40} onSwipeableWillOpen={() => Haptics.selectionAsync()} containerStyle={{ overflow: 'visible' }} enabled={!isEditing}>
                    <Pressable style={({ pressed }) => [styles.callRow, { backgroundColor: pressed ? withAlpha(colors.text, 0.05) : 'transparent', borderBottomColor: withAlpha(colors.text, 0.03) }]}>
                        <View style={styles.avatarContainer}>
                            <SafeLiquidGlass style={styles.avatarGlass} blurIntensity={10} tint={theme === 'dark' ? 'dark' : 'light'}>
                                {record.remoteUser.userImage ? <Image source={{ uri: record.remoteUser.userImage }} style={styles.avatarImage} /> :
                                    <View style={styles.avatarPlaceholder}><Text style={[styles.avatarText, { color: colors.text }]}>{(record.remoteUser.userName || '?').substring(0, 1).toUpperCase()}</Text></View>}
                            </SafeLiquidGlass>
                        </View>
                        <View style={styles.callInfo}>
                            <Text style={[styles.callName, { color: record.status === 'missed' ? '#ef4444' : colors.text }]} numberOfLines={1}>{record.remoteUser.userName}</Text>
                            <View style={{ flexDirection: 'row', alignItems: 'center', marginTop: 3 }}>
                                <DirectionIcon size={13} color={directionColor} strokeWidth={2.5} />
                                <Text style={[styles.callMeta, { color: colors.textSecondary, marginLeft: 4 }]}>
                                    {record.status === 'missed' ? 'Missed' : (record.duration > 0 ? formatDuration(record.duration) : record.direction)}
                                </Text>
                            </View>
                        </View>
                        <View style={styles.callRight}>
                            <Text style={[styles.callTime, { color: colors.textSecondary }]}>{formatCallTime(record.timestamp)}</Text>
                            <View style={{ marginTop: 4 }}>
                                {record.type === 'video' ? <Video size={18} color={colors.primary} /> : <Phone size={18} color={colors.primary} />}
                            </View>
                        </View>
                    </Pressable>
                </Swipeable>
            </Animated.View>
        </View>
    );
});

export default function CallsScreen() {
    const { colors, effectiveTheme } = useThemeStore();
    const insets = useSafeAreaInsets();
    const callHistory = useCallStore(s => s.callHistory || []);
    const deleteCallRecord = useCallStore(s => s.deleteCallRecord);
    const clearHistory = useCallStore(s => s.clearHistory);

    const [searchQuery, setSearchQuery] = useState('');
    const [isSearchActive, setIsSearchActive] = useState(false);
    const [isEditing, setIsEditing] = useState(false);

    const scrollY = useSharedValue(0);
    const searchFocusProgress = useSharedValue(0);
    const searchInputRef = useRef<TextInput>(null);

    const scrollHandler = useAnimatedScrollHandler((e) => { scrollY.value = e.contentOffset.y; });

    const stableCallHistory = useMemo(() => dedupeCallHistory(callHistory), [callHistory]);

    const filteredCalls = useMemo(() => {
        const q = searchQuery.toLowerCase().trim();
        if (!q) return stableCallHistory;
        return stableCallHistory.filter(c => c.remoteUser.userName.toLowerCase().includes(q));
    }, [stableCallHistory, searchQuery]);

    const handleSearchFocus = () => {
        setIsSearchActive(true);
        Haptics.selectionAsync();
        searchFocusProgress.value = withTiming(1, { duration: 350, easing: Easing.bezier(0.33, 1, 0.68, 1) });
        setTimeout(() => searchInputRef.current?.focus(), 50);
    };

    const handleSearchClose = () => {
        searchFocusProgress.value = withTiming(0, { duration: 250 }, () => { runOnJS(setIsSearchActive)(false); });
        searchInputRef.current?.blur();
        setSearchQuery('');
    };

    const searchInputOverlayStyle = useAnimatedStyle(() => {
        const targetY = insets.top + 10;
        const opacity = interpolate(searchFocusProgress.value, [0, 0.15], [0, 1], Extrapolate.CLAMP);
        return {
            position: 'absolute', top: 0, left: 0, right: 0, zIndex: 4000, height: 44, opacity,
            transform: [{ translateY: interpolate(searchFocusProgress.value, [0, 1], [targetY - 20, targetY], Extrapolate.CLAMP) }],
            paddingHorizontal: 20,
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
        <View style={[styles.container, { backgroundColor: colors.background }]}>
            <Stack.Screen options={{ headerShown: false }} />

            {/* Search Overlay Result List */}
            <Animated.View style={[StyleSheet.absoluteFill, { backgroundColor: colors.background, zIndex: 3000 }, searchOverlayStyle]}>
                <View style={{ flex: 1, paddingTop: insets.top + 70 }}>
                    {searchQuery === '' && stableCallHistory.length > 0 && (
                        <View style={{ paddingHorizontal: 20, marginBottom: 15 }}>
                            <Text style={{ color: colors.textSecondary, fontSize: 13, textTransform: 'uppercase', letterSpacing: 0.5, marginBottom: 10 }}>Recent Calls</Text>
                            <ScrollView horizontal showsHorizontalScrollIndicator={false}>
                                {stableCallHistory.slice(0, 5).map((c, index) => (
                                    <TouchableOpacity key={callRecordKey(c, index)} style={{ marginRight: 15, alignItems: 'center' }}>
                                        <SafeLiquidGlass style={{ width: 50, height: 50, borderRadius: 25, overflow: 'hidden' }} blurIntensity={10} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                                            {c.remoteUser.userImage ? <Image source={{ uri: c.remoteUser.userImage }} style={{ width: 50, height: 50 }} /> :
                                                <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: withAlpha(colors.text, 0.05) }}><Text style={{ color: colors.text }}>{(c.remoteUser.userName || '?').substring(0, 1).toUpperCase()}</Text></View>}
                                        </SafeLiquidGlass>
                                        <Text style={{ color: colors.text, fontSize: 11, marginTop: 4, maxWidth: 60 }} numberOfLines={1}>{c.remoteUser.userName}</Text>
                                    </TouchableOpacity>
                                ))}
                            </ScrollView>
                        </View>
                    )}
                    <FlatList
                        data={filteredCalls}
                        keyExtractor={(item, index) => callRecordKey(item, index)}
                        renderItem={({ item }) => <CallRow record={item} colors={colors} theme={effectiveTheme} isEditing={false} onDelete={deleteCallRecord} />}
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
                        <TextInput ref={searchInputRef} style={[styles.searchInput, { color: colors.text }]} placeholder="Search calls..." placeholderTextColor={colors.textSecondary} value={searchQuery} onChangeText={setSearchQuery} />
                        {searchQuery.length > 0 && <TouchableOpacity onPress={() => setSearchQuery('')} style={{ padding: 10 }}><X size={16} color={colors.textSecondary} /></TouchableOpacity>}
                    </SafeLiquidGlass>
                    <TouchableOpacity onPress={handleSearchClose} style={{ marginLeft: 10, height: '100%', justifyContent: 'center' }}><Text style={{ color: colors.primary, fontWeight: '600' }}>Cancel</Text></TouchableOpacity>
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
                    <TouchableOpacity onPress={handleSearchFocus} style={styles.iconBtnCircle}><Search size={20} color={colors.text} /></TouchableOpacity>
                    <View style={{ width: 1, height: 18, backgroundColor: withAlpha(colors.text, 0.1) }} />
                    <TouchableOpacity onPress={() => setIsEditing(!isEditing)} style={styles.textBtnTouchPadding}>
                        <Text style={[styles.headerTextBtn, { color: colors.text }]}>{isEditing ? 'Done' : 'Edit'}</Text>
                    </TouchableOpacity>
                </SafeLiquidGlass>

                <Text style={[styles.headerTitle, { color: colors.text }]}>Calls</Text>

                {isEditing ? (
                    <SafeLiquidGlass style={styles.glassBtnSmall} blurIntensity={15} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                        <TouchableOpacity onPress={clearHistory} style={styles.textBtnTouch}><Text style={[styles.headerTextBtn, { color: '#ef4444' }]}>Clear</Text></TouchableOpacity>
                    </SafeLiquidGlass>
                ) : <View style={{ width: 60 }} />}
            </Animated.View>

            <Animated.ScrollView onScroll={scrollHandler} scrollEventThrottle={16} contentContainerStyle={{ paddingTop: insets.top + 60, paddingBottom: 100 }} showsVerticalScrollIndicator={false}>
                {stableCallHistory.length > 0 ? (
                    <View style={styles.listContainer}>
                        {stableCallHistory.map((record, index) => <CallRow key={callRecordKey(record, index)} record={record} colors={colors} theme={effectiveTheme} isEditing={isEditing} onDelete={deleteCallRecord} />)}
                    </View>
                ) : (
                    <View style={styles.emptyContainer}>
                        <LottieView source={require('../../src/lottie/Potato.json')} autoPlay loop style={styles.lottiePotato} />
                        <Text style={[styles.emptyTitle, { color: colors.text }]}>No Recent Calls</Text>
                        <Text style={[styles.emptySubtitle, { color: colors.textSecondary }]}>Your call history will appear here</Text>
                    </View>
                )}
            </Animated.ScrollView>
        </View>
    );
}

const styles = StyleSheet.create({
    container: { flex: 1 },
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
    callRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 12, paddingHorizontal: 16 },
    avatarContainer: { marginRight: 12 },
    avatarGlass: { width: 50, height: 50, borderRadius: 25, overflow: 'hidden' },
    avatarImage: { width: '100%', height: '100%' },
    avatarPlaceholder: { flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(127,127,127,0.1)' },
    avatarText: { fontSize: 18, fontWeight: '700' },
    callInfo: { flex: 1 },
    callName: { fontSize: 17, fontWeight: '600' },
    callMeta: { fontSize: 13 },
    callRight: { alignItems: 'flex-end', marginLeft: 10 },
    callTime: { fontSize: 13 },
    emptyContainer: { flex: 1, alignItems: 'center', justifyContent: 'center', marginTop: 80 },
    lottiePotato: { width: 200, height: 200 },
    emptyTitle: { fontSize: 20, fontWeight: '700', marginTop: 20 },
    emptySubtitle: { fontSize: 16, marginTop: 8, textAlign: 'center', paddingHorizontal: 40 },
    swipeAction: { alignItems: 'center', justifyContent: 'center' },
});
