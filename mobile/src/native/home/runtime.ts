import type { NativeChatHomeModule } from './types';

const HOME_MODULE_NAME = 'ChatNativeHome';

let cachedHomeModule: NativeChatHomeModule | null | undefined;

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
      const optionalModule = core.requireOptionalNativeModule(moduleName) as T | null;
      if (optionalModule) return optionalModule;
    }

    const nativeModulesProxy = core.NativeModulesProxy as Record<string, T> | undefined;
    if (nativeModulesProxy && nativeModulesProxy[moduleName]) {
      return nativeModulesProxy[moduleName];
    }
  } catch {
    return null;
  }
  return null;
};

export const getNativeChatHomeModule = (): NativeChatHomeModule | null => {
  if (cachedHomeModule) return cachedHomeModule;
  const resolved = loadOptionalNativeModule<NativeChatHomeModule>(HOME_MODULE_NAME);
  if (resolved || !__DEV__) {
    cachedHomeModule = resolved;
  }
  return resolved ?? null;
};
