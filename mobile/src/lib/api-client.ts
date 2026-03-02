import { Platform } from 'react-native'

// Connection priority order:
// 1. Railway (direct) - fastest for users with unrestricted access
// 2. ngrok tunnel - stable fallback for censored regions
// 3. Local dev server - for development only
const BASE_URLS = [
    'https://modest-recreation-production-8329.up.railway.app/api',  // Railway (direct)
    'https://vibe.ngrok.io/api',                                      // ngrok (tunnel to Railway)
    Platform.OS === 'android' ? 'http://10.0.2.2:4000/api' : 'http://localhost:4000/api', // Local dev
]

// Common headers for all requests
const HEADERS = {
    'Content-Type': 'application/json',
    'ngrok-skip-browser-warning': 'true',
}

const getLoginToken = (): string | null => {
    try {
        const AuthManager = require('./AuthManager').default;
        const session = AuthManager.getInstance().getSession();
        if (session?.loginToken) return session.loginToken;
    } catch { }

    try {
        const { useAuthStore } = require('./stores/auth-store');
        const user = useAuthStore.getState().user;
        if (user?.loginToken) return user.loginToken;
        if ((user as any)?.token) return (user as any).token;
    } catch { }

    return null;
};



let activeBaseUrl = BASE_URLS[0];

const getOrderedBaseUrls = () => {
    const seen = new Set<string>();
    const ordered: string[] = [];
    for (const url of [activeBaseUrl, ...BASE_URLS]) {
        if (!url || seen.has(url)) continue;
        seen.add(url);
        ordered.push(url);
    }
    return ordered;
};

const isNetworkErrorLike = (error: unknown) => {
    const message = String((error as any)?.message || error || '').toLowerCase();
    return (
        message.includes('network request failed') ||
        message.includes('network error') ||
        message.includes('failed to fetch') ||
        message.includes('fetch failed') ||
        message.includes('timeout') ||
        message.includes('timed out') ||
        message.includes('aborted')
    );
};

const fetchWithRetry = async (endpoint: string, options: RequestInit = {}) => {
    let lastError;

    for (const url of getOrderedBaseUrls()) {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 12000);
        try {
            if (endpoint.startsWith('http')) {
                // If it's a full URL, don't use the loop prefix
                // console.log(`[API] Fetching Full URL: ${endpoint}`);
                const res = await fetch(endpoint, options);
                clearTimeout(timeoutId);
                return res;
            }

            // console.log(`[API] Fetching ${url}${endpoint}`);

            // Use ProxyManager to handle relay routing if enabled
            const ProxyManager = require('./ProxyManager').default;
            const pm = ProxyManager.getInstance();

            let res;
            if (pm.isRelayActive()) {
                // If relay is active, we skip the loop and just use the relay
                // The relay client handles the connection to the target server
                // We pass the relative endpoint since the relay is configured to hit the API
                // console.log(`[API] Fetching via Relay: ${endpoint}`);
                const token = getLoginToken();
                const optHeaders = (options.headers || {}) as any;
                res = await pm.relayFetch(endpoint, {
                    ...options,
                    headers: {
                        ...HEADERS,
                        ...optHeaders,
                        ...(token && !optHeaders.Authorization && !optHeaders.authorization ? { Authorization: `Bearer ${token}` } : {}),
                    },
                });
                clearTimeout(timeoutId);
                // Break loop as we only need one attempt via relay
                if (!res.ok && res.status !== 404) throw new Error(`Relay fetch failed: ${res.status}`);
                return res;
            }

            const token = getLoginToken();
            const optHeaders = (options.headers || {}) as any;

            const resFetch = await fetch(`${url}${endpoint}`, {
                ...options,
                signal: controller.signal,
                headers: {
                    ...HEADERS,
                    ...optHeaders,
                    ...(token && !optHeaders.Authorization && !optHeaders.authorization ? { Authorization: `Bearer ${token}` } : {}),
                },
            });
            res = resFetch;
            clearTimeout(timeoutId);

            // console.log(`[API] Response ${res.status} from ${url}${endpoint}`);

            // Common mis-deploy case: URL points to a static server (e.g. Caddy) instead of the Phoenix API.
            if (res.status === 405) {
                const serverHeader = (res.headers.get('server') || '').toLowerCase();
                const allowHeader = res.headers.get('allow') || '';
                if (serverHeader.includes('caddy') || allowHeader.includes('GET') || allowHeader.includes('HEAD')) {
                    throw new Error(`API misconfigured: ${url} returned 405 (likely static server, not the Vibe API). Deploy the backend or update BASE_URLS.`);
                }
            }

            // Check if response is valid JSON
            const contentType = res.headers.get("content-type");
            if (contentType && contentType.indexOf("application/json") === -1) {
                const text = await res.text();
                // console.warn(`[API] Non-JSON response (Status ${res.status}):`, text.substring(0, 100)); // Reduce noise
                throw new Error(`Invalid response type: ${text.substring(0, 50)}...`);
            }

            // Mark this URL as active/working
            activeBaseUrl = url;

            // Check for session expiration (401)
            if (res.status === 401 && !endpoint.includes('login') && !endpoint.includes('register')) {
                try {
                    const { useAuthStore } = require('./stores/auth-store');
                    useAuthStore.getState().setSessionExpired(true);
                } catch (e) {
                    console.warn('[API] Failed to set session expired', e);
                }
            }

            return res;
        } catch (e: any) {
            clearTimeout(timeoutId);
            // console.log(`[API] Connection failed to ${url}`, e.message);
            lastError = e;
            // Continue to next URL
        }
    }

    throw lastError || new Error('Network request failed after retries');
};


