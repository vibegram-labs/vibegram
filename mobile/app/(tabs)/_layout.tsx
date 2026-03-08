
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { View, Text, TouchableOpacity, StyleSheet, Platform, Dimensions, Keyboard, BackHandler, ActivityIndicator, DeviceEventEmitter } from 'react-native'
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    interpolate,
    runOnJS,
    Extrapolation,
    withTiming,
    Easing,
} from 'react-native-reanimated'
import { GestureHandlerRootView } from 'react-native-gesture-handler'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { useRouter } from 'expo-router'
import { useTranslation } from 'react-i18next'
import { useThemeStore } from '../../src/lib/stores/theme-store'
import { useUIStore } from '../../src/lib/stores/ui-store'
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass'
import NativeTabBar, { isNativeTabBarAvailable } from '../../src/components/native/NativeTabBar'
import AndroidBottomTabBar from '../../src/components/native/AndroidBottomTabBar'
import { useChatStore } from '../../src/lib/ChatStore'
import { useAuthStore } from '../../src/lib/stores/auth-store'
import { ContactsIcon, CallsIcon, SettingsIcon, VibeLogoIcon } from '../../src/components/Icons'
import DoubleChatIcon from '../../src/components/icons/DoubleChatIcon'
import HomeScreen from './home'
import SettingsScreen from './settings'
import ContactsScreen from './contacts'
import CallsScreen from './calls'
import { StoryCamera } from '../story-camera'
import { AgentChatScreen } from '../../src/components/agent'
import { useAgentStore } from '../../src/lib/agent/AgentStore'
import { BlurView } from 'expo-blur'
import { Image } from 'react-native'
import MaskedView from '@react-native-masked-view/masked-view'

const GestureHandlerRootViewAny = GestureHandlerRootView as any
const AnimatedView = Animated.View as any
const { width: SCREEN_WIDTH } = Dimensions.get('window')
const BOTTOM_BAR_HORIZONTAL_PADDING = 12
const BOTTOM_BAR_GAP = 8
const FALLBACK_PILL_HORIZONTAL_PADDING = 10
const FALLBACK_TAB_COUNT = 4


// Page Indices (4 swipeable pages - agent is now a root-level push screen)
const PAGES = {
    contacts: 0,
    calls: 1,
    home: 2,
    settings: 3,
    vibe: 4,
} as const;

type PageName = keyof typeof PAGES;

const normalizeProfileImageUri = (value?: string | null) => {
    if (!value) return undefined
    if (
        value.startsWith('http://')
        || value.startsWith('https://')
        || value.startsWith('file://')
        || value.startsWith('content://')
        || value.startsWith('data:')
    ) {
        return value
    }
    return `data:image/jpeg;base64,${value}`
}

const VibeButton = ({ onPress, isDark }: { onPress: () => void, isDark: boolean }) => {
    const size = 64;
    const borderRadius = size / 2;

    return (
        <TouchableOpacity
            onPress={onPress}
            activeOpacity={0.8}
            style={styles.vibeButtonContainer}
        >
            <SafeLiquidGlass
                style={[
                    styles.vibeButtonPill,
                    {
                        width: size,
                        height: size,
                        borderRadius,
                        backgroundColor: isDark ? 'rgba(18,20,28,0.6)' : 'rgba(244,248,255,0.66)',
                        borderColor: isDark ? 'rgba(255,255,255,0.13)' : 'rgba(10,18,32,0.11)',
                        borderWidth: 1,
                        overflow: 'hidden',
                    }
                ]}
                blurIntensity={18}
                effect="clear"
                tint="default"
                interactive
            >
                <View style={styles.vibeButtonInner}>
                    <MaskedView
                        style={styles.maskContainer}
                        maskElement={
                            <Image
                                source={require('../../assets/logos/logotransparent.png')}
                                style={styles.vibeLogo}
                            />
                        }
                    >
                        <View style={[
                            styles.maskColorFill,
                            { backgroundColor: isDark ? '#FFFFFF' : '#000000' }
                        ]} />
                    </MaskedView>
                </View>
            </SafeLiquidGlass>
        </TouchableOpacity>
    );
};

