import { create } from 'zustand';
import { persist, createJSONStorage } from 'zustand/middleware';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { requestPermissionsAndGetToken } from '../NotificationManager';
import { useAuthStore } from './auth-store';
import { getNativeCallModule } from '../../native/call/runtime';

interface NotificationState {
    notificationsEnabled: boolean;
    pushToken: string | null;
    isInitializing: boolean;
    initStartedAt: number | null;
    pendingInitRequested: boolean;
    pendingInitForceSync: boolean;
    pendingInitReasons: string[];
    lastSyncedToken: string | null;
    lastSyncedUserId: string | null;
    lastSyncedAt: number | null;
    setNotificationsEnabled: (enabled: boolean) => Promise<void>;
    initNotifications: (options?: { forceSync?: boolean; reason?: string }) => Promise<void>;
}

const PUSH_TOKEN_RESYNC_INTERVAL_MS = 10 * 60 * 1000;
const INIT_STALE_TIMEOUT_MS = 45 * 1000;

export const useNotificationStore = create<NotificationState>()(
    persist(
        (set, get) => ({
            notificationsEnabled: true, // Default to true
            pushToken: null,
            isInitializing: false,
            initStartedAt: null,
            pendingInitRequested: false,
            pendingInitForceSync: false,
            pendingInitReasons: [],
            lastSyncedToken: null,
            lastSyncedUserId: null,
            lastSyncedAt: null,

            setNotificationsEnabled: async (enabled: boolean) => {
                // console.log('[NotificationStore] setNotificationsEnabled', { enabled });
                set({ notificationsEnabled: enabled });
                if (enabled) {
                    await get().initNotifications();
                } else {
                    // If disabled, we might want to clear the token on the server
                    const { user, updateProfileInfo } = useAuthStore.getState();
                    if (user && updateProfileInfo) {
                        try {
                            await updateProfileInfo({ pushToken: '' });
                            set({
                                pushToken: null,
                                initStartedAt: null,
                                pendingInitRequested: false,
                                pendingInitForceSync: false,
                                pendingInitReasons: [],
                                lastSyncedToken: null,
                                lastSyncedUserId: user.userId,
                                lastSyncedAt: Date.now(),
                            });
                        } catch (e) {
                            console.warn('[NotificationStore] Failed to clear push token on server', e);
                        }
                    }
                }
            },

            initNotifications: async (options = {}) => {
                const { forceSync = false, reason = 'unknown' } = options;
                const { notificationsEnabled, isInitializing, initStartedAt } = get();
                if (!notificationsEnabled) {
                    /*
                    console.log('[NotificationStore] initNotifications skipped', {
                        notificationsEnabled,
                        isInitializing,
                        reason,
                    });
                    */
                    return;
                }

                if (isInitializing) {
                    const isStale =
                        !initStartedAt || (Date.now() - initStartedAt) > INIT_STALE_TIMEOUT_MS;
                    if (isStale) {
                        console.warn('[NotificationStore] Detected stale notification init lock; resetting', {
                            reason,
                            initStartedAt,
                        });
                        set({
                            isInitializing: false,
                            initStartedAt: null,
                            pendingInitRequested: false,
                            pendingInitForceSync: false,
                            pendingInitReasons: [],
                        });
                    } else {
                        set((state) => {
                            const hasReason = state.pendingInitReasons.includes(reason);
                            const pendingInitReasons = hasReason
                                ? state.pendingInitReasons
                                : [...state.pendingInitReasons, reason];

                            return {
                                pendingInitRequested: true,
                                pendingInitForceSync: state.pendingInitForceSync || forceSync,
                                pendingInitReasons,
                            };
                        });

                        /*
                        console.log('[NotificationStore] initNotifications queued while initializing', {
                            reason,
                            forceSync,
                        });
                        */
                        return;
                    }
                }

                set({
                    isInitializing: true,
                    initStartedAt: Date.now(),
                    pendingInitRequested: false,
                    pendingInitForceSync: false,
                    pendingInitReasons: [],
                });
                try {
                    /*
                    console.log('[NotificationStore] Requesting permissions and token...', {
                        reason,
                        forceSync,
                    });
                    */
                    const token = await requestPermissionsAndGetToken();
                    if (token) {
                        // console.log('[NotificationStore] Got push token:', token);
                        set({ pushToken: token });

                        // Sync with backend via AuthStore
                        const { user, updateProfileInfo } = useAuthStore.getState();
                        if (!user || !updateProfileInfo) {
                            // console.log('[NotificationStore] Cannot sync token yet (missing user or updateProfileInfo)');
                        } else {
                            const nativeCallModule = getNativeCallModule();
                            const nativePushTokens = nativeCallModule?.getPushTokens?.() ?? null;
                            const serializedPushToken = JSON.stringify({
                                expo: token,
                                ...(typeof nativePushTokens?.fcm === 'string' && nativePushTokens.fcm ? { fcm: nativePushTokens.fcm } : {}),
                                ...(typeof nativePushTokens?.apns === 'string' && nativePushTokens.apns ? { apns: nativePushTokens.apns } : {}),
                                ...(typeof nativePushTokens?.voip === 'string' && nativePushTokens.voip ? { apns_voip: nativePushTokens.voip } : {}),
                            });
                            const { lastSyncedToken, lastSyncedUserId, lastSyncedAt } = get();
                            const now = Date.now();
                            const syncExpired = !lastSyncedAt || (now - lastSyncedAt) > PUSH_TOKEN_RESYNC_INTERVAL_MS;
                            const reasons: string[] = [];

                            if (forceSync) reasons.push('forceSync');
                            if (user.pushToken !== serializedPushToken && user.pushToken !== token) reasons.push('authStoreMismatch');
                            if (lastSyncedToken !== serializedPushToken && lastSyncedToken !== token) reasons.push('lastSyncedTokenMismatch');
                            if (lastSyncedUserId !== user.userId) reasons.push('lastSyncedUserMismatch');
                            if (syncExpired) reasons.push('syncExpired');

                            if (reasons.length > 0) {
                                /*
                                console.log('[NotificationStore] Syncing token with backend', {
                                    userId: user.userId,
                                    hadToken: !!user.pushToken,
                                    reason,
                                    reasons,
                                    nativeTokens: {
                                        fcm: !!nativePushTokens?.fcm,
                                        apns: !!nativePushTokens?.apns,
                                        voip: !!nativePushTokens?.voip,
                                    },
                                });
                                */
                                await updateProfileInfo({ pushToken: serializedPushToken });
                                set({
                                    lastSyncedToken: serializedPushToken,
                                    lastSyncedUserId: user.userId,
                                    lastSyncedAt: now,
                                });
                                // console.log('[NotificationStore] Token sync completed');
                            } else {
                                /*
                                console.log('[NotificationStore] Token recently synced, skipping profile update', {
                                    userId: user.userId,
                                    reason,
                                    lastSyncedAt,
                                });
                                */
                            }
                        }
                    } else {
                        // console.log('[NotificationStore] No push token returned from NotificationManager');
                    }
                } catch (error) {
                    console.error('[NotificationStore] Failed to initialize notifications:', error);
                } finally {
                    set({
                        isInitializing: false,
                        initStartedAt: null,
                    });

                    const { pendingInitRequested, pendingInitForceSync, pendingInitReasons } = get();
                    if (pendingInitRequested) {
                        set({
                            pendingInitRequested: false,
                            pendingInitForceSync: false,
                            pendingInitReasons: [],
                        });
                        const queuedReason = pendingInitReasons.length > 0
                            ? `queued:${pendingInitReasons.join(',')}`
                            : 'queued';
                        setTimeout(() => {
                            get().initNotifications({
                                forceSync: pendingInitForceSync,
                                reason: queuedReason,
                            });
                        }, 0);
                    }
                }
            },
        }),
        {
            name: 'notification-storage',
            storage: createJSONStorage(() => AsyncStorage),
            version: 2,
            migrate: (persistedState: any) => {
                return {
                    notificationsEnabled: persistedState?.notificationsEnabled ?? true,
                    pushToken: typeof persistedState?.pushToken === 'string' ? persistedState.pushToken : null,
                    isInitializing: false,
                    initStartedAt: null,
                    pendingInitRequested: false,
                    pendingInitForceSync: false,
                    pendingInitReasons: [],
                    lastSyncedToken: typeof persistedState?.lastSyncedToken === 'string' ? persistedState.lastSyncedToken : null,
                    lastSyncedUserId: typeof persistedState?.lastSyncedUserId === 'string' ? persistedState.lastSyncedUserId : null,
                    lastSyncedAt: typeof persistedState?.lastSyncedAt === 'number' ? persistedState.lastSyncedAt : null,
                };
            },
            partialize: (state) => ({
                notificationsEnabled: state.notificationsEnabled,
                pushToken: state.pushToken,
                lastSyncedToken: state.lastSyncedToken,
                lastSyncedUserId: state.lastSyncedUserId,
                lastSyncedAt: state.lastSyncedAt,
            }),
        }
    )
);
