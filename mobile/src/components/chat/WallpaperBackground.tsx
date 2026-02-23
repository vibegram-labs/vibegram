import React, { useMemo } from 'react';
import { View, StyleSheet, Image, Platform } from 'react-native';
import { useWallpaperStore, resolveThemeVariant } from '../../lib/stores/wallpaper-store';
import { useThemeStore } from '../../lib/stores/theme-store';
import TelegramDoodleWallpaper from './wallpapers/TelegramDoodleWallpaper';
import { isDarkColor } from '../../lib/utils/color';
import MusicWallpaper from './wallpapers/MusicWallpaper';
import FoodWallpaper from './wallpapers/FoodWallpaper';
import TravelWallpaper from './wallpapers/TravelWallpaper';
import WeatherWallpaper from './wallpapers/WeatherWallpaper';
import TechWallpaper from './wallpapers/TechWallpaper';
import PatternWallpaper from './wallpapers/PatternWallpaper';
import MaskedView from '@react-native-masked-view/masked-view';
import { LinearGradient } from 'expo-linear-gradient';
import { Asset } from 'expo-asset';
const MaskedViewAny = MaskedView as any;

// Pre-resolve image assets at module load (not per render)
const WALLPAPER_ASSETS = {
    'doodles': require('../../../assets/Wallpapers/doodle_transparent.png'),
    'music': require('../../../assets/Wallpapers/music_transparent.png'),
    'music2': require('../../../assets/Wallpapers/music2_transparent.png'),
    'food': require('../../../assets/Wallpapers/food_transparent.png'),
    'animals': require('../../../assets/Wallpapers/animals_transparent.png'),
    'hearts': require('../../../assets/Wallpapers/doodle_transparent.png'), // Fallback
} as const;

// Prefetch all wallpaper images at module load to eliminate flash/delay
let _assetsReady = false;
const _assetPromise = Asset.loadAsync(Object.values(WALLPAPER_ASSETS)).then(() => {
    _assetsReady = true;
}).catch(() => {
    _assetsReady = true; // Continue even if prefetch fails
});

const WallpaperComponents = {
    doodles: TelegramDoodleWallpaper,
    music: MusicWallpaper,
    hearts: (props: any) => <View />, // Placeholder, processed via keyed logic below
    food: (props: any) => <View />,   // Placeholder
    travel: TravelWallpaper,
    weather: WeatherWallpaper,
    tech: TechWallpaper,
    geometric: (props: any) => <PatternWallpaper {...props} patternType="geometric" />,
    nature: (props: any) => <PatternWallpaper {...props} patternType="nature" />,
    space: (props: any) => <PatternWallpaper {...props} patternType="space" />,
    abstract: (props: any) => <PatternWallpaper {...props} patternType="abstract" />,
} as const;

interface Props {
    theme?: any;
    // Override for previews
    previewThemeId?: string;
    width?: number;
    height?: number;
}

