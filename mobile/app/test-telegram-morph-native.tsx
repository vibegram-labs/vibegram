import React, { useCallback, useMemo, useState } from 'react';
import { StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import {
  getNativeChatRuntimeInfo,
  mapMessagesToNativeRows,
  NativeChatSurface,
  type NativeChatAppearance,
} from '../src/native/chat';

type DemoMessage = {
  id: string;
  text: string;
  timestamp: string;
  timestampMs: number;
  isMe: boolean;
  status: 'sent';
};

const MODE_LABELS = ['None', 'SlideUp', 'Telegram', 'Spring'] as const;

const makeSeedMessages = (): DemoMessage[] => {
  const now = Date.now();
  return [
    {
      id: 'seed-1',
      text: 'Native Telegram morph isolation lab',
      timestamp: '10:01',
      timestampMs: now - 240000,
      isMe: false,
      status: 'sent',
    },
    {
      id: 'seed-2',
      text: 'Send from native input to test send -> list morph only',
      timestamp: '10:02',
      timestampMs: now - 180000,
      isMe: true,
      status: 'sent',
    },
    {
      id: 'seed-3',
      text: 'No ChatStore and no bridge send timing noise here.',
      timestamp: '10:03',
      timestampMs: now - 120000,
      isMe: false,
      status: 'sent',
    },
  ];
};

const formatTime = (ms: number) =>
  new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });

