import { create } from 'zustand'
import AsyncStorage from '@react-native-async-storage/async-storage'
import { createJSONStorage, persist } from 'zustand/middleware'

interface User {
    userId: string
    username: string
    secureId: string
    loginToken: string
    publicKey?: string
    identityKey?: string
    profileImage?: string
    phoneNumber?: string
    name?: string
    pushToken?: string
    showLastSeen?: boolean
    showOnlineStatus?: boolean
    bio?: string
    autoDeleteTimer?: number
    privacyForward?: 'everybody' | 'contacts' | 'nobody'
    privacyCalls?: 'everybody' | 'contacts' | 'nobody'
    privacyPhoneNumber?: 'everybody' | 'contacts' | 'nobody'
    privacyProfilePhotos?: 'everybody' | 'contacts' | 'nobody'
    privacyBio?: 'everybody' | 'contacts' | 'nobody'
    privacyGifts?: 'everybody' | 'contacts' | 'nobody'
    privacyBirthday?: 'everybody' | 'contacts' | 'nobody'
    privacySavedMusic?: 'everybody' | 'contacts' | 'nobody'
    dateOfBirth?: string
}

interface AuthState {
    user: User | null
    isSessionExpired: boolean
    setSessionExpired: (v: boolean) => void
    isAuthenticated: boolean
    hasHydrated: boolean
    setHasHydrated: (v: boolean) => void
    login: (user: User) => void
    logout: () => void
    checkSession: () => Promise<void>
    validateSession: () => Promise<void>
    updateProfileImage: (base64Image: string) => Promise<void>
    updatePhoneNumber: (phone: string) => Promise<void>
    updateProfileInfo: (updates: {
        name?: string,
        username?: string,
        phoneNumber?: string,
        pushToken?: string,
        showLastSeen?: boolean,
        showOnlineStatus?: boolean,
        bio?: string,
        autoDeleteTimer?: number,
        privacyForward?: 'everybody' | 'contacts' | 'nobody',
        privacyCalls?: 'everybody' | 'contacts' | 'nobody',
        privacyPhoneNumber?: 'everybody' | 'contacts' | 'nobody',
        privacyProfilePhotos?: 'everybody' | 'contacts' | 'nobody',
        privacyBio?: 'everybody' | 'contacts' | 'nobody',
        privacyGifts?: 'everybody' | 'contacts' | 'nobody',
        privacyBirthday?: 'everybody' | 'contacts' | 'nobody',
        privacySavedMusic?: 'everybody' | 'contacts' | 'nobody',
        dateOfBirth?: string,
    }) => Promise<void>
}

function pickProfileImage(value: any): string | undefined {
    if (!value || typeof value !== 'object') return undefined
    const candidates = [
        value.profileImage,
        value.profile_image,
        value.avatarUrl,
        value.avatar_url,
        value.user?.profileImage,
        value.user?.profile_image,
        value.user?.avatarUrl,
        value.user?.avatar_url,
    ]
    return candidates.find((item): item is string => typeof item === 'string' && item.trim().length > 0)
}

export const useAuthStore = create<AuthState>()(
    persist(
        (set, get) => ({
            user: null,
            isSessionExpired: false,
            isAuthenticated: false,
            hasHydrated: false,
            setHasHydrated: (v) => set({ hasHydrated: v }),
            setSessionExpired: (v) => set({ isSessionExpired: v }),
            login: (user) => {
                const normalizedUser = {
                    ...user,
                    loginToken: (user as any)?.loginToken || (user as any)?.token || '',
                } as User;
                set({ user: normalizedUser, isAuthenticated: true, isSessionExpired: false });
            },
            logout: async () => {
                const AuthManager = require('../AuthManager').default;
                await AuthManager.getInstance().logout();

                try {
                    const { clearSessionScopedClientCaches } = require('../session-cache');
                    await clearSessionScopedClientCaches(null);
                } catch (e) {
                    console.warn('Failed to clear client caches on logout', e);
                }

                set({ user: null, isAuthenticated: false, isSessionExpired: false });
            },
            checkSession: async () => {
                // Persist middleware handles hydration automatically.
                // Here we could validate the token with backend if needed.
                const { user } = get()
                if (user) {
                    set({ isAuthenticated: true })
                } else {
                    set({ isAuthenticated: false })
                }
            },
            validateSession: async () => {
                const { user } = get();
                if (!user) return;
                try {
                    const { apiClient } = require('../api-client');
                    // We call getUser to validate the token.
                    // If it returns 401, apiClient will trigger setSessionExpired(true).
                    await apiClient.getUser(user.userId);
                } catch (e) {
                    // Ignore errors, we only care about 401 which is handled in apiClient
                }
            },
            updateProfileImage: async (base64Image: string) => {
                const { user } = get();
                if (!user) return;
                try {
                    const { apiClient } = require('../api-client');
                    const updateResponse = await apiClient.updateProfile({
                        userId: user.userId,
                        profileImage: base64Image,
                    });
                    const refreshedUser = await apiClient.getUser(user.userId);
                    const resolvedProfileImage =
                        pickProfileImage(refreshedUser)
                        ?? pickProfileImage(updateResponse)
                        ?? base64Image;

                    set({
                        user: {
                            ...user,
                            ...(updateResponse && typeof updateResponse === 'object' ? updateResponse : {}),
                            ...(refreshedUser && typeof refreshedUser === 'object' ? refreshedUser : {}),
                            profileImage: resolvedProfileImage,
                        },
                    });
                } catch (error) {
                    console.error('Failed to update profile image:', error);
                    throw error;
                }
            },
            updatePhoneNumber: async (phone: string) => {
                const { user } = get();
                if (!user) return;
                try {
                    const { apiClient } = require('../api-client');
                    await apiClient.updateProfile({ userId: user.userId, phoneNumber: phone });
                    set({ user: { ...user, phoneNumber: phone } });
                } catch (error) {
                    console.error('Failed to update phone number:', error);
                    throw error;
                }
            },
            updateProfileInfo: async (updates) => {
                const { user } = get();
                if (!user) return;
                try {
                    const { apiClient } = require('../api-client');
                    const res = await apiClient.updateProfile({ userId: user.userId, ...updates });
                    // API returns the updated full user object fields
                    set({ user: { ...user, ...updates, name: res.name || updates.name, username: res.username || updates.username } });
                } catch (error) {
                    console.error('Failed to update profile info:', error);
                    throw error;
                }
            }
        }),
        {
            name: 'auth-storage',
            storage: createJSONStorage(() => AsyncStorage),
            onRehydrateStorage: () => (state) => {
                state?.setHasHydrated(true);
            },
            partialize: (state) => ({
                user: state.user,
                isAuthenticated: state.isAuthenticated,
            }),
        }
    )
)
