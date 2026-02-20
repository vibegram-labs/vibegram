import { create } from 'zustand'
import { createJSONStorage, persist } from 'zustand/middleware'
import AsyncStorage from '@react-native-async-storage/async-storage'
import { apiClient, uploadMedia } from '../api-client'

export interface Story {
    id: string
    user_id: string
    media_url: string
    media_type: 'image' | 'video'
    caption?: string
    duration: number
    original_media_url?: string  // For AI edits - original before modification
    visibility: 'everyone' | 'contacts' | 'close_friends' | 'custom'
    view_count: number
    expires_at: string
    created_at: string
}

export interface StoryGroup {
    user_id: string
    username: string
    profile_image?: string
    stories: Story[]
    has_unseen: boolean
}

export interface StoryDraft {
    id: string
    mediaUri: string
    mediaType: 'image' | 'video'
    createdAt: string
}

interface StoryState {
    // Feed - stories from other users
    feed: StoryGroup[]
    feedLoading: boolean

    // My stories
    myStories: Story[]
    myStoriesLoading: boolean

    // Story creation
    isCreating: boolean
    uploadProgress: number
    createError: string | null

    // Current viewing
    currentViewingUserId: string | null
    currentStoryIndex: number

    // Actions
    loadFeed: (userId: string) => Promise<void>
    loadMyStories: (userId: string) => Promise<void>

    // Drafts
    drafts: StoryDraft[]
    saveDraft: (draft: Omit<StoryDraft, 'id' | 'createdAt'>) => void
    deleteDraft: (id: string) => void

    createStory: (params: CreateStoryParams) => Promise<Story | null>
    deleteStory: (storyId: string, userId: string) => Promise<boolean>
    markStoryViewed: (storyId: string, viewerId: string) => Promise<void>
    updateVisibility: (storyId: string, userId: string, visibility: Story['visibility'], visibleTo?: string[], hiddenFrom?: string[]) => Promise<boolean>

    // Viewing state
    setCurrentViewing: (userId: string, index: number) => void
    nextStory: () => void
    prevStory: () => void
    clearViewing: () => void

    // Reset
    reset: () => void
}

interface CreateStoryParams {
    userId: string
    mediaUrl: string
    mediaType?: 'image' | 'video'
    caption?: string
    visibility?: Story['visibility']
    visibleTo?: string[]
    hiddenFrom?: string[]
    originalMediaUrl?: string  // If AI-edited, the original image
    duration?: number
}