export default function TestTelegramMorphNativeScreen() {
  const insets = useSafeAreaInsets();
  const runtime = useMemo(() => getNativeChatRuntimeInfo(), []);

  const [animMode, setAnimMode] = useState(2);
  const [sessionId, setSessionId] = useState(1);
  const [messages, setMessages] = useState<DemoMessage[]>(() => makeSeedMessages());
  const [lastEvent, setLastEvent] = useState('Ready');

  const rows = useMemo(
    () =>
      mapMessagesToNativeRows(
        messages.map((m) => ({
          id: m.id,
          text: m.text,
          timestamp: m.timestamp,
          timestampMs: m.timestampMs,
          isMe: m.isMe,
          status: m.status,
          type: 'text',
        }))
      ),
    [messages]
  );

  const appearance = useMemo(
    () =>
      ({
        backgroundMode: 'gradient',
        wallpaperGradient: ['#141526', '#181a34', '#121423'],
        wallpaperOpacity: 1,
        bubbleMeGradient: ['#7C5CE0', '#6A4FCF'],
        bubbleThemColor: '#2A2E4B',
        textColorMe: '#FFFFFF',
        textColorThem: '#E8EBFF',
        timeColorMe: 'rgba(255,255,255,0.72)',
        timeColorThem: 'rgba(232,235,255,0.62)',
        dayTextColor: 'rgba(236,239,255,0.82)',
        dayBackgroundColor: 'rgba(18,20,35,0.44)',
        dayBorderColor: 'rgba(255,255,255,0.14)',
        insertionAnimationMode: animMode,
      }) as NativeChatAppearance,
    [animMode]
  );

  const pushIncoming = useCallback(() => {
    const now = Date.now();
    setMessages((prev) => [
      ...prev,
      {
        id: `seed-them-${now}`,
        text: 'Incoming row for list stability check',
        timestamp: formatTime(now),
        timestampMs: now,
        isMe: false,
        status: 'sent',
      },
    ]);
  }, []);

  const resetSession = useCallback(() => {
    setMessages(makeSeedMessages());
    setSessionId((prev) => prev + 1);
    setLastEvent('Session reset');
  }, []);

  return (
    <View style={[styles.screen, { paddingTop: insets.top }]}>
      <View style={styles.header}>
        <Text style={styles.title}>Telegram Morph Native Isolate</Text>
        <Text style={styles.subtitle}>
          {runtime.enabled ? 'Native runtime active' : 'Native runtime unavailable'} · Mode:{' '}
          {MODE_LABELS[animMode]}
        </Text>
        <Text style={styles.hint}>
          Use the native input at bottom. This route tests only native send transition to native row insert.
        </Text>
      </View>

      <View style={styles.modeRow}>
        {MODE_LABELS.map((label, idx) => (
          <TouchableOpacity
            key={label}
            style={[styles.modeChip, animMode === idx && styles.modeChipActive]}
            onPress={() => setAnimMode(idx)}
          >
            <Text style={[styles.modeChipText, animMode === idx && styles.modeChipTextActive]}>
              {label}
            </Text>
          </TouchableOpacity>
        ))}
      </View>

      <View style={styles.actionRow}>
        <TouchableOpacity style={styles.actionBtn} onPress={pushIncoming}>
          <Text style={styles.actionText}>+ Incoming</Text>
        </TouchableOpacity>
        <TouchableOpacity style={styles.actionBtn} onPress={resetSession}>
          <Text style={styles.actionText}>Reset Surface</Text>
        </TouchableOpacity>
      </View>

      <View style={styles.eventBar}>
        <Text numberOfLines={1} style={styles.eventText}>
          Event: {lastEvent}
        </Text>
      </View>

      <View style={styles.surfaceWrap}>
        <NativeChatSurface
          surfaceId={`test-telegram-morph-native-${sessionId}`}
          rows={rows}
          appearance={appearance}
          inputBarEnabled
          nativeSendEnabled
          inputPlaceholder="Message"
          onNativeEvent={(event) => {
            const e = event?.nativeEvent || {};
            const type = String(e.type || 'unknown');
            const messageId = String(e.messageId || '');
            if (
              type === 'sendTransitionStarted'
              || type === 'sendTransitionCompleted'
              || type === 'recordingState'
            ) {
              setLastEvent(messageId ? `${type} (${messageId})` : type);
            }
          }}
        />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: {
    flex: 1,
    backgroundColor: '#0F1020',
  },
  header: {
    paddingHorizontal: 14,
    paddingTop: 10,
    paddingBottom: 8,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: 'rgba(255,255,255,0.12)',
  },
  title: {
    color: '#FFFFFF',
    fontSize: 16,
    fontWeight: '700',
  },
  subtitle: {
    color: 'rgba(255,255,255,0.74)',
    fontSize: 12,
    marginTop: 2,
  },
  hint: {
    color: 'rgba(255,255,255,0.56)',
    fontSize: 11,
    marginTop: 3,
  },
  modeRow: {
    flexDirection: 'row',
    paddingHorizontal: 10,
    paddingVertical: 8,
    gap: 6,
  },
  modeChip: {
    flex: 1,
    borderRadius: 10,
    paddingVertical: 7,
    alignItems: 'center',
    backgroundColor: 'rgba(255,255,255,0.08)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.08)',
  },
  modeChipActive: {
    backgroundColor: 'rgba(124,92,224,0.34)',
    borderColor: '#7C5CE0',
  },
  modeChipText: {
    color: 'rgba(255,255,255,0.72)',
    fontSize: 11,
    fontWeight: '600',
  },
  modeChipTextActive: {
    color: '#FFFFFF',
  },
  actionRow: {
    flexDirection: 'row',
    gap: 8,
    paddingHorizontal: 10,
    paddingBottom: 8,
  },
  actionBtn: {
    flex: 1,
    paddingVertical: 8,
    borderRadius: 10,
    alignItems: 'center',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.14)',
    backgroundColor: 'rgba(255,255,255,0.06)',
  },
  actionText: {
    color: '#FFFFFF',
    fontSize: 12,
    fontWeight: '600',
  },
  eventBar: {
    marginHorizontal: 10,
    marginBottom: 8,
    borderRadius: 8,
    paddingHorizontal: 10,
    paddingVertical: 7,
    backgroundColor: 'rgba(0,0,0,0.28)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.08)',
  },
  eventText: {
    color: 'rgba(255,255,255,0.82)',
    fontSize: 11,
  },
  surfaceWrap: {
    flex: 1,
  },
});
