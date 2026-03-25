import React, { useCallback, useEffect, useMemo } from 'react';
import { Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useAgentStore } from '../../lib/agent/AgentStore';
import { useVibeAgentBuilderStore } from '../../lib/agent/VibeAgentBuilderStore';
import { useThemeStore } from '../../lib/stores/theme-store';
import { resolveThemeVariant, useWallpaperStore } from '../../lib/stores/wallpaper-store';
import { NativeChatMainSurface, getNativeChatMainModule, mapMessagesToNativeRows } from '../../native/chat';
import { AGENT_USER_ID, type RuntimeChatMessage } from '../../native/chat/mapper';

type Mode = 'default' | 'builder';

interface VibeChatMainScreenProps {
  mode?: Mode;
  onBack?: () => void;
  onOpenBuilder?: () => void;
  onOpenSettings?: () => void;
}

const VIBE_TITLE = 'Vibe';
const VIBE_SUBTITLE = 'AI assistant';
const VIBE_HANDLE = '@vibe';
const BUILDER_TITLE = '@vibeagent';
const BUILDER_HANDLE = '@vibeagent';
const DEFAULT_SURFACE_ID = 'vibe-main-chat';
const BUILDER_SURFACE_ID = 'vibe-builder-chat';

const buildIntroMessage = (mode: Mode, selectedAgentLabel?: string | null, suggestions?: string[]) => {
  if (mode === 'builder') {
    const lines = [
      'I can create, configure, and explain how to integrate agents for you.',
      selectedAgentLabel
        ? `Current draft: ${selectedAgentLabel}`
        : 'Describe the agent naturally. I can set the prompt, webhook, ids, and integration details for you.',
    ];
    const topSuggestions = (suggestions || []).slice(0, 3);
    if (topSuggestions.length > 0) {
      lines.push('', topSuggestions.join('\n'));
    }
    return lines.join('\n');
  }

  return 'Ask anything, or mention @vibeagent to start building an agent.';
};

const getMessageTimestamp = (value: unknown, fallback: number) => {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string') {
    const parsedNumber = Number(value);
    if (Number.isFinite(parsedNumber)) return parsedNumber;
    const parsedDate = Date.parse(value);
    if (Number.isFinite(parsedDate)) return parsedDate;
  }
  return fallback;
};

type NativeOptimisticMessage = {
  messageId?: string;
  timestamp?: number;
};

