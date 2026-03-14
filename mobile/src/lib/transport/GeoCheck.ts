import AsyncStorage from '@react-native-async-storage/async-storage';

/**
 * Geo-IP check for blackout eligibility.
 *
 * The blackout system (bridge/offline transport) is only intended for countries
 * where direct connections to the server are censored (e.g. Russia, China, Iran).
 * Users in other countries should NEVER enter blackout mode, even if transient
 * network failures occur.
 *
 * This module checks the user's country via a free geo-IP API and caches the
 * result. If the lookup fails, we assume the user is NOT in a censored region
 * (safe default — worst case they use direct connection and it fails naturally).
 */

const STORAGE_KEY = 'vibe.geo.country.v1';
const GEO_CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000; // re-check once per day
const GEO_TIMEOUT_MS = 5_000;

// ISO 3166-1 alpha-2 codes for countries known to censor internet access
// to the point where direct connections to our servers may be blocked.
const CENSORED_COUNTRY_CODES = new Set([
  'CN',  // China
  'IR',  // Iran
  'RU',  // Russia
  'TM',  // Turkmenistan
  'KP',  // North Korea
  'BY',  // Belarus
  'MM',  // Myanmar
]);

interface GeoCache {
  countryCode: string;
  checkedAt: number;
}

let cachedResult: { eligible: boolean; countryCode: string | null } | null = null;
let checkPromise: Promise<{ eligible: boolean; countryCode: string | null }> | null = null;

/**
 * Returns whether the user is in a country where blackout mode is applicable.
 * Uses cached result if available and recent. Falls back to `false` (not eligible)
 * if geo lookup fails — meaning direct mode will be used.
 */
export const isBlackoutEligibleRegion = async (): Promise<{ eligible: boolean; countryCode: string | null }> => {
  // Return in-memory cache immediately if available
  if (cachedResult) return cachedResult;
  // Deduplicate concurrent calls
  if (checkPromise) return checkPromise;

  checkPromise = (async () => {
    // Try to load cached geo result from storage
    try {
      const raw = await AsyncStorage.getItem(STORAGE_KEY);
      if (raw) {
        const parsed = JSON.parse(raw) as GeoCache;
        if (parsed.countryCode && parsed.checkedAt) {
          const age = Date.now() - parsed.checkedAt;
          if (age < GEO_CHECK_INTERVAL_MS) {
            const eligible = CENSORED_COUNTRY_CODES.has(parsed.countryCode.toUpperCase());
            cachedResult = { eligible, countryCode: parsed.countryCode.toUpperCase() };
            console.log(`[GeoCheck] cached country=${parsed.countryCode} eligible=${eligible}`);
            return cachedResult;
          }
        }
      }
    } catch {
      // Storage read failed — continue to network check
    }

    // Fetch country from geo-IP service
    const countryCode = await fetchCountryCode();
    if (countryCode) {
      const eligible = CENSORED_COUNTRY_CODES.has(countryCode);
      cachedResult = { eligible, countryCode };
      // Persist to storage
      try {
        const payload: GeoCache = { countryCode, checkedAt: Date.now() };
        await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(payload));
      } catch {
        // Best-effort persistence
      }
      console.log(`[GeoCheck] fetched country=${countryCode} eligible=${eligible}`);
      return cachedResult;
    }

    // Geo lookup failed — default to NOT eligible (use direct mode)
    // This is the safe default: users with good connections won't be blocked,
    // and users in censored countries will still hit natural connection failures.
    cachedResult = { eligible: false, countryCode: null };
    console.log('[GeoCheck] lookup failed — defaulting to direct (not blackout eligible)');
    return cachedResult;
  })();

  try {
    return await checkPromise;
  } finally {
    checkPromise = null;
  }
};

/**
 * Try multiple free geo-IP services with a fast timeout.
 * Returns uppercase 2-letter country code or null.
 */
const fetchCountryCode = async (): Promise<string | null> => {
  const endpoints = [
    {
      url: 'http://ip-api.com/json/?fields=countryCode',
      extract: (data: any) => data?.countryCode,
    },
    {
      url: 'https://ipapi.co/json/',
      extract: (data: any) => data?.country_code,
    },
  ];

  for (const endpoint of endpoints) {
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), GEO_TIMEOUT_MS);
      const response = await fetch(endpoint.url, {
        signal: controller.signal,
        headers: { Accept: 'application/json' },
      });
      clearTimeout(timeoutId);
      if (response.ok) {
        const data = await response.json();
        const code = endpoint.extract(data);
        if (typeof code === 'string' && code.length === 2) {
          return code.toUpperCase();
        }
      }
    } catch {
      // Try next endpoint
    }
  }
  return null;
};

/**
 * Check if a specific country code is in the censored list.
 * Useful for testing / manual override.
 */
export const isCensoredCountry = (countryCode: string): boolean =>
  CENSORED_COUNTRY_CODES.has(countryCode.toUpperCase());

/**
 * Force the geo-check cache to a specific value (for testing / manual override).
 */
export const overrideGeoResult = (countryCode: string | null, eligible: boolean): void => {
  cachedResult = { eligible, countryCode };
};

/**
 * Clear the cached geo result to force a fresh lookup.
 */
export const clearGeoCache = async (): Promise<void> => {
  cachedResult = null;
  try {
    await AsyncStorage.removeItem(STORAGE_KEY);
  } catch {
    // Best-effort
  }
};
