import React, { useEffect } from 'react';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useAgentStore } from '../src/lib/agent/AgentStore';
import VibeChatMainScreen from '../src/components/agent/VibeChatMainScreen';

export default function AgentScreen() {
    const router = useRouter();
    const { setActiveConversation } = useAgentStore();
    const params = useLocalSearchParams<{ conversationId?: string; mode?: string }>();

    // Handle conversationId from navigation (e.g., from @vibe toast)
    useEffect(() => {
        if (params.mode !== 'builder' && params.conversationId) {
            setActiveConversation(params.conversationId);
        }
    }, [params.conversationId, params.mode, setActiveConversation]);

    return (
        <VibeChatMainScreen
            mode={params.mode === 'builder' ? 'builder' : 'default'}
            onBack={() => router.back()}
            onOpenBuilder={() => router.replace('/agent?mode=builder')}
            onOpenSettings={() => router.push('/agent-settings')}
        />
    );
}