/**
 * Upload media file to server with progress tracking.
 * Returns the public URL of the uploaded file.
 */
export const uploadMedia = async (
    fileUri: string,
    userId: string,
    type: 'image' | 'audio' | 'video' | 'file' = 'file',
    onProgress?: (progress: number) => void,
    signal?: AbortSignal,
): Promise<string | null> => {
    // Determine filename and mime type from URI
    const uriParts = fileUri.split('/');
    const fileName = uriParts[uriParts.length - 1] || `upload_${Date.now()}`;
    const ext = fileName.split('.').pop()?.toLowerCase() || '';
    const mimeMap: Record<string, string> = {
        jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', gif: 'image/gif',
        webp: 'image/webp', heic: 'image/heic',
        m4a: 'audio/mp4', mp3: 'audio/mpeg', wav: 'audio/wav',
        mp4: 'video/mp4', mov: 'video/quicktime',
    };
    const mimeType = mimeMap[ext] || 'application/octet-stream';

    const uploadOrder = getOrderedBaseUrls();
    const startTime = Date.now();
    const totalBudgetMs = 35000;
    const maxAttemptTimeoutMs = 20000;

    for (const baseUrl of uploadOrder) {
        const elapsed = Date.now() - startTime;
        if (elapsed >= totalBudgetMs) break;
        const remainingMs = totalBudgetMs - elapsed;
        const attemptTimeoutMs = Math.max(6000, Math.min(maxAttemptTimeoutMs, remainingMs));

        try {
            // Strip /api suffix to get the base server URL, then append the upload path
            const serverBase = baseUrl.replace(/\/api$/, '');
            const uploadUrl = `${serverBase}/api/media/upload`;

            // console.log(`[API] Uploading media to ${uploadUrl}`);

            const formData = new FormData();
            formData.append('file', {
                uri: fileUri,
                name: fileName,
                type: mimeType,
            } as any);
            formData.append('user_id', userId);
            formData.append('type', type);

            // Use XMLHttpRequest for upload progress
            const result = await new Promise<{ url: string }>((resolve, reject) => {
                const xhr = new XMLHttpRequest();
                xhr.open('POST', uploadUrl);
                xhr.setRequestHeader('ngrok-skip-browser-warning', 'true');
                const token = getLoginToken();
                if (token) xhr.setRequestHeader('Authorization', `Bearer ${token}`);

                // Support cancellation via AbortSignal
                if (signal) {
                    if (signal.aborted) {
                        reject(new Error('Upload cancelled'));
                        return;
                    }
                    signal.addEventListener('abort', () => xhr.abort());
                }

                xhr.upload.onprogress = (event) => {
                    if (event.lengthComputable && onProgress) {
                        onProgress(event.loaded / event.total);
                    }
                };

                xhr.onload = () => {
                    if (xhr.status >= 200 && xhr.status < 300) {
                        try {
                            const data = JSON.parse(xhr.responseText);
                            resolve(data);
                        } catch {
                            reject(new Error('Invalid response'));
                        }
                    } else {
                        reject(new Error(`Upload failed: ${xhr.status}`));
                    }
                };

                xhr.onerror = () => reject(new Error('Upload network error'));
                xhr.onabort = () => reject(new Error('Upload cancelled'));
                xhr.ontimeout = () => reject(new Error('Upload timeout'));
                xhr.timeout = attemptTimeoutMs;

                xhr.send(formData);
            });

            // console.log('[API] Upload success:', result.url);
            activeBaseUrl = baseUrl;
            return result.url;
        } catch (e: any) {
            console.warn(`[API] Upload failed to ${baseUrl}:`, e.message);
            continue;
        }
    }

    console.warn('[API] All upload endpoints failed, deferring media send until connection recovers');
    return null;
};



