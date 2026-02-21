import '../src/lib/polyfill-crypto';
import '../src/lib/i18n';
import { Stack, useRouter, useSegments } from 'expo-router'
import { StatusBar } from 'expo-status-bar'
import { GestureHandlerRootView } from 'react-native-gesture-handler'
import { View, Appearance, Platform } from 'react-native'
import { KeyboardProvider } from 'react-native-keyboard-controller'
import * as NavigationBar from 'expo-navigation-bar';
import { useFonts, SpaceGrotesk_400Regular, SpaceGrotesk_700Bold } from '@expo-google-fonts/space-grotesk'
import * as SplashScreen from 'expo-splash-screen'
import { useEffect, useRef } from 'react'
import * as Notifications from 'expo-notifications'
import { useThemeStore } from '../src/lib/stores/theme-store'
import { useAuthStore } from '../src/lib/stores/auth-store'
import ThemeBackground from '../src/components/ThemeBackground'
import GlassToast from '../src/components/ui/GlassToast';
import { useNotificationStore } from '../src/lib/stores/notification-store';
import { GlobalMusicPlayer } from '../src/components/music/GlobalMusicPlayer';
import VibeResponseToast from '../src/components/shared/VibeResponseToast';
import { useTransientAgentStore } from '../src/lib/stores/transient-agent-store';

// Call components (dynamically imported to handle environments without WebRTC)
import IncomingCallModal from '../src/components/call/IncomingCallModal';
import ActiveCallScreen from '../src/components/call/ActiveCallScreen';
import { useCallStore } from '../src/lib/stores/CallStore';
import SessionExpiredBanner from '../src/components/shared/SessionExpiredBanner';

SplashScreen.preventAutoHideAsync()

