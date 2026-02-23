import React from 'react';
import { StyleSheet, Text, View, TouchableOpacity, Image, Platform } from 'react-native';
import { BlurView } from 'expo-blur';
import { ChevronLeft, Search, Phone, Video } from 'lucide-react-native';
import { HeaderBackIcon, HeaderPhoneIcon, HeaderVideoIcon, HeaderSearchIcon } from '../Icons';
import MaskedView from '@react-native-masked-view/masked-view';
import { LinearGradient } from 'expo-linear-gradient';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useRouter } from 'expo-router';
import SafeLiquidGlass from '../native/SafeLiquidGlass';

const MaskedViewAny = MaskedView as any;

interface ChatScreenHeaderProps {
    title: string;
    subtitle: string;
    isOnline?: boolean;
    avatarUri?: string;
    colors: any;
    effectiveTheme: 'light' | 'dark';
    wallpaperGradient: string[];
    bubbleTheme: {
        meGradient: [string, string];
    };
    onPressSearch?: () => void;
    onPressAvatar?: () => void;
    onAudioCall?: () => void;
    onVideoCall?: () => void;
}

const withAlpha = (color: string, alpha: number) => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`;
    if (color.startsWith('#')) {
        const r = parseInt(color.slice(1, 3), 16);
        const g = parseInt(color.slice(3, 5), 16);
        const b = parseInt(color.slice(5, 7), 16);
        return `rgba(${r}, ${g}, ${b}, ${alpha})`;
    }
    return color;
};

export default function ChatScreenHeader({
    title,
    subtitle,
    isOnline,
    avatarUri,
    colors,
    effectiveTheme,
    wallpaperGradient,
    bubbleTheme,
    onPressSearch,
    onPressAvatar,
    onAudioCall,
    onVideoCall
}: ChatScreenHeaderProps) {
    const insets = useSafeAreaInsets();
    const router = useRouter();

    if (Platform.OS === 'android') {
        return (
            <View style={[styles.androidHeader, { height: insets.top + 60, paddingTop: insets.top }]}>
                <View style={StyleSheet.absoluteFill}>
                    <BlurView
                        intensity={30}
                        tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                        style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(wallpaperGradient[0] || colors.background, 0.95) }]}
                    />
                </View>

                <View style={styles.androidLeft}>
                    <TouchableOpacity onPress={() => router.back()} style={styles.androidBack}>
                        <HeaderBackIcon color={colors.text} size={22} strokeWidth={1.2} />
                    </TouchableOpacity>

                    <TouchableOpacity onPress={onPressAvatar} style={styles.androidProfileGroup} activeOpacity={0.8}>
                        <View style={styles.androidAvatar}>
                            {avatarUri ? (
                                <Image source={{ uri: avatarUri }} style={styles.avatarImage} />
                            ) : (
                                <LinearGradient
                                    colors={bubbleTheme.meGradient}
                                    start={{ x: 0, y: 0 }}
                                    end={{ x: 1, y: 1 }}
                                    style={styles.avatarFallback}
                                >
                                    <Text style={styles.avatarLetter}>{title[0]?.toUpperCase() || 'U'}</Text>
                                </LinearGradient>
                            )}
                        </View>
                        <View style={styles.androidTextGroup}>
                            <Text style={[styles.androidTitle, { color: colors.text }]} numberOfLines={1}>{title}</Text>
                            <Text style={[styles.androidSubtitle, { color: isOnline ? '#53E08A' : withAlpha(colors.text, 0.68) }]} numberOfLines={1}>
                                {subtitle}
                            </Text>
                        </View>
                    </TouchableOpacity>
                </View>

                <View style={styles.androidRight}>
                    <TouchableOpacity style={styles.androidIconAction} onPress={onVideoCall} disabled={!onVideoCall}>
                        <HeaderVideoIcon color={colors.text} size={22} strokeWidth={1.3} />
                    </TouchableOpacity>
                    <TouchableOpacity style={styles.androidIconAction} onPress={onAudioCall} disabled={!onAudioCall}>
                        <HeaderPhoneIcon color={colors.text} size={22} strokeWidth={1.3} />
                    </TouchableOpacity>
                    {onPressSearch && (
                        <TouchableOpacity style={styles.androidIconAction} onPress={onPressSearch}>
                            <HeaderSearchIcon color={colors.text} size={22} strokeWidth={1.3} />
                        </TouchableOpacity>
                    )}
                </View>
            </View>
        );
    }

    return (
        <>
            <View style={[styles.headerMask, { height: insets.top + 80 }]}>
                <MaskedViewAny
                    style={StyleSheet.absoluteFill}
                    maskElement={<LinearGradient colors={['rgba(0,0,0,0.9)', 'rgba(0,0,0,0)']} locations={[0.56, 1]} style={StyleSheet.absoluteFill} />}
                >
                    <BlurView
                        intensity={20}
                        tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                        style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(wallpaperGradient[0] || '#000', 0.85) }]}
                    />
                </MaskedViewAny>
            </View>

            <View style={[styles.headerContentContainer, { height: insets.top + 60, paddingTop: insets.top }]} pointerEvents="box-none">
                <View style={{ position: 'absolute', left: 14, top: insets.top + 8 }}>
                    <SafeLiquidGlass style={{ borderRadius: 22, overflow: 'hidden' }} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                        <TouchableOpacity style={styles.headerCircleBtn} onPress={() => router.back()}>
                            <ChevronLeft color={colors.text} size={30} />
                        </TouchableOpacity>
                    </SafeLiquidGlass>
                </View>

                <SafeLiquidGlass style={{ maxWidth: '60%', minWidth: 170, height: 44, borderRadius: 22, overflow: 'hidden' }} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                    <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 12 }}>
                        <Text style={[styles.headerTitle, { color: colors.text }]} numberOfLines={1}>{title}</Text>
                        <Text style={[styles.headerStatus, { color: isOnline ? '#53E08A' : withAlpha(colors.text, 0.68) }]} numberOfLines={1}>
                            {subtitle}
                        </Text>
                    </View>
                </SafeLiquidGlass>

                <View style={[styles.rightActions, { top: insets.top + 8 }]}>
                    {onPressSearch && (
                        <SafeLiquidGlass style={{ height: 44, width: 44, borderRadius: 22, overflow: 'hidden' }} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                            <TouchableOpacity style={styles.headerCircleBtn} onPress={onPressSearch}>
                                <Search color={colors.text} size={20} strokeWidth={2.2} />
                            </TouchableOpacity>
                        </SafeLiquidGlass>
                    )}

                    <TouchableOpacity onPress={onPressAvatar} activeOpacity={0.8}>
                        <SafeLiquidGlass style={{ height: 44, width: 44, borderRadius: 22, overflow: 'hidden' }} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                            {avatarUri ? (
                                <Image source={{ uri: avatarUri }} style={styles.avatarImage} />
                            ) : (
                                <LinearGradient
                                    colors={bubbleTheme.meGradient}
                                    start={{ x: 0, y: 0 }}
                                    end={{ x: 1, y: 1 }}
                                    style={styles.avatarFallback}
                                >
                                    <Text style={styles.avatarLetter}>{title[0]?.toUpperCase() || 'U'}</Text>
                                </LinearGradient>
                            )}
                        </SafeLiquidGlass>
                    </TouchableOpacity>
                </View>
            </View>
        </>
    );
}

const styles = StyleSheet.create({
    headerMask: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        zIndex: 60,
        pointerEvents: 'none',
    },
    headerContentContainer: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        zIndex: 130,
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        paddingHorizontal: 14,
    },
    rightActions: {
        position: 'absolute',
        right: 14,
        top: 0,
        flexDirection: 'row',
        alignItems: 'center',
        gap: 8,
    },
    headerCircleBtn: {
        width: 44,
        height: 44,
        alignItems: 'center',
        justifyContent: 'center',
    },
    headerTitle: {
        fontSize: 16,
        fontWeight: '700',
    },
    headerStatus: {
        fontSize: 12,
        fontWeight: '500',
        marginTop: -1,
    },
    avatarFallback: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
    },
    avatarImage: {
        width: '100%',
        height: '100%',
    },
    avatarLetter: {
        color: '#fff',
        fontSize: 18,
        fontWeight: '600',
    },
    // Android specific styles
    androidHeader: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 8,
        zIndex: 130,
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
    },
    androidLeft: {
        flexDirection: 'row',
        alignItems: 'center',
        flex: 1,
    },
    androidBack: {
        width: 44,
        height: 44,
        alignItems: 'center',
        justifyContent: 'center',
        marginRight: 4,
    },
    androidProfileGroup: {
        flexDirection: 'row',
        alignItems: 'center',
        flex: 1,
    },
    androidAvatar: {
        width: 38,
        height: 38,
        borderRadius: 19,
        overflow: 'hidden',
        marginRight: 12,
    },
    androidTextGroup: {
        flex: 1,
        justifyContent: 'center',
        paddingRight: 8,
    },
    androidTitle: {
        fontSize: 18,
        fontWeight: '700',
        marginBottom: 2,
    },
    androidSubtitle: {
        fontSize: 13,
        fontWeight: '500',
    },
    androidRight: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 0,
        paddingRight: 4,
    },
    androidIconAction: {
        width: 40,
        height: 40,
        alignItems: 'center',
        justifyContent: 'center',
        borderRadius: 20,
    },
});
