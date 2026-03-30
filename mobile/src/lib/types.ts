
export interface Message {
    id: string;
    fromId: string;
    chatId?: string;
    encryptedContent: string;
    type: 'text' | 'image' | 'video' | 'voice' | 'call' | 'gif' | 'file' | 'location' | 'music' | 'sticker' | 'contact';
    mediaUrl?: string;
    fileName?: string;
    fileSize?: number;
    latitude?: number;
    longitude?: number;
    duration?: number; // Voice/video message duration in seconds
    contact?: {
        id?: string;
        username?: string;
        phoneNumber?: string;
        profileImage?: string;
    };
    timestamp: number;
    status?: 'sending' | 'pending' | 'sent' | 'delivered' | 'read' | 'error';
    readBy?: string[];
    errorMessage?: string;
    replyToId?: string;
    plaintext?: string;
    caption?: string; // Caption text attached to media messages
    extra?: any;
    toolResults?: any[];
    mediaKey?: string; // AES-256-GCM key for decrypting mediaUrl file content
    isEdited?: boolean;
    editedAt?: number;

    // One-time view media (like Instagram's "view once")
    viewOnce?: boolean;
    viewedBy?: string[]; // User IDs who have viewed this one-time media

    // Circular video note (like Telegram's video messages)
    isVideoNote?: boolean;
    isAgentMessage?: boolean;
    agentName?: string;
    agentId?: string;
}

export type ChatType = 'dm' | 'group' | 'channel';
export type ChatRole = 'owner' | 'admin' | 'member' | 'subscriber';

export interface ChatMember {
    userId: string;
    name?: string;
    role?: ChatRole;
}

export interface Chat {
    chatId: string;
    type?: ChatType;
    name?: string;
    description?: string;
    avatarUrl?: string;
    creatorId?: string;
    memberCount?: number;
    role?: ChatRole;
    members?: ChatMember[];
    friendId: string;
    friendName: string;
    friendIsAgent?: boolean;
    friendAgentId?: string;
    acceptsIncomingChat?: boolean;
    messages: Message[];
    lastMessage?: Message;
    unreadCount?: number;
    friendImage?: string;
    previewLastMessage?: string; // Cache
    historyNextCursor?: string | null;
    historyHasMore?: boolean;
    pinned?: boolean;
    muted?: boolean;
    markedUnread?: boolean;
    // Keys are complex in RN, simplified for UI for now
    friendKey?: any;
    friendIdentityKey?: any;
}

export interface ScheduledPost {
    id: string;
    channelId: string;
    content: string;
    type: 'text' | 'image' | 'media';
    mediaUrl?: string;
    scheduledAt: string;
    status: 'pending' | 'posted' | 'cancelled';
}
