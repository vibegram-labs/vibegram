import type { NativeCallModule, NativeCallUiEvent } from './types';
import { Platform } from 'react-native';

const MODULE_NAME = 'VibeNativeCall';

let cachedModule: NativeCallModule | null | undefined;

const loadOptionalNativeModule = <T>(moduleName: string): T | null => {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const core = require('expo-modules-core');

    if (typeof core.requireNativeModule === 'function') {
      try {
        return core.requireNativeModule(moduleName) as T;
      } catch {
        // fall through
      }
    }

    if (typeof core.requireOptionalNativeModule === 'function') {
      const optional = core.requireOptionalNativeModule(moduleName) as T | null;
      if (optional) return optional;
    }

    const proxy = core.NativeModulesProxy as Record<string, T> | undefined;
    return proxy?.[moduleName] ?? null;
  } catch {
    return null;
  }
};

export const getNativeCallModule = (): NativeCallModule | null => {
  // Temporary kill-switch: force iOS to use the React Native call flow/UI.
  if (Platform.OS === 'ios') return null;
  if (cachedModule) return cachedModule;
  const resolved = loadOptionalNativeModule<NativeCallModule>(MODULE_NAME);
  if (resolved || !__DEV__) {
    cachedModule = resolved;
  }
  return resolved ?? null;
};

type NativeCallUiSubscription = { remove: () => void };

export const addNativeCallUiListener = (
  listener: (event: NativeCallUiEvent) => void,
): NativeCallUiSubscription | null => {
  const nativeModule = getNativeCallModule();
  if (!nativeModule) return null;
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { EventEmitter } = require('expo-modules-core');
    const emitter = new EventEmitter(nativeModule);
    return emitter.addListener('onCallUiEvent', listener);
  } catch {
    return null;
  }
};
