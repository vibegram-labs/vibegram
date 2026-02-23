import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
    Dimensions,
    Image,
    Pressable,
    StyleSheet,
    Text,
    View,
    TextInput,
    ActivityIndicator,
    FlatList,
    Platform,
    Keyboard,
} from 'react-native';
import * as ImagePicker from 'expo-image-picker';
import * as DocumentPicker from 'expo-document-picker';
import * as Location from 'expo-location';
import * as MediaLibrary from 'expo-media-library';
import { CameraView, useCameraPermissions } from 'expo-camera';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withSpring,
    interpolate,
} from 'react-native-reanimated';
import { LinearGradient } from 'expo-linear-gradient';
import {
    Camera,
    Image as ImageIcon,
    File as FileIcon,
    MapPin,
    User,
    Plus,
    Send,
    X,
} from 'lucide-react-native';
import NativeTabBar from '../native/NativeTabBar';

import GlassMorphMenu from '../settings/GlassMorphMenu';
import { useThemeStore } from '../../lib/stores/theme-store';
import { useContactStore, Contact } from '../../lib/stores/contact-store';

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

export interface SelectedMediaItem {
    uri: string;
    width?: number;
    height?: number;
    assetId: string;
    viewOnce?: boolean;
    caption?: string;
    type: 'image' | 'video';
    duration?: number;
}

interface AttachmentMenuProps {
    visible?: boolean;
    onClose?: () => void;
    onSelectImage: (uri: string, width?: number, height?: number) => void;
    onSelectFile: (uri: string, name: string) => void;
    onSelectLocation: (coords: { latitude: number; longitude: number }) => void;
    onSelectContact: (contact: Contact) => void;
    onSelectImages?: (items: SelectedMediaItem[]) => void;
    onOpenPreview?: (items: SelectedMediaItem[]) => void;
    buttonSize?: number;
    renderTrigger?: boolean;
}

const createAssetId = () => `${Date.now()}-${Math.floor(Math.random() * 1_000_000)}`;

const MENU_HEIGHT = Math.round(SCREEN_HEIGHT * 0.65);
const TAB_BAR_HEIGHT = 64;
const MENU_SIDE_INSET = 10;
const ATTACHMENT_TABS = ['gallery', 'file', 'location', 'contact'] as const;
const URL_SCHEME_RE = /^(https?:\/\/|file:\/\/|content:\/\/|data:|ph:\/\/|assets-library:\/\/)/i;
const RENDERABLE_IMAGE_URI_RE = /^(https?:\/\/|file:\/\/|content:\/\/|data:|assets-library:\/\/)/i;

const isSupportedUri = (value?: string | null) => {
    if (!value || typeof value !== 'string') return false;
    return URL_SCHEME_RE.test(value.trim());
};

const isRenderableImageUri = (value?: string | null) => {
    if (!value || typeof value !== 'string') return false;
    return RENDERABLE_IMAGE_URI_RE.test(value.trim());
};

const sanitizeContactForShare = (contact: Contact): Contact => ({
    ...contact,
    profileImage: isSupportedUri(contact.profileImage) ? contact.profileImage?.trim() : undefined,
});