export const useStoryStore = create<StoryState>()(
    persist(
        (set, get) => ({
            feed: [],
            feedLoading: false,
            myStories: [],
            myStoriesLoading: false,
            isCreating: false,
            uploadProgress: 0,
            createError: null,
            currentViewingUserId: null,
            currentStoryIndex: 0,
            drafts: [],

            saveDraft: (draft) => {
                set(state => ({
                    drafts: [
                        {
                            id: Math.random().toString(36).substring(7),
                            createdAt: new Date().toISOString(),
                            ...draft
                        },
                        ...state.drafts
                    ]
                }))
            },

            deleteDraft: (id) => {
                set(state => ({
                    drafts: state.drafts.filter(d => d.id !== id)
                }))
            },

            loadFeed: async (userId: string) => {
                set({ feedLoading: true })
                // console.log('[StoryStore] Loading feed for:', userId)
                try {
                    const response = await apiClient.getStoriesFeed(userId)
                    // console.log('[StoryStore] Feed response:', response)
                    if (response.success) {
                        set({ feed: response.feed, feedLoading: false })
                    } else {
                        console.warn('[StoryStore] Feed unavailable, keeping local state:', response)
                        set({ feedLoading: false })
                    }
                } catch (error) {
                    console.warn('[StoryStore] Failed to load feed (network/deferred):', error)
                    set({ feedLoading: false })
                }
            },

            loadMyStories: async (userId: string) => {
                set({ myStoriesLoading: true })
                try {
                    const response = await apiClient.getMyStories(userId)
                    if (response.success) {
                        set({ myStories: response.stories, myStoriesLoading: false })
                    } else {
                        console.warn('[StoryStore] My stories unavailable, keeping local state:', response)
                        set({ myStoriesLoading: false })
                    }
                } catch (error) {
                    console.warn('[StoryStore] Failed to load my stories (network/deferred):', error)
                    set({ myStoriesLoading: false })
                }
            },

            createStory: async (params: CreateStoryParams) => {
                set({ isCreating: true, uploadProgress: 0, createError: null })
                try {
                    let remoteMediaUrl = params.mediaUrl
                    let remoteOriginalUrl = params.originalMediaUrl

                    // Upload local file to Supabase storage first
                    const isLocalFile = params.mediaUrl.startsWith('file://') ||
                        params.mediaUrl.startsWith('/') ||
                        params.mediaUrl.startsWith('ph://')

                    if (isLocalFile) {
                        // console.log('[StoryStore] Uploading local media to storage...')
                        const uploadedUrl = await uploadMedia(
                            params.mediaUrl,
                            params.userId,
                            params.mediaType || 'image',
                            (progress) => set({ uploadProgress: progress * 0.9 }) // 90% is upload
                        )
                        if (!uploadedUrl) {
                            set({ isCreating: false, uploadProgress: 0, createError: 'Failed to upload media' })
                            return null
                        }
                        remoteMediaUrl = uploadedUrl
                        // console.log('[StoryStore] Media uploaded:', remoteMediaUrl)
                    }

                    // Also upload original media if it's local (AI-edited story)
                    if (remoteOriginalUrl) {
                        const isOriginalLocal = remoteOriginalUrl.startsWith('file://') ||
                            remoteOriginalUrl.startsWith('/') ||
                            remoteOriginalUrl.startsWith('ph://')
                        if (isOriginalLocal) {
                            const uploadedOriginal = await uploadMedia(
                                remoteOriginalUrl,
                                params.userId,
                                params.mediaType || 'image'
                            )
                            if (uploadedOriginal) {
                                remoteOriginalUrl = uploadedOriginal
                            }
                        }
                    }

                    // Finalizing (last 10%)
                    set({ uploadProgress: 0.95 })

                    const response = await apiClient.createStory({
                        user_id: params.userId,
                        media_url: remoteMediaUrl,
                        media_type: params.mediaType || 'image',
                        caption: params.caption,
                        visibility: params.visibility || 'everyone',
                        visible_to: params.visibleTo || [],
                        hidden_from: params.hiddenFrom || [],
                        original_media_url: remoteOriginalUrl,
                        duration: params.duration
                    })

                    set({ uploadProgress: 1.0 })

                    if (response.success && response.story) {
                        // Add to my stories
                        set(state => ({
                            myStories: [response.story, ...state.myStories],
                            isCreating: false,
                            uploadProgress: 0
                        }))
                        return response.story
                    } else {
                        set({ isCreating: false, uploadProgress: 0, createError: 'Failed to create story' })
                        return null
                    }
                } catch (error: any) {
                    console.error('[StoryStore] Failed to create story:', error)
                    set({ isCreating: false, uploadProgress: 0, createError: error.message || 'Failed to create story' })
                    return null
                }
            },

            deleteStory: async (storyId: string, userId: string) => {
                try {
                    const response = await apiClient.deleteStory(storyId, userId)
                    if (response.success) {
                        set(state => ({
                            myStories: state.myStories.filter(s => s.id !== storyId)
                        }))
                        return true
                    }
                    return false
                } catch (error) {
                    console.error('[StoryStore] Failed to delete story:', error)
                    return false
                }
            },

            markStoryViewed: async (storyId: string, viewerId: string) => {
                try {
                    await apiClient.markStoryViewed(storyId, viewerId)

                    // Update local feed to mark as seen
                    set(state => {
                        const newFeed = state.feed.map(group => {
                            const updatedStories = group.stories.map(story =>
                                story.id === storyId ? { ...story, viewed: true } : story
                            )
                            // Check if all stories are viewed
                            const allViewed = updatedStories.every((s: any) => s.viewed)
                            return {
                                ...group,
                                stories: updatedStories,
                                has_unseen: !allViewed
                            }
                        })
                        return { feed: newFeed }
                    })
                } catch (error) {
                    console.error('[StoryStore] Failed to mark story viewed:', error)
                }
            },

            updateVisibility: async (storyId: string, userId: string, visibility: Story['visibility'], visibleTo?: string[], hiddenFrom?: string[]) => {
                try {
                    const response = await apiClient.updateStoryVisibility(storyId, {
                        user_id: userId,
                        visibility,
                        visible_to: visibleTo || [],
                        hidden_from: hiddenFrom || []
                    })

                    if (response.success) {
                        set(state => ({
                            myStories: state.myStories.map(s =>
                                s.id === storyId ? { ...s, visibility } : s
                            )
                        }))
                        return true
                    }
                    return false
                } catch (error) {
                    console.error('[StoryStore] Failed to update visibility:', error)
                    return false
                }
            },

            setCurrentViewing: (userId: string, index: number) => {
                set({ currentViewingUserId: userId, currentStoryIndex: index })
            },

            nextStory: () => {
                const { feed, currentViewingUserId, currentStoryIndex } = get()
                const group = feed.find(g => g.user_id === currentViewingUserId)

                if (group && currentStoryIndex < group.stories.length - 1) {
                    set({ currentStoryIndex: currentStoryIndex + 1 })
                } else {
                    // Move to next user's stories
                    const currentIdx = feed.findIndex(g => g.user_id === currentViewingUserId)
                    if (currentIdx < feed.length - 1) {
                        set({
                            currentViewingUserId: feed[currentIdx + 1].user_id,
                            currentStoryIndex: 0
                        })
                    } else {
                        // End of all stories
                        set({ currentViewingUserId: null, currentStoryIndex: 0 })
                    }
                }
            },

            prevStory: () => {
                const { feed, currentViewingUserId, currentStoryIndex } = get()

                if (currentStoryIndex > 0) {
                    set({ currentStoryIndex: currentStoryIndex - 1 })
                } else {
                    // Move to previous user's stories
                    const currentIdx = feed.findIndex(g => g.user_id === currentViewingUserId)
                    if (currentIdx > 0) {
                        const prevGroup = feed[currentIdx - 1]
                        set({
                            currentViewingUserId: prevGroup.user_id,
                            currentStoryIndex: prevGroup.stories.length - 1
                        })
                    }
                }
            },

            clearViewing: () => {
                set({ currentViewingUserId: null, currentStoryIndex: 0 })
            },

            reset: () => {
                set({
                    feed: [],
                    feedLoading: false,
                    myStories: [],
                    myStoriesLoading: false,
                    isCreating: false,
                    createError: null,
                    currentViewingUserId: null,
                    currentStoryIndex: 0
                })
            }
        }),
        {
            name: 'vibe-story-store',
            storage: createJSONStorage(() => AsyncStorage),
            partialize: (state) => ({
                // Don't persist viewing state
                feed: state.feed,
                myStories: state.myStories
            })
        }
    )
)
