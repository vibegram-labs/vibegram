import { Stack } from 'expo-router';
import { I18nManager } from 'react-native';

export default function AuthLayout() {
    return (
        <Stack screenOptions={{
            headerShown: false,
            animation: 'slide_from_right',
            gestureEnabled: true,
            gestureDirection: 'horizontal',
            presentation: 'card'
        }}>
            <Stack.Screen name="welcome" />
            <Stack.Screen name="signin" />
            <Stack.Screen name="signup" />
        </Stack>
    );
}
