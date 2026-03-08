import React, { useState, useRef, useEffect, useMemo } from 'react'
import {
    View,
    Text,
    StyleSheet,
    Dimensions,
    ScrollView,
    Alert,
    TouchableOpacity,
    Modal,
    useWindowDimensions,
    Keyboard,
    DeviceEventEmitter,
    Pressable
} from 'react-native'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import Animated, {
    FadeIn,
    useSharedValue,
    useAnimatedStyle,
    withSpring,
    cancelAnimation,
    runOnJS,
    interpolate,
    Extrapolate,
    useDerivedValue
} from 'react-native-reanimated'
import { Gesture, GestureDetector, GestureHandlerRootView } from 'react-native-gesture-handler'
import { LinearGradient } from 'expo-linear-gradient'
import MaskedView from '@react-native-masked-view/masked-view'
import { BlurView } from 'expo-blur'
import { useThemeStore } from '../../lib/stores/theme-store'
import { useWallpaperStore, resolveThemeVariant } from '../../lib/stores/wallpaper-store'
import { useAgentStore } from '../../lib/agent/AgentStore'
import ChatInput from '../../components/shared/ChatInput'
import { isNativeTabBarAvailable } from '../native/NativeTabBar'
import StreamingText from '../../components/shared/StreamingText'
import { KeyboardStickyView } from 'react-native-keyboard-controller'
import { AgentLoader, ProgressItem } from '../../components/ui/AgentLoader'
import { useHaptics } from '../../lib/hooks/useHaptics'
import SafeLiquidGlass from '../native/SafeLiquidGlass'
import AnimatedGlassButton from '../native/AnimatedGlassButton'
import { DocumentIcon, RefreshIcon, ThumbUpIcon, ThumbDownIcon, HistoryIcon, PlusIcon, CloseIcon } from '../../components/Icons'
import * as Clipboard from 'expo-clipboard'
import { MessageContextMenu, GlassToast } from '../../components/chat/ChatOverlays'
import { ArrowLeft, Settings, Plus, Trash2, MessageSquare, Clock } from 'lucide-react-native'

import { MusicBubble } from './MusicBubble'
import { MessageBubbleBody } from '../../components/chat/bubbles'

const MaskedViewAny = MaskedView as any
const AnimatedView = Animated.View as any
const { height: SCREEN_HEIGHT, width: SCREEN_WIDTH } = Dimensions.get('window')

// RTL Helper
const isRTL = (text: string) => /[\u0591-\u07FF\uFB1D-\uFDFD\uFE70-\uFEFC]/.test(text)

