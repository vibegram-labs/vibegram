import { useEffect } from 'react'
import { Redirect } from 'expo-router'
import { View } from 'react-native'
import { useAuthStore } from '../src/lib/stores/auth-store'
import { useThemeStore } from '../src/lib/stores/theme-store'

export default function Index() {
    const { isAuthenticated, hasHydrated, checkSession } = useAuthStore()
    const { initTheme } = useThemeStore()

    useEffect(() => {
        // console.log('[Index] Mounted - isAuthenticated:', isAuthenticated, 'hydrated:', hasHydrated)
        // Initialize theme on mount
        initTheme()
        // Check session on mount
        checkSession()
    }, [])

    // console.log('[Index] Rendering - isAuthenticated:', isAuthenticated, 'hydrated:', hasHydrated)

    // Wait for Zustand hydration before deciding where to redirect
    if (!hasHydrated) {
        return <View style={{ flex: 1 }} />
    }

    // If authenticated, go to tabs
    if (isAuthenticated) {
        // console.log('[Index] Redirecting to /(tabs)/home')
        return <Redirect href="/(tabs)/home" />
    }

    // Otherwise go to auth flow
    // console.log('[Index] Redirecting to /(auth)/welcome')
    return <Redirect href="/(auth)/welcome" />
}