export default function VibeChatMainScreen({
  mode = 'default',
  onBack,
  onOpenBuilder,
  onOpenSettings,
}: VibeChatMainScreenProps) {
  const insets = useSafeAreaInsets();
  const { colors, effectiveTheme } = useThemeStore();
  const activeWallpaperTheme = useWallpaperStore((state) => state.activeTheme);

  const conversations = useAgentStore((state) => state.conversations);
  const activeConversationId = useAgentStore((state) => state.activeConversationId);
  const isConnected = useAgentStore((state) => state.isConnected);
  const hasHydrated = useAgentStore((state) => state._hasHydrated);
  const connect = useAgentStore((state) => state.connect);
  const createConversation = useAgentStore((state) => state.createConversation);
  const loadConversation = useAgentStore((state) => state.loadConversation);
  const loadFromStorage = useAgentStore((state) => state.loadFromStorage);
  const sendAgentMessage = useAgentStore((state) => state.sendMessage);
  const setActiveConversation = useAgentStore((state) => state.setActiveConversation);
  const syncFromServer = useAgentStore((state) => state.syncFromServer);

  const builderConversationId = useVibeAgentBuilderStore((state) => state.conversationId);
  const builderMessages = useVibeAgentBuilderStore((state) => state.messages);
  const builderSuggestions = useVibeAgentBuilderStore((state) => state.suggestions);
  const builderAgent = useVibeAgentBuilderStore((state) => state.agent);
  const builderSetupState = useVibeAgentBuilderStore((state) => state.setupState);
  const builderPendingUiRequest = useVibeAgentBuilderStore((state) => state.pendingUiRequest);
  const builderReviewSections = useVibeAgentBuilderStore((state) => state.reviewSections);
  const builderActivity = useVibeAgentBuilderStore((state) => state.activity);
  const builderLoad = useVibeAgentBuilderStore((state) => state.load);
  const sendBuilderMessage = useVibeAgentBuilderStore((state) => state.sendMessage);
  const submitBuilderUiResponse = useVibeAgentBuilderStore((state) => state.submitUiResponse);
  const createBuilderDraft = useVibeAgentBuilderStore((state) => state.createDraftFromReview);
  const toggleBuilderAgentDisabled = useVibeAgentBuilderStore((state) => state.toggleDisableActive);

  const nativeMainModule = useMemo(() => getNativeChatMainModule(), []);
  const nativeAvailable = !!nativeMainModule && (nativeMainModule.isSupported?.() ?? true);
  const isBuilderMode = mode === 'builder';
  const surfaceId = useMemo(
    () => `${isBuilderMode ? BUILDER_SURFACE_ID : DEFAULT_SURFACE_ID}-${Math.random().toString(36).slice(2, 10)}`,
    [isBuilderMode],
  );

  const activeConversation = useMemo(() => {
    if (isBuilderMode) return null;
    const preferredId = activeConversationId || conversations[0]?.id || null;
    return preferredId ? conversations.find((conversation) => conversation.id === preferredId) || null : null;
  }, [activeConversationId, conversations, isBuilderMode]);

  useEffect(() => {
    if (isBuilderMode) {
      void builderLoad();
      return;
    }

    void loadFromStorage();
    connect();

    const syncTimer = setTimeout(() => {
      if (useAgentStore.getState().isConnected) {
        syncFromServer();
      }
    }, 1000);

    return () => clearTimeout(syncTimer);
  }, [builderLoad, connect, isBuilderMode, loadFromStorage, syncFromServer]);

  useEffect(() => {
    if (isBuilderMode) return;
    if (activeConversationId || conversations.length === 0) return;
    const fallbackConversationId = conversations[0]?.id;
    if (fallbackConversationId) {
      setActiveConversation(fallbackConversationId);
    }
  }, [activeConversationId, conversations, isBuilderMode, setActiveConversation]);

  useEffect(() => {
    if (isBuilderMode) return;
    if (!hasHydrated || !isConnected || !activeConversationId) return;

    const currentConversations = useAgentStore.getState().conversations;
    const activeConversationSnapshot = currentConversations.find(
      (conversation) => conversation.id === activeConversationId,
    );
    const lastMessage = activeConversationSnapshot?.messages[activeConversationSnapshot.messages.length - 1];
    const lastMessageTimestamp = typeof lastMessage?.timestamp === 'number' ? lastMessage.timestamp : 0;
    const hasRecentOptimisticUserMessage =
      lastMessage?.role === 'user' && Date.now() - lastMessageTimestamp < 5000;

    if (!hasRecentOptimisticUserMessage) {
      void loadConversation(activeConversationId);
    }
  }, [activeConversationId, hasHydrated, isBuilderMode, isConnected, loadConversation]);

  const resolvedWallpaperTheme = useMemo(() => {
    const resolved = resolveThemeVariant(activeWallpaperTheme, effectiveTheme === 'dark');
    const backgroundGradient = Array.isArray(resolved.backgroundGradient)
      ? resolved.backgroundGradient
      : [];

    return {
      ...resolved,
      backgroundGradient:
        backgroundGradient.length >= 2 ? backgroundGradient : [colors.background, colors.background],
    };
  }, [activeWallpaperTheme, colors.background, effectiveTheme]);

  const nativeRows = useMemo(() => {
    const sourceMessages = isBuilderMode
      ? builderMessages
      : (activeConversation?.messages || []);

    const runtimeMessages: RuntimeChatMessage[] = sourceMessages.map((message, index) => {
      const timestampMs = getMessageTimestamp(
        (message as any)?.timestamp,
        Date.now() + index,
      );
      const isUser = message.role === 'user';

      return {
        id: message.id || `${mode}-${index}-${timestampMs}`,
        chatId: isBuilderMode ? (builderConversationId || BUILDER_SURFACE_ID) : (activeConversation?.id || DEFAULT_SURFACE_ID),
        fromId: isUser ? 'me' : AGENT_USER_ID,
        timestampMs,
        timestamp: new Date(timestampMs).toISOString(),
        text: message.content,
        plainContent: isUser ? undefined : message.content,
        type: 'text',
        status: isUser ? 'sent' : undefined,
        isMe: isUser,
        isAgentMessage: !isUser,
        agentName: !isUser ? (isBuilderMode ? 'VibeAgent' : 'Vibe') : undefined,
        isStreaming: !isUser && (message as any)?.isStreaming === true,
      };
    });

    if (runtimeMessages.length === 0) {
      const introTimestamp = Date.now();
      runtimeMessages.push({
        id: `${mode}-intro`,
        chatId: isBuilderMode ? BUILDER_SURFACE_ID : DEFAULT_SURFACE_ID,
        fromId: AGENT_USER_ID,
        timestampMs: introTimestamp,
        timestamp: new Date(introTimestamp).toISOString(),
        text: buildIntroMessage(
          mode,
          builderAgent?.username ? `@${builderAgent.username}` : builderAgent?.displayName || null,
          builderSuggestions,
        ),
        plainContent: buildIntroMessage(
          mode,
          builderAgent?.username ? `@${builderAgent.username}` : builderAgent?.displayName || null,
          builderSuggestions,
        ),
        type: 'text',
        isMe: false,
        isAgentMessage: true,
        agentName: isBuilderMode ? 'VibeAgent' : 'Vibe',
      });
    }

    runtimeMessages.sort((left, right) => left.timestampMs - right.timestampMs);
    return mapMessagesToNativeRows(runtimeMessages);
  }, [
    activeConversation?.id,
    activeConversation?.messages,
    builderActivity,
    builderAgent?.displayName,
    builderAgent?.username,
    builderConversationId,
    builderMessages,
    builderPendingUiRequest,
    builderReviewSections,
    builderSetupState,
    builderSuggestions,
    isBuilderMode,
    mode,
  ]);

  const builderSetupPanel = useMemo(() => {
    if (!isBuilderMode) return null;
    return {
      setupState: builderSetupState,
      pendingUiRequest: builderPendingUiRequest,
      reviewSections: builderReviewSections,
      activity: builderActivity,
      agentEnabled: builderAgent?.status !== 'disabled',
    };
  }, [
    builderAgent?.status,
    builderActivity,
    builderPendingUiRequest,
    builderReviewSections,
    builderSetupState,
    isBuilderMode,
  ]);

  const handleSubmit = useCallback(async (rawText: string, optimistic?: NativeOptimisticMessage) => {
    const trimmed = rawText.trim();
    if (!trimmed) return;

    const currentText = trimmed;

    if (isBuilderMode) {
      await sendBuilderMessage(currentText, optimistic);
      return;
    }

    if (!useAgentStore.getState().activeConversationId) {
      createConversation(currentText.slice(0, 30));
    }

    sendAgentMessage(currentText, undefined, false, undefined, optimistic);
  }, [createConversation, isBuilderMode, sendAgentMessage, sendBuilderMessage]);

  const handleNativeEvent = useCallback((event: { nativeEvent?: Record<string, unknown> } | Record<string, unknown>) => {
    const eventPayload = (event as any)?.nativeEvent || (event as Record<string, unknown>) || {};
    const payload =
      eventPayload && typeof eventPayload.payload === 'object' && eventPayload.payload
        ? (eventPayload.payload as Record<string, unknown>)
        : eventPayload;
    const type = typeof payload.type === 'string' ? payload.type : '';

    if (type === 'mainPageChanged') return;

    if (type === 'headerBack') {
      onBack?.();
      return;
    }

    if (type === 'headerAvatarPressed' || type === 'headerAgentPressed') {
      onOpenSettings?.();
      return;
    }

    if (type === 'openVibeAgentBuilder') {
      onOpenBuilder?.();
      return;
    }

    if (type === 'builderSetupSubmit' && isBuilderMode) {
      const requestId = typeof payload.requestId === 'string' ? payload.requestId.trim() : '';
      if (!requestId) return;

      const answers =
        payload.answers && typeof payload.answers === 'object'
          ? (payload.answers as Record<string, unknown>)
          : {};
      const optimisticUserContent =
        typeof payload.summary === 'string' && payload.summary.trim().length > 0
          ? payload.summary.trim()
          : undefined;

      void submitBuilderUiResponse(requestId, answers, optimisticUserContent);
      return;
    }

    if (type === 'builderReviewCreateDraft' && isBuilderMode) {
      const desiredEnabled =
        typeof payload.agentEnabled === 'boolean' ? payload.agentEnabled : undefined;
      const currentEnabled = builderAgent?.status !== 'disabled';

      void (async () => {
        if (typeof desiredEnabled === 'boolean' && desiredEnabled !== currentEnabled) {
          await toggleBuilderAgentDisabled();
        }
        await createBuilderDraft();
      })();
      return;
    }

    if (type !== 'sendMessage') return;

    const text =
      (typeof payload.agentText === 'string' && payload.agentText.trim())
      || (typeof payload.text === 'string' && payload.text.trim())
      || '';

    if (!text) return;
    const messageId = typeof payload.messageId === 'string' ? payload.messageId : undefined;
    const timestamp = getMessageTimestamp(payload.timestampMs ?? payload.timestamp, Date.now());
    void handleSubmit(text, {
      messageId,
      timestamp,
    });
  }, [
    createBuilderDraft,
    builderAgent?.status,
    handleSubmit,
    isBuilderMode,
    onBack,
    onOpenBuilder,
    onOpenSettings,
    submitBuilderUiResponse,
    toggleBuilderAgentDisabled,
  ]);

  if (!nativeAvailable) {
    return (
      <View
        style={{
          flex: 1,
          backgroundColor: colors.background,
          justifyContent: 'center',
          alignItems: 'center',
          paddingHorizontal: 24,
        }}
      >
        <Text style={{ color: colors.text, textAlign: 'center' }}>
          Native main chat view is unavailable in this build. Rebuild the app after native module changes.
        </Text>
      </View>
    );
  }

  const headerTitle = isBuilderMode ? BUILDER_TITLE : VIBE_TITLE;
  const headerSubtitle = isBuilderMode
    ? (
      builderAgent?.username
        ? `Editing @${builderAgent.username}`
        : 'Agent setup assistant'
    )
    : VIBE_SUBTITLE;
  const profileBio = isBuilderMode
    ? 'Create agents in chat, describe them naturally, and get the exact invoke URL, webhook setup, and vibeChatId guidance.'
    : 'Ask questions, generate content, and jump into @vibeagent when you want to build a standalone agent.';

  return (
    <View style={{ flex: 1, backgroundColor: 'transparent' }}>
      <NativeChatMainSurface
        forceRender
        surfaceId={surfaceId}
        rows={nativeRows}
        appearance={{
          backgroundMode: 'gradient',
          nativeThemeId: `${isBuilderMode ? 'vibeagent' : 'vibe'}-${effectiveTheme}`,
          nativeThemeIsDark: effectiveTheme === 'dark',
          wallpaperGradient: resolvedWallpaperTheme.backgroundGradient,
          wallpaperOpacity: 1,
          wallpaperPatternGradient: resolvedWallpaperTheme.patternGradientColors || [],
          wallpaperPatternLocations: resolvedWallpaperTheme.patternGradientLocations || undefined,
          wallpaperPatternOpacity: resolvedWallpaperTheme.patternOpacity || 0,
          wallpaperMaskKey: resolvedWallpaperTheme.maskedImage || resolvedWallpaperTheme.patternType || undefined,
          bubbleMeGradient: resolvedWallpaperTheme.bubbleMeGradient || [
            resolvedWallpaperTheme.bubbleMe,
            resolvedWallpaperTheme.bubbleMe,
          ],
          bubbleThemGradient:
            resolvedWallpaperTheme.bubbleThemGradient
            || [resolvedWallpaperTheme.bubbleThem, resolvedWallpaperTheme.bubbleThem],
          bubbleThemColor:
            resolvedWallpaperTheme.bubbleThemGradient?.[0]
            || resolvedWallpaperTheme.bubbleThem
            || colors.card,
          textColorMe: resolvedWallpaperTheme.textColorMe || colors.text,
          textColorThem: resolvedWallpaperTheme.textColorThem || colors.text,
          timeColorThem: colors.textSecondary,
        }}
        contentPaddingTop={0}
        contentPaddingBottom={Math.max(14, insets.bottom + 8)}
        inputBarEnabled
        inputPlaceholder={isBuilderMode ? 'Describe your agent, or type /' : 'Message Vibe'}
        nativeSendEnabled={false}
        headerTitle={headerTitle}
        headerSubtitle={headerSubtitle}
        profileName={headerTitle}
        profileHandle={isBuilderMode ? BUILDER_HANDLE : VIBE_HANDLE}
        profileBio={profileBio}
        builderSetupPanel={builderSetupPanel}
        onNativeEvent={handleNativeEvent}
        onNativeError={(error, context) => {
          console.warn('[vibe/native-main]', context, error);
        }}
      />
    </View>
  );
}