function WallpaperBackground({
    theme,
    previewThemeId,
    width: propWidth,
    height: propHeight
}: Props) {
    const { activeTheme, activeThemeId } = useWallpaperStore();
    const { effectiveTheme, colors } = useThemeStore();
    const isDark = effectiveTheme === 'dark';

    // Resolve the theme to the correct light/dark variant
    const themeToRender = useMemo(() => {
        if (theme) return theme;
        return resolveThemeVariant(activeTheme, isDark);
    }, [activeTheme, isDark, theme]);

    // Custom Image Override check
    if (themeToRender.type === 'image') {
        const imageKey = themeToRender.maskedImage || 'music';
        const WallpaperAsset = WALLPAPER_ASSETS[imageKey as keyof typeof WALLPAPER_ASSETS];

        return (
            <View style={styles.container} pointerEvents="none">
                <Image
                    source={WallpaperAsset}
                    style={StyleSheet.absoluteFill}
                    resizeMode="cover"
                />
                {/* Optional subtle overlay for readability */}
                <LinearGradient
                    colors={['rgba(0,0,0,0.5)', 'transparent', 'rgba(0,0,0,0.5)']}
                    style={StyleSheet.absoluteFill}
                    locations={[0, 0.5, 1]}
                />
            </View>
        );
    }

    if (themeToRender.type === 'none') {
        return (
            <View style={[styles.container, { backgroundColor: themeToRender.backgroundGradient[0] }]} pointerEvents="none" />
        );
    }

    // Masked Image Pattern (Vibrant Gradient Paths)
    if (themeToRender.type === 'masked-image') {
        // Default to 'doodles' logic which now uses our high-res transparent PNG
        const imageKey = themeToRender.maskedImage || 'doodles';
        // Safe lookup with fallback
        const WallpaperAsset = WALLPAPER_ASSETS[imageKey as keyof typeof WALLPAPER_ASSETS] || WALLPAPER_ASSETS['doodles'];
        // Get Gradient Colors - these fill the shapes
        const GRADIENT_COLORS = themeToRender.patternGradientColors || ['#3B82F6', '#8B5CF6', '#D946EF', '#F43F5E'];
        const GRADIENT_LOCATIONS = themeToRender.patternGradientLocations || [0, 0.33, 0.66, 1];

        // Background Gradient
        const BG_COLORS = themeToRender.backgroundGradient || ['#000000', '#000000'];

        return (
            <View style={[styles.container, { backgroundColor: BG_COLORS[0] }]} pointerEvents="none">
                {/* 1. Base Layer: Main Background Gradient */}
                <LinearGradient
                    colors={BG_COLORS}
                    style={StyleSheet.absoluteFill}
                    start={{ x: 0, y: 0 }}
                    end={{ x: 1, y: 1 }}
                />

                {/* 2. Masked Gradient Layer (Android uses software mask mode for back-navigation stability) */}
                <MaskedViewAny
                    key={`mask-${themeToRender.id}-${imageKey}-${isDark ? 'dark' : 'light'}`}
                    style={StyleSheet.absoluteFill}
                    androidRenderingMode={Platform.OS === 'android' ? 'software' : undefined}
                    maskElement={
                        <View
                            collapsable={false}
                            renderToHardwareTextureAndroid={true}
                            style={{
                                flex: 1,
                                width: '100%',
                                height: '100%',
                                backgroundColor: 'transparent',
                                alignItems: 'center',
                                justifyContent: 'center',
                            }}
                        >
                            <Image
                                source={WallpaperAsset}
                                collapsable={false}
                                style={{
                                    width: propWidth || '100%',
                                    height: propHeight || '100%',
                                }}
                                resizeMode="cover"
                                fadeDuration={0}
                            />
                        </View>
                    }
                >
                    <View
                        collapsable={false}
                        renderToHardwareTextureAndroid={true}
                        style={StyleSheet.absoluteFill}
                    >
                        <LinearGradient
                            colors={GRADIENT_COLORS}
                            locations={GRADIENT_LOCATIONS}
                            start={{ x: 0, y: 0 }}
                            end={{ x: 1, y: 1 }}
                            style={[StyleSheet.absoluteFill, { opacity: themeToRender.patternOpacity || 0.08 }]}
                        />
                    </View>
                </MaskedViewAny>
            </View>
        );
    }

    // Pattern
    const activePattern = themeToRender.id === 'custom' ? themeToRender.patternType : themeToRender.patternType || 'doodles';
    const CurrentWallpaper = WallpaperComponents[activePattern as keyof typeof WallpaperComponents] || TelegramDoodleWallpaper;

    return (
        <View style={styles.container} pointerEvents="none">
            <CurrentWallpaper
                theme={themeToRender}
                width={propWidth}
                height={propHeight}
            />
        </View>
    );
}

export default React.memo(WallpaperBackground);

const styles = StyleSheet.create({
    container: {
        ...StyleSheet.absoluteFillObject,
        zIndex: 0,
    },
    image: {
        ...StyleSheet.absoluteFillObject,
    }
});