const PAGE_NAMES: PageName[] = ['contacts', 'calls', 'home', 'settings', 'vibe'];

const NativeTabsMemo = React.memo(function NativeTabsMemo({
    currentTab,
    handleTabPress,
    totalUnread,
    settingsIconSource,
    activeTintColor,
    inactiveTintColor,
    isDark,
    isVibeExpanded,
    onVibeSubmit,
    safeRouterPush,
    bottomBarFadeStyle,
    t,
}: {
    currentTab: PageName;
    handleTabPress: (page: PageName) => void;
    totalUnread: number;
    settingsIconSource: any;
    activeTintColor: string;
    inactiveTintColor: string;
    isDark: boolean;
    isVibeExpanded: boolean;
    onVibeSubmit: (text: string) => void;
    safeRouterPush: (path: string, source: string) => void;
    bottomBarFadeStyle: any;
    t: (key: string) => string;
}) {
    const nativeOnIndexChange = useCallback((index: number) => {
        const page = PAGE_NAMES[index];
        if (!page) return;
        handleTabPress(page);
    }, [handleTabPress]);

    const nativeOnVibePress = useCallback(() => {
        handleTabPress('vibe');
    }, [handleTabPress]);

    const nativeTabs = useMemo(() => [
        {
            key: 'contacts',
            title: t('tabs.contacts'),
            sfSymbol: 'person.2.fill',
            unfocusedSfSymbol: 'person.2',
        },
        {
            key: 'calls',
            title: t('tabs.calls'),
            sfSymbol: 'phone.fill',
            unfocusedSfSymbol: 'phone',
        },
        {
            key: 'home',
            title: t('tabs.chats'),
            sfSymbol: 'bubble.left.and.bubble.right.fill',
            unfocusedSfSymbol: 'bubble.left.and.bubble.right',
            badge: totalUnread > 0 ? (totalUnread > 99 ? '99+' : String(totalUnread)) : undefined,
        },
        {
            key: 'settings',
            title: t('tabs.settings'),
            sfSymbol: 'person.crop.circle.fill',
            unfocusedSfSymbol: 'person.crop.circle',
            iconSource: settingsIconSource,
            unfocusedIconSource: settingsIconSource,
        },
        {
            key: 'vibe',
            title: 'Vibe',
            preventsDefault: true,
        },
    ], [t, totalUnread, settingsIconSource]);

    return (
        <AnimatedView style={[styles.nativeBottomBarWrapper, bottomBarFadeStyle, { zIndex: 10 }]}>
            <NativeTabBar
                currentIndex={PAGES[currentTab]}
                onIndexChange={nativeOnIndexChange}
                tabs={nativeTabs}
                activeTintColor={activeTintColor}
                inactiveTintColor={inactiveTintColor}
                isDark={isDark}
                isVibeExpanded={isVibeExpanded}
                onVibePress={nativeOnVibePress}
                onVibeSubmit={onVibeSubmit}
            />
        </AnimatedView>
    );
});

