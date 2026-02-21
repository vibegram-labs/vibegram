import { create } from 'zustand';
import { persist, createJSONStorage } from 'zustand/middleware';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { requestPermissionsAndGetToken } from '../NotificationManager';
import { useAuthStore } from './auth-store';

interface NotificationState {
    notificationsEnabled: boolean;
    pushToken: string | null;
    isInitializing: boolean;
    setNotificationsEnabled: (enabled: boolean) => Promise<void>;
    initNotifications: () => Promise<void>;
}

export const useNotificationStore = create<NotificationState>()(
    persist(
        (set, get) => ({
            notificationsEnabled: true, // Default to true
            pushToken: null,
            isInitializing: false,

            setNotificationsEnabled: async (enabled: boolean) => {
                console.log('[NotificationStore] setNotificationsEnabled', { enabled });
                set({ notificationsEnabled: enabled });
                if (enabled) {
                    await get().initNotifications();
                } else {
                    // If disabled, we might want to clear the token on the server
                    const { user, updateProfileInfo } = useAuthStore.getState();
                    if (user && updateProfileInfo) {
                        try {
                            await updateProfileInfo({ pushToken: '' });
                        } catch (e) {
                            console.warn('[NotificationStore] Failed to clear push token on server', e);
                        }
                    }
                }
            },

            initNotifications: async () => {
                const { notificationsEnabled, isInitializing } = get();
                if (!notificationsEnabled || isInitializing) {
                    console.log('[NotificationStore] initNotifications skipped', {
                        notificationsEnabled,
                        isInitializing,
                    });
                    return;
                }

                set({ isInitializing: true });
                try {
                    console.log('[NotificationStore] Requesting permissions and token...');
                    const token = await requestPermissionsAndGetToken();
                    if (token) {
                        console.log('[NotificationStore] Got push token:', token);
                        set({ pushToken: token });

                        // Sync with backend via AuthStore
                        const { user, updateProfileInfo } = useAuthStore.getState();
                        if (!user || !updateProfileInfo) {
                            console.log('[NotificationStore] Cannot sync token yet (missing user or updateProfileInfo)');
                        } else if (user.pushToken !== token) {
                            console.log('[NotificationStore] Syncing token with backend', {
                                userId: user.userId,
                                hadToken: !!user.pushToken,
                            });
                            await updateProfileInfo({ pushToken: token });
                            console.log('[NotificationStore] Token sync completed');
                        } else {
                            console.log('[NotificationStore] Token already synced, skipping profile update');
                        }
                    } else {
                        console.log('[NotificationStore] No push token returned from NotificationManager');
                    }
                } catch (error) {
                    console.error('[NotificationStore] Failed to initialize notifications:', error);
                } finally {
                    set({ isInitializing: false });
                }
            },
        }),
        {
            name: 'notification-storage',
            storage: createJSONStorage(() => AsyncStorage),
        }
    )
);
