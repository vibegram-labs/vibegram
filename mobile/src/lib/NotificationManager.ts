import * as Device from 'expo-device';
import * as Notifications from 'expo-notifications';
import Constants from 'expo-constants';
import { Platform } from 'react-native';

// Configure how notifications behave when received in foreground
Notifications.setNotificationHandler({
    handleNotification: async () => ({
        shouldShowAlert: true, // Show banner even when app is open
        shouldPlaySound: true,
        shouldSetBadge: true,
        shouldShowBanner: true,
        shouldShowList: true,
    }),
});

export const requestPermissionsAndGetToken = async (): Promise<string | undefined> => {
    if (Platform.OS === 'android') {
        await Notifications.setNotificationChannelAsync('default', {
            name: 'default',
            importance: Notifications.AndroidImportance.MAX,
            vibrationPattern: [0, 250, 250, 250],
            lightColor: '#FF231F7C',
        });
    }

    // NOTE: Device check removed for Simulator testing
    const { status: existingStatus } = await Notifications.getPermissionsAsync();
    let finalStatus = existingStatus;

    if (existingStatus !== 'granted') {
        const { status } = await Notifications.requestPermissionsAsync({
            ios: {
                allowAlert: true,
                allowBadge: true,
                allowSound: true,
            },
        });
        finalStatus = status;
    }

    if (finalStatus !== 'granted') {
        console.log('Failed to get push token for push notification!');
        return undefined;
    }

    try {
        const projectId = Constants?.expoConfig?.extra?.eas?.projectId ?? Constants?.easConfig?.projectId;
        if (!projectId) {
            console.log('Project ID not found in Constants');
        }

        const tokenData = await Notifications.getExpoPushTokenAsync({
            projectId,
        });
        console.log('Expo Push Token:', tokenData.data);
        return tokenData.data;
    } catch (e) {
        console.log('Error fetching push token:', e);
        return undefined;
    }
};
