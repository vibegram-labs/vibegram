
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { View, Text, TouchableOpacity, StyleSheet, Platform, Dimensions, Keyboard, BackHandler, ActivityIndicator, DeviceEventEmitter, InteractionManager } from 'react-native'
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
import { useTranslation } from 'react-i18next'
import { useThemeStore } from '../../src/lib/stores/theme-store'
import { useUIStore } from '../../src/lib/stores/ui-store'
import { resolveThemeVariant, useWallpaperStore } from '../../src/lib/stores/wallpaper-store'
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass'
import NativeTabBar, { isNativeTabBarAvailable, type NativeTabBarEditMode } from '../../src/components/native/NativeTabBar'
import { useChatStore } from '../../src/lib/ChatStore'
import { useAuthStore } from '../../src/lib/stores/auth-store'
import { ContactsIcon, CallsIcon, SettingsIcon } from '../../src/components/Icons'
import DoubleChatIcon from '../../src/components/icons/DoubleChatIcon'
import HomeScreen from './home'
import SettingsScreen from './settings'
import ContactsScreen from './contacts'
import CallsScreen from './calls'
import { StoryCamera } from '../story-camera'
import { AgentChatScreen } from '../../src/components/agent'
import { useAgentStore } from '../../src/lib/agent/AgentStore'
import { KeyboardStickyView } from 'react-native-keyboard-controller'
import { BlurView } from 'expo-blur'
import { File as ExpoFile, Paths } from 'expo-file-system'
import { Image } from 'react-native'
import MaskedView from '@react-native-masked-view/masked-view'

const GestureHandlerRootViewAny = GestureHandlerRootView as any
const AnimatedView = Animated.View as any
const { width: SCREEN_WIDTH } = Dimensions.get('window')
const BOTTOM_BAR_HORIZONTAL_PADDING = 12
const BOTTOM_BAR_GAP = 8
const FALLBACK_PILL_HORIZONTAL_PADDING = 10
const FALLBACK_TAB_COUNT = 4


// Page indices for the tab pager. Vibe stays inside the tab stack.
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

const withAlpha = (color: string, alpha: number): string => {
    if (!color) return `rgba(127, 127, 127, ${alpha})`
    if (color.startsWith('#')) {
        const hex = color.replace('#', '')
        const normalizedHex = hex.length === 3
            ? hex.split('').map((char) => char + char).join('')
            : hex
        if (normalizedHex.length !== 6) return color
        const r = parseInt(normalizedHex.substring(0, 2), 16)
        const g = parseInt(normalizedHex.substring(2, 4), 16)
        const b = parseInt(normalizedHex.substring(4, 6), 16)
        return `rgba(${r}, ${g}, ${b}, ${alpha})`
    }
    if (color.startsWith('rgba')) {
        return color.replace(/[\d\.]+\)$/g, `${alpha})`)
    }
    return color
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
    isVibeStreaming,
    onVibeSubmit,
    onVibeStop,
    bottomBarFadeStyle,
    t,
    editMode,
}: {
    currentTab: PageName;
    handleTabPress: (page: PageName) => void;
    totalUnread: number;
    settingsIconSource: any;
    activeTintColor: string;
    inactiveTintColor: string;
    isDark: boolean;
    isVibeExpanded: boolean;
    isVibeStreaming: boolean;
    onVibeSubmit: (text: string) => void;
    onVibeStop: () => void;
    bottomBarFadeStyle: any;
    t: (key: string) => string;
    editMode?: NativeTabBarEditMode;
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
                isVibeStreaming={isVibeStreaming}
                onVibePress={nativeOnVibePress}
                onVibeSubmit={onVibeSubmit}
                onVibeStop={onVibeStop}
                editMode={editMode}
            />
        </AnimatedView>
    );
});

