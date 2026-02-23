import '../src/lib/polyfill-crypto';
import '../src/lib/i18n';
import { Stack, useRouter, useSegments } from 'expo-router'
import { StatusBar } from 'expo-status-bar'
import { GestureHandlerRootView } from 'react-native-gesture-handler'
import { View, Appearance, Platform, AppState } from 'react-native'
import { KeyboardProvider } from 'react-native-keyboard-controller'
import * as NavigationBar from 'expo-navigation-bar';
import { useFonts, SpaceGrotesk_400Regular, SpaceGrotesk_700Bold } from '@expo-google-fonts/space-grotesk'
import * as SplashScreen from 'expo-splash-screen'
import { useEffect, useRef } from 'react'
import * as Notifications from 'expo-notifications'
import { useShallow } from 'zustand/react/shallow'
import { useThemeStore } from '../src/lib/stores/theme-store'
import { resolveThemeVariant, useWallpaperStore } from '../src/lib/stores/wallpaper-store'
import { useAuthStore } from '../src/lib/stores/auth-store'
import ThemeBackground from '../src/components/ThemeBackground'
import GlassToast from '../src/components/ui/GlassToast';
import { useNotificationStore } from '../src/lib/stores/notification-store';
import { GlobalMusicPlayer } from '../src/components/music/GlobalMusicPlayer';
import VibeResponseToast from '../src/components/shared/VibeResponseToast';
import { useTransientAgentStore } from '../src/lib/stores/transient-agent-store';

// Call state is still managed in JS, but iOS/Android native call UI is used.
import { useCallStore } from '../src/lib/stores/CallStore';
import { getUserChannel } from '../src/lib/ChatStore';
import SessionExpiredBanner from '../src/components/shared/SessionExpiredBanner';
import { addNativeCallUiListener, getNativeCallModule } from '../src/native/call/runtime';

SplashScreen.preventAutoHideAsync()

// Persist across RootLayout remounts within the same JS runtime (dev reloads / error recovery)
const handledNotificationResponseKeys = new Set<string>()

const getNotificationResponseKey = (
  response: Notifications.NotificationResponse
): string => {
  const notification = response.notification
  const identifier = notification.request.identifier
  const data = notification.request.content.data as Record<string, unknown> | undefined
  const messageId = typeof data?.messageId === 'string' ? data.messageId : null
  const chatId = typeof data?.chatId === 'string' ? data.chatId : null
  const type = typeof data?.type === 'string' ? data.type : null

  if (messageId) return `msg:${messageId}`
  if (chatId && type) return `chat:${chatId}:${type}`
  if (chatId) return `chat:${chatId}`
  return `id:${identifier}`
}

