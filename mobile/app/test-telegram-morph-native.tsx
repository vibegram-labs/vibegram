import React, { useCallback, useMemo, useState, useRef } from 'react';
import { StyleSheet, Text, TouchableOpacity, View, Animated, ScrollView, Pressable } from 'react-native';
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

const HoldEffectBubble = ({ title, desc, scaleMethod, isMe }: any) => {
  const scaleAnim = useRef(new Animated.Value(1)).current;
  const [pressed, setPressed] = useState(false);

  // We'll simulate the cell full width
  const handlePressIn = () => {
    setPressed(true);
    Animated.spring(scaleAnim, {
      toValue: 0.95,
      useNativeDriver: true,
      damping: 15,
      stiffness: 300,
    }).start();
  };

  const handlePressOut = () => {
    setPressed(false);
    Animated.spring(scaleAnim, {
      toValue: 1,
      useNativeDriver: true,
      damping: 15,
      stiffness: 300,
    }).start();
  };

  // We define the bubble logic based on scaleMethod
  let containerTransform: any = [];
  let bubbleTransform: any = [];

  // Cell width is arbitrary, say 350
  const CELL_WIDTH = 350;
  // Bubble roughly 250px wide, centered in its side
  const BUBBLE_WIDTH = 250;
  const BUBBLE_HEIGHT = 60;
  
  if (scaleMethod === 'scale_cell_center') {
    // Scales the whole cell row from the exact center of the cell
    containerTransform = [{ scale: scaleAnim }];
  } else if (scaleMethod === 'scale_bubble_direct') {
    // Scales just the bubble view itself (its own center)
    bubbleTransform = [{ scale: scaleAnim }];
  } else if (scaleMethod === 'ios_math') {
    // The current iOS math used inside ChatListViewCells.swift:
    // Scale the whole cell, but translate so it pivots around the bubble's center
    // Let's assume bubble center is X: (cellWidth - (bubbleWidth/2)) if isMe 
    const cx = CELL_WIDTH / 2;
    const px = isMe ? CELL_WIDTH - BUBBLE_WIDTH / 2 : BUBBLE_WIDTH / 2;
    // We can't do exact dynamic math easily in Animated without Reanimated,
    // so we interpolate:
    const translateX = scaleAnim.interpolate({
      inputRange: [0.95, 1],
      outputRange: [(px - cx) * (1 - 0.95), 0],
    });
    
    containerTransform = [
      { translateX },
      { scale: scaleAnim },
    ];
  } else if (scaleMethod === 'anchor_edge') {
    // Just scaling bubble directly, but with a slight translation to anchor the edge
    const edgeTranslate = scaleAnim.interpolate({
      inputRange: [0.95, 1],
      outputRange: [isMe ? (BUBBLE_WIDTH * 0.05) / 2 : -(BUBBLE_WIDTH * 0.05) / 2, 0],
    });
    bubbleTransform = [
      { translateX: edgeTranslate },
      { scale: scaleAnim }
    ];
  }

  return (
    <View style={styles.labCard}>
      <Text style={styles.labCardTitle}>{title}</Text>
      <Text style={styles.labCardDesc}>{desc}</Text>
      
      <Pressable onPressIn={handlePressIn} onPressOut={handlePressOut} delayLongPress={50}>
        <View style={styles.cellOuter}>
          <Animated.View style={[styles.cellContainer, { transform: containerTransform }, isMe ? { alignItems: 'flex-end'} : {alignItems: 'flex-start'}]}>
             <Animated.View style={[styles.demoBubble, isMe ? styles.demoBubbleMe : styles.demoBubbleThem, { transform: bubbleTransform }]}>
                <Text style={styles.demoBubbleText}>Tap and hold me to test the effect!</Text>
             </Animated.View>
          </Animated.View>
        </View>
      </Pressable>
    </View>
  );
};