export default function TabLayout() {
    const { colors, effectiveTheme } = useThemeStore()
    const activeWallpaperTheme = useWallpaperStore(s => s.activeTheme)
    const { user } = useAuthStore()
    const { t } = useTranslation()
    const setActiveChat = useChatStore(s => s.setActiveChat)
    const isHomeEditing = useUIStore(s => s.isHomeEditing)
    const homeEditSelectionCount = useUIStore(s => s.homeEditSelectionCount)
    const requestHomeEditAction = useUIStore(s => s.requestHomeEditAction)

    // Total Unread
    const totalUnread = useChatStore(s =>
        s.chats.reduce((sum, chat) => sum + (chat.unreadCount || 0), 0)
    )

    const isDark = effectiveTheme === 'dark'
    const normalizedSettingsProfileUri = useMemo(
        () => normalizeProfileImageUri(user?.profileImage),
        [user?.profileImage]
    )
    const [settingsProfileUri, setSettingsProfileUri] = useState<string | undefined>(normalizedSettingsProfileUri)

    useEffect(() => {
        let cancelled = false

        const resolveSettingsProfileUri = async () => {
            if (!normalizedSettingsProfileUri) {
                if (!cancelled) {
                    setSettingsProfileUri(undefined)
                }
                return
            }

            if (!normalizedSettingsProfileUri.startsWith('data:')) {
                if (!cancelled) {
                    setSettingsProfileUri(normalizedSettingsProfileUri)
                }
                return
            }

            const commaIndex = normalizedSettingsProfileUri.indexOf(',')
            if (commaIndex === -1) {
                console.warn('[TabsLayout] settings tab avatar data URI is malformed, using inline source')
                if (!cancelled) {
                    setSettingsProfileUri(normalizedSettingsProfileUri)
                }
                return
            }

            const metadata = normalizedSettingsProfileUri.slice(0, commaIndex)
            const base64Payload = normalizedSettingsProfileUri.slice(commaIndex + 1)
            const fileExtension = metadata.includes('image/png')
                ? 'png'
                : metadata.includes('image/webp')
                    ? 'webp'
                    : 'jpg'
            const cacheFile = new ExpoFile(
                Paths.cache,
                `native-tab-settings-avatar-${user?.userId || 'current'}.${fileExtension}`
            )

            try {
                cacheFile.create({ overwrite: true, intermediates: true })
                cacheFile.write(base64Payload, { encoding: 'base64' })
                console.log('[TabsLayout] cached settings tab avatar for native tab bar', {
                    cacheUri: cacheFile.uri,
                    fileExtension,
                })
                if (!cancelled) {
                    setSettingsProfileUri(cacheFile.uri)
                }
            } catch (error) {
                console.warn('[TabsLayout] failed to cache settings tab avatar, using inline source', error)
                if (!cancelled) {
                    setSettingsProfileUri(normalizedSettingsProfileUri)
                }
            }
        }

        void resolveSettingsProfileUri()

        return () => {
            cancelled = true
        }
    }, [normalizedSettingsProfileUri, user?.userId])

    const settingsIconSource = useMemo(
        () => (settingsProfileUri ? { uri: settingsProfileUri } : undefined),
        [settingsProfileUri]
    )

    const insets = useSafeAreaInsets()
    const bottomInsetPadding = Math.max(0, Math.min(insets.bottom, 18))

    // Local State for Active Tab (Defaults to 'home')
    const [currentTab, setCurrentTab] = useState<PageName>('home')
    const [isVibeStreaming, setIsVibeStreaming] = useState(false)

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
    const resolvedWallpaperTheme = useMemo(() => {
        const resolved = resolveThemeVariant(activeWallpaperTheme, effectiveTheme === 'dark')
        const bg = Array.isArray(resolved.backgroundGradient) ? resolved.backgroundGradient : []
        return {
            ...resolved,
            backgroundGradient: bg.length >= 2 ? bg : [colors.background, colors.background],
        }
    }, [activeWallpaperTheme, colors.background, effectiveTheme])

    const handleVibeSubmit = useCallback((text: string) => {
        const trimmed = text.trim()
        if (!trimmed) return

        try {
            const store = useAgentStore.getState()
            if (!store.activeConversationId) {
                store.createConversation(trimmed.substring(0, 20))
            }
            store.sendMessage(trimmed)
            DeviceEventEmitter.emit('onVibeSubmit', trimmed)
        } catch (error) {
            console.error('[TabsLayout] Vibe send error', error)
        }
    }, [])

    const handleVibeStop = useCallback(() => {
        DeviceEventEmitter.emit('onVibeStop')
    }, [])

    useEffect(() => {
        const sub = DeviceEventEmitter.addListener('onVibeStreamingState', (payload: any) => {
            if (typeof payload === 'boolean') {
                setIsVibeStreaming(payload)
                return
            }
            setIsVibeStreaming(!!payload?.isStreaming)
        })

        return () => sub.remove()
    }, [])

    useEffect(() => {
        const preloadTask = InteractionManager.runAfterInteractions(() => {
            setMountedPages(prev => prev.vibe ? prev : { ...prev, vibe: true })
        })

        return () => {
            preloadTask.cancel()
        }
    }, [])

    // Bottom bar stays mounted so the native Vibe input can expand on the tab.
    const showBottomBar = !isHomeEditing

    // Tab Press Handler — instant switch with lazy mount
    const handleTabPress = useCallback((page: PageName) => {
        try {
            Keyboard.dismiss()
            setMountedPages(prev => prev[page] ? prev : { ...prev, [page]: true })
            setCurrentTab(page)
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

    const isHomeEditActionMode = currentTab === 'home' && isHomeEditing
    const editActionGlassTintColor = useMemo(() => {
        const baseColor = resolvedWallpaperTheme.backgroundGradient?.[0] || colors.background
        return withAlpha(baseColor, effectiveTheme === 'dark' ? 0.16 : 0.2)
    }, [colors.background, effectiveTheme, resolvedWallpaperTheme.backgroundGradient])
    const homeEditMode = useMemo<NativeTabBarEditMode>(() => {
        const hasSelection = homeEditSelectionCount > 0

        return {
            isActive: isHomeEditActionMode,
            primaryTitle: hasSelection ? 'Read' : 'Read All',
            secondaryTitle: 'Delete',
            primaryEnabled: true,
            secondaryEnabled: hasSelection,
            glassTintColor: editActionGlassTintColor,
            onPrimaryActionPress: () => requestHomeEditAction(hasSelection ? 'read' : 'readAll'),
            onSecondaryActionPress: () => {
                if (!hasSelection) return
                requestHomeEditAction('delete')
            },
        }
    }, [editActionGlassTintColor, homeEditSelectionCount, isHomeEditActionMode, requestHomeEditAction])


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
                        style={[StyleSheet.absoluteFill, currentTab === 'contacts' ? styles.pageVisible : styles.pageHidden]}
                    >
                        <ContactsScreen />
                    </AnimatedView>
                )}
                {mountedPages.calls && (
                    <AnimatedView
                        pointerEvents={currentTab === 'calls' ? 'auto' : 'none'}
                        style={[StyleSheet.absoluteFill, currentTab === 'calls' ? styles.pageVisible : styles.pageHidden]}
                    >
                        <CallsScreen />
                    </AnimatedView>
                )}
                {mountedPages.home && (
                    <AnimatedView
                        pointerEvents={currentTab === 'home' ? 'auto' : 'none'}
                        style={[StyleSheet.absoluteFill, currentTab === 'home' ? styles.pageVisible : styles.pageHidden]}
                    >
                        <HomeScreen
                            onChatSelect={(id) => setActiveChat(id)}
                            onOpenStoryCamera={openStoryCamera}
                            onOpenVibe={() => handleTabPress('vibe')}
                        />
                    </AnimatedView>
                )}
                {mountedPages.settings && (
                    <AnimatedView
                        pointerEvents={currentTab === 'settings' ? 'auto' : 'none'}
                        style={[StyleSheet.absoluteFill, currentTab === 'settings' ? styles.pageVisible : styles.pageHidden]}
                    >
                        <SettingsScreen />
                    </AnimatedView>
                )}
                {mountedPages.vibe && (
                    <AnimatedView
                        pointerEvents={currentTab === 'vibe' ? 'auto' : 'none'}
                        style={[StyleSheet.absoluteFill, currentTab === 'vibe' ? styles.pageVisible : styles.pageHidden]}
                    >
                        <AgentChatScreen onBack={() => handleTabPress('home')} />
                    </AnimatedView>
                )}

                {/* Bottom Navigation */}
                {showBottomBar && (
                    <KeyboardStickyView
                        offset={{ closed: 0, opened: 0 }}
                        style={{ position: 'absolute', bottom: 0, left: 0, right: 0, zIndex: 10 }}
                    >
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
                                isVibeStreaming={isVibeStreaming}
                                onVibeSubmit={handleVibeSubmit}
                                onVibeStop={handleVibeStop}
                                bottomBarFadeStyle={bottomBarFadeStyle}
                                t={t}
                                editMode={homeEditMode}
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
                                    <NativeTabBar
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
                                        editMode={homeEditMode}
                                        onVibePress={() => handleTabPress('vibe')}
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
                                        editMode={homeEditMode}
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
                    </KeyboardStickyView>
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
    pageVisible: {
        display: 'flex',
        zIndex: 1,
    },
    pageHidden: {
        display: 'none',
        zIndex: 0,
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