export default function RootLayout() {
  const { colors, effectiveTheme, initTheme } = useThemeStore()
  const { isAuthenticated, user, hasHydrated } = useAuthStore()
  const segments = useSegments()
  const router = useRouter()
  const GestureHandlerRootViewAny = GestureHandlerRootView as any
  const nativeCallUiRuntimeInfo = getNativeCallModule()
  const supportsNativeInAppCallUi = !!nativeCallUiRuntimeInfo?.supportsInAppUi?.()
  const enableNativeInAppCallUi = supportsNativeInAppCallUi
  const activeWallpaperTheme = useWallpaperStore((s) => s.activeTheme)
  const activeWallpaperThemeId = useWallpaperStore((s) => s.activeThemeId)

  const callUiSnapshot = useCallStore(
    useShallow((s) => ({
      callId: s.callId,
      callType: s.callType,
      callStatus: s.callStatus,
      callDirection: s.callDirection,
      remoteUser: s.remoteUser,
      isMuted: s.isMuted,
      isSpeakerOn: s.isSpeakerOn,
      isVideoEnabled: s.isVideoEnabled,
      callDuration: s.callDuration,
      isFrontCamera: s.isFrontCamera,
      incomingCallData: s.incomingCallData,
    }))
  )

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
  const nativeCallDrainInFlightRef = useRef(false);
  const deferredNativeCallEventsRef = useRef<any[]>([]);
  const nativeCallUiDebugKeyRef = useRef<string>('');
  const resolvedCallWallpaperTheme = resolveThemeVariant(activeWallpaperTheme, effectiveTheme === 'dark')

  const drainNativeCallEvents = async () => {
    if (nativeCallDrainInFlightRef.current) return;
    const nativeCall = getNativeCallModule();
    if (!nativeCall?.drainPendingEvents) return;
    nativeCallDrainInFlightRef.current = true;
    try {
      const events = [...deferredNativeCallEventsRef.current, ...(nativeCall.drainPendingEvents() || [])];
      deferredNativeCallEventsRef.current = [];
      for (const raw of events) {
        const event = raw as any;
        const type = typeof event?.type === 'string' ? event.type : '';
        const payload = event?.payload as Record<string, unknown> | undefined;
        if (!payload || typeof payload !== 'object') continue;

        if (type === 'incomingCall') {
          useCallStore.getState().handleIncomingCallPayload(payload);
          continue;
        }

        if (type === 'callAction') {
          const action = typeof (payload as any).action === 'string' ? ((payload as any).action as string).toLowerCase() : '';
          useCallStore.getState().handleIncomingCallPayload(payload);
          if (action === 'answer') {
            const accepted = await useCallStore.getState().acceptCall(undefined as any);
            if (accepted) {
              nativeCall.clearIncomingCallUi?.(payload);
            } else {
              deferredNativeCallEventsRef.current.push(raw);
            }
          } else if (action === 'decline') {
            useCallStore.getState().declineCall(undefined as any);
            nativeCall.clearIncomingCallUi?.(payload);
          }
        }
      }
    } catch (error) {
      // console.warn('[NativeCall] Failed to drain pending events', error);
    } finally {
      nativeCallDrainInFlightRef.current = false;
    }
  };

  const handleNotificationData = (data: Record<string, unknown> | undefined): boolean => {
    const handled = useCallStore.getState().handleIncomingCallPayload(data);
    if (data) {
      /*
      console.log('[Notifications] call-payload-check', {
        handled,
        keys: Object.keys(data),
        event: typeof data.event === 'string' ? data.event : undefined,
        type: typeof data.type === 'string' ? data.type : undefined,
        callId: typeof data.callId === 'string' ? data.callId : (typeof (data as any).call_id === 'string' ? (data as any).call_id : undefined),
        messageId: typeof data.messageId === 'string' ? data.messageId : (typeof (data as any).message_id === 'string' ? (data as any).message_id : undefined),
      });
      */
    }
    return handled;
  };

  useEffect(() => {
    if (!enableNativeInAppCallUi) return;
    const sub = addNativeCallUiListener(async (event) => {
      const type = event?.type;
      // console.log('[NativeCallUI][JS] onCallUiEvent', event);
      switch (type) {
        case 'accept':
          await useCallStore.getState().acceptCall(getUserChannel());
          break;
        case 'decline':
          useCallStore.getState().declineCall(getUserChannel());
          break;
        case 'end':
          useCallStore.getState().endCall(getUserChannel());
          break;
        case 'toggleMute':
          useCallStore.getState().toggleMute();
          break;
        case 'toggleSpeaker':
          useCallStore.getState().toggleSpeaker();
          break;
        case 'toggleVideo':
          useCallStore.getState().toggleVideo();
          break;
        case 'flipCamera':
          useCallStore.getState().flipCamera();
          break;
        case 'message':
        case 'remind':
          // Keep JS modal for these advanced actions for now; native UI emits and JS can extend later.
          break;
      }
    });
    return () => sub?.remove();
  }, [enableNativeInAppCallUi]);

  useEffect(() => {
    if (Platform.OS !== 'ios' || enableNativeInAppCallUi) return;
    getNativeCallModule()?.hideCallUi?.();
  }, [enableNativeInAppCallUi]);

  useEffect(() => {
    if (!enableNativeInAppCallUi) return;
    const nativeCall = getNativeCallModule();
    if (!nativeCall?.setCallUiState) return;

    const isInCallLike =
      callUiSnapshot.callStatus !== 'idle' &&
      callUiSnapshot.callStatus !== 'ended';
    const isIncoming =
      callUiSnapshot.callDirection === 'incoming' &&
      callUiSnapshot.callStatus === 'ringing' &&
      !!callUiSnapshot.incomingCallData;

    const mode = !isInCallLike ? 'hidden' : (isIncoming ? 'incoming' : 'active');
    const remoteName =
      callUiSnapshot.incomingCallData?.fromUserName ||
      callUiSnapshot.remoteUser?.userName ||
      undefined;
    const remoteImage =
      callUiSnapshot.incomingCallData?.fromUserImage ||
      callUiSnapshot.remoteUser?.userImage ||
      undefined;
    const callType =
      callUiSnapshot.incomingCallData?.callType ||
      callUiSnapshot.callType ||
      'voice';

    const callId =
      callUiSnapshot.callId || callUiSnapshot.incomingCallData?.callId || undefined;
    const debugKey = [
      mode,
      callUiSnapshot.callStatus,
      callUiSnapshot.callDirection,
      callId ?? '-',
      callType,
      callUiSnapshot.isMuted ? 'm1' : 'm0',
      callUiSnapshot.isSpeakerOn ? 's1' : 's0',
      callUiSnapshot.isVideoEnabled ? 'v1' : 'v0',
      effectiveTheme,
    ].join('|');
    if (nativeCallUiDebugKeyRef.current !== debugKey) {
      nativeCallUiDebugKeyRef.current = debugKey;
      /*
      console.log('[NativeCallUI][JS] setCallUiState', {
        mode,
        visible: mode !== 'hidden',
        callId,
        callStatus: callUiSnapshot.callStatus,
        callDirection: callUiSnapshot.callDirection,
        callType,
        isMuted: callUiSnapshot.isMuted,
        isSpeakerOn: callUiSnapshot.isSpeakerOn,
        isVideoEnabled: callUiSnapshot.isVideoEnabled,
      });
      */
    }

    nativeCall.setCallUiState({
      visible: mode !== 'hidden',
      mode,
      callId,
      callType,
      callStatus: callUiSnapshot.callStatus,
      remoteUserName: remoteName,
      remoteUserImage: remoteImage,
      isMuted: callUiSnapshot.isMuted,
      isSpeakerOn: callUiSnapshot.isSpeakerOn,
      isVideoEnabled: callUiSnapshot.isVideoEnabled,
      canFlipCamera: callType === 'video',
      callDuration: callUiSnapshot.callDuration,
      isDark: effectiveTheme === 'dark',
      nativeThemeId: activeWallpaperThemeId,
      nativeThemeIsDark: effectiveTheme === 'dark',
      wallpaperGradient: resolvedCallWallpaperTheme.backgroundGradient,
      wallpaperOpacity: 1,
      wallpaperPatternGradient: resolvedCallWallpaperTheme.patternGradientColors || [],
      wallpaperPatternLocations: resolvedCallWallpaperTheme.patternGradientLocations || [],
      wallpaperPatternOpacity: resolvedCallWallpaperTheme.patternOpacity ?? 0,
      wallpaperMaskKey:
        resolvedCallWallpaperTheme.maskedImage ||
        activeWallpaperTheme.maskedImage ||
        undefined,
    });
  }, [
    enableNativeInAppCallUi,
    callUiSnapshot,
    effectiveTheme,
    activeWallpaperTheme,
    activeWallpaperThemeId,
    resolvedCallWallpaperTheme,
  ]);

  // Keep call duration ticking even when local RN call screens are disabled.
  useEffect(() => {
    let timer: ReturnType<typeof setInterval> | null = null;
    if (callUiSnapshot.callStatus === 'active') {
      timer = setInterval(() => {
        useCallStore.getState().updateDuration();
      }, 1000);
    }
    return () => {
      if (timer) clearInterval(timer);
    };
  }, [callUiSnapshot.callStatus]);

  useEffect(() => {
    void drainNativeCallEvents();
    const sub = AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        void drainNativeCallEvents();
      }
    });
    return () => sub.remove();
  }, []);

  useEffect(() => {
    if (!hasHydrated || !isAuthenticated) return;
    void drainNativeCallEvents();
  }, [hasHydrated, isAuthenticated]);

  useEffect(() => {
    Notifications.getPermissionsAsync()
      .then((perm) => {
        /*
        console.log('[Notifications] Permission snapshot', {
          status: perm.status,
          granted: perm.granted,
          canAskAgain: perm.canAskAgain,
          iosStatus: (perm as any)?.ios?.status,
          iosAllowsAlert: (perm as any)?.ios?.allowsAlert,
          iosAllowsBadge: (perm as any)?.ios?.allowsBadge,
          iosAllowsSound: (perm as any)?.ios?.allowsSound,
        });
        */
      })
    // .catch((err) => console.warn('[Notifications] Permission snapshot failed', err));

    // Foreground notification received
    notificationListener.current = Notifications.addNotificationReceivedListener(notification => {
      const data = notification.request.content.data as Record<string, unknown> | undefined;
      const triggerAny = notification.request.trigger as any;
      const aps = triggerAny?.payload?.aps ?? triggerAny?.aps ?? null;
      const mutableContent = (
        aps?.['mutable-content'] ??
        aps?.mutableContent ??
        null
      );
      const hasAlert = !!aps?.alert;
      /*
      console.log('[Notifications] Received in foreground:', {
        id: notification.request.identifier,
        title: notification.request.content.title,
        body: notification.request.content.body,
        appState: 'foreground',
        apsMutableContent: mutableContent,
        apsHasAlert: hasAlert,
        data,
      });
      */
      if (handleNotificationData(data)) {
        void drainNativeCallEvents();
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
      const key = getNotificationResponseKey(response);
      if (handledNotificationIdsRef.current.has(key) || handledNotificationResponseKeys.has(key)) {
        return;
      }
      handledNotificationIdsRef.current.add(key);
      handledNotificationResponseKeys.add(key);
      const data = response.notification.request.content.data as Record<string, unknown> | undefined;
      // console.log('[Notifications] Tapped:', data);
      if (handleNotificationData(data)) {
        void drainNativeCallEvents();
        return;
      }
      const chatId = typeof data?.chatId === 'string' ? data.chatId : null;
      if (chatId) {
        router.push({ pathname: '/chat' as any, params: { id: chatId } });
      }
    });

    Notifications.getLastNotificationResponseAsync()
      .then(async (response) => {
        if (!response) return;
        const key = getNotificationResponseKey(response);
        if (handledNotificationIdsRef.current.has(key) || handledNotificationResponseKeys.has(key)) {
          // Best effort clear to prevent replay loops after remounts.
          try {
            await (Notifications as any).clearLastNotificationResponseAsync?.();
          } catch { }
          return;
        }
        handledNotificationIdsRef.current.add(key);
        handledNotificationResponseKeys.add(key);
        const data = response.notification.request.content.data as Record<string, unknown> | undefined;
        // console.log('[Notifications] Last response:', data);
        if (handleNotificationData(data)) {
          void drainNativeCallEvents();
          try {
            await (Notifications as any).clearLastNotificationResponseAsync?.();
          } catch { }
          return;
        }
        const chatId = typeof data?.chatId === 'string' ? data.chatId : null;
        if (chatId) {
          router.push({ pathname: '/chat' as any, params: { id: chatId } });
        }
        try {
          await (Notifications as any).clearLastNotificationResponseAsync?.();
        } catch { }
      })
    /*
    .catch((error) => {
      console.warn('[Notifications] Failed to read last response', error);
    });
    */

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
      // console.log('[Layout] Auth Loaded:', !!session);
      // If SecureStore has a valid session but Zustand store lost it, restore auth state
      const authState = useAuthStore.getState();
      if (session && !authState.isAuthenticated && authState.hasHydrated) {
        // console.log('[Layout] Restoring auth state from SecureStore session');
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
        useNotificationStore.getState().initNotifications({
          forceSync: true,
          reason: 'app_boot',
        });
        // Check WebRTC availability for calls (safe in Expo Go - will just report false)
        useCallStore.getState().checkWebRTCAvailability().then(available => {
          // console.log('[Layout] WebRTC available for calls:', available);
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

    // console.log('[RootLayout] Auth check - segments:', segments, 'isAuthenticated:', isAuthenticated, 'hydrated:', hasHydrated)

    if (isAuthenticated) {
      // Validate session in background to catch 401s if socket fails
      useAuthStore.getState().validateSession();
    }

    const inAuthGroup = segments[0] === '(auth)'

    if (!isAuthenticated && !inAuthGroup) {
      // Redirect to signin if not authenticated
      // console.log('[RootLayout] Not authenticated, redirecting to signin')
      router.replace('/(auth)/welcome')
    } else if (isAuthenticated && inAuthGroup) {
      // Redirect to home if authenticated and trying to access auth pages
      // console.log('[RootLayout] Authenticated but in auth group, redirecting to home')
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

          {/* Native call UI is the single call surface; local RN call overlays disabled. */}
        </View>
      </KeyboardProvider>
    </GestureHandlerRootViewAny>
  )
}
