import Constants, { ExecutionEnvironment } from 'expo-constants';

import type {
  NativeChatAgentModule,
  NativeChatCoreModule,
  NativeChatEngineModule,
  NativeChatListModule,
  NativeChatMainModule,
  NativeChatRuntimeInfo,
} from './types';

const CORE_MODULE_NAME = 'ChatNativeCore';
const LIST_MODULE_NAME = 'ChatNativeList';
const MAIN_MODULE_NAME = 'ChatNativeMain';
const AGENT_MODULE_NAME = 'ChatNativeAgent';
const ENGINE_MODULE_NAME = 'ChatEngine';
const ENGINE_MODULE_NAME_LEGACY = 'ChatNativeEngine';

let cachedCoreModule: NativeChatCoreModule | null | undefined;
let cachedListModule: NativeChatListModule | null | undefined;
let cachedMainModule: NativeChatMainModule | null | undefined;
let cachedAgentModule: NativeChatAgentModule | null | undefined;
let cachedEngineModule: NativeChatEngineModule | null | undefined;

const resolveRemoteFlag = (): boolean => {
  const envFlag = process.env.EXPO_PUBLIC_NATIVE_CHAT_ENABLED;
  if (envFlag === '1' || envFlag === 'true') return true;
  if (envFlag === '0' || envFlag === 'false') return false;

  const extra = (Constants.expoConfig?.extra || Constants.manifest2?.extra || {}) as {
    nativeChat?: { enabled?: boolean };
  };
  if (typeof extra?.nativeChat?.enabled === 'boolean') {
    return extra.nativeChat.enabled;
  }

  // Dev client default: keep native chat path on unless explicitly disabled.
  if (__DEV__) return true;

  return false;
};

export const isExpoGo =
  Constants.executionEnvironment === ExecutionEnvironment.StoreClient;

const loadOptionalNativeModule = <T>(moduleName: string): T | null => {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const core = require('expo-modules-core');

    // Prefer strict lookup first.
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

    // Fallback for environments where modules are exposed on NativeModulesProxy.
    const nativeModulesProxy = core.NativeModulesProxy as Record<string, T> | undefined;
    if (nativeModulesProxy && nativeModulesProxy[moduleName]) {
      return nativeModulesProxy[moduleName];
    }
  } catch {
    return null;
  }
  return null;
};

export const getNativeChatCoreModule = (): NativeChatCoreModule | null => {
  if (cachedCoreModule) return cachedCoreModule;
  const resolved = loadOptionalNativeModule<NativeChatCoreModule>(CORE_MODULE_NAME);
  // In dev, avoid sticky-null cache so late module registration can recover.
  if (resolved || !__DEV__) {
    cachedCoreModule = resolved;
  }
  return resolved ?? null;
};

export const clearNativeChatModuleCache = (): void => {
  cachedCoreModule = undefined;
  cachedListModule = undefined;
  cachedMainModule = undefined;
  cachedAgentModule = undefined;
  cachedEngineModule = undefined;
};

export const getNativeModuleProxyKeys = (): string[] => {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const core = require('expo-modules-core');
    const nativeModulesProxy = core.NativeModulesProxy as Record<string, unknown> | undefined;
    if (!nativeModulesProxy) return [];
    return Object.keys(nativeModulesProxy).sort();
  } catch {
    return [];
  }
};

export const getNativeChatListModule = (): NativeChatListModule | null => {
  if (cachedListModule) return cachedListModule;
  const resolved = loadOptionalNativeModule<NativeChatListModule>(LIST_MODULE_NAME);
  if (resolved || !__DEV__) {
    cachedListModule = resolved;
  }
  return resolved ?? null;
};

export const getNativeChatMainModule = (): NativeChatMainModule | null => {
  if (cachedMainModule) return cachedMainModule;
  const resolved = loadOptionalNativeModule<NativeChatMainModule>(MAIN_MODULE_NAME);
  if (resolved || !__DEV__) {
    cachedMainModule = resolved;
  }
  return resolved ?? null;
};

export const getNativeChatAgentModule = (): NativeChatAgentModule | null => {
  if (cachedAgentModule) return cachedAgentModule;
  const resolved = loadOptionalNativeModule<NativeChatAgentModule>(AGENT_MODULE_NAME);
  if (resolved || !__DEV__) {
    cachedAgentModule = resolved;
  }
  return resolved ?? null;
};

export const getNativeChatEngineModule = (): NativeChatEngineModule | null => {
  if (cachedEngineModule) return cachedEngineModule;
  const resolved =
    loadOptionalNativeModule<NativeChatEngineModule>(ENGINE_MODULE_NAME)
    || loadOptionalNativeModule<NativeChatEngineModule>(ENGINE_MODULE_NAME_LEGACY);
  if (resolved || !__DEV__) {
    cachedEngineModule = resolved;
  }
  return resolved ?? null;
};

export const getNativeChatRuntimeInfo = (): NativeChatRuntimeInfo => {
  const remoteFlag = resolveRemoteFlag();
  const coreModule = getNativeChatCoreModule();
  const listModule = getNativeChatListModule();
  const moduleAvailable = !!coreModule && (coreModule.isSupported?.() ?? true);
  const listModuleAvailable = !!listModule && (listModule.isSupported?.() ?? true);

  return {
    enabled: !isExpoGo && remoteFlag && moduleAvailable && listModuleAvailable,
    isExpoGo,
    remoteFlag,
    moduleAvailable,
    listModuleAvailable,
  };
};

export const isNativeChatEnabled = (): boolean => getNativeChatRuntimeInfo().enabled;

export const isNativeChatJsFallbackEnabled = (): boolean => {
  const envFlag = process.env.EXPO_PUBLIC_CHAT_NATIVE_JS_FALLBACK;
  if (envFlag === '1' || envFlag === 'true') return true;
  if (envFlag === '0' || envFlag === 'false') return false;

  const extra = (Constants.expoConfig?.extra || Constants.manifest2?.extra || {}) as {
    nativeChat?: { jsFallbackEnabled?: boolean };
  };
  return extra?.nativeChat?.jsFallbackEnabled === true;
};