// Helper for alpha colors
const withAlpha = (color: string, alpha: number): string => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`
    if (color.startsWith('#')) {
        const hex = color.replace('#', '')
        const r = parseInt(hex.substring(0, 2), 16)
        const g = parseInt(hex.substring(2, 4), 16)
        const b = parseInt(hex.substring(4, 6), 16)
        return `rgba(${r}, ${g}, ${b}, ${alpha})`
    }
    return color
}

// Message type
interface Message {
    id: string
    role: 'user' | 'agent' | 'assistant'
    content?: string
    message?: string
    segments?: any[]
    timestamp?: string | number
    pairId?: string
    toolResults?: any[]
}

// Conversation type from store
interface Conversation {
    id: string
    title: string
    createdAt: number
    messages: Message[]
}

const MessageItem = React.memo(({ item, index, onLongPress, isActive, renderActionButtons, nextItem, prevItem }: any) => {
    const { colors } = useThemeStore()
    const isUser = item.role === 'user'
    const messageText = item.content || item.message || ''

    // Sequence logic for tails/corners
    const isSequenceStart = !prevItem || prevItem.role !== item.role
    const isSequenceEnd = !nextItem || nextItem.role !== item.role
    const isMiddle = !isSequenceStart && !isSequenceEnd

    return (
        <View style={{ marginBottom: isSequenceEnd ? 16 : 4 }}>
            {isUser ? (
                <View style={{ alignItems: 'flex-end', paddingHorizontal: 16 }}>
                    <TouchableOpacity
                        activeOpacity={0.9}
                        onLongPress={(e) => onLongPress(e, item, messageText)}
                    >
                        <LinearGradient
                            colors={isActive ? [colors.primary, colors.primary] : (item.bubbleTheme?.meGradient || ['#007AFF', '#007AFF'])}
                            start={{ x: 0, y: 0 }}
                            end={{ x: 1, y: 1 }}
                            style={[
                                {
                                    padding: 8,
                                    paddingHorizontal: 12,
                                    borderRadius: 18,
                                    maxWidth: '85%',
                                },
                                { borderBottomRightRadius: 4 }
                            ]}
                        >
                            <MessageBubbleBody
                                item={{
                                    ...item,
                                    isMe: true,
                                    text: messageText,
                                    timestamp: item.timestamp ? (typeof item.timestamp === 'number' ? new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false }) : item.timestamp) : ''
                                } as any}
                            />
                        </LinearGradient>
                    </TouchableOpacity>
                </View>
            ) : (
                <View style={{ paddingLeft: 8, paddingRight: 32, paddingVertical: 4 }}>
                    <StreamingText
                        text={messageText}
                        isStreaming={false}
                        style={{ fontSize: 18, lineHeight: 26, color: colors.text }}
                    />
                </View>
            )}
            {!isUser && messageText && renderActionButtons && renderActionButtons(item, messageText)}

            {/* Tool Results - if any additional results besides music need separate rendering */}
            {!isUser && item.toolResults?.find((t: any) => t.tool === 'search_music')?.data?.tracks && (
                <View style={{ marginLeft: 8, marginTop: 4 }}>
                    <MusicBubble tracks={item.toolResults.find((t: any) => t.tool === 'search_music').data.tracks} />
                </View>
            )}
        </View>
    )
})

// History Panel Component
const HistoryPanel = ({
    conversations,
    activeConversationId,
    onSelectConversation,
    onNewConversation,
    onDeleteConversation
}: {
    conversations: Conversation[]
    activeConversationId: string | null
    onSelectConversation: (id: string) => void
    onNewConversation: () => void
    onDeleteConversation: (id: string) => void
}) => {
    const { colors, effectiveTheme } = useThemeStore()
    const insets = useSafeAreaInsets()
    const haptic = useHaptics()

    const formatDate = (timestamp: number) => {
        const date = new Date(timestamp)
        const now = new Date()
        const diff = now.getTime() - date.getTime()
        const days = Math.floor(diff / (1000 * 60 * 60 * 24))

        if (days === 0) return 'Today'
        if (days === 1) return 'Yesterday'
        if (days < 7) return `${days} days ago`
        return date.toLocaleDateString()
    }

    return (
        <View style={{ flex: 1, backgroundColor: colors.background }}>
            {/* Conversations List */}
            <ScrollView
                style={{ flex: 1 }}
                contentContainerStyle={{ paddingTop: insets.top + 80, paddingBottom: 100 }}
                showsVerticalScrollIndicator={false}
            >
                {conversations.length === 0 ? (
                    <View style={{ padding: 20, alignItems: 'center' }}>
                        <MessageSquare color={colors.textSecondary} size={48} style={{ opacity: 0.3 }} />
                        <Text style={{ color: colors.textSecondary, marginTop: 16, textAlign: 'center' }}>
                            No conversations yet.{'\n'}Start chatting with Vibe AI!
                        </Text>
                    </View>
                ) : (
                    conversations.map((conv) => (
                        <TouchableOpacity
                            key={conv.id}
                            onPress={() => {
                                haptic.selection()
                                onSelectConversation(conv.id)
                            }}
                            onLongPress={() => {
                                haptic.medium()
                                Alert.alert(
                                    'Delete Conversation',
                                    'Are you sure you want to delete this conversation?',
                                    [
                                        { text: 'Cancel', style: 'cancel' },
                                        {
                                            text: 'Delete',
                                            style: 'destructive',
                                            onPress: () => onDeleteConversation(conv.id)
                                        }
                                    ]
                                )
                            }}
                            style={{
                                paddingHorizontal: 20,
                                paddingVertical: 16,
                                borderBottomWidth: 1,
                                borderBottomColor: withAlpha(colors.text, 0.05),
                                opacity: conv.id === activeConversationId ? 1 : 0.7
                            }}
                        >
                            <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                                <View style={{ flex: 1, marginRight: 12 }}>
                                    <Text
                                        numberOfLines={1}
                                        style={{
                                            fontSize: 16,
                                            fontWeight: '600',
                                            color: colors.text,
                                            marginBottom: 4
                                        }}
                                    >
                                        {conv.title || 'New Conversation'}
                                    </Text>
                                    <Text
                                        numberOfLines={1}
                                        style={{
                                            fontSize: 14,
                                            color: colors.textSecondary
                                        }}
                                    >
                                        {conv.messages.length > 0
                                            ? (conv.messages[conv.messages.length - 1].content || 'No messages')
                                            : 'No messages'}
                                    </Text>
                                </View>
                                <Text style={{ fontSize: 12, color: colors.textSecondary, marginTop: 2 }}>
                                    {formatDate(conv.createdAt)}
                                </Text>
                            </View>
                        </TouchableOpacity>
                    ))
                )}
            </ScrollView>
        </View>
    )
}

const EMPTY_MESSAGES: Message[] = []

export default function ChatScreen({
    keyboardProgress,
    keyboardHeight,
    onSettings,
    onBack
}: {
    keyboardProgress?: any,
    keyboardHeight?: any,
    onSettings?: () => void,
    onBack?: () => void
}) {
    const insets = useSafeAreaInsets()
    const { colors, effectiveTheme } = useThemeStore()
    const { activeTheme } = useWallpaperStore()
    const isLight = effectiveTheme === 'light'
    const haptic = useHaptics()

    const resolvedTheme = useMemo(() => {
        return resolveThemeVariant(activeTheme, effectiveTheme === 'dark');
    }, [activeTheme, effectiveTheme]);

    const bubbleTheme = useMemo(() => ({
        meGradient: (resolvedTheme.bubbleMeGradient && resolvedTheme.bubbleMeGradient.length >= 2
            ? [resolvedTheme.bubbleMeGradient[0], resolvedTheme.bubbleMeGradient[1]]
            : [resolvedTheme.bubbleMe, resolvedTheme.bubbleMe]) as [string, string],
        themGradient: (resolvedTheme.bubbleThemGradient && resolvedTheme.bubbleThemGradient.length >= 2
            ? [resolvedTheme.bubbleThemGradient[0], resolvedTheme.bubbleThemGradient[1]]
            : [resolvedTheme.bubbleThem, resolvedTheme.bubbleThem]) as [string, string],
    }), [resolvedTheme]);

    // Store state - Phoenix Channel based
    const conversations = useAgentStore((state) => state.conversations)
    const storeMessages = useAgentStore((state) => (state.conversations || []).find(c => c.id === state.activeConversationId)?.messages || EMPTY_MESSAGES)
    const currentConversationId = useAgentStore((state) => state.activeConversationId)
    const storeIsStreaming = useAgentStore((state) => state.isStreaming)
    const storeIsLoading = useAgentStore((state) => state.isLoading)
    const currentTool = useAgentStore((state) => state.currentTool)
    const storeError = useAgentStore((state) => state.error)
    const isConnected = useAgentStore((state) => state.isConnected)
    const hasHydrated = useAgentStore((state) => state._hasHydrated)

    // Store actions
    const connect = useAgentStore((state) => state.connect)
    const sendMessage = useAgentStore((state) => state.sendMessage)
    const createNewConversation = useAgentStore((state) => state.createConversation)
    const deleteConversation = useAgentStore((state) => state.deleteConversation)
    const setActiveConversation = useAgentStore((state) => state.setActiveConversation)
    const loadFromStorage = useAgentStore((state) => state.loadFromStorage)
    const stopStreaming = useAgentStore((state) => state.stopStreaming)
    const syncFromServer = useAgentStore((state) => state.syncFromServer)
    const loadConversation = useAgentStore((state) => state.loadConversation)

    // Local state for UI
    const [localMessages, setLocalMessages] = useState<Message[]>([])
    const [inputText, setInputText] = useState('')
    const [animationComplete, setAnimationComplete] = useState(false)
    const scrollViewRef = useRef<any>(null)
    const userMessageCountRef = useRef(0)
    const [spacerHeight, setSpacerHeight] = useState(0)

    // Context Menu & Toast State
    const [contextMenu, setContextMenu] = useState<{ visible: boolean, messageId?: string, isUser?: boolean, content?: string, y?: number } | null>(null)
    const [editingMessageId, setEditingMessageId] = useState<string | null>(null)
    const [toastVisible, setToastVisible] = useState(false)

    // Progress History - derived from currentTool
    const [progressHistory, setProgressHistory] = useState<ProgressItem[]>([])
    const { width, height } = useWindowDimensions()

    // --- SWIPE LOGIC (Chat <-> History) ---
    const pageIndex = useSharedValue(0) // 0 = Chat, 1 = History
    const translateX = useSharedValue(0)
    const isGesturing = useSharedValue(false)

    const navigateToHistory = () => {
        Keyboard.dismiss()
        pageIndex.value = 1
        translateX.value = withSpring(-SCREEN_WIDTH, { damping: 24, stiffness: 220, mass: 0.8 })
    }

    const navigateToChat = () => {
        Keyboard.dismiss()
        pageIndex.value = 0
        translateX.value = withSpring(0, { damping: 24, stiffness: 220, mass: 0.8 })
    }

    const gesture = Gesture.Pan()
        .activeOffsetX([-20, 20])
        .failOffsetY([-20, 20])
        .onStart(() => {
            isGesturing.value = true
            cancelAnimation(translateX)
        })
        .onUpdate((e) => {
            const baseX = -pageIndex.value * SCREEN_WIDTH
            let newX = baseX + e.translationX

            // Rubber banding
            if (newX > 0) newX = e.translationX * 0.3
            if (newX < -SCREEN_WIDTH) {
                const diff = newX - (-SCREEN_WIDTH)
                newX = -SCREEN_WIDTH + diff * 0.3
            }
            translateX.value = newX
        })
        .onEnd((e) => {
            isGesturing.value = false
            const { translationX, velocityX } = e
            const threshold = SCREEN_WIDTH * 0.25
            const currentPage = pageIndex.value
            let nextIndex = currentPage

            if (currentPage === 0) { // On Chat
                if (translationX < -threshold || velocityX < -500) nextIndex = 1
            } else { // On History
                if (translationX > threshold || velocityX > 500) nextIndex = 0
            }

            pageIndex.value = nextIndex
            translateX.value = withSpring(-nextIndex * SCREEN_WIDTH, {
                damping: 24, stiffness: 220, mass: 0.8, velocity: velocityX
            })
        })

    const swipeStyle = useAnimatedStyle(() => ({
        transform: [{ translateX: translateX.value }]
    }))

    const chatTitleStyle = useAnimatedStyle(() => ({
        opacity: interpolate(translateX.value, [-SCREEN_WIDTH / 2, 0], [0, 1], Extrapolate.CLAMP),
        transform: [{ translateY: interpolate(translateX.value, [-SCREEN_WIDTH / 2, 0], [-10, 0], Extrapolate.CLAMP) }]
    }))

    const historyTitleStyle = useAnimatedStyle(() => ({
        opacity: interpolate(translateX.value, [-SCREEN_WIDTH, -SCREEN_WIDTH / 2], [1, 0], Extrapolate.CLAMP),
        transform: [{ translateY: interpolate(translateX.value, [-SCREEN_WIDTH, -SCREEN_WIDTH / 2], [0, 10], Extrapolate.CLAMP) }]
    }))

    const headerButtonProgress = useDerivedValue(() => {
        return interpolate(translateX.value, [0, -SCREEN_WIDTH], [0, 1], Extrapolate.CLAMP)
    })
    // ------------------------------------

    // Connect to Phoenix Channel on mount and refresh data
    useEffect(() => {
        loadFromStorage()
        connect()

        // Sync from server after connection is established
        const syncTimer = setTimeout(() => {
            if (isConnected) {
                syncFromServer()
            }
        }, 1000)

        return () => clearTimeout(syncTimer)
    }, [])

    // Load active conversation messages when switching or on reconnect
    useEffect(() => {
        if (hasHydrated && isConnected && currentConversationId) {
            // Check if we have recent local messages (optimistic state) to avoid overwriting with empty server state
            // This happens when 'createConversation' updates the ID and we have a pending user message
            const currentConvs = useAgentStore.getState().conversations
            const activeConv = currentConvs.find(c => c.id === currentConversationId)
            const lastMsg = activeConv?.messages[activeConv.messages.length - 1]

            const isRecentUserMessage = lastMsg?.role === 'user' &&
                (Date.now() - (typeof lastMsg.timestamp === 'number' ? lastMsg.timestamp : 0) < 5000)

            if (isRecentUserMessage) {
                console.log('[ChatScreen] Skipping loadConversation to preserve optimistic state')
                return
            }

            // Always reload conversation from server to get fresh messages
            loadConversation(currentConversationId)
        }
    }, [hasHydrated, isConnected, currentConversationId])

    // Sync progress from tool events
    useEffect(() => {
        if (currentTool && currentTool.label) {
            setProgressHistory(prev => {
                if (prev.some(p => p.label === currentTool.label)) return prev
                return [...prev, {
                    label: currentTool.label || '',
                    badges: [],
                    eventType: 'progress'
                }]
            })
        }
    }, [currentTool])

    // Effects - sync from store
    useEffect(() => {
        if (storeMessages && storeMessages.length > 0) {
            setLocalMessages(storeMessages as Message[])
            userMessageCountRef.current = storeMessages.filter(m => m.role === 'user').length
        } else {
            setLocalMessages([])
            userMessageCountRef.current = 0
        }
    }, [storeMessages])

    useEffect(() => {
        setSpacerHeight(0)
    }, [currentConversationId])

    const { flatListMessages, footerMessages } = useMemo(() => {
        if (!localMessages.length) return { flatListMessages: [], footerMessages: [] }
        const lastUserIndex = localMessages.map(m => m.role).lastIndexOf('user')
        if (lastUserIndex === -1) {
            return { flatListMessages: localMessages, footerMessages: [] }
        }
        return {
            flatListMessages: localMessages.slice(0, lastUserIndex + 1),
            footerMessages: localMessages.slice(lastUserIndex + 1)
        }
    }, [localMessages])

    const handleCopy = async (text: string) => {
        await Clipboard.setStringAsync(text)
        haptic.light()
        setToastVisible(true)
    }

    const handleEditInit = (messageId: string, content: string) => {
        setEditingMessageId(messageId)
        setInputText(content)
        setContextMenu(null)
    }

    const handleStopStreaming = () => {
        stopStreaming()
    }

    const handleRegenerate = async (userText: string, agentMsgId: string) => {
        if (!userText.trim() || !currentConversationId) return
        haptic.medium()
        setAnimationComplete(false)

        // Cleanup: remove the agent message and any subsequent messages to "regenerate" from that point
        const msgIndex = localMessages.findIndex(m => m.id === agentMsgId)
        if (msgIndex !== -1) {
            setLocalMessages(prev => prev.slice(0, msgIndex))
        }

        // Set spacer height for the new response
        userMessageCountRef.current = localMessages.filter(m => m.role === 'user').length
        setSpacerHeight(userMessageCountRef.current <= 1 ? SCREEN_HEIGHT * 0.2 : SCREEN_HEIGHT * 0.65)

        setProgressHistory([])
        // Use true for isRegenerate to prevent adding the user message again
        sendMessage(userText, undefined, true)
        setTimeout(() => scrollViewRef.current?.scrollToEnd({ animated: true }), 100)
    }

    const handleSend = async (text: string) => {
        if (!text.trim()) return
        haptic.selection()
        setAnimationComplete(false)
        const finalText = text.trim()
        setInputText('')
        setProgressHistory([])

        try {
            let convId = currentConversationId
            if (!convId) {
                convId = createNewConversation(finalText.substring(0, 20))
            }

            if (editingMessageId) {
                const editIndex = localMessages.findIndex(m => m.id === editingMessageId)
                if (editIndex !== -1) {
                    setLocalMessages(prev => {
                        const truncated = prev.slice(0, editIndex + 1)
                        truncated[editIndex] = { ...truncated[editIndex], content: finalText }
                        return truncated
                    })
                    setEditingMessageId(null)
                }
            }

            userMessageCountRef.current += 1
            setSpacerHeight(userMessageCountRef.current === 1 ? SCREEN_HEIGHT * 0.2 : SCREEN_HEIGHT * 0.65)
            sendMessage(finalText)
            setTimeout(() => scrollViewRef.current?.scrollToEnd({ animated: true }), 100)

        } catch (e) {
            console.error(e)
            Alert.alert('Error', 'Failed to send message')
        }
    }

    // (handleSendRef removed as dispatch is globalized)

    // Bind Native Tab Bar 'Message Vibe' to UI effects 
    useEffect(() => {
        const sub = DeviceEventEmitter.addListener('onVibeSubmit', (text: string) => {
            console.log('[AgentChatScreen] Updating UI after native submit:', text)
            setInputText('')
            setProgressHistory([])
            setAnimationComplete(false)
            haptic.selection()

            // Adjust spacers to allow scroll view to bump down to keyboard height comfortably
            userMessageCountRef.current += 1
            setSpacerHeight(userMessageCountRef.current === 1 ? SCREEN_HEIGHT * 0.2 : SCREEN_HEIGHT * 0.65)
            setTimeout(() => scrollViewRef.current?.scrollToEnd({ animated: true }), 100)
        })
        return () => sub.remove()
    }, [])

    const handleSelectConversation = (id: string) => {
        setActiveConversation(id)
        navigateToChat()
    }

    const handleNewConversation = () => {
        const id = createNewConversation('New Chat')
        setActiveConversation(id)
        navigateToChat()
    }

    const handleDeleteConversation = (id: string) => {
        deleteConversation(id)
        haptic.medium()
    }

    const getUserTextForMessage = (msgId: string) => {
        const msgIndex = localMessages.findIndex(m => m.id === msgId)
        if (msgIndex === -1) return ''

        // Look backwards for the first user message
        for (let i = msgIndex - 1; i >= 0; i--) {
            if (localMessages[i].role === 'user') {
                return localMessages[i].content || localMessages[i].message || ''
            }
        }
        return ''
    }

    const renderActionButtons = (msg: Message, messageText: string) => (
        <AnimatedView entering={FadeIn.duration(200)} style={{ flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 8 }}>
            <TouchableOpacity onPress={() => handleCopy(messageText)} style={{ padding: 6, borderRadius: 8 }}>
                <DocumentIcon size={16} color={withAlpha(colors.text, 0.5)} strokeWidth={1.6} />
            </TouchableOpacity>
            <TouchableOpacity onPress={() => { haptic.light(); setToastVisible(true) }} style={{ padding: 6, borderRadius: 8 }}>
                <ThumbUpIcon size={16} color={withAlpha(colors.text, 0.5)} strokeWidth={1.6} />
            </TouchableOpacity>
            <TouchableOpacity onPress={() => { haptic.light(); setToastVisible(true) }} style={{ padding: 6, borderRadius: 8 }}>
                <ThumbDownIcon size={16} color={withAlpha(colors.text, 0.5)} strokeWidth={1.6} />
            </TouchableOpacity>
            <TouchableOpacity onPress={() => handleRegenerate(getUserTextForMessage(msg.id), msg.id)} style={{ padding: 6, borderRadius: 8 }}>
                <RefreshIcon size={16} color={withAlpha(colors.text, 0.5)} strokeWidth={1.6} />
            </TouchableOpacity>
        </AnimatedView>
    )

    const renderFooterMessages = () => {
        if (footerMessages.length === 0) return null
        return (
            <View>
                {footerMessages.map((msg, idx) => {
                    if (msg.role === 'user') return null
                    const messageText = msg.content || msg.message || ''
                    const isStreamingMsg = storeIsStreaming && idx === footerMessages.length - 1
                    const showActions = !isStreamingMsg && messageText && (animationComplete || !storeIsStreaming)
                    const isRtlText = isRTL(messageText)

                    return (
                        <AnimatedView key={msg.id || idx} entering={FadeIn.duration(300)} style={{ marginBottom: 24 }}>
                            {(!messageText && isStreamingMsg) && <AgentLoader text="Thinking..." showProgress={true} progressHistory={progressHistory} isStreaming={true} isComplete={false} />}
                            {messageText && (
                                <View style={{ paddingLeft: 8, paddingRight: 32 }}>
                                    {progressHistory.length > 0 && <AgentLoader text={isStreamingMsg ? "Thinking..." : ""} showProgress={true} progressHistory={progressHistory} isStreaming={isStreamingMsg} isComplete={!isStreamingMsg} style={{ marginBottom: 8 }} />}
                                    <StreamingText
                                        text={messageText}
                                        isStreaming={isStreamingMsg}
                                        style={{ fontSize: 18, lineHeight: 26, color: colors.text, textAlign: isRtlText ? 'right' : 'left' }}
                                        onAnimationComplete={() => setAnimationComplete(true)}
                                    />
                                </View>
                            )}
                            {msg.toolResults?.find((t: any) => t.tool === 'search_music')?.data?.tracks && (
                                <View style={{ marginLeft: 8, marginTop: 4 }}>
                                    <MusicBubble tracks={msg.toolResults.find((t: any) => t.tool === 'search_music').data.tracks} />
                                </View>
                            )}
                            {messageText && showActions && renderActionButtons(msg, messageText)}
                        </AnimatedView>
                    )
                })}
            </View>
        )
    }

    // Sort conversations by most recent
    const sortedConversations = useMemo(() => {
        return [...conversations].sort((a, b) => b.createdAt - a.createdAt)
    }, [conversations])

    return (
        <View style={{ flex: 1, backgroundColor: colors.background }}>
            <GestureHandlerRootView style={{ flex: 1 }}>

                {/* --- SHARED HEADER --- */}
                <View style={{ position: 'absolute', top: 0, left: 0, right: 0, height: insets.top + 60, zIndex: 100 }}>
                    {/* Header Mask */}
                    <View style={styles.headerContainer}>
                        <MaskedViewAny
                            style={StyleSheet.absoluteFill}
                            maskElement={<LinearGradient colors={['rgba(0,0,0,1)', 'rgba(0,0,0,0)']} locations={[0.6, 1]} style={StyleSheet.absoluteFill} />}
                        >
                            <BlurView intensity={10} tint={effectiveTheme === 'dark' ? 'dark' : 'light'} style={[StyleSheet.absoluteFill, { backgroundColor: 'transparent' }]} />
                        </MaskedViewAny>
                    </View>

                    {/* Header Content */}
                    <View style={[styles.headerContentContainer, { paddingTop: insets.top + 10, height: '100%' }]}>
                        {/* Left: Back / Close */}
                        <View style={styles.headerBtnWrapper}>
                            <AnimatedGlassButton
                                progress={headerButtonProgress}
                                homeIcon={<ArrowLeft color={colors.text} size={22} />}
                                panelIcon={<CloseIcon color={colors.text} size={22} />}
                                showPanelIcon={false}
                                onPress={() => {
                                    if (headerButtonProgress.value > 0.5) {
                                        navigateToChat()
                                    } else {
                                        onBack?.()
                                    }
                                }}
                                size={44}
                                effectiveTheme={effectiveTheme === 'dark' ? 'dark' : 'light'}
                                homeBackgroundColor="transparent"
                                panelBackgroundColor="transparent"
                            />
                        </View>

                        {/* Center: Dynamic Title */}
                        <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', height: 44 }}>
                            {/* Chat Title */}
                            <Animated.View style={[chatTitleStyle, { position: 'absolute', alignItems: 'center' }]}>
                                <Text style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>Vibe AI</Text>
                            </Animated.View>

                            {/* History Title */}
                            <Animated.View style={[historyTitleStyle, { position: 'absolute', alignItems: 'center' }]}>
                                <Text style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>History</Text>
                            </Animated.View>
                        </View>

                        {/* Right: Toggle / New Chat */}
                        <View style={styles.headerBtnWrapper}>
                            <AnimatedGlassButton
                                progress={headerButtonProgress}
                                homeIcon={<HistoryIcon color={colors.text} size={22} />}
                                panelIcon={<PlusIcon color={colors.text} size={22} />}
                                showPanelIcon={false}
                                onPress={() => {
                                    if (headerButtonProgress.value > 0.5) {
                                        handleNewConversation()
                                    } else {
                                        navigateToHistory()
                                    }
                                }}
                                size={44}
                                effectiveTheme={effectiveTheme === 'dark' ? 'dark' : 'light'}
                                homeBackgroundColor="transparent"
                                panelBackgroundColor="transparent"
                            />
                        </View>
                    </View>
                </View>

                <GestureDetector gesture={gesture}>
                    <Animated.View style={[{ flex: 1, flexDirection: 'row', width: SCREEN_WIDTH * 2 }, swipeStyle]}>

                        {/* --- PAGE 0: CHAT SCREEN --- */}
                        <View style={{ width: SCREEN_WIDTH, height: '100%' }}>
                            <View style={{ flex: 1, flexDirection: 'column' }}>
                                <ScrollView ref={scrollViewRef} style={{ flex: 1 }} contentContainerStyle={{ paddingTop: insets.top + 80, paddingHorizontal: 5, paddingBottom: 140, flexGrow: 1 }} showsVerticalScrollIndicator={false} keyboardDismissMode="interactive" keyboardShouldPersistTaps="handled">
                                    <View style={{ flexGrow: 1, minHeight: '100%' }}>
                                        <Pressable style={{ flexGrow: 1 }} onPress={() => Keyboard.dismiss()}>
                                            <AnimatedView style={[{ height: spacerHeight }]} />
                                        </Pressable>
                                        {flatListMessages.map((msg, index) => (
                                            <MessageItem
                                                key={msg.id || index}
                                                item={{
                                                    ...msg,
                                                    bubbleTheme
                                                }}
                                                index={index}
                                                prevItem={index > 0 ? flatListMessages[index - 1] : null}
                                                nextItem={index < flatListMessages.length - 1 ? flatListMessages[index + 1] : null}
                                                isActive={contextMenu?.messageId === msg.id}
                                                onLongPress={(e: any, msgItem: any, text: string) => {
                                                    setContextMenu({
                                                        visible: true,
                                                        messageId: msgItem.id,
                                                        isUser: msgItem.role === 'user',
                                                        content: text,
                                                        y: e.nativeEvent.pageY
                                                    })
                                                }}
                                                renderActionButtons={renderActionButtons}
                                            />
                                        ))}
                                        {renderFooterMessages()}
                                    </View>
                                </ScrollView>

                                <View style={{ position: 'absolute', bottom: 0, left: 0, right: 0, height: insets.bottom + 82, pointerEvents: 'none' }}>
                                    <LinearGradient
                                        colors={['rgba(0,0,0,0)', isLight ? 'rgba(255,255,255,1)' : 'rgba(0,0,0,1)']}
                                        locations={[0, 0.6]}
                                        style={StyleSheet.absoluteFill}
                                    />
                                </View>

                                {!isNativeTabBarAvailable() && (
                                    <KeyboardStickyView offset={{ closed: -20, opened: -10 }} style={{ position: 'absolute', bottom: 0, left: 0, right: 0, zIndex: 20 }}>
                                        <ChatInput
                                            value={inputText}
                                            onChangeText={setInputText}
                                            onSend={() => { if (inputText.trim()) void handleSend(inputText.trim()) }}
                                            isStreaming={storeIsStreaming}
                                            onStopStreaming={handleStopStreaming}
                                            placeholder={editingMessageId ? "Update message..." : "Message Vibe..."}
                                            keyboardProgress={keyboardProgress}
                                            isEditing={!!editingMessageId}
                                            onCancelEdit={() => { setEditingMessageId(null); setInputText('') }}
                                            onVoicePress={() => {
                                                console.log('[Chat] Voice button pressed - opening voice panel')
                                                haptic.medium()
                                            }}
                                        />
                                    </KeyboardStickyView>
                                )}
                            </View>

                            <GlassToast visible={toastVisible} onClose={() => setToastVisible(false)} topInset={insets.top} />
                            <MessageContextMenu
                                visible={!!contextMenu?.visible}
                                onClose={() => setContextMenu(null)}
                                onEdit={contextMenu?.isUser ? () => handleEditInit(contextMenu!.messageId!, contextMenu!.content!) : undefined}
                                onCopy={() => handleCopy(contextMenu?.content || '')}
                                isUser={contextMenu?.isUser}
                                targetY={contextMenu?.y}
                            />
                        </View>

                        {/* --- PAGE 1: HISTORY PANEL --- */}
                        <View style={{ width: SCREEN_WIDTH, height: '100%' }}>
                            <HistoryPanel
                                conversations={sortedConversations}
                                activeConversationId={currentConversationId}
                                onSelectConversation={handleSelectConversation}
                                onNewConversation={handleNewConversation}
                                onDeleteConversation={handleDeleteConversation}
                            />
                        </View>

                    </Animated.View>
                </GestureDetector>
            </GestureHandlerRootView>
        </View>
    )
}

const styles = StyleSheet.create({
    // Header
    headerContainer: { position: 'absolute', top: 0, left: 0, right: 0, zIndex: 50 },
    headerContentContainer: { position: 'absolute', top: 0, left: 0, right: 0, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 16, paddingBottom: 4 },
    headerBtnWrapper: { width: 44, height: 44, borderRadius: 22, overflow: 'hidden', zIndex: 140 },
    headerGlassBtn: { width: 44, height: 44, borderRadius: 22, overflow: 'hidden', alignItems: 'center', justifyContent: 'center' },
    headerTouchArea: { width: '100%', height: '100%', alignItems: 'center', justifyContent: 'center', zIndex: 150 },
    headerCenterWrapper: { flex: 1, alignItems: 'center', justifyContent: 'center', marginHorizontal: 10, height: 44 },
    headerCenterGlass: { flex: 1, borderRadius: 22, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 40 },
    headerTitle: { fontSize: 15, fontWeight: '700', textAlign: 'center' },
    headerStatus: { fontSize: 11, fontWeight: '500', textAlign: 'center', marginTop: 1 },
})
