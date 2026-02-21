import * as Device from 'expo-device';
import * as Notifications from 'expo-notifications';
import Constants from 'expo-constants';
import { Platform } from 'react-native';

// Configure how notifications behave when received in foreground
Notifications.setNotificationHandler({
    handleNotification: async (notification) => {
        const data = notification.request.content.data as Record<string, unknown> | undefined;
        const type = typeof data?.type === 'string' ? data.type : '';
        const isIncomingCall = type === 'call-start';

        // For incoming calls, use in-app native overlay instead of foreground banner.
        if (isIncomingCall) {
            return {
                shouldPlaySound: false,
                shouldSetBadge: false,
                shouldShowBanner: false,
                shouldShowList: false,
            };
        }

        return {
            shouldPlaySound: true,
            shouldSetBadge: true,
            shouldShowBanner: true,
            shouldShowList: true,
        };
    },
});

export const requestPermissionsAndGetToken = async (): Promise<string | undefined> => {
    console.log('[NotificationManager] init', {
        platform: Platform.OS,
        isDevice: Device.isDevice,
        appOwnership: Constants.appOwnership,
        executionEnvironment: Constants.executionEnvironment,
    });

    if (Platform.OS === 'android') {
        console.log('[NotificationManager] configuring Android channel: default');
        await Notifications.setNotificationChannelAsync('default', {
            name: 'default',
            importance: Notifications.AndroidImportance.MAX,
            vibrationPattern: [0, 250, 250, 250],
            lightColor: '#FF231F7C',
        });
    }

    // NOTE: Device check removed for Simulator testing
    const existing = await Notifications.getPermissionsAsync();
    const { status: existingStatus } = existing;
    console.log('[NotificationManager] permission status before request', {
        status: existing.status,
        canAskAgain: existing.canAskAgain,
        granted: existing.granted,
        iosStatus: (existing as any)?.ios?.status,
        iosAllowsAlert: (existing as any)?.ios?.allowsAlert,
        iosAllowsBadge: (existing as any)?.ios?.allowsBadge,
        iosAllowsSound: (existing as any)?.ios?.allowsSound,
    });
    let finalStatus = existingStatus;

    if (existingStatus !== 'granted') {
        const requested = await Notifications.requestPermissionsAsync({
            ios: {
                allowAlert: true,
                allowBadge: true,
                allowSound: true,
            },
        });
        finalStatus = requested.status;
        console.log('[NotificationManager] permission status after request', {
            status: requested.status,
            canAskAgain: requested.canAskAgain,
            granted: requested.granted,
            iosStatus: (requested as any)?.ios?.status,
            iosAllowsAlert: (requested as any)?.ios?.allowsAlert,
            iosAllowsBadge: (requested as any)?.ios?.allowsBadge,
            iosAllowsSound: (requested as any)?.ios?.allowsSound,
        });
    }

    if (finalStatus !== 'granted') {
        console.log('[NotificationManager] push permission not granted');
        return undefined;
    }

    try {
        const projectId = Constants?.expoConfig?.extra?.eas?.projectId ?? Constants?.easConfig?.projectId;
        if (!projectId) {
            console.log('[NotificationManager] projectId missing in Constants');
        } else {
            console.log('[NotificationManager] using projectId', projectId);
        }

        const tokenData = await Notifications.getExpoPushTokenAsync({
            projectId,
        });
        console.log('[NotificationManager] Expo push token acquired', tokenData.data);
        return tokenData.data;
    } catch (e) {
        console.log('[NotificationManager] Error fetching Expo push token', e);
        return undefined;
    }
};