export default function RootLayout() {
  const { colors, effectiveTheme, initTheme } = useThemeStore()
  const { isAuthenticated, user, hasHydrated } = useAuthStore()
  const segments = useSegments()
  const router = useRouter()
  const GestureHandlerRootViewAny = GestureHandlerRootView as any

  // Transient Agent Store for @vibe queries (global)
  const { pendingResponse, clearPending, promoteToPersistent } = useTransientAgentStore()

  // Handle "View Full" to navigate to agent screen
  const handleViewFullResponse = async () => {
    const conversationId = await promoteToPersistent()
    if (conversationId) {
      router.push({
        pathname: '/agent',
        params: { conversationId }
      })
    }
  }

  // Notification listeners — receive + tap
  const notificationListener = useRef<Notifications.EventSubscription | null>(null);
  const responseListener = useRef<Notifications.EventSubscription | null>(null);
  const handledNotificationIdsRef = useRef<Set<string>>(new Set());

  const handleNotificationData = (data: Record<string, unknown> | undefined): boolean => {
    return useCallStore.getState().handleIncomingCallPayload(data);
  };

  useEffect(() => {
    // Foreground notification received
    notificationListener.current = Notifications.addNotificationReceivedListener(notification => {
      const data = notification.request.content.data as Record<string, unknown> | undefined;
      console.log('[Notifications] Received in foreground:', data);
      if (handleNotificationData(data)) {
        return;
      }
      // If we're already in the chat that sent this notification, suppress it
      const { useChatStore } = require('../src/lib/ChatStore');
      const activeChatId = useChatStore.getState().activeChatId;
      const chatId = typeof data?.chatId === 'string' ? data.chatId : null;
      if (chatId && chatId === activeChatId) {
        Notifications.dismissNotificationAsync(notification.request.identifier);
      }
    });

    // User tapped on notification — navigate to chat
    responseListener.current = Notifications.addNotificationResponseReceivedListener(response => {
      const id = response.notification.request.identifier;
      if (handledNotificationIdsRef.current.has(id)) return;
      handledNotificationIdsRef.current.add(id);
      const data = response.notification.request.content.data as Record<string, unknown> | undefined;
      console.log('[Notifications] Tapped:', data);
      if (handleNotificationData(data)) {
        return;
      }
      const chatId = typeof data?.chatId === 'string' ? data.chatId : null;
      if (chatId) {
        router.push({ pathname: '/chat' as any, params: { id: chatId } });
      }
    });

    Notifications.getLastNotificationResponseAsync()
      .then((response) => {
        if (!response) return;
        const id = response.notification.request.identifier;
        if (handledNotificationIdsRef.current.has(id)) return;
        handledNotificationIdsRef.current.add(id);
        const data = response.notification.request.content.data as Record<string, unknown> | undefined;
        console.log('[Notifications] Last response:', data);
        if (handleNotificationData(data)) {
          return;
        }
        const chatId = typeof data?.chatId === 'string' ? data.chatId : null;
        if (chatId) {
          router.push({ pathname: '/chat' as any, params: { id: chatId } });
        }
      })
      .catch((error) => {
        console.warn('[Notifications] Failed to read last response', error);
      });

    return () => {
      notificationListener.current?.remove();
      responseListener.current?.remove();
    };
  }, []);

  const [fontsLoaded] = useFonts({
    'SpaceGrotesk-Regular': SpaceGrotesk_400Regular,
    'SpaceGrotesk-Bold': SpaceGrotesk_700Bold,
  })

  useEffect(() => {
    // Ensure theme is active immediately
    initTheme()

    if (Platform.OS === 'android') {
      NavigationBar.setPositionAsync('absolute')
      NavigationBar.setBackgroundColorAsync('transparent')
    }

    // Initialize Auth Session then Socket
    const AuthManager = require('../src/lib/AuthManager').default
    const { useChatStore } = require('../src/lib/ChatStore')

    AuthManager.getInstance().init().then((session: any) => {
      console.log('[Layout] Auth Loaded:', !!session);
      // If SecureStore has a valid session but Zustand store lost it, restore auth state
      const authState = useAuthStore.getState();
      if (session && !authState.isAuthenticated && authState.hasHydrated) {
        console.log('[Layout] Restoring auth state from SecureStore session');
        useAuthStore.getState().login({
          userId: session.userId,
          secureId: session.secureId,
          username: '',
          loginToken: session.loginToken || '',
        });
      }
      // Initialize socket after auth is ready
      if (session) {
        if (!useChatStore.getState().isConnected) {
          useChatStore.getState().initSocket()
        }
        // Register for Push Notifications even if socket is already connected.
        // This guarantees iOS permission/token sync on cold starts.
        useNotificationStore.getState().initNotifications();
        // Check WebRTC availability for calls (safe in Expo Go - will just report false)
        useCallStore.getState().checkWebRTCAvailability().then(available => {
          console.log('[Layout] WebRTC available for calls:', available);
        });
      }
    });

    // Listen for system appearance changes
    const subscription = Appearance.addChangeListener(() => {
      initTheme()
    })

    return () => subscription.remove()
  }, [initTheme])

  useEffect(() => {
    if (fontsLoaded) {
      SplashScreen.hideAsync().catch(() => { });
    }
  }, [fontsLoaded])

  // Auth Protection — wait for Zustand hydration before redirecting
  useEffect(() => {
    if (!fontsLoaded || !hasHydrated) return;

    console.log('[RootLayout] Auth check - segments:', segments, 'isAuthenticated:', isAuthenticated, 'hydrated:', hasHydrated)

    if (isAuthenticated) {
      // Validate session in background to catch 401s if socket fails
      useAuthStore.getState().validateSession();
    }

    const inAuthGroup = segments[0] === '(auth)'

    if (!isAuthenticated && !inAuthGroup) {
      // Redirect to signin if not authenticated
      console.log('[RootLayout] Not authenticated, redirecting to signin')
      router.replace('/(auth)/welcome')
    } else if (isAuthenticated && inAuthGroup) {
      // Redirect to home if authenticated and trying to access auth pages
      console.log('[RootLayout] Authenticated but in auth group, redirecting to home')
      router.replace('/(tabs)/home')
    }
  }, [isAuthenticated, segments, fontsLoaded, hasHydrated])

  if (!fontsLoaded) return null

  return (
    <GestureHandlerRootViewAny style={{ flex: 1 }}>
      <KeyboardProvider>
        <View style={{ flex: 1 }}>
          <ThemeBackground pattern="fluid" />
          <GlobalMusicPlayer />
          <StatusBar style={effectiveTheme === 'dark' ? 'light' : 'dark'} />
          <Stack
            screenOptions={{
              headerShown: false,
              contentStyle: { backgroundColor: 'transparent' },
              animation: 'default',
            }}
          >
            <Stack.Screen name="index" />
            <Stack.Screen name="(auth)" />
            <Stack.Screen name="(tabs)" />
            <Stack.Screen name="chat" options={{ animation: 'slide_from_right', contentStyle: { backgroundColor: 'transparent' }, presentation: 'card' }} />
            <Stack.Screen name="agent" options={{ animation: 'slide_from_right', contentStyle: { backgroundColor: 'transparent' }, presentation: 'card' }} />
            <Stack.Screen name="profile" options={{ animation: 'slide_from_right', contentStyle: { backgroundColor: 'transparent' }, presentation: 'card' }} />
            <Stack.Screen
              name="story-camera"
              options={{
                // Feels like a back-swipe reveal: camera comes from left, home moves right.
                animation: 'slide_from_left',
                presentation: 'card',
                gestureEnabled: true,
                gestureDirection: 'horizontal',
                // Must be opaque so it doesn't look like an overlay on top of Home.
                contentStyle: { backgroundColor: '#000' },
              }}
            />
            <Stack.Screen name="modal" options={{ presentation: 'modal', headerShown: false }} />
          </Stack>
          <GlassToast />
          <SessionExpiredBanner />

          {/* Global Vibe Response Toast */}
          <VibeResponseToast
            visible={!!pendingResponse}
            response={pendingResponse?.response || ''}
            userMessage={pendingResponse?.userMessage}
            isStreaming={pendingResponse?.isStreaming || false}
            isComplete={pendingResponse?.isComplete || false}
            error={pendingResponse?.error}
            currentTool={pendingResponse?.currentTool}
            onClose={clearPending}
            onViewFull={handleViewFullResponse}
          />

          {/* Global Call Overlays */}
          <IncomingCallModal />
          <ActiveCallScreen />
        </View>
      </KeyboardProvider>
    </GestureHandlerRootViewAny>
  )
}
