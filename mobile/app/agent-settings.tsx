import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useThemeStore } from '../src/lib/stores/theme-store';

export default function AgentSettingsRoute() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { colors } = useThemeStore();

  return (
    <View style={[styles.container, { backgroundColor: colors.background, paddingTop: insets.top + 12 }]}>
      <View style={styles.header}>
        <Pressable onPress={() => router.back()} style={styles.backButton}>
          <Text style={[styles.backLabel, { color: colors.primary || colors.text }]}>Back</Text>
        </Pressable>
        <Text style={[styles.title, { color: colors.text }]}>Agent Settings</Text>
        <View style={styles.headerSpacer} />
      </View>

      <View style={[styles.card, { backgroundColor: colors.card, borderColor: `${colors.text}14` }]}>
        <Text style={[styles.sectionTitle, { color: colors.text }]}>How it works</Text>
        <Text style={[styles.body, { color: colors.textSecondary }]}>
          Build agents through @vibeagent in the normal chat screen. Keep management actions separate here, similar to Telegram's split between BotFather setup and bot profile/settings.
        </Text>
      </View>

      <View style={[styles.card, { backgroundColor: colors.card, borderColor: `${colors.text}14` }]}>
        <Text style={[styles.sectionTitle, { color: colors.text }]}>Next actions</Text>
        <Text style={[styles.body, { color: colors.textSecondary }]}>
          Continue setup in chat to create a draft, set the prompt, enable tools, and publish.
        </Text>
        <Pressable
          onPress={() => router.replace('/agent?mode=builder')}
          style={[styles.primaryButton, { backgroundColor: colors.primary || colors.text }]}
        >
          <Text style={[styles.primaryButtonLabel, { color: colors.background }]}>Open @vibeagent</Text>
        </Pressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    paddingHorizontal: 20,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: 24,
  },
  backButton: {
    minWidth: 56,
  },
  backLabel: {
    fontSize: 16,
    fontWeight: '600',
  },
  title: {
    fontSize: 22,
    fontWeight: '700',
  },
  headerSpacer: {
    width: 56,
  },
  card: {
    borderWidth: 1,
    borderRadius: 22,
    padding: 18,
    marginBottom: 16,
  },
  sectionTitle: {
    fontSize: 18,
    fontWeight: '700',
    marginBottom: 8,
  },
  body: {
    fontSize: 15,
    lineHeight: 22,
  },
  primaryButton: {
    marginTop: 16,
    borderRadius: 16,
    paddingVertical: 14,
    alignItems: 'center',
  },
  primaryButtonLabel: {
    fontSize: 15,
    fontWeight: '700',
  },
});