function HoldEffectLab() {
  return (
    <ScrollView style={styles.surfaceWrap} contentContainerStyle={{ padding: 16 }}>
      <Text style={styles.labInstruct}>
        Tap and hold the bubbles below to see how they scale down. Look closely at how the bubble shifts horizontally. 
      </Text>
      
      <HoldEffectBubble 
         title="1. Scale Cell Center (Bad)" 
         desc="Scales the whole row around the center of the screen. Bubble shifts towards center."
         scaleMethod="scale_cell_center"
         isMe={true}
      />

      <HoldEffectBubble 
         title="2. Current iOS Math (Translate + Scale Cell)" 
         desc="This is what the Swift code is doing now: scaling the whole cell but translating it to pivot on the bubble. Might cause jitter."
         scaleMethod="ios_math"
         isMe={true}
      />

      <HoldEffectBubble 
         title="3. Scale Bubble Directly (Best)" 
         desc="Only scales the bubble container itself around its own center. No translation math needed. Smooth."
         scaleMethod="scale_bubble_direct"
         isMe={true}
      />

      <HoldEffectBubble 
         title="4. Scale + Anchor Edge" 
         desc="Scales the bubble directly but translates slightly to keep the bubble tail anchored to the edge."
         scaleMethod="anchor_edge"
         isMe={true}
      />
      
      <View style={{height: 40}} />
      <Text style={{color: '#fff', fontSize: 16, fontWeight: 'bold', marginBottom: 10}}>Receiver (Them) Bubbles:</Text>
      
      <HoldEffectBubble 
         title="Current iOS Math (Them)" 
         desc="Translate + Scale cell on the left side."
         scaleMethod="ios_math"
         isMe={false}
      />
      <HoldEffectBubble 
         title="Scale Bubble Directly (Them)" 
         desc="Pivot around its own center."
         scaleMethod="scale_bubble_direct"
         isMe={false}
      />
            
    </ScrollView>
  );
}

export default function TestTelegramMorphNativeScreen() {
  const insets = useSafeAreaInsets();
  const runtime = useMemo(() => getNativeChatRuntimeInfo(), []);

  const [activeTab, setActiveTab] = useState<'surface' | 'lab'>('lab');
  
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
        <Text style={styles.title}>Hold Effect & Morph Lab</Text>
        <Text style={styles.subtitle}>
          {runtime.enabled ? 'Native runtime active' : 'Native runtime unavailable'}
        </Text>
      </View>

      <View style={styles.tabRow}>
        <TouchableOpacity
          style={[styles.tabBtn, activeTab === 'lab' && styles.tabBtnActive]}
          onPress={() => setActiveTab('lab')}
        >
          <Text style={[styles.tabText, activeTab === 'lab' && styles.tabTextActive]}>Hold Lab</Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.tabBtn, activeTab === 'surface' && styles.tabBtnActive]}
          onPress={() => setActiveTab('surface')}
        >
          <Text style={[styles.tabText, activeTab === 'surface' && styles.tabTextActive]}>List Surface</Text>
        </TouchableOpacity>
      </View>

      {activeTab === 'surface' ? (
        <>
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
        </>
      ) : (
        <HoldEffectLab />
      )}
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
  tabRow: {
    flexDirection: 'row',
    paddingHorizontal: 10,
    paddingVertical: 10,
    gap: 10,
    backgroundColor: 'rgba(0,0,0,0.2)'
  },
  tabBtn: {
    flex: 1,
    paddingVertical: 10,
    alignItems: 'center',
    borderRadius: 8,
    backgroundColor: 'rgba(255,255,255,0.05)'
  },
  tabBtnActive: {
    backgroundColor: '#7C5CE0'
  },
  tabText: {
    color: 'rgba(255,255,255,0.6)',
    fontWeight: '600'
  },
  tabTextActive: {
    color: '#fff'
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
  
  // Lab styles
  labInstruct: {
    color: 'rgba(255,255,255,0.8)',
    fontSize: 14,
    marginBottom: 20,
    lineHeight: 20
  },
  labCard: {
    marginBottom: 24,
    backgroundColor: 'rgba(255,255,255,0.05)',
    borderRadius: 12,
    padding: 16,
  },
  labCardTitle: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '700',
    marginBottom: 4,
  },
  labCardDesc: {
    color: 'rgba(255,255,255,0.6)',
    fontSize: 13,
    marginBottom: 16,
  },
  cellOuter: {
    width: 350,
    height: 70,
    backgroundColor: 'rgba(255,255,255,0.03)',
    borderRadius: 8,
    overflow: 'hidden',
    justifyContent: 'center',
    alignSelf: 'center'
  },
  cellContainer: {
    width: 350,
    paddingHorizontal: 10,
  },
  demoBubble: {
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderRadius: 18,
    maxWidth: 250,
  },
  demoBubbleMe: {
    backgroundColor: '#7C5CE0',
    borderBottomRightRadius: 4,
  },
  demoBubbleThem: {
    backgroundColor: '#2A2E4B',
    borderBottomLeftRadius: 4,
  },
  demoBubbleText: {
    color: '#fff',
    fontSize: 15,
  }
});
