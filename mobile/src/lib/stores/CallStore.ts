/**
 * Call Store - Manages voice/video call state with Zustand
 * 
 * Uses dynamic imports for react-native-webrtc to prevent crashes in Expo Go.
 * The app will gracefully handle unavailable WebRTC by disabling call features.
 */

import { create } from 'zustand';
import WebRTCService from '../services/WebRTCService';
import ProxyManager from '../ProxyManager';

// Detect if we're behind strict network filtering and should force TURN relay
const shouldForceRelay = (): boolean => {
    try {
        return ProxyManager.getInstance().getConnectionMode() === 'relay';
    } catch {
        return false;
    }
};

// Types
export type CallType = 'voice' | 'video';
export type CallDirection = 'incoming' | 'outgoing';
export type CallStatus = 'idle' | 'ringing' | 'connecting' | 'active' | 'ended' | 'failed' | 'reconnecting';

export interface CallHistoryRecord {
    id: string;
    remoteUser: CallParticipant;
    type: CallType;
    direction: CallDirection;
    status: 'completed' | 'missed' | 'declined' | 'failed';
    timestamp: number;
    duration: number;
}

export interface CallParticipant {
    userId: string;
    userName: string;
    userImage?: string;
}

const asNonEmptyString = (value: unknown): string | null => {
    if (typeof value !== 'string') return null;
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : null;
};

const asRecord = (value: unknown): Record<string, unknown> | null => {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
    return value as Record<string, unknown>;
};

const parseJsonRecord = (value: unknown): Record<string, unknown> | null => {
    const raw = asNonEmptyString(value);
    if (!raw) return null;
    if (!(raw.startsWith('{') && raw.endsWith('}'))) return null;
    try {
        const parsed = JSON.parse(raw);
        return asRecord(parsed);
    } catch {
        return null;
    }
};

const isIncomingCallTypeValue = (value: unknown): boolean => {
    const raw = asNonEmptyString(value)?.toLowerCase();
    if (!raw) return false;
    return (
        raw === 'call-start' ||
        raw === 'call_start' ||
        raw === 'incoming-call' ||
        raw === 'incoming_call' ||
        raw === 'call'
    );
};

const normalizeCallType = (value: unknown): CallType => {
    const raw = asNonEmptyString(value)?.toLowerCase();
    return raw === 'video' ? 'video' : 'voice';
};

const normalizeIncomingCallPayload = (
    payload: Record<string, unknown> | null | undefined
): CallState['incomingCallData'] | null => {
    if (!payload) return null;

    const candidates: Record<string, unknown>[] = [payload];
    const nestedKeys = [
        'payload',
        'call',
        'callData',
        'call_data',
        'data',
        'meta',
    ] as const;
    for (const key of nestedKeys) {
        const nested = asRecord(payload[key]) || parseJsonRecord(payload[key]);
        if (nested) candidates.push(nested);
    }

    const pickString = (...keys: string[]): string | null => {
        for (const candidate of candidates) {
            for (const key of keys) {
                const value = asNonEmptyString(candidate[key]);
                if (value) return value;
            }
        }
        return null;
    };

    const hasExplicitCallEvent = (() => {
        for (const candidate of candidates) {
            if (isIncomingCallTypeValue(candidate.event) || isIncomingCallTypeValue(candidate.type)) {
                return true;
            }
        }
        return false;
    })();

    const callTypeValue = (() => {
        for (const candidate of candidates) {
            const direct = candidate.callType ?? candidate.call_type;
            if (direct != null) return direct;
            // Some backends send { type: 'video', event: 'call-start' }
            if (!isIncomingCallTypeValue(candidate.type)) {
                const t = asNonEmptyString(candidate.type)?.toLowerCase();
                if (t === 'video' || t === 'voice') return t;
            }
        }
        return undefined;
    })();

    const fromUserId =
        pickString('fromUserId', 'from_user_id', 'callerId', 'caller_id', 'userId', 'user_id');
    const callId =
        pickString('callId', 'call_id', 'callUUID', 'call_uuid', 'callToken', 'call_token');
    if (!fromUserId || !callId) return null;

    // Prevent normal message/notification payloads from being mistaken as incoming calls.
    // We require either an explicit call event marker or a call-specific type hint.
    const hasCallSpecificType =
        callTypeValue != null ||
        candidates.some((candidate) => candidate.callType != null || candidate.call_type != null);
    if (!hasExplicitCallEvent && !hasCallSpecificType) return null;

    return {
        fromUserId,
        fromUserName:
            pickString('fromUserName', 'from_user_name', 'callerName', 'caller_name', 'userName', 'user_name') ||
            fromUserId.slice(0, 8),
        fromUserImage:
            pickString('fromUserImage', 'from_user_image', 'callerImage', 'caller_image', 'userImage', 'user_image') ||
            undefined,
        callType: normalizeCallType(callTypeValue),
        callId,
    };
};