export default function TabLayout() {
    const { colors, effectiveTheme } = useThemeStore()
    const { user } = useAuthStore()
    const { t } = useTranslation()
    const activeChatId = useChatStore(s => s.activeChatId)
    const setActiveChat = useChatStore(s => s.setActiveChat)
    const isHomeEditing = useUIStore(s => s.isHomeEditing)

    // Total Unread
    const totalUnread = useChatStore(s =>
        s.chats.reduce((sum, chat) => sum + (chat.unreadCount || 0), 0)
    )

    const isDark = effectiveTheme === 'dark'
    const settingsProfileUri = useMemo(
        () => normalizeProfileImageUri(user?.profileImage),
        [user?.profileImage]
    )
    const settingsIconSource = useMemo(
        () => (settingsProfileUri ? { uri: settingsProfileUri } : undefined),
        [settingsProfileUri]
    )

    const insets = useSafeAreaInsets()
    const bottomInsetPadding = Math.max(0, Math.min(insets.bottom, 18))

    // Local State for Active Tab (Defaults to 'home')
    const [currentTab, setCurrentTab] = useState<PageName>('home')

    // Animation Values
    const pageIndex = useSharedValue<number>(PAGES['home'])

    // Fallback tab bar indicator
    const translateX = useSharedValue(-PAGES['home'] * SCREEN_WIDTH)

    // Lazy mount: only mount a screen once it has been visited
    const [mountedPages, setMountedPages] = useState<Record<PageName, boolean>>({
        contacts: false,
        calls: false,
        home: true,  // initial tab
        settings: false,
        vibe: false,
    })

    // Story camera reveal (behind tabs)
    const [isStoryCameraOpen, setIsStoryCameraOpen] = useState(false)
    const [shouldRenderStoryCamera, setShouldRenderStoryCamera] = useState(false)
    const storyProgress = useSharedValue(0)
    const storyMountTimerRef = useRef<any>(null)

    const router = useRouter()

    // Wire up global input for Agent vibe mode
    // (We now forward events to AgentChatScreen to use its heavy animations and logic instead of directly hitting the store)

    const handleVibeSubmit = useCallback((text: string) => {
        if (!text.trim()) return;
        DeviceEventEmitter.emit('onVibeSubmit', text);
    }, []);

    const safeRouterPush = useCallback((path: string, source: string) => {
        try {
            console.log(`[TabsLayout] ${source} -> ${path}`)
            router.push(path as any)
        } catch (error) {
            console.error(`[TabsLayout] ${source} navigation failed`, error)
        }
    }, [router])

    // Bottom bar always visible now unless editing
    const showBottomBar = !isHomeEditing

    // Tab Press Handler — instant switch with lazy mount
    const handleTabPress = useCallback((page: PageName) => {
        try {
            Keyboard.dismiss()
            setMountedPages(prev => prev[page] ? prev : { ...prev, [page]: true })
            setCurrentTab(page)
            pageIndex.value = PAGES[page]
            translateX.value = withTiming(-PAGES[page] * SCREEN_WIDTH, { duration: 240 })
        } catch (error) {
            console.error('[TabsLayout] handleTabPress failed', error)
        }
    }, [])

    const openStoryCamera = useCallback(() => {
        if (isStoryCameraOpen) return
        setIsStoryCameraOpen(true)
        setShouldRenderStoryCamera(false)
        // Avoid jank: start the card animation first, then mount the heavy camera view.
        if (storyMountTimerRef.current) clearTimeout(storyMountTimerRef.current)
        storyMountTimerRef.current = setTimeout(() => setShouldRenderStoryCamera(true), 90)
        storyProgress.value = 0
        storyProgress.value = withTiming(1, {
            duration: 420,
            easing: Easing.bezier(0.22, 1, 0.36, 1),
        })
    }, [isStoryCameraOpen])

    const closeStoryCamera = useCallback(() => {
        if (storyMountTimerRef.current) clearTimeout(storyMountTimerRef.current)
        storyProgress.value = withTiming(
            0,
            { duration: 320, easing: Easing.bezier(0.4, 0, 0.2, 1) },
            (finished) => {
                if (finished) {
                    runOnJS(setIsStoryCameraOpen)(false)
                    runOnJS(setShouldRenderStoryCamera)(false)
                }
            }
        )
    }, [])

    useEffect(() => {
        if (!isStoryCameraOpen) return
        const sub = BackHandler.addEventListener('hardwareBackPress', () => {
            closeStoryCamera()
            return true
        })
        return () => sub.remove()
    }, [isStoryCameraOpen, closeStoryCamera])

    const tabsCardStyle = useAnimatedStyle(() => ({
        transform: [
            { translateX: interpolate(storyProgress.value, [0, 1], [0, SCREEN_WIDTH * 1.02]) },
            { scale: interpolate(storyProgress.value, [0, 1], [1, 0.94]) },
        ],
        borderRadius: interpolate(storyProgress.value, [0, 1], [0, 26]),
        overflow: 'hidden',
        shadowOpacity: interpolate(storyProgress.value, [0, 1], [0, 0.28]),
        shadowRadius: 40,
        shadowOffset: { width: -14, height: 0 },
        elevation: interpolate(storyProgress.value, [0, 1], [0, 18]),
    }))

    const storyUnderlayStyle = useAnimatedStyle(() => ({
        opacity: storyProgress.value,
        transform: [
            { translateX: interpolate(storyProgress.value, [0, 1], [-SCREEN_WIDTH * 0.2, 0]) },
            { scale: interpolate(storyProgress.value, [0, 1], [1.035, 1]) },
        ],
    }))

    const bottomBarFadeStyle = useAnimatedStyle(() => ({
        opacity: interpolate(storyProgress.value, [0, 0.12], [1, 0], Extrapolation.CLAMP),
    }))


    // Conditional Rendering logic removed in favor of Overlay below

    const nativeTabsAvailable = isNativeTabBarAvailable()
    const fallbackTabWidth = useMemo(() => {
        const available =
            SCREEN_WIDTH
            - (BOTTOM_BAR_HORIZONTAL_PADDING * 2)
            - 64 // Vibe button width
            - BOTTOM_BAR_GAP
            - FALLBACK_PILL_HORIZONTAL_PADDING

        return Math.max(50, Math.min(70, Math.floor(available / FALLBACK_TAB_COUNT)))
    }, [])

    const animatedPageStyles = {
        contacts: useAnimatedStyle(() => ({
            opacity: withTiming(pageIndex.value === PAGES.contacts ? 1 : 0, { duration: 250, easing: Easing.out(Easing.cubic) }),
            zIndex: pageIndex.value === PAGES.contacts ? 1 : 0,
        })),
        calls: useAnimatedStyle(() => ({
            opacity: withTiming(pageIndex.value === PAGES.calls ? 1 : 0, { duration: 250, easing: Easing.out(Easing.cubic) }),
            zIndex: pageIndex.value === PAGES.calls ? 1 : 0,
        })),
        home: useAnimatedStyle(() => ({
            opacity: withTiming(pageIndex.value === PAGES.home ? 1 : 0, { duration: 250, easing: Easing.out(Easing.cubic) }),
            zIndex: pageIndex.value === PAGES.home ? 1 : 0,
        })),
        settings: useAnimatedStyle(() => ({
            opacity: withTiming(pageIndex.value === PAGES.settings ? 1 : 0, { duration: 250, easing: Easing.out(Easing.cubic) }),
            zIndex: pageIndex.value === PAGES.settings ? 1 : 0,
        })),
        vibe: useAnimatedStyle(() => ({
            opacity: withTiming(pageIndex.value === PAGES.vibe ? 1 : 0, { duration: 250, easing: Easing.out(Easing.cubic) }),
            zIndex: pageIndex.value === PAGES.vibe ? 1 : 0,
        })),
    }

    // ────────────────────────────────────────────────────────────────────────
    // MAIN LAYOUT (Supports both Native Tabs and Fallback Tabs)
    // ────────────────────────────────────────────────────────────────────────
    return (
        <GestureHandlerRootViewAny style={{ flex: 1, backgroundColor: 'transparent' }}>
            {isStoryCameraOpen && (
                <AnimatedView style={[StyleSheet.absoluteFill, { zIndex: 100 }, storyUnderlayStyle]}>
                    {shouldRenderStoryCamera ? (
                        <StoryCamera onRequestClose={closeStoryCamera} deferCameraMountMs={180} />
                    ) : (
                        <View style={[StyleSheet.absoluteFill, { backgroundColor: '#000' }]}>
                            <BlurView intensity={30} tint="dark" style={StyleSheet.absoluteFill} />
                            <View style={[StyleSheet.absoluteFill, { backgroundColor: 'rgba(0,0,0,0.25)' }]} />
                            <View style={[StyleSheet.absoluteFill, { alignItems: 'center', justifyContent: 'center' }]}>
                                <ActivityIndicator color="#fff" />
                            </View>
                        </View>
                    )}
                </AnimatedView>
            )}

            <AnimatedView
                pointerEvents={isStoryCameraOpen ? 'none' : 'auto'}
                style={[{ flex: 1, zIndex: 2, shadowColor: '#000' }, tabsCardStyle]}
            >
                {/* Pages — lazy mounted, display:none when inactive */}
                {mountedPages.contacts && (
                    <AnimatedView
                        pointerEvents={currentTab === 'contacts' ? 'auto' : 'none'}
                        style={[StyleSheet.absoluteFill, animatedPageStyles.contacts]}
                    >
                        <ContactsScreen />
                    </AnimatedView>
                )}
                {mountedPages.calls && (
                    <AnimatedView
                        pointerEvents={currentTab === 'calls' ? 'auto' : 'none'}
                        style={[StyleSheet.absoluteFill, animatedPageStyles.calls]}
                    >
                        <CallsScreen />
                    </AnimatedView>
                )}
                {mountedPages.home && (
                    <AnimatedView
                        pointerEvents={currentTab === 'home' ? 'auto' : 'none'}
                        style={[StyleSheet.absoluteFill, animatedPageStyles.home]}
                    >
                        <HomeScreen
                            onChatSelect={(id) => setActiveChat(id)}
                            onOpenStoryCamera={openStoryCamera}
                        />
                    </AnimatedView>
                )}
                {mountedPages.settings && (
                    <AnimatedView
                        pointerEvents={currentTab === 'settings' ? 'auto' : 'none'}
                        style={[StyleSheet.absoluteFill, animatedPageStyles.settings]}
                    >
                        <SettingsScreen />
                    </AnimatedView>
                )}
                {mountedPages.vibe && (
                    <AnimatedView
                        pointerEvents={currentTab === 'vibe' ? 'auto' : 'none'}
                        style={[StyleSheet.absoluteFill, animatedPageStyles.vibe]}
                    >
                        <AgentChatScreen onBack={() => handleTabPress('home')} />
                    </AnimatedView>
                )}

                {/* Bottom Navigation */}
                {showBottomBar && (
                    <>
                        {nativeTabsAvailable ? (
                            <NativeTabsMemo
                                currentTab={currentTab}
                                handleTabPress={handleTabPress}
                                totalUnread={totalUnread}
                                settingsIconSource={settingsIconSource}
                                activeTintColor={colors.primary || (isDark ? '#e5e5e5' : '#007AFF')}
                                inactiveTintColor={isDark ? 'rgba(229,229,229,0.6)' : 'rgba(0,0,0,0.4)'}
                                isDark={isDark}
                                isVibeExpanded={currentTab === 'vibe'}
                                onVibeSubmit={handleVibeSubmit}
                                safeRouterPush={safeRouterPush}
                                bottomBarFadeStyle={bottomBarFadeStyle}
                                t={t}
                            />
                        ) : (
                            <AnimatedView
                                style={[
                                    styles.bottomBarWrapper,
                                    Platform.OS === 'android' && [
                                        styles.bottomBarWrapperAndroidAttached,
                                        { bottom: 10 + Math.max(0, insets.bottom - 10) }
                                    ],
                                    bottomBarFadeStyle,
                                ]}
                            >
                                {/* Main Tab Bar - Fallback mode */}
                                {Platform.OS === 'android' ? (
                                    <AndroidBottomTabBar
                                        currentIndex={PAGES[currentTab]}
                                        onIndexChange={(index) => {
                                            try {
                                                const pageNames: PageName[] = ['contacts', 'calls', 'home', 'settings'];
                                                console.log('[TabsLayout] android tab index change', index, pageNames[index]);
                                                handleTabPress(pageNames[index]);
                                            } catch (error) {
                                                console.error('[TabsLayout] android tab index change failed', error);
                                            }
                                        }}
                                        tabs={[
                                            {
                                                key: 'contacts',
                                                title: t('tabs.contacts'),
                                                sfSymbol: 'person.2.fill',
                                                unfocusedSfSymbol: 'person.2',
                                                renderIcon: ({ focused, color, size }) => (
                                                    <ContactsIcon size={size} color={color} focused={focused} />
                                                ),
                                            },
                                            {
                                                key: 'calls',
                                                title: t('tabs.calls'),
                                                sfSymbol: 'phone.fill',
                                                unfocusedSfSymbol: 'phone',
                                                renderIcon: ({ focused, color, size }) => (
                                                    <CallsIcon size={size} color={color} focused={focused} />
                                                ),
                                            },
                                            {
                                                key: 'home',
                                                title: t('tabs.chats'),
                                                sfSymbol: 'bubble.left.and.bubble.right.fill',
                                                unfocusedSfSymbol: 'bubble.left.and.bubble.right',
                                                renderIcon: ({ focused, color, size }) => (
                                                    <View>
                                                        <DoubleChatIcon size={size} color={color} focused={focused} />
                                                        {totalUnread > 0 && (
                                                            <View style={styles.badge}>
                                                                <Text style={styles.badgeText}>{totalUnread > 99 ? '99+' : totalUnread}</Text>
                                                            </View>
                                                        )}
                                                    </View>
                                                ),
                                            },
                                            {
                                                key: 'settings',
                                                title: t('tabs.settings'),
                                                sfSymbol: 'gearshape.fill',
                                                unfocusedSfSymbol: 'gearshape',
                                                renderIcon: ({ focused, color, size }) => (
                                                    <SettingsIcon
                                                        size={size}
                                                        color={color}
                                                        focused={focused}
                                                        imageUri={user?.profileImage}
                                                        name={user?.name || user?.username}
                                                    />
                                                ),
                                            },
                                            {
                                                key: 'vibe',
                                                title: 'Vibe',
                                                preventsDefault: true,
                                                renderIcon: ({ color, size, focused }) => (
                                                    <Image
                                                        source={require('../../assets/logos/logotransparent.png')}
                                                        style={{
                                                            width: size + 2,
                                                            height: size + 2,
                                                            tintColor: focused ? (color || '#fff') : (color || 'rgba(255,255,255,0.85)'),
                                                            resizeMode: 'contain'
                                                        }}
                                                    />
                                                ),
                                            },
                                        ]}
                                        activeTintColor={colors.primary || (isDark ? '#e5e5e5' : '#007AFF')}
                                        inactiveTintColor={isDark ? 'rgba(229,229,229,0.6)' : 'rgba(0,0,0,0.4)'}
                                        isDark={isDark}
                                        onVibePress={() => safeRouterPush('/agent', 'android-bottom-vibe-tab')}
                                    />
                                ) : (
                                    <NativeTabBar
                                        currentIndex={PAGES[currentTab]}
                                        onIndexChange={(index) => {
                                            try {
                                                const pageNames: PageName[] = ['contacts', 'calls', 'home', 'settings'];
                                                console.log('[TabsLayout] fallback tab index change', index, pageNames[index]);
                                                handleTabPress(pageNames[index]);
                                            } catch (error) {
                                                console.error('[TabsLayout] fallback tab index change failed', error);
                                            }
                                        }}
                                        tabs={[
                                            {
                                                key: 'contacts',
                                                title: t('tabs.contacts'),
                                                sfSymbol: 'person.2.fill',
                                                unfocusedSfSymbol: 'person.2',
                                                renderIcon: ({ focused, color, size }) => (
                                                    <ContactsIcon size={size} color={color} focused={focused} />
                                                ),
                                            },
                                            {
                                                key: 'calls',
                                                title: t('tabs.calls'),
                                                sfSymbol: 'phone.fill',
                                                unfocusedSfSymbol: 'phone',
                                                renderIcon: ({ focused, color, size }) => (
                                                    <CallsIcon size={size} color={color} focused={focused} />
                                                ),
                                            },
                                            {
                                                key: 'home',
                                                title: t('tabs.chats'),
                                                sfSymbol: 'bubble.left.and.bubble.right.fill',
                                                unfocusedSfSymbol: 'bubble.left.and.bubble.right',
                                                badge: totalUnread > 0 ? (totalUnread > 99 ? '99+' : String(totalUnread)) : undefined,
                                                renderIcon: ({ focused, color, size }) => (
                                                    <View>
                                                        <DoubleChatIcon size={size} color={color} focused={focused} />
                                                        {totalUnread > 0 && (
                                                            <View style={styles.badge}>
                                                                <Text style={styles.badgeText}>{totalUnread > 99 ? '99+' : totalUnread}</Text>
                                                            </View>
                                                        )}
                                                    </View>
                                                ),
                                            },
                                            {
                                                key: 'settings',
                                                title: t('tabs.settings'),
                                                sfSymbol: 'gearshape.fill',
                                                unfocusedSfSymbol: 'gearshape',
                                                renderIcon: ({ focused, color, size }) => (
                                                    <SettingsIcon
                                                        size={size}
                                                        color={color}
                                                        focused={focused}
                                                        imageUri={user?.profileImage}
                                                        name={user?.name || user?.username}
                                                    />
                                                ),
                                            },
                                            {
                                                key: 'vibe',
                                                title: 'Vibe',
                                                preventsDefault: true,
                                                renderIcon: ({ color, size, focused }: { color: string, size: number, focused: boolean }) => (
                                                    <Image
                                                        source={require('../../assets/logos/logotransparent.png')}
                                                        style={{
                                                            width: size + 2,
                                                            height: size + 2,
                                                            tintColor: focused ? (color || '#fff') : (color || 'rgba(255,255,255,0.85)'),
                                                            resizeMode: 'contain'
                                                        }}
                                                    />
                                                ),
                                            }
                                        ]}
                                        activeTintColor={colors.primary || (isDark ? '#e5e5e5' : '#007AFF')}
                                        inactiveTintColor={isDark ? 'rgba(229,229,229,0.6)' : 'rgba(0,0,0,0.4)'}
                                        isDark={isDark}
                                        translateX={translateX}
                                        screenWidth={SCREEN_WIDTH}
                                        fallbackTabWidth={fallbackTabWidth}
                                        onVibePress={() => handleTabPress('vibe')}
                                    />
                                )}
                                {Platform.OS !== 'android' && (
                                    <VibeButton
                                        onPress={() => handleTabPress('vibe')}
                                        isDark={isDark}
                                    />
                                )}
                            </AnimatedView>
                        )}
                    </>
                )}
            </AnimatedView>

        </GestureHandlerRootViewAny>
    )
}