export const apiClient = {
    checkUsername: async (username: string) => {
        try {
            const res = await fetchWithRetry(`/username/check/${username}`)
            return await res.json()
        } catch (e) {
            console.error('Check username failed', e)
            return { available: false, error: 'Network error' }
        }
    },

    register: async (data: any) => {
        try {
            const res = await fetchWithRetry(`/register`, {
                method: 'POST',
                body: JSON.stringify(data)
            })
            const json = await res.json()
            if (!res.ok) throw new Error(json.error || 'Registration failed')
            return json
        } catch (e: any) {
            throw new Error(e.message || 'Network error')
        }
    },

    login: async (data: any) => {
        try {
            const res = await fetchWithRetry(`/login`, {
                method: 'POST',
                body: JSON.stringify(data)
            })

            // Log response body
            const text = await res.text();
            // console.log(`[API] Login response body:`, text.substring(0, 200));

            let json;
            try {
                json = JSON.parse(text);
            } catch (e) {
                // console.log('[API] JSON Parse Error:', e);
                throw new Error('Invalid JSON response');
            }

            if (!res.ok) throw new Error(json.error || 'Login failed')

            // TEMPORARY PROBE: Remove profileImage to see if it fixes the crash
            if (json.profileImage) {
                // console.log('[API] Stripping profileImage for safety');
                delete json.profileImage;
            }

            return json
        } catch (e: any) {
            // console.log('[API] Login Exception:', e.message);
            throw new Error(e.message || 'Network error')
        }
    },

    findUserByName: async (username: string) => {
        try {
            const res = await fetchWithRetry(`/user/name/${username}`)
            if (res.status === 404) return null
            return await res.json()
        } catch (e) {
            console.error('Find user by name failed', e)
            return null
        }
    },

    findUserByPhone: async (phone: string) => {
        try {
            const res = await fetchWithRetry(`/user/phone/${phone}`)
            if (res.status === 404) return null
            return await res.json()
        } catch (e) {
            console.error('Find user by phone failed', e)
            return null
        }
    },

    matchContacts: async (phoneNumbers: string[]) => {
        try {
            const res = await fetchWithRetry(`/user/contacts/match`, {
                method: 'POST',
                body: JSON.stringify({ phoneNumbers })
            })
            const json = await res.json()
            if (!res.ok) throw new Error(json?.error || 'Contact match failed')
            return json as { matches: any[]; total: number }
        } catch (e: any) {
            throw new Error(e.message || 'Contact match failed')
        }
    },

    getUser: async (userId: string) => {
        try {
            const res = await fetchWithRetry(`/user/${userId}`)
            if (res.status === 404) return null
            return await res.json()
        } catch (e: unknown) {
            if (isNetworkErrorLike(e)) {
                console.warn('Get user failed (network):', (e as any)?.message || e)
            } else {
                console.error('Get user failed', e)
            }
            return null
        }
    },

    updateProfile: async (data: {
        userId: string,
        profileImage?: string,
        phoneNumber?: string,
        name?: string,
        username?: string,
        pushToken?: string,
        showLastSeen?: boolean,
        showOnlineStatus?: boolean,
        bio?: string,
        autoDeleteTimer?: number,
        privacyForward?: string,
        privacyCalls?: string,
        privacyPhoneNumber?: string,
        privacyProfilePhotos?: string,
        privacyBio?: string,
        privacyGifts?: string,
        privacyBirthday?: string,
        privacySavedMusic?: string,
        dateOfBirth?: string
    }) => {
        try {
            const res = await fetchWithRetry(`/user/profile`, {
                method: 'POST',
                body: JSON.stringify(data)
            })
            return await res.json()
        } catch (e) {
            console.error('Update profile failed', e)
            throw e
        }
    },

    blockUser: async (userId: string, blockedUserId: string) => {
        const res = await fetchWithRetry(`/user/block`, {
            method: 'POST',
            body: JSON.stringify({ blocked_user_id: blockedUserId })
        })
        return await res.json()
    },

    unblockUser: async (userId: string, blockedUserId: string) => {
        const res = await fetchWithRetry(`/user/unblock`, {
            method: 'POST',
            body: JSON.stringify({ blocked_user_id: blockedUserId })
        })
        return await res.json()
    },

    listBlockedUsers: async (userId: string) => {
        const res = await fetchWithRetry(`/user/blocks/${userId}`)
        return await res.json()
    },

    getChats: async (userId: string) => {
        try {
            const res = await fetchWithRetry(`/chats/${userId}`)
            const text = await res.text()
            let json;
            try {
                json = JSON.parse(text);
            } catch (e) {
                if (!res.ok) throw new Error(`HTTP ${res.status}`);
                throw new Error('Invalid JSON response');
            }
            if (!res.ok) throw new Error(json?.errors?.detail || json?.error || `HTTP ${res.status}`)
            if (!Array.isArray(json)) {
                if (json?.data && Array.isArray(json.data)) return json.data;
                throw new Error(json?.errors?.detail || 'Invalid response format');
            }
            return json
        } catch (e: unknown) {
            if (isNetworkErrorLike(e)) {
                console.warn('Get chats failed (network):', (e as any)?.message || e)
            } else {
                console.error('Get chats failed', e)
            }
            throw e
        }
    },

    deleteMessage: async (chatId: string, messageId: string, forEveryone = true) => {
        const res = await fetchWithRetry(`/chat/${chatId}/messages/${messageId}`, {
            method: 'DELETE',
            body: JSON.stringify({ for_everyone: forEveryone }),
        });
        const json = await res.json();
        if (!res.ok) throw new Error(json?.error || 'Delete message failed');
        return json;
    },

    getPinnedMessages: async (chatId: string) => {
        const res = await fetchWithRetry(`/chat/${chatId}/pinned_messages`);
        const json = await res.json();
        if (!res.ok) throw new Error(json?.error || 'Get pinned messages failed');
        return json;
    },

    pinMessage: async (chatId: string, messageId: string, pinned = true) => {
        const res = await fetchWithRetry(`/chat/${chatId}/messages/${messageId}/pin`, {
            method: 'POST',
            body: JSON.stringify({ pinned }),
        });
        const json = await res.json();
        if (!res.ok) throw new Error(json?.error || 'Pin message failed');
        return json;
    },

    getMessagingConnections: async () => {
        return {
            telegram: false,
            whatsapp: false,
            instagram: false,
        }
    },

    getGmailStatus: async () => {
        return {
            connected: false
        }
    },

    agentChat: async (payload: any) => {
        try {
            const res = await fetchWithRetry(`/agent/chat`, {
                method: 'POST',
                body: JSON.stringify(payload)
            })
            return await res.json()
        } catch (e: any) {
            console.error('Agent chat failed', e)
            return { error: e.message || 'Network error' }
        }
    },

    deleteAccount: async (userId: string) => {
        try {
            const res = await fetchWithRetry(`/user/delete`, {
                method: 'POST',
                body: JSON.stringify({ userId })
            })
            if (!res.ok) throw new Error('Failed to delete account')
            const text = await res.text();
            try {
                return JSON.parse(text);
            } catch {
                return { success: true };
            }
        } catch (e: any) {
            console.error('Delete account failed', e)
            throw new Error(e.message || 'Network error')
        }
    },

    getSavedMessages: async (userId: string) => {
        try {
            const res = await fetchWithRetry(`/saved_messages/${userId}`);
            return await res.json();
        } catch (e) {
            console.error('Get saved messages failed', e);
            return { data: [] };
        }
    },

    saveMessage: async (msgData: any) => {
        try {
            const res = await fetchWithRetry(`/saved_messages`, {
                method: 'POST',
                body: JSON.stringify(msgData)
            });
            return await res.json();
        } catch (e) {
            console.error('Save message failed', e);
            return { error: 'Failed' };
        }
    },

    deleteSavedMessage: async (userId: string, originalMessageId: string) => {
        try {
            const res = await fetchWithRetry(`/saved_messages/${userId}/${originalMessageId}`, {
                method: 'DELETE'
            });
            return await res.json();
        } catch (e) {
            console.error('Delete saved message failed', e);
            return { error: 'Failed' };
        }
    },

    // ========================================
    // Subscription & Plans
    // ========================================

    getPlans: async () => {
        try {
            const res = await fetchWithRetry(`/plans`);
            return await res.json();
        } catch (e) {
            console.error('Get plans failed', e);
            return { plans: [] };
        }
    },

    getSubscription: async (userId: string) => {
        try {
            const res = await fetchWithRetry(`/subscription/${userId}`);
            return await res.json();
        } catch (e) {
            console.error('Get subscription failed', e);
            return { tier: 'free', subscription: null };
        }
    },

    createCheckout: async (userId: string, planId: string) => {
        try {
            const res = await fetchWithRetry(`/subscription/checkout`, {
                method: 'POST',
                body: JSON.stringify({ plan_id: planId })
            });
            const json = await res.json();
            if (!res.ok) throw new Error(json.error || 'Checkout failed');
            return json;
        } catch (e: any) {
            console.error('Create checkout failed', e);
            throw new Error(e.message || 'Network error');
        }
    },

    cancelSubscription: async (userId: string) => {
        try {
            const res = await fetchWithRetry(`/subscription/cancel`, {
                method: 'POST',
                body: JSON.stringify({})
            });
            const json = await res.json();
            if (!res.ok) throw new Error(json.error || 'Cancel failed');
            return json;
        } catch (e: any) {
            console.error('Cancel subscription failed', e);
            throw new Error(e.message || 'Network error');
        }
    },

    // ========================================
    // Referrals
    // ========================================

    getReferralCode: async (userId: string) => {
        try {
            const res = await fetchWithRetry(`/referral/code/${userId}`);
            return await res.json();
        } catch (e) {
            console.error('Get referral code failed', e);
            return { code: null };
        }
    },

    getReferralStats: async (userId: string) => {
        try {
            const res = await fetchWithRetry(`/referral/stats/${userId}`);
            return await res.json();
        } catch (e) {
            console.error('Get referral stats failed', e);
            return {
                referralCode: null,
                verifiedCount: 0,
                pendingCount: 0,
                totalCount: 0,
                bronzeThreshold: 4000,
                progressPercent: 0
            };
        }
    },

    applyReferralCode: async (code: string, userId: string) => {
        try {
            const res = await fetchWithRetry(`/referral/apply`, {
                method: 'POST',
                body: JSON.stringify({ code })
            });
            const json = await res.json();
            if (!res.ok) throw new Error(json.error || 'Apply referral failed');
            return json;
        } catch (e: any) {
            console.error('Apply referral code failed', e);
            throw new Error(e.message || 'Network error');
        }
    },

    // ========================================
    // Badges
    // ========================================

    getBadges: async (userId: string) => {
        try {
            const res = await fetchWithRetry(`/badges/${userId}`);
            return await res.json();
        } catch (e) {
            console.error('Get badges failed', e);
            return { activeBadge: null, allBadges: [] };
        }
    },

    // ========================================
    // Business Settings
    // ========================================

    getBusinessSettings: async (userId: string) => {
        try {
            const res = await fetchWithRetry(`/business/settings/${userId}`);
            return await res.json();
        } catch (e) {
            console.error('Get business settings failed', e);
            return { hasAccess: false, settings: null };
        }
    },

    updateBusinessSettings: async (userId: string, settings: {
        businessProfileEnabled?: boolean;
        autoReplyEnabled?: boolean;
        autoReplyMessage?: string;
        businessHoursStart?: string;
        businessHoursEnd?: string;
    }) => {
        try {
            const res = await fetchWithRetry(`/business/settings`, {
                method: 'POST',
                body: JSON.stringify({ ...settings })
            });
            const json = await res.json();
            if (!res.ok) throw new Error(json.error || 'Update failed');
            return json;
        } catch (e: any) {
            console.error('Update business settings failed', e);
            throw new Error(e.message || 'Network error');
        }
    },

    // ========================================
    // Music Streaming (Backend Proxy)
    // ========================================

    getMusicStreamUrl: (videoId: string) => {
        // Use the first available base URL without /api suffix
        const baseUrl = BASE_URLS[0].replace('/api', '');
        return `${baseUrl}/api/music/stream/${videoId}`;
    },

    getMusicInfo: async (videoId: string) => {
        try {
            const res = await fetchWithRetry(`/music/info/${videoId}`);
            return await res.json();
        } catch (e) {
            console.error('Get music info failed', e);
            return { cached: false, stream_url: null };
        }
    },

    // ========================================
    // Stories
    // ========================================

    createStory: async (data: {
        user_id: string;
        media_url: string;
        media_type?: string;
        caption?: string;
        visibility?: string;
        visible_to?: string[];
        hidden_from?: string[];
        original_media_url?: string;
        duration?: number;
    }) => {
        try {
            const res = await fetchWithRetry(`/stories`, {
                method: 'POST',
                body: JSON.stringify(data)
            });
            return await res.json();
        } catch (e) {
            console.error('Create story failed', e);
            return { success: false, error: 'Failed to create story' };
        }
    },

    getStoriesFeed: async (userId: string) => {
        try {
            const res = await fetchWithRetry(`/stories/feed/${userId}`);
            return await res.json();
        } catch (e: unknown) {
            if (isNetworkErrorLike(e)) {
                console.warn('Get stories feed failed (network):', (e as any)?.message || e);
            } else {
                console.error('Get stories feed failed', e);
            }
            return { success: false, feed: [] };
        }
    },

    getMyStories: async (userId: string) => {
        try {
            const res = await fetchWithRetry(`/stories/my/${userId}`);
            return await res.json();
        } catch (e: unknown) {
            if (isNetworkErrorLike(e)) {
                console.warn('Get my stories failed (network):', (e as any)?.message || e);
            } else {
                console.error('Get my stories failed', e);
            }
            return { success: false, stories: [] };
        }
    },

    getUserStories: async (targetUserId: string, viewerId?: string) => {
        try {
            const url = viewerId
                ? `/stories/user/${targetUserId}?viewer_id=${viewerId}`
                : `/stories/user/${targetUserId}`;
            const res = await fetchWithRetry(url);
            return await res.json();
        } catch (e) {
            console.error('Get user stories failed', e);
            return { success: false, stories: [] };
        }
    },

    markStoryViewed: async (storyId: string, viewerId: string) => {
        try {
            const res = await fetchWithRetry(`/stories/${storyId}/view`, {
                method: 'POST',
                body: JSON.stringify({ viewer_id: viewerId })
            });
            return await res.json();
        } catch (e) {
            console.error('Mark story viewed failed', e);
            return { success: false };
        }
    },

    getStoryViewers: async (storyId: string, userId: string) => {
        try {
            const res = await fetchWithRetry(`/stories/${storyId}/viewers?user_id=${userId}`);
            return await res.json();
        } catch (e) {
            console.error('Get story viewers failed', e);
            return { success: false, viewers: [], count: 0 };
        }
    },

    deleteStory: async (storyId: string, userId: string) => {
        try {
            const res = await fetchWithRetry(`/stories/${storyId}?user_id=${userId}`, {
                method: 'DELETE'
            });
            return await res.json();
        } catch (e) {
            console.error('Delete story failed', e);
            return { success: false };
        }
    },

    updateStoryVisibility: async (storyId: string, data: {
        user_id: string;
        visibility: string;
        visible_to?: string[];
        hidden_from?: string[];
    }) => {
        try {
            const res = await fetchWithRetry(`/stories/${storyId}/visibility`, {
                method: 'PUT',
                body: JSON.stringify(data)
            });
            return await res.json();
        } catch (e) {
            console.error('Update story visibility failed', e);
            return { success: false };
        }
    },

    // ========================================
    // AI Tools
    // ========================================

    // ========================================
    // Groups
    // ========================================

    createGroup: async (creatorId: string, name: string, memberIds: string[]) => {
        try {
            const res = await fetchWithRetry(`/group`, {
                method: 'POST',
                body: JSON.stringify({ creatorId, name, memberIds })
            });
            return await res.json();
        } catch (e) {
            console.error('Create group failed', e);
            return { error: 'Failed to create group' };
        }
    },

    addGroupMembers: async (groupId: string, memberIds: string[]) => {
        try {
            const res = await fetchWithRetry(`/group/${groupId}/members`, {
                method: 'POST',
                body: JSON.stringify({ memberIds })
            });
            return await res.json();
        } catch (e) {
            console.error('Add group members failed', e);
            return { error: 'Failed' };
        }
    },

    removeGroupMember: async (groupId: string, userId: string) => {
        try {
            const res = await fetchWithRetry(`/group/${groupId}/members/${userId}`, {
                method: 'DELETE'
            });
            return await res.json();
        } catch (e) {
            console.error('Remove group member failed', e);
            return { error: 'Failed' };
        }
    },

    // ========================================
    // Channels
    // ========================================

    createChannel: async (creatorId: string, name: string, description?: string) => {
        try {
            const res = await fetchWithRetry(`/channel`, {
                method: 'POST',
                body: JSON.stringify({ creatorId, name, description })
            });
            return await res.json();
        } catch (e) {
            console.error('Create channel failed', e);
            return { error: 'Failed to create channel' };
        }
    },

    listChannels: async () => {
        try {
            const res = await fetchWithRetry(`/channels`);
            return await res.json();
        } catch (e) {
            console.error('List channels failed', e);
            return [];
        }
    },

    joinChannel: async (channelId: string, userId: string) => {
        try {
            const res = await fetchWithRetry(`/channel/${channelId}/join`, {
                method: 'POST',
                body: JSON.stringify({})
            });
            return await res.json();
        } catch (e) {
            console.error('Join channel failed', e);
            return { error: 'Failed' };
        }
    },

    leaveChannel: async (channelId: string, userId: string) => {
        try {
            const res = await fetchWithRetry(`/channel/${channelId}/leave`, {
                method: 'POST',
                body: JSON.stringify({})
            });
            return await res.json();
        } catch (e) {
            console.error('Leave channel failed', e);
            return { error: 'Failed' };
        }
    },

    getChannelAnalytics: async (channelId: string) => {
        try {
            const res = await fetchWithRetry(`/channel/${channelId}/analytics`);
            return await res.json();
        } catch (e) {
            console.error('Get channel analytics failed', e);
            return { subscriber_count: 0, message_count: 0, recent_joins_7d: 0 };
        }
    },

    // ========================================
    // Scheduled Posts
    // ========================================

    schedulePost: async (channelId: string, userId: string, content: string, scheduledAt: string, type?: string, mediaUrl?: string) => {
        try {
            const res = await fetchWithRetry(`/channel/${channelId}/schedule`, {
                method: 'POST',
                body: JSON.stringify({ content, scheduledAt, type: type || 'text', mediaUrl })
            });
            return await res.json();
        } catch (e) {
            console.error('Schedule post failed', e);
            return { error: 'Failed' };
        }
    },

    getScheduledPosts: async (channelId: string) => {
        try {
            const res = await fetchWithRetry(`/channel/${channelId}/schedule`);
            return await res.json();
        } catch (e) {
            console.error('Get scheduled posts failed', e);
            return [];
        }
    },

    cancelScheduledPost: async (postId: string, userId: string) => {
        try {
            const res = await fetchWithRetry(`/schedule/${postId}`, {
                method: 'DELETE',
                body: JSON.stringify({})
            });
            return await res.json();
        } catch (e) {
            console.error('Cancel scheduled post failed', e);
            return { error: 'Failed' };
        }
    },

    // ========================================
    // AI Tools
    // ========================================

    // ========================================
    // TURN/ICE Credentials for Calls
    // ========================================

    getTurnCredentials: async (): Promise<{
        iceServers: Array<{ urls: string; username?: string; credential?: string }>;
        ttl?: number;
        iceTransportPolicy?: 'all' | 'relay';
    } | null> => {
        try {
            const res = await fetchWithRetry(`/turn-credentials`);
            if (!res.ok) return null;
            return await res.json();
        } catch (e) {
            console.warn('[API] Get TURN credentials failed', e);
            return null;
        }
    },

    editImage: async (image_url: string, prompt: string) => {
        try {
            const res = await fetchWithRetry(`/ai/edit_image`, {
                method: 'POST',
                body: JSON.stringify({ image_url, prompt })
            });
            const data = await res.json();

            // Fix relative URL if needed
            if (data.success && data.url && data.url.startsWith('/')) {
                // Remove '/api' from base url to get root
                const rootUrl = activeBaseUrl.replace(/\/api$/, '');
                data.url = `${rootUrl}${data.url}`;
                console.log('[API] Resolved relative URL to:', data.url);
            }
            return data;
        } catch (e: any) {
            console.error('AI Edit Image failed', e);
            return { success: false, error: e.message || 'Network error' };
        }
    }
}