interface CallState {
    // WebRTC availability
    isWebRTCAvailable: boolean;

    // Call history
    callHistory: CallHistoryRecord[];

    // Current call info
    callId: string | null;
    callType: CallType | null;
    callDirection: CallDirection | null;
    callStatus: CallStatus;

    // Participants
    localUser: CallParticipant | null;
    remoteUser: CallParticipant | null;

    // Media state
    isMuted: boolean;
    isSpeakerOn: boolean;
    isVideoEnabled: boolean;
    isFrontCamera: boolean;

    // Streams (stored as opaque refs, actual MediaStream handled by service)
    hasLocalStream: boolean;
    hasRemoteStream: boolean;

    // Timing
    callStartTime: number | null;
    callDuration: number;

    // Incoming call data (for modal)
    incomingCallData: {
        fromUserId: string;
        fromUserName: string;
        fromUserImage?: string;
        callType: CallType;
        callId: string;
    } | null;

    // Signaling channel (Phoenix user channel)
    signalingChannel: any | null;

    // Internal timing refs (not part of state, but kept tracking)
    _callWatchdogTimeout?: any;
}

interface CallActions {
    // Initialization
    checkWebRTCAvailability: () => Promise<boolean>;

    // History management
    clearHistory: () => void;
    deleteCallRecord: (id: string) => void;

    // Outgoing calls
    startCall: (remoteUser: CallParticipant, type: CallType, socket: any) => Promise<boolean>;

    // Incoming calls
    handleIncomingCallPayload: (payload: Record<string, unknown> | null | undefined) => boolean;
    handleIncomingCall: (data: CallState['incomingCallData']) => void;
    acceptCall: (socket: any) => Promise<boolean>;
    declineCall: (socket: any) => void;

    // Call control  
    endCall: (socket?: any) => void;
    toggleMute: () => void;
    toggleSpeaker: () => void;
    toggleVideo: () => void;
    flipCamera: () => void;

    // Timer
    updateDuration: () => void;

    // WebRTC signaling handlers
    handleCallAccepted: (payload?: Record<string, unknown>) => Promise<void>;
    handleWebRTCSignal: (data: any) => Promise<void>;
    handleCallEnded: (payload?: Record<string, unknown>) => void;

    // Reset
    resetCall: () => void;
}

import { createJSONStorage, persist } from 'zustand/middleware';
import AsyncStorage from '@react-native-async-storage/async-storage';

const initialState: CallState = {
    isWebRTCAvailable: false,
    callHistory: [],
    callId: null,
    callType: null,
    callDirection: null,
    callStatus: 'idle',
    localUser: null,
    remoteUser: null,
    isMuted: false,
    isSpeakerOn: false,
    isVideoEnabled: true,
    isFrontCamera: true,
    hasLocalStream: false,
    hasRemoteStream: false,
    callStartTime: null,
    callDuration: 0,
    incomingCallData: null,
    signalingChannel: null,
};