const styles = StyleSheet.create({
    swipeContainer: {
        flex: 1,
        flexDirection: 'row',
        width: SCREEN_WIDTH * 4, // 4 pages: contacts, calls, home, settings
    },
    page: {
        width: SCREEN_WIDTH,
        height: '100%',
        overflow: 'hidden',
    },
    nativePageContainer: {
        flex: 1,
    },
    nativePageContainerWithTabs: {
        paddingBottom: 0,
    },
    nativeBottomBarWrapper: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        backgroundColor: 'transparent',
    },
    bottomBarWrapper: {
        position: 'absolute',
        bottom: Platform.OS === 'ios' ? 25 : 30,
        width: '100%',
        flexDirection: 'row',
        justifyContent: 'center',
        alignItems: 'center',
        gap: BOTTOM_BAR_GAP,
        paddingHorizontal: BOTTOM_BAR_HORIZONTAL_PADDING
    },
    bottomBarWrapperAndroidAttached: {
        bottom: 10,
        left: 0,
        right: 0,
        width: '100%',
        justifyContent: 'flex-end',
        alignItems: 'stretch',
        gap: 0,
        paddingHorizontal: 10,
    },
    badge: {
        position: 'absolute',
        top: -6,
        right: -10,
        backgroundColor: '#ef4444',
        borderRadius: 10,
        paddingHorizontal: 5,
        paddingVertical: 1,
        minWidth: 18,
        alignItems: 'center',
        justifyContent: 'center',
        borderWidth: 1.5,
        borderColor: '#fff'
    },
    badgeText: {
        color: '#fff',
        fontSize: 10,
        fontWeight: 'bold'
    },
    vibeButtonContainer: {
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 4 },
        shadowOpacity: 0.1,
        shadowRadius: 8,
        elevation: 5,
    },
    vibeButtonPill: {
        justifyContent: 'center',
        alignItems: 'center',
    },
    vibeButtonInner: {
        flex: 1,
        width: '100%',
        height: '100%',
        justifyContent: 'center',
        alignItems: 'center',
    },
    maskContainer: {
        width: 42,
        height: 42,
    },
    maskColorFill: {
        flex: 1,
    },
    vibeLogo: {
        width: 42,
        height: 42,
        resizeMode: 'contain',
    }
})