export const AttachmentMenu = ({
    visible,
    onClose,
    onSelectImage,
    onSelectFile,
    onSelectLocation,
    onSelectContact,
    onSelectImages,
    onOpenPreview,
    buttonSize = 42,
    renderTrigger,
}: AttachmentMenuProps) => {
    const { colors, effectiveTheme } = useThemeStore();
    const contacts = useContactStore((s) => s.contacts);
    const isDark = effectiveTheme === 'dark';

    const isControlled = typeof visible === 'boolean';
    const shouldRenderTrigger = renderTrigger ?? !isControlled;

    const hostRef = useRef<View>(null);
    const openTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
    const [menuOpen, setMenuOpen] = useState(false);
    const [openOffsetX, setOpenOffsetX] = useState(0);
    const [menuWidth, setMenuWidth] = useState(Math.max(260, SCREEN_WIDTH - (MENU_SIDE_INSET * 2)));
    const open = isControlled ? !!visible : menuOpen;
    const [cameraPermission, requestCameraPermission] = useCameraPermissions();

    // --- State ---
    const [heavyLoadReady, setHeavyLoadReady] = useState(false);
    const [activeTab, setActiveTab] = useState<'gallery' | 'file' | 'location' | 'contact'>('gallery');
    const [galleryAssets, setGalleryAssets] = useState<MediaLibrary.Asset[]>([]);
    const [selectedMap, setSelectedMap] = useState<Map<string, MediaLibrary.Asset>>(new Map());
    const [caption, setCaption] = useState('');
    const [hasNextPage, setHasNextPage] = useState(true);
    const [endCursor, setEndCursor] = useState<string | undefined>(undefined);
    const [loadingMore, setLoadingMore] = useState(false);
    const [assetResolvedUris, setAssetResolvedUris] = useState<Record<string, string>>({});

    // Animation values
    const inputMode = useSharedValue(0); // 0 = tabs, 1 = input

    const syncOpenOffsetX = useCallback(() => {
        hostRef.current?.measureInWindow((x) => {
            if (!Number.isFinite(x)) return;
            const windowWidth = Dimensions.get('window').width;
            const nextOffset = MENU_SIDE_INSET - x;
            const nextWidth = Math.max(260, windowWidth - (MENU_SIDE_INSET * 2));
            setMenuWidth((prev) => (Math.abs(prev - nextWidth) < 0.5 ? prev : nextWidth));
            setOpenOffsetX((prev) => (Math.abs(prev - nextOffset) < 0.5 ? prev : nextOffset));
        });
    }, []);

    const resolveAssetUris = useCallback(async (assets: MediaLibrary.Asset[]) => {
        const phAssets = assets.filter((asset) => typeof asset.uri === 'string' && asset.uri.startsWith('ph://'));
        if (phAssets.length === 0) return;

        const resolvedEntries = await Promise.all(phAssets.map(async (asset) => {
            try {
                const info = await MediaLibrary.getAssetInfoAsync(asset.id);
                const localUri = info?.localUri || info?.uri || '';
                if (isRenderableImageUri(localUri)) {
                    return [asset.id, localUri] as const;
                }
            } catch {
                // Ignore per-asset resolution errors.
            }
            return null;
        }));

        setAssetResolvedUris((prev) => {
            let changed = false;
            const next = { ...prev };
            resolvedEntries.forEach((entry) => {
                if (!entry) return;
                const [assetId, uri] = entry;
                if (next[assetId] === uri) return;
                next[assetId] = uri;
                changed = true;
            });
            return changed ? next : prev;
        });
    }, []);

    useEffect(() => () => {
        if (!openTimerRef.current) return;
        clearTimeout(openTimerRef.current);
        openTimerRef.current = null;
    }, []);

    // Reset when menu closes
    useEffect(() => {
        if (!open) {
            const t = setTimeout(() => {
                setHeavyLoadReady(false);
                setSelectedMap(new Map());
                setCaption('');
                setActiveTab('gallery');
                setAssetResolvedUris({});
                inputMode.value = 0;
            }, 300);
            return () => clearTimeout(t);
        } else {
            // Delay heavy load until animation completes
            const t = setTimeout(() => {
                setHeavyLoadReady(true);
                loadRecent(true);
            }, 350);
            return () => clearTimeout(t);
        }
    }, [open]);

    // Update input mode based on selection
    useEffect(() => {
        const hasSelection = selectedMap.size > 0;
        inputMode.value = withSpring(hasSelection ? 1 : 0, {
            damping: 20,
            stiffness: 120,
            mass: 0.8,
        });
    }, [selectedMap.size]);

    const requestClose = useCallback(() => {
        if (isControlled) {
            onClose?.();
        } else {
            setMenuOpen(false);
            onClose?.();
        }
    }, [isControlled, onClose]);

    const loadRecent = useCallback(async (reset = false) => {
        try {
            const perm = await MediaLibrary.getPermissionsAsync();
            if (!perm.granted) {
                const req = await MediaLibrary.requestPermissionsAsync();
                if (!req.granted) return;
            }

            const pageParams: any = {
                first: 40,
                mediaType: ['photo', 'video'],
                sortBy: [MediaLibrary.SortBy.creationTime],
            };
            if (!reset && endCursor) pageParams.after = endCursor;

            const { assets, hasNextPage: next, endCursor: cursor } = await MediaLibrary.getAssetsAsync(pageParams);
            const safeAssets = assets.filter((asset) => isSupportedUri(asset.uri));
            void resolveAssetUris(safeAssets);

            if (reset) {
                setGalleryAssets(safeAssets);
            } else {
                setGalleryAssets((prev) => [...prev, ...safeAssets]);
            }
            setHasNextPage(next);
            setEndCursor(cursor);
        } catch (err) {
            console.warn('[AttachmentMenu] load failed:', err);
        }
    }, [endCursor, resolveAssetUris]);

    const handleLoadMore = () => {
        if (!hasNextPage || loadingMore) return;
        setLoadingMore(true);
        loadRecent(false).finally(() => setLoadingMore(false));
    };

    const toggleSelection = (asset: MediaLibrary.Asset) => {
        const next = new Map(selectedMap);
        if (next.has(asset.id)) {
            next.delete(asset.id);
        } else {
            next.set(asset.id, asset);
        }
        setSelectedMap(next);
    };

    const handleSend = () => {
        const items: SelectedMediaItem[] = Array.from(selectedMap.values())
            .map((asset) => {
                const resolved = assetResolvedUris[asset.id];
                return {
                    ...asset,
                    uri: resolved || asset.uri,
                };
            })
            .filter((asset) => isSupportedUri(asset.uri))
            .map(asset => ({
                uri: asset.uri,
                width: asset.width,
                height: asset.height,
                assetId: asset.id,
                duration: asset.duration,
                type: asset.mediaType === 'video' ? 'video' : 'image',
                caption: caption.trim() || undefined,
            }));

        if (items.length === 0) return;

        // If generic callback
        if (onSelectImages) {
            onSelectImages(items);
        } else if (items.length === 1 && onSelectImage) {
            // Fallback for single legacy
            onSelectImage(items[0].uri, items[0].width, items[0].height);
        }

        requestClose();
    };

    // --- Pickers ---
    const handleCameraPress = useCallback(async () => {
        if (!cameraPermission?.granted) {
            const result = await requestCameraPermission();
            if (!result.granted) return;
        }
        await pickCamera();
    }, [cameraPermission?.granted, requestCameraPermission]);

    const pickCamera = async () => {
        requestClose();
        setTimeout(async () => {
            const res = await ImagePicker.launchCameraAsync({
                mediaTypes: ['images', 'videos'],
                quality: 1,
            });
            if (!res.canceled && res.assets[0]) {
                const a = res.assets[0];
                if (onSelectImages) {
                    onSelectImages([{
                        uri: a.uri,
                        width: a.width,
                        height: a.height,
                        assetId: createAssetId(),
                        type: a.type === 'video' ? 'video' : 'image',
                    }]);
                } else {
                    onSelectImage(a.uri, a.width, a.height);
                }
            }
        }, 200);
    };

    const pickFile = async () => {
        const res = await DocumentPicker.getDocumentAsync({ type: '*/*', copyToCacheDirectory: true });
        if (!res.canceled && res.assets[0]) {
            onSelectFile(res.assets[0].uri, res.assets[0].name);
            requestClose();
        }
    };

    const pickLocation = async () => {
        const perm = await Location.requestForegroundPermissionsAsync();
        if (perm.status !== 'granted') return;
        const loc = await Location.getCurrentPositionAsync({});
        onSelectLocation(loc.coords);
        requestClose();
    };

    const pickContact = async () => {
        if (!contacts.length) return;
        onSelectContact(sanitizeContactForShare(contacts[0]));
        requestClose();
    };

    // --- Renderers ---
    const renderMediaGridItem = ({ item }: { item: MediaLibrary.Asset }) => {
        const isSelected = selectedMap.has(item.id);
        const index = Array.from(selectedMap.keys()).indexOf(item.id);
        const resolvedUri = assetResolvedUris[item.id];
        const imageUri = isRenderableImageUri(resolvedUri)
            ? resolvedUri
            : (isRenderableImageUri(item.uri) ? item.uri : null);

        return (
            <Pressable
                style={styles.mediaGridItem}
                onPress={() => toggleSelection(item)}
            >
                {imageUri ? (
                    <Image source={{ uri: imageUri }} style={[styles.mediaGridImage, isSelected && styles.gridImageSelected]} />
                ) : (
                    <View style={styles.mediaGridImageFallback} />
                )}
                {item.mediaType === 'video' && (
                    <View style={styles.durationBadge}>
                        <Text style={styles.durationText}>
                            {Math.floor(item.duration / 60)}:{(item.duration % 60).toString().padStart(2, '0')}
                        </Text>
                    </View>
                )}
                <View style={[styles.selectionCircle, isSelected && styles.selectionCircleActive]}>
                    {isSelected && (
                        <View style={styles.selectionDot}>
                            <Text style={styles.selectionNum}>{index + 1}</Text>
                        </View>
                    )}
                </View>
            </Pressable>
        );
    };

    useEffect(() => {
        if (!open) return;
        if (cameraPermission?.granted) return;
        if (cameraPermission && !cameraPermission.canAskAgain) return;
        void requestCameraPermission();
    }, [open, cameraPermission?.granted, cameraPermission?.canAskAgain, requestCameraPermission]);

    // Animated Styles for Bottom Bar
    const tabContainerStyle = useAnimatedStyle(() => {
        // Tabs translate down and fade out when input mode activates
        const translateY = interpolate(inputMode.value, [0, 1], [0, TAB_BAR_HEIGHT]);
        const opacity = interpolate(inputMode.value, [0, 0.4], [1, 0]);
        const scale = interpolate(inputMode.value, [0, 1], [1, 0.9]);
        return {
            transform: [{ translateY }, { scale }],
            opacity,
        };
    });

    const inputContainerStyle = useAnimatedStyle(() => {
        // Input translates up (from bottom) and fades in
        const translateY = interpolate(inputMode.value, [0, 1], [TAB_BAR_HEIGHT + 20, 0]);
        const opacity = interpolate(inputMode.value, [0.4, 1], [0, 1]);
        const scale = interpolate(inputMode.value, [0, 1], [0.9, 1]);
        return {
            transform: [{ translateY }, { scale }],
            opacity,
        };
    });

    const renderBottomDock = () => {
        const selectionCount = selectedMap.size;
        const currentTabIndex = Math.max(0, ATTACHMENT_TABS.indexOf(activeTab));

        const handleTabChange = (index: number) => {
            const nextTab = ATTACHMENT_TABS[index] || 'gallery';
            setActiveTab(nextTab);
            if (nextTab === 'file') {
                void pickFile();
                return;
            }
            if (nextTab === 'location') {
                void pickLocation();
                return;
            }
            if (nextTab === 'contact') {
                void pickContact();
            }
        };

        return (
            <View style={styles.bottomDockHost}>
                <Animated.View style={[styles.tabBarLayer, tabContainerStyle]} pointerEvents={selectionCount > 0 ? 'none' : 'auto'}>
                    <NativeTabBar
                        currentIndex={currentTabIndex}
                        onIndexChange={handleTabChange}
                        tabs={[
                            { key: 'gallery', title: 'Gallery', renderIcon: ({ color, size }) => <ImageIcon size={size} color={color} /> },
                            { key: 'file', title: 'File', renderIcon: ({ color, size }) => <FileIcon size={size} color={color} /> },
                            { key: 'location', title: 'Location', renderIcon: ({ color, size }) => <MapPin size={size} color={color} /> },
                            { key: 'contact', title: 'Contact', renderIcon: ({ color, size }) => <User size={size} color={color} /> },
                        ]}
                        activeTintColor={colors.primary}
                        inactiveTintColor={colors.textSecondary}
                        isDark={isDark}
                        labeled
                    />
                </Animated.View>

                <Animated.View style={[styles.inputLayer, inputContainerStyle]} pointerEvents={selectionCount > 0 ? 'auto' : 'none'}>
                    <View style={[styles.inputField, { borderColor: isDark ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.08)' }]}>
                        <TextInput
                            style={[styles.input, { color: colors.text }]}
                            placeholder={`Caption for ${selectionCount} item${selectionCount > 1 ? 's' : ''}...`}
                            placeholderTextColor={colors.textSecondary}
                            value={caption}
                            onChangeText={setCaption}
                            returnKeyType="send"
                            onSubmitEditing={handleSend}
                        />
                        {caption.length > 0 && (
                            <Pressable onPress={() => setCaption('')} style={styles.clearBtn}>
                                <X size={14} color={colors.textSecondary} />
                            </Pressable>
                        )}
                    </View>
                    <Pressable
                        style={[styles.sendBtn, { backgroundColor: colors.primary }]}
                        onPress={handleSend}
                    >
                        <Send size={20} color="#fff" fill="currentColor" />
                    </Pressable>
                </Animated.View>
            </View>
        );
    };

    const expandedContent = useMemo(() => {
        if (!heavyLoadReady) {
            return (
                <View style={styles.loadingContainer}>
                    <ActivityIndicator size="small" color={colors.primary} />
                </View>
            );
        }

        return (
            <View style={styles.contentParams}>
                <View style={styles.mainArea}>
                    <View style={styles.mediaRow}>
                        <Pressable style={styles.cameraPreviewCard} onPress={handleCameraPress}>
                            {cameraPermission?.granted ? (
                                <CameraView style={StyleSheet.absoluteFill} facing="back" />
                            ) : (
                                <LinearGradient
                                    colors={isDark ? ['rgba(36,44,58,0.95)', 'rgba(22,28,38,0.95)'] : ['rgba(225,235,255,0.95)', 'rgba(206,222,250,0.95)']}
                                    start={{ x: 0, y: 0 }}
                                    end={{ x: 1, y: 1 }}
                                    style={styles.cameraPreviewFill}
                                >
                                    <Camera size={24} color={isDark ? '#dce7ff' : '#274472'} />
                                </LinearGradient>
                            )}
                            <View style={styles.cameraPreviewOverlay} />
                        </Pressable>

                        <View style={styles.mediaGridPane}>
                            <FlatList
                                data={galleryAssets}
                                keyExtractor={(item) => item.id}
                                numColumns={1}
                                renderItem={({ item }) => renderMediaGridItem({ item })}
                                contentContainerStyle={styles.mediaGridContent}
                                onEndReached={handleLoadMore}
                                onEndReachedThreshold={0.35}
                                showsVerticalScrollIndicator={false}
                            />
                        </View>
                    </View>
                </View>

                {/* Custom Bottom Dock */}
                {renderBottomDock()}
            </View>
        );
    }, [heavyLoadReady, galleryAssets, selectedMap, caption, activeTab, colors, isDark, inputMode, assetResolvedUris, cameraPermission?.granted, handleCameraPress]);

    return (
        <View
            ref={hostRef}
            onLayout={syncOpenOffsetX}
            style={[styles.host, shouldRenderTrigger ? { width: buttonSize, height: buttonSize } : styles.hiddenHost]}
        >
            <GlassMorphMenu
                onSelect={() => { }}
                items={[]}
                itemColumns={1}
                anchor="bottom-left"
                menuWidth={menuWidth}
                menuHeight={MENU_HEIGHT}
                openOffsetY={8}
                openOffsetX={openOffsetX}
                collapsedSize={buttonSize}
                open={open}
                onOpenChange={(next) => {
                    if (next) {
                        Keyboard.dismiss();
                        syncOpenOffsetX();
                    }

                    if (isControlled) {
                        if (!next) onClose?.();
                        return;
                    }

                    if (openTimerRef.current) {
                        clearTimeout(openTimerRef.current);
                        openTimerRef.current = null;
                    }

                    if (next) {
                        openTimerRef.current = setTimeout(() => {
                            setMenuOpen(true);
                            openTimerRef.current = null;
                        }, Platform.OS === 'ios' ? 100 : 60);
                        return;
                    }

                    setMenuOpen(false);
                    if (!next) onClose?.();
                }}
                renderTrigger={shouldRenderTrigger}
                expandedContent={expandedContent}
                customIcon={(
                    <View
                        style={[
                            styles.plusHost,
                            {
                                width: buttonSize,
                                height: buttonSize,
                                borderRadius: buttonSize / 2,
                                backgroundColor: isDark
                                    ? 'rgba(28,30,38,0.66)'
                                    : 'rgba(255,255,255,0.74)',
                                borderColor: isDark
                                    ? 'rgba(255,255,255,0.10)'
                                    : 'rgba(255,255,255,0.42)',
                            },
                        ]}
                    >
                        <Animated.View style={open ? { transform: [{ rotate: '45deg' }] } : undefined}>
                            <Plus size={Math.round(buttonSize * 0.52)} color={colors.text} strokeWidth={2.3} />
                        </Animated.View>
                    </View>
                )}
            />
        </View>
    );
};

const styles = StyleSheet.create({
    host: {
        position: 'relative',
        overflow: 'visible',
        zIndex: 40,
        marginBottom: -1,
    },
    hiddenHost: {
        width: 0,
        height: 0,
        marginBottom: 0,
    },
    plusHost: {
        alignItems: 'center',
        justifyContent: 'center',
        borderWidth: StyleSheet.hairlineWidth,
    },
    loadingContainer: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
        minHeight: 200,
    },
    contentParams: {
        flex: 1,
        width: '100%',
        height: '100%',
        position: 'relative',
        overflow: 'hidden',
        borderRadius: 24,
    },
    mainArea: {
        flex: 1,
        paddingBottom: TAB_BAR_HEIGHT + 8,
    },
    mediaRow: {
        flexDirection: 'row',
        flex: 1,
        gap: 8,
        paddingHorizontal: 8,
        paddingTop: 8,
        paddingBottom: 8,
    },
    mediaGridPane: {
        flex: 1,
        borderRadius: 12,
        overflow: 'hidden',
    },
    mediaGridContent: {
        paddingRight: 2,
        paddingBottom: 2,
    },
    mediaGridItem: {
        width: '100%',
        height: 176,
        borderRadius: 12,
        overflow: 'hidden',
        position: 'relative',
        marginBottom: 6,
    },
    mediaGridImage: {
        width: '100%',
        height: '100%',
    },
    mediaGridImageFallback: {
        width: '100%',
        height: '100%',
        backgroundColor: 'rgba(127,127,127,0.24)',
    },
    gridImageSelected: {
        opacity: 0.7,
    },
    cameraPreviewCard: {
        height: '100%',
        aspectRatio: 9 / 16,
        borderRadius: 14,
        overflow: 'hidden',
    },
    cameraPreviewFill: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
    },
    cameraPreviewOverlay: {
        ...StyleSheet.absoluteFillObject,
        backgroundColor: 'rgba(0,0,0,0.12)',
    },
    selectionCircle: {
        position: 'absolute',
        top: 6,
        right: 6,
        width: 22,
        height: 22,
        borderRadius: 11,
        borderWidth: 1.5,
        borderColor: 'rgba(255,255,255,0.8)',
        backgroundColor: 'rgba(0,0,0,0.2)',
        alignItems: 'center',
        justifyContent: 'center',
    },
    selectionCircleActive: {
        backgroundColor: '#3b82f6', // primary blue
        borderColor: 'white',
    },
    selectionDot: {
        width: 14,
        height: 14,
        alignItems: 'center',
        justifyContent: 'center',
    },
    selectionNum: {
        fontSize: 10,
        fontWeight: 'bold',
        color: '#fff',
    },
    durationBadge: {
        position: 'absolute',
        bottom: 5,
        left: 5,
        backgroundColor: 'rgba(0,0,0,0.6)',
        borderRadius: 4,
        paddingHorizontal: 4,
        paddingVertical: 2,
    },
    durationText: {
        color: '#fff',
        fontSize: 10,
        fontWeight: '600',
    },
    bottomDockHost: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        height: TAB_BAR_HEIGHT,
        justifyContent: 'center',
    },
    tabBarLayer: {
        ...StyleSheet.absoluteFillObject,
        alignItems: 'center',
        justifyContent: 'center',
    },
    inputLayer: {
        ...StyleSheet.absoluteFillObject,
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 10,
        gap: 10,
    },
    inputField: {
        flex: 1,
        height: 42,
        borderRadius: 21,
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 12,
        borderWidth: StyleSheet.hairlineWidth,
        backgroundColor: 'transparent',
    },
    input: {
        flex: 1,
        fontSize: 15,
        height: '100%',
    },
    clearBtn: {
        padding: 4,
    },
    sendBtn: {
        width: 42,
        height: 42,
        borderRadius: 21,
        alignItems: 'center',
        justifyContent: 'center',
    },
});