export const useCallStore = create<CallState & CallActions>()(
    persist(
        (set, get) => {
            const clearWatchdog = () => {
                const state = get() as any;
                if (state._callWatchdogTimeout) {
                    clearTimeout(state._callWatchdogTimeout);
                    set({ _callWatchdogTimeout: undefined });
                }
            };

            const startWatchdog = (timeoutMs: number = 30000, context: string = 'timeout') => {
                clearWatchdog();
                const timeoutId = setTimeout(() => {
                    const current = get();
                    if (current.callStatus === 'connecting' || current.callStatus === 'reconnecting') {
                        console.log(`[CallStore] Watchdog triggered for ${context}, ending call`);
                        markCallFailed();
                    }
                }, timeoutMs);
                set({ _callWatchdogTimeout: timeoutId });
            };

            const markCallFailed = () => {
                clearWatchdog();
                set({ callStatus: 'failed' });
                setTimeout(() => {
                    if (get().callStatus === 'failed') {
                        get().resetCall();
                    }
                }, 2500);
            };

            const pushWebRTCSignal = (signalType: 'offer' | 'answer' | 'ice-candidate', payload: Record<string, any>) => {
                const { signalingChannel, remoteUser, callId } = get();
                if (!signalingChannel || typeof signalingChannel.push !== 'function' || !remoteUser?.userId || !callId) {
                    return;
                }

                signalingChannel.push('webrtc-signal', {
                    toUserId: remoteUser.userId,
                    callId,
                    type: signalType,
                    ...payload,
                });
            };

            const bindSignalingCallbacks = (channelOverride?: any) => {
                const channel = channelOverride || get().signalingChannel;
                if (channel && channel !== get().signalingChannel) {
                    set({ signalingChannel: channel });
                }

                WebRTCService.onIceCandidate = (candidate: any) => {
                    pushWebRTCSignal('ice-candidate', { candidate });
                };

                WebRTCService.onOffer = (offer: any) => {
                    pushWebRTCSignal('offer', { sdp: offer });
                };

                WebRTCService.onAnswer = (answer: any) => {
                    pushWebRTCSignal('answer', { sdp: answer });
                };

                WebRTCService.onRemoteStream = () => {
                    const current = get();
                    if (current.callStatus === 'idle' || current.callStatus === 'ended') return;
                    set({
                        hasRemoteStream: true,
                        callStatus: 'active',
                        callStartTime: current.callStartTime || Date.now(),
                    });
                    WebRTCService.startBandwidthMonitor();
                };

                WebRTCService.onConnectionStateChange = (state: string) => {
                    if (state === 'connected') {
                        clearWatchdog();
                        const current = get();
                        if (current.callStatus !== 'active') {
                            set({
                                callStatus: 'active',
                                callStartTime: current.callStartTime || Date.now(),
                            });
                            WebRTCService.startBandwidthMonitor();
                        }
                        return;
                    }

                    if (state === 'disconnected') {
                        const current = get();
                        if (current.callStatus === 'active' || current.callStatus === 'connecting') {
                            set({ callStatus: 'reconnecting' });
                            startWatchdog(25000, 'reconnecting');
                        }
                        return;
                    }

                    if (state === 'failed' || state === 'closed') {
                        clearWatchdog();
                        const current = get();
                        if (current.callStatus !== 'idle' && current.callStatus !== 'ended') {
                            if (current.callStatus === 'connecting' || current.callStatus === 'reconnecting') {
                                markCallFailed();
                            } else {
                                get().endCall(channel || current.signalingChannel || undefined);
                            }
                        }
                    }
                };
            };

            const resolveSignalingChannel = (socketOverride?: any) => {
                if (socketOverride && typeof socketOverride.push === 'function') {
                    return socketOverride;
                }
                const storedChannel = get().signalingChannel;
                if (storedChannel && typeof storedChannel.push === 'function') {
                    return storedChannel;
                }
                try {
                    const { getUserChannel } = require('../ChatStore');
                    const globalChannel = getUserChannel?.();
                    if (globalChannel && typeof globalChannel.push === 'function') {
                        return globalChannel;
                    }
                } catch {
                    // Ignore cyclic import resolution failures.
                }
                return null;
            };

            return {
                ...initialState,

                checkWebRTCAvailability: async () => {
                    try {
                        const available = await WebRTCService.isAvailable();
                        set({ isWebRTCAvailable: available });
                        return available;
                    } catch (e) {
                        set({ isWebRTCAvailable: false });
                        return false;
                    }
                },

                clearHistory: () => set({ callHistory: [] }),

                deleteCallRecord: (id) => {
                    set({
                        callHistory: get().callHistory.filter(c => c.id !== id)
                    });
                },

                startCall: async (remoteUser, type, socket) => {
                    const { isWebRTCAvailable, callStatus } = get();
                    const channel = resolveSignalingChannel(socket);
                    console.log('[CallStore] startCall requested', {
                        type,
                        remoteUserId: remoteUser?.userId,
                        isWebRTCAvailable,
                        callStatus,
                        hasSocketArg: !!socket,
                        hasResolvedChannel: !!channel,
                        canPush: !!channel && typeof channel.push === 'function',
                    });

                    if (!isWebRTCAvailable) {
                        console.warn('[CallStore] WebRTC not available, cannot start call');
                        return false;
                    }
                    if (callStatus !== 'idle') {
                        console.warn('[CallStore] Already in a call, status:', callStatus);
                        return false;
                    }
                    if (!channel) {
                        console.warn('[CallStore] User channel unavailable, cannot trigger call-start');
                        return false;
                    }

                    const callId = `call_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
                    console.log('[CallStore] startCall state setup', { callId, type, remoteUserId: remoteUser.userId });

                    set({
                        callId,
                        callType: type,
                        callDirection: 'outgoing',
                        callStatus: 'ringing',
                        remoteUser,
                        isVideoEnabled: type === 'video',
                        signalingChannel: channel,
                    });

                    try {
                        // Pre-fetch TURN credentials (runs in parallel with media init)
                        const [mediaReady] = await Promise.all([
                            WebRTCService.initializeMedia(type === 'video'),
                            WebRTCService.fetchIceServers(),
                        ]);
                        console.log('[CallStore] startCall media initialization result', { callId, type, mediaReady });
                        if (!mediaReady) {
                            console.warn('[CallStore] Media init returned false');
                            markCallFailed();
                            return false;
                        }
                        bindSignalingCallbacks(channel);
                        set({ hasLocalStream: true });

                        console.log('[CallStore] pushing call-start', {
                            callId,
                            type,
                            toUserId: remoteUser.userId,
                        });
                        const pushResult = channel.push('call-start', {
                            toUserId: remoteUser.userId,
                            callId,
                            callType: type,
                        });
                        try {
                            pushResult
                                ?.receive?.('ok', (resp: any) => {
                                    console.log('[CallStore] call-start ack ok', { callId, type, resp });
                                })
                                ?.receive?.('error', (resp: any) => {
                                    console.warn('[CallStore] call-start ack error', { callId, type, resp });
                                })
                                ?.receive?.('timeout', () => {
                                    console.warn('[CallStore] call-start ack timeout', { callId, type });
                                });
                        } catch { }
                        console.log('[CallStore] call-start pushed', { callId, type });

                        // Wait longer (30s) generally, or `startWatchdog` if needed.
                        startWatchdog(40000, 'call-start-ringing');
                        console.log('[CallStore] watchdog started for outgoing call', { callId });

                        return true;
                    } catch (e) {
                        console.error('[CallStore] startCall error:', e);
                        markCallFailed();
                        return false;
                    }
                },

                handleIncomingCallPayload: (payload) => {
                    const normalized = normalizeIncomingCallPayload(payload);
                    if (!normalized) return false;
                    try {
                        console.log('[CallStore] Incoming call payload accepted', {
                            fromUserId: normalized.fromUserId,
                            callId: normalized.callId,
                            callType: normalized.callType,
                            keys: payload ? Object.keys(payload) : [],
                        });
                    } catch { }
                    get().handleIncomingCall(normalized);
                    return true;
                },

                handleIncomingCall: (data) => {
                    const normalized = normalizeIncomingCallPayload(data as Record<string, unknown>);
                    if (!normalized) return;
                    const current = get();
                    const isSameIncomingCall =
                        current.callDirection === 'incoming' &&
                        current.callStatus === 'ringing' &&
                        current.callId === normalized.callId;

                    if (current.callStatus !== 'idle' && !isSameIncomingCall) return;

                    if (isSameIncomingCall) {
                        const mergedIncoming = {
                            ...(current.incomingCallData || normalized),
                            ...normalized,
                        };
                        set({
                            incomingCallData: mergedIncoming,
                            remoteUser: {
                                userId: mergedIncoming.fromUserId,
                                userName: mergedIncoming.fromUserName,
                                userImage: mergedIncoming.fromUserImage,
                            },
                            callType: mergedIncoming.callType,
                        });
                        return;
                    }

                    set({
                        incomingCallData: normalized,
                        callStatus: 'ringing',
                        callDirection: 'incoming',
                        callId: normalized.callId,
                        callType: normalized.callType,
                        remoteUser: {
                            userId: normalized.fromUserId,
                            userName: normalized.fromUserName,
                            userImage: normalized.fromUserImage,
                        },
                    });
                },

                acceptCall: async (socket) => {
                    const { incomingCallData, isWebRTCAvailable, callType } = get();
                    const channel = resolveSignalingChannel(socket);
                    if (!incomingCallData || !isWebRTCAvailable) return false;
                    if (!channel) {
                        console.warn('[CallStore] User channel unavailable, cannot accept call');
                        return false;
                    }

                    set({ callStatus: 'connecting', signalingChannel: channel });

                    try {
                        // Pre-fetch TURN credentials in parallel with media init
                        const [mediaReady] = await Promise.all([
                            WebRTCService.initializeMedia(callType === 'video'),
                            WebRTCService.fetchIceServers(),
                        ]);
                        if (!mediaReady) {
                            markCallFailed();
                            return false;
                        }
                        bindSignalingCallbacks(channel);
                        set({ hasLocalStream: true });

                        channel.push('call-accepted', {
                            toUserId: incomingCallData.fromUserId,
                            callId: incomingCallData.callId,
                        });

                        startWatchdog(20000, 'accept-connecting');

                        return true;
                    } catch (e) {
                        get().resetCall();
                        return false;
                    }
                },

                declineCall: (socket) => {
                    const { incomingCallData, callId, remoteUser, callType, callDirection, signalingChannel } = get();
                    const channel = resolveSignalingChannel(socket || signalingChannel);

                    if (incomingCallData && channel && typeof channel.push === 'function') {
                        channel.push('call-end', {
                            toUserId: incomingCallData.fromUserId,
                            reason: 'declined',
                        });
                    }

                    // Add to history as declined
                    if (callId && remoteUser) {
                        const record: CallHistoryRecord = {
                            id: callId,
                            remoteUser,
                            type: callType!,
                            direction: callDirection!,
                            status: 'declined',
                            timestamp: Date.now(),
                            duration: 0
                        };
                        set({ callHistory: [record, ...get().callHistory] });
                    }

                    get().resetCall();
                },

                handleCallAccepted: async (payload) => {
                    const current = get();
                    const { callDirection, remoteUser, callId } = current;
                    const acceptedCallId = asNonEmptyString(payload?.callId) || asNonEmptyString(payload?.call_id);
                    if (acceptedCallId && callId && acceptedCallId !== callId) return;
                    if (callDirection !== 'outgoing' || !remoteUser) return;
                    const channel = resolveSignalingChannel(current.signalingChannel);
                    if (!channel) {
                        console.warn('[CallStore] Missing signaling channel after call acceptance');
                        markCallFailed();
                        return;
                    }

                    set({ callStatus: 'connecting', signalingChannel: channel });
                    startWatchdog(20000, 'handle-call-accepted-connecting');

                    try {
                        bindSignalingCallbacks(channel);
                        const forceRelay = shouldForceRelay();
                        const offer = await WebRTCService.createOffer(forceRelay);
                        if (!offer) throw new Error('Failed to create offer');
                    } catch (e) {
                        console.error('[CallStore] Failed to create offer:', e);
                        get().endCall(channel);
                    }
                },

                handleWebRTCSignal: async (data) => {
                    const { callId, callStatus } = get();
                    const signalCallId = asNonEmptyString(data?.callId) || asNonEmptyString(data?.call_id);
                    if (signalCallId && callId && signalCallId !== callId) {
                        return;
                    }
                    if (callStatus === 'idle' || callStatus === 'ended') {
                        return;
                    }

                    const type = asNonEmptyString(data?.type);
                    const sdp = data?.sdp;
                    const candidate = data?.candidate;
                    const sdpText =
                        typeof sdp === 'string'
                            ? sdp
                            : (typeof sdp?.sdp === 'string' ? sdp.sdp : null);
                    if (sdpText && sdpText.includes('m=video')) {
                        set({ callType: 'video' });
                    }
                    try {
                        bindSignalingCallbacks();
                        const forceRelay = shouldForceRelay();
                        if (type === 'offer') {
                            if (!sdp) return;
                            await WebRTCService.handleOffer(sdp, forceRelay);
                        } else if (type === 'answer') {
                            if (!sdp) return;
                            await WebRTCService.handleAnswer(sdp);
                            set({ callStatus: 'active', callStartTime: Date.now() });
                            WebRTCService.startBandwidthMonitor();
                        } else if (type === 'ice-candidate' && candidate) {
                            await WebRTCService.handleIceCandidate(candidate);
                        }
                    } catch (e) {
                        console.error('[CallStore] WebRTC signal error:', e);
                    }
                },

                handleCallEnded: (payload) => {
                    const { callId, remoteUser, callType, callDirection, callStatus, callDuration } = get();
                    const endedCallId = asNonEmptyString(payload?.callId) || asNonEmptyString(payload?.call_id);
                    if (endedCallId && callId && endedCallId !== callId) {
                        return;
                    }

                    // Save to history before resetting
                    if (callId && remoteUser) {
                        let status: CallHistoryRecord['status'] = 'completed';
                        if (callStatus === 'ringing') status = callDirection === 'incoming' ? 'missed' : 'declined';
                        if (callStatus === 'failed') status = 'failed';

                        const record: CallHistoryRecord = {
                            id: callId,
                            remoteUser,
                            type: callType!,
                            direction: callDirection!,
                            status,
                            timestamp: Date.now(),
                            duration: callDuration
                        };
                        set({ callHistory: [record, ...get().callHistory] });
                    }

                    get().resetCall();
                },

                endCall: (socket) => {
                    const { remoteUser, callId, callType, callDirection, callStatus, callDuration, signalingChannel } = get();
                    const channel = resolveSignalingChannel(socket || signalingChannel);

                    if (remoteUser && channel && typeof channel.push === 'function') {
                        channel.push('call-end', {
                            toUserId: remoteUser.userId,
                            callId,
                            reason: 'ended',
                        });
                    }

                    // Save to history before resetting
                    if (callId && remoteUser) {
                        let status: CallHistoryRecord['status'] = 'completed';
                        if (callStatus === 'ringing') status = 'declined';
                        if (callStatus === 'failed') status = 'failed';

                        const record: CallHistoryRecord = {
                            id: callId,
                            remoteUser,
                            type: callType!,
                            direction: callDirection!,
                            status,
                            timestamp: Date.now(),
                            duration: callDuration
                        };
                        set({ callHistory: [record, ...get().callHistory] });
                    }

                    get().resetCall();
                },

                toggleMute: () => {
                    const { isMuted } = get();
                    WebRTCService.setAudioEnabled(isMuted);
                    set({ isMuted: !isMuted });
                },

                toggleSpeaker: () => {
                    const { isSpeakerOn } = get();
                    WebRTCService.setSpeakerEnabled(!isSpeakerOn);
                    set({ isSpeakerOn: !isSpeakerOn });
                },

                toggleVideo: () => {
                    void (async () => {
                        const current = get();
                        const nextEnabled = !current.isVideoEnabled;

                        if (!nextEnabled) {
                            WebRTCService.setVideoEnabled(false);
                            set({ isVideoEnabled: false });
                            return;
                        }

                        const needsTrackUpgrade = !WebRTCService.hasLocalVideoTrack();
                        if (needsTrackUpgrade) {
                            const ready = await WebRTCService.ensureLocalVideoTrack();
                            if (!ready) {
                                console.warn('[CallStore] Failed to enable local video track');
                                return;
                            }

                            // Mark UI as video-capable immediately so the local preview / controls can render.
                            set({
                                isVideoEnabled: true,
                                callType: 'video',
                                hasLocalStream: true,
                            });

                            const { callStatus } = get();
                            if (callStatus === 'active' || callStatus === 'connecting') {
                                try {
                                    bindSignalingCallbacks();
                                    const offer = await WebRTCService.createRenegotiationOffer();
                                    if (!offer) {
                                        console.warn('[CallStore] Renegotiation offer was not created');
                                    }
                                } catch (e) {
                                    console.warn('[CallStore] Failed to renegotiate video upgrade', e);
                                }
                            }
                            return;
                        }

                        WebRTCService.setVideoEnabled(true);
                        set({
                            isVideoEnabled: true,
                            callType: current.callType ?? 'video',
                        });
                    })();
                },

                flipCamera: () => {
                    const { isFrontCamera } = get();
                    WebRTCService.flipCamera();
                    set({ isFrontCamera: !isFrontCamera });
                },

                updateDuration: () => {
                    const { callStartTime, callStatus } = get();
                    if (callStatus === 'active' && callStartTime) {
                        set({ callDuration: Math.floor((Date.now() - callStartTime) / 1000) });
                    }
                },

                resetCall: () => {
                    clearWatchdog();
                    WebRTCService.cleanup();
                    WebRTCService.onIceCandidate = null;
                    WebRTCService.onOffer = null;
                    WebRTCService.onAnswer = null;
                    WebRTCService.onRemoteStream = null;
                    WebRTCService.onConnectionStateChange = null;
                    set({
                        ...initialState,
                        callHistory: get().callHistory, // Keep history
                        isWebRTCAvailable: get().isWebRTCAvailable,
                    });
                },
            };
        },
        {
            name: 'vibe-calls',
            storage: createJSONStorage(() => AsyncStorage),
            partialize: (state) => ({ callHistory: state.callHistory }),
        }
    )
);

// Selector hooks for optimized re-renders
export const useIsInCall = () => useCallStore(s => s.callStatus !== 'idle');
export const useHasIncomingCall = () => useCallStore(s => s.incomingCallData !== null && s.callStatus === 'ringing' && s.callDirection === 'incoming');
export const useCallStatus = () => useCallStore(s => s.callStatus);
export const useRemoteUser = () => useCallStore(s => s.remoteUser);
