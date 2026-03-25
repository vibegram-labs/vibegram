import React, { useState, useRef, useEffect } from 'react'
import {
    View,
    Text,
    StyleSheet,
    TouchableOpacity,
    Image,
    Pressable,
    Dimensions,
    Platform,
    StatusBar,
    Alert,
    ActivityIndicator
} from 'react-native'
import { CameraView, CameraType, FlashMode, useCameraPermissions } from 'expo-camera'
import * as ImagePicker from 'expo-image-picker'
import * as MediaLibrary from 'expo-media-library'
import { useLocalSearchParams, useRouter } from 'expo-router'
import * as FileSystem from 'expo-file-system/legacy'
import { Audio } from 'expo-av'
import {
    X,
    Zap,
    ZapOff,
    Repeat2,
    Folder,
} from 'lucide-react-native'
import { Gesture, GestureDetector } from 'react-native-gesture-handler'
import { apiClient } from '../src/lib/api-client'
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withSpring,
    withTiming,
    withSequence,
    FadeIn,
    FadeOut,
    interpolate,
    runOnJS
} from 'react-native-reanimated'
import * as Haptics from 'expo-haptics'

import { theme } from '../src/lib/theme'
import SafeLiquidGlass from '../src/components/native/SafeLiquidGlass'
import NativeStoryCamera, { isNativeStoryCameraAvailable, type NativeStoryCameraEventPayload } from '../src/components/native/NativeStoryCamera'
import NativeStoryComposer, {
    isNativeStoryComposerAvailable,
    type NativeStoryComposerEventPayload,
} from '../src/components/native/NativeStoryComposer'
import { useStoryStore } from '../src/lib/stores/story-store'
import { useAuthStore } from '../src/lib/stores/auth-store'
import { RefreshIcon, ImageIcon } from '../src/components/Icons'
import { StoryPreview } from '../src/components/story/StoryPreview'
import { BlurView } from 'expo-blur'

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window')

// Always use dark theme for camera
const colors = theme.dark;

const withAlpha = (color: string, opacity: number) => {
    if (!color) return `rgba(0,0,0,${opacity})`;
    if (color.startsWith('#')) {
        const r = parseInt(color.slice(1, 3), 16);
        const g = parseInt(color.slice(3, 5), 16);
        const b = parseInt(color.slice(5, 7), 16);
        return `rgba(${r}, ${g}, ${b}, ${opacity})`;
    }
    return color;
};

type StoryCameraProps = {
    onRequestClose?: () => void;
    deferCameraMountMs?: number;
};

// ...

export function StoryCamera({ onRequestClose, deferCameraMountMs = 0 }: StoryCameraProps) {
    const router = useRouter()
    const params = useLocalSearchParams() // Get params
    const requestClose = onRequestClose ?? (() => router.back())
    const { createStory, saveDraft } = useStoryStore()
    const { user } = useAuthStore()
    const useNativeStoryCamera = Platform.OS === 'ios' && isNativeStoryCameraAvailable()
    const useNativeStoryComposer = Platform.OS === 'ios' && isNativeStoryComposerAvailable()

    // Permissions
    const [permission, requestPermission] = useCameraPermissions()
    const [audioPermission, requestAudioPermission] = Audio.usePermissions()
    const [mediaLibraryPermission, requestMediaLibraryPermission] = MediaLibrary.usePermissions()

    // Camera State
    const cameraRef = useRef<CameraView>(null)
    const [facing, setFacing] = useState<CameraType>('back')
    const [flash, setFlash] = useState<FlashMode>('off')
    const [mode, setMode] = useState<'picture' | 'video'>('picture')
    const [isRecording, setIsRecording] = useState(false)
    const [capturedMedia, setCapturedMedia] = useState<{ uri: string, type: 'image' | 'video', mirrored: boolean } | null>(null)
    const [originalMedia, setOriginalMedia] = useState<{ uri: string, type: 'image' | 'video', mirrored: boolean } | null>(null)
    const [latestImage, setLatestImage] = useState<string | null>(null)
    const [isEditing, setIsEditing] = useState(false)
    const [editError, setEditError] = useState<string | null>(null)
    const [editRateLimitSeconds, setEditRateLimitSeconds] = useState<number | null>(null)
    const [shouldMountCamera, setShouldMountCamera] = useState(deferCameraMountMs <= 0)
    const [isCameraReady, setIsCameraReady] = useState(false)

    // Animation values
    const captureBtnScale = useSharedValue(1)
    const recordProgress = useSharedValue(0)

    // Effect to check for draft params
    useEffect(() => {
        if (params?.draftUri) {
            const uri = params.draftUri as string
            const type = params.draftType as 'image' | 'video' || 'image'
            setCapturedMedia({ uri, type, mirrored: false })
            setOriginalMedia({ uri, type, mirrored: false })
        }
    }, [params])

    // Gesture Handler for horizontal swipe (mode switch)
    const panGesture = Gesture.Pan()
        .activeOffsetX([-10, 10])
        .onEnd((e) => {
            if (e.translationX > 50) {
                runOnJS(setMode)('picture')
                runOnJS(Haptics.selectionAsync)()
            } else if (e.translationX < -50) {
                runOnJS(setMode)('video')
                runOnJS(Haptics.selectionAsync)()
            }
        })

    // Vertical swipe to close
    const verticalSwipe = Gesture.Pan()
        .activeOffsetY(50)
        .onEnd((e) => {
            if (e.translationY > 50) {
                runOnJS(requestClose)()
                runOnJS(Haptics.selectionAsync)()
            }
        })

    // Tap to focus gesture
    const [focusPoint, setFocusPoint] = useState<{ x: number, y: number } | null>(null)
    const [showFocus, setShowFocus] = useState(false)
    const focusScale = useSharedValue(1.3)
    const focusOpacity = useSharedValue(0)

    const focusAnimatedStyle = useAnimatedStyle(() => ({
        transform: [{ scale: focusScale.value }],
        opacity: focusOpacity.value
    }))

    // Card offset for focus position calculation
    const cardMarginTop = Platform.OS === 'ios' ? 55 : 35
    const cardMarginHorizontal = 10

    const handleFocusTap = (x: number, y: number) => {
        // Adjust tap position to account for card margins
        const adjustedX = x - cardMarginHorizontal
        const adjustedY = y - cardMarginTop

        // Only show focus if tap is within the camera card bounds
        if (adjustedX < 0 || adjustedY < 0) return

        setFocusPoint({ x: adjustedX, y: adjustedY })
        setShowFocus(true)
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light)

        // Animate: scale down from 1.2 to 1, then fade
        focusScale.value = 1.2
        focusOpacity.value = 1
        focusScale.value = withSequence(
            withTiming(1, { duration: 150 }),
            withTiming(0.95, { duration: 80 }),
            withTiming(1, { duration: 80 })
        )

        // Fade out after delay
        setTimeout(() => {
            focusOpacity.value = withTiming(0, { duration: 300 })
            setTimeout(() => setShowFocus(false), 300)
        }, 600)
    }

    const tapGesture = Gesture.Tap()
        .onStart((e) => {
            runOnJS(handleFocusTap)(e.x, e.y)
        })

    // Combine gestures: tap for focus, pan for mode switch
    // Combine gestures: tap for focus, pan for mode switch, vertical swipe to close
    const composedGestures = Gesture.Race(panGesture, verticalSwipe, tapGesture)

    // Animated Styles
    const captureButtonStyle = useAnimatedStyle(() => ({
        transform: [{ scale: captureBtnScale.value }]
    }))

    const recordRingStyle = useAnimatedStyle(() => ({
        borderWidth: interpolate(recordProgress.value, [0, 1], [4, 8]),
        borderColor: isRecording ? colors.status.error : '#fff',
        transform: [{ scale: isRecording ? 1.2 : 1 }]
    }))

    useEffect(() => {
        if (useNativeStoryCamera) return
        if (!permission?.granted) requestPermission()
        if (!audioPermission?.granted) requestAudioPermission()
        if (!mediaLibraryPermission?.granted) requestMediaLibraryPermission()

        if (mediaLibraryPermission?.granted || mediaLibraryPermission?.status === 'granted') {
            MediaLibrary.getAssetsAsync({ first: 1, sortBy: ['creationTime'], mediaType: ['photo', 'video'] }).then(async res => {
                if (res.assets.length > 0) {
                    const asset = res.assets[0]
                    try {
                        const info = await MediaLibrary.getAssetInfoAsync(asset.id)
                        setLatestImage(info.localUri || asset.uri)
                    } catch (e) {
                        setLatestImage(asset.uri)
                    }
                }
            })
        }
    }, [mediaLibraryPermission, useNativeStoryCamera])

    useEffect(() => {
        if (deferCameraMountMs <= 0) return
        setShouldMountCamera(false)
        setIsCameraReady(false)
        const t = setTimeout(() => setShouldMountCamera(true), deferCameraMountMs)
        return () => clearTimeout(t)
    }, [deferCameraMountMs])

    if (!useNativeStoryCamera && !permission?.granted) {
        return (
            <View style={[styles.container, { backgroundColor: colors.bg.primary, justifyContent: 'center', alignItems: 'center' }]}>
                <Text style={{ color: colors.text.primary, marginBottom: 20 }}>Camera permission required</Text>
                <TouchableOpacity onPress={requestPermission} style={[styles.permButton, { backgroundColor: colors.accent.DEFAULT }]}>
                    <Text style={{ color: colors.bg.primary, fontWeight: 'bold' }}>Grant Permission</Text>
                </TouchableOpacity>
            </View>
        )
    }

    const toggleCamera = () => {
        setFacing(current => (current === 'back' ? 'front' : 'back'))
        Haptics.selectionAsync()
    }

    const toggleFlash = () => {
        setFlash(current => (current === 'off' ? 'on' : 'off'))
        Haptics.selectionAsync()
    }

    const takePicture = async () => {
        if (!cameraRef.current) return
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium)
        captureBtnScale.value = withTiming(0.8, { duration: 100 }, () => {
            captureBtnScale.value = withTiming(1, { duration: 150 })
        })

        try {
            const photo = await cameraRef.current.takePictureAsync({ quality: 1.0, skipProcessing: true })
            if (photo) {
                setCapturedMedia({ uri: photo.uri, type: 'image', mirrored: facing === 'front' })
                setOriginalMedia(null)
                setEditError(null)
            }
        } catch (e) {
            Alert.alert('Error', 'Failed to capture image')
        }
    }

    const startRecording = async () => {
        if (!cameraRef.current || isRecording) return
        setIsRecording(true)
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Heavy)
        recordProgress.value = withTiming(1, { duration: 15000 })
        try {
            const video = await cameraRef.current.recordAsync({ maxDuration: 15 })
            if (video) setCapturedMedia({ uri: video.uri, type: 'video', mirrored: facing === 'front' })
        } catch (e) {
            console.error(e)
        } finally {
            setIsRecording(false)
            recordProgress.value = 0
        }
    }

    const stopRecording = () => {
        if (!cameraRef.current || !isRecording) return
        cameraRef.current.stopRecording()
    }

    const pickFromGallery = async () => {
        const result = await ImagePicker.launchImageLibraryAsync({
            mediaTypes: mode === 'picture' ? ['images'] : ['videos'],
            allowsEditing: false,
            quality: 0.8,
        })
        if (!result.canceled && result.assets[0]) {
            setCapturedMedia({
                uri: result.assets[0].uri,
                type: result.assets[0].type === 'video' ? 'video' : 'image',
                mirrored: false
            })
            setOriginalMedia(null)
            setEditError(null)
        }
    }

    const extractRetryAfterSeconds = (value: any): number | null => {
        if (typeof value === 'number' && Number.isFinite(value) && value > 0) return Math.floor(value);
        if (typeof value === 'string') {
            const direct = parseInt(value, 10);
            if (!Number.isNaN(direct) && direct > 0) return direct;
            const fromMessage = value.match(/(\d+)\s*(seconds?|secs?|s)/i);
            if (fromMessage) {
                const parsed = parseInt(fromMessage[1], 10);
                if (!Number.isNaN(parsed) && parsed > 0) return parsed;
            }
        }
        return null;
    };

    const handleAIEdit = async (prompt: string) => {

        if (!capturedMedia || !prompt.trim() || isEditing) {

            return;
        }
        setIsEditing(true)
        setEditError(null)
        setEditRateLimitSeconds(null)

        // Timeout after 30 seconds
        const timeoutId = setTimeout(() => {

            setIsEditing(false);
            setEditError("AI editing took too long. Please try again.");
        }, 30000);

        try {
            let imageUrl = capturedMedia.uri;


            // If local file, convert to base64
            if (!imageUrl.startsWith('http') && !imageUrl.startsWith('data:')) {

                const base64 = await FileSystem.readAsStringAsync(capturedMedia.uri, { encoding: 'base64' });
                const mimeType = capturedMedia.type === 'video' ? 'video/mp4' : 'image/jpeg';
                imageUrl = `data:${mimeType};base64,${base64}`;

            }


            const result = await apiClient.editImage(imageUrl, prompt)
            clearTimeout(timeoutId);


            if (result.success && result.url) {
                // Save original if first edit
                if (!originalMedia) {
                    setOriginalMedia(capturedMedia)
                }

                if (result.url.startsWith('http') || result.url.startsWith('data:')) {
                    setCapturedMedia({ ...capturedMedia, uri: result.url })
                } else {
                    Alert.alert("Nano Banana Says", result.url)
                }
            } else {
                const errorText = result.error || result.message || "Could not edit image. Please try again.";
                const retryAfter =
                    extractRetryAfterSeconds(result.retry_after) ??
                    extractRetryAfterSeconds(result.retryAfter) ??
                    extractRetryAfterSeconds(errorText);
                const isRateLimited = /too many requests|rate limit|please slow down/i.test(errorText) || !!retryAfter;

                if (isRateLimited) {
                    setEditRateLimitSeconds(retryAfter || 60);
                    setEditError('You hit the image edit limit.');
                } else {
                    setEditError(errorText);
                }
            }
        } catch (e: any) {
            clearTimeout(timeoutId);
            console.error('[StoryCamera] AI Edit Exception:', e);
            const rawMessage = e?.message || "AI Edit failed. Please try again.";
            const retryAfter = extractRetryAfterSeconds(rawMessage);
            const isRateLimited = /too many requests|rate limit|please slow down|429/i.test(rawMessage) || !!retryAfter;
            if (isRateLimited) {
                setEditRateLimitSeconds(retryAfter || 60);
                setEditError('You hit the image edit limit.');
            } else {
                setEditError(rawMessage);
            }
        } finally {
            clearTimeout(timeoutId);
            setIsEditing(false)
        }
    }

    const onPost = async (details?: {
        prompt?: string,
        audience?: string,
        visibleTo?: string[],
        hiddenFrom?: string[],
        allowScreenshots?: boolean,
        postToProfile?: boolean,
        duration?: number
    }) => {
        if (!capturedMedia || !user?.userId) return

        // Map audience 'selected' to 'custom' for API
        const visibility = (details?.audience === 'selected' ? 'custom' : details?.audience || 'everyone') as any

        // Fire and forget - background upload
        createStory({
            userId: user.userId,
            mediaUrl: capturedMedia.uri,
            mediaType: capturedMedia.type,
            visibility: visibility,
            visibleTo: details?.visibleTo,
            hiddenFrom: details?.hiddenFrom,
            duration: details?.duration
        })

        // Immediately close
        requestClose()
    }

    const discardCapturedMedia = () => {
        setCapturedMedia(null)
        setOriginalMedia(null)
        setEditError(null)
        setEditRateLimitSeconds(null)
    }

    const handleSaveDraft = () => {
        if (!capturedMedia) return
        saveDraft({
            mediaUri: capturedMedia.uri,
            mediaType: capturedMedia.type
        })
        Alert.alert("Draft Saved", "Your story has been saved to drafts.", [
            { text: "OK", onPress: () => requestClose() }
        ])
    }

    const handleNativeCameraEvent = ({ nativeEvent }: { nativeEvent: NativeStoryCameraEventPayload }) => {
        switch (nativeEvent.type) {
            case 'capture':
                setCapturedMedia({
                    uri: nativeEvent.uri,
                    type: nativeEvent.mediaType,
                    mirrored: !!nativeEvent.mirrored,
                })
                setOriginalMedia(null)
                setEditError(null)
                setEditRateLimitSeconds(null)
                return
            case 'openDrafts':
                router.push('/story-drafts')
                return
            case 'close':
                requestClose()
                return
            case 'error':
                Alert.alert('Error', nativeEvent.message || 'Failed to use the native camera.')
                return
        }
    }

    const handleNativeComposerEvent = ({ nativeEvent }: { nativeEvent: NativeStoryComposerEventPayload }) => {
        switch (nativeEvent.type) {
            case 'discard':
                discardCapturedMedia()
                return
            case 'saveDraft':
                handleSaveDraft()
                return
            case 'aiEdit':
                void handleAIEdit(nativeEvent.prompt)
                return
            case 'publish':
                void onPost({
                    audience: nativeEvent.audience,
                    allowScreenshots: nativeEvent.allowScreenshots,
                    postToProfile: nativeEvent.postToProfile,
                    duration: nativeEvent.duration,
                })
                return
        }
    }

    if (capturedMedia && useNativeStoryComposer) {
        return (
            <View style={[styles.container, { backgroundColor: colors.bg.primary }]}>
                <StatusBar barStyle="light-content" />
                <NativeStoryComposer
                    mediaUri={capturedMedia.uri}
                    mediaType={capturedMedia.type}
                    mirrored={!!capturedMedia.mirrored}
                    onNativeEvent={handleNativeComposerEvent}
                    style={styles.nativeCamera}
                />
            </View>
        )
    }

    if (capturedMedia) {
        return (
            <StoryPreview
                media={capturedMedia}
                onDiscard={discardCapturedMedia}
                onPost={onPost}
                onSaveDraft={handleSaveDraft}
                onSettings={() => { }}
                onAIEdit={handleAIEdit}
                isEditing={isEditing}
                editError={editError}
                editRateLimitSeconds={editRateLimitSeconds}
                onClearError={() => {
                    setEditError(null);
                    setEditRateLimitSeconds(null);
                }}
                canRevert={!!originalMedia}
                onRevert={() => {
                    if (originalMedia) {
                        setCapturedMedia(originalMedia)
                        setOriginalMedia(null)
                    }
                }}
            />
        )
    }

    if (useNativeStoryCamera) {
        return (
            <View style={[styles.container, { backgroundColor: colors.bg.primary }]}>
                <StatusBar barStyle="light-content" />
                <NativeStoryCamera
                    deferMountMs={deferCameraMountMs}
                    onNativeEvent={handleNativeCameraEvent}
                    style={styles.nativeCamera}
                />
            </View>
        )
    }

    return (
        <GestureDetector gesture={composedGestures}>
            <View style={[styles.container, { backgroundColor: colors.bg.primary }]}>
                <StatusBar barStyle="light-content" />
                <View style={[styles.cardWrapper, { backgroundColor: colors.bg.primary, borderColor: colors.border.subtle }]}>
                    {shouldMountCamera ? (
                        <CameraView
                            ref={cameraRef}
                            style={styles.fullScreen}
                            facing={facing}
                            flash={flash}
                            mode={mode}
                            mirror={facing === 'front'}
                            onCameraReady={() => setIsCameraReady(true)}
                        >
                            {/* Focus Indicator - Simple circle */}
                            {showFocus && focusPoint && (
                                <Animated.View
                                    style={[
                                        styles.focusRing,
                                        {
                                            left: focusPoint.x - 30,
                                            top: focusPoint.y - 30,
                                        },
                                        focusAnimatedStyle
                                    ]}
                                />
                            )}
                        </CameraView>
                    ) : (
                        <View style={[styles.fullScreen, { backgroundColor: '#0b0b0f' }]} />
                    )}

                    {/* Prevent black flash while CameraView initializes */}
                    {(!isCameraReady || !shouldMountCamera) && (
                        <View style={StyleSheet.absoluteFill} pointerEvents="none">
                            <BlurView intensity={32} tint="dark" style={StyleSheet.absoluteFill} />
                            <View style={[StyleSheet.absoluteFill, { backgroundColor: 'rgba(0,0,0,0.25)' }]} />
                            <View style={[StyleSheet.absoluteFill, { alignItems: 'center', justifyContent: 'center' }]}>
                                <ActivityIndicator color="#fff" />
                            </View>
                        </View>
                    )}

                    {/* Camera Overlay - Outside CameraView to prevent re-render flicker */}
                    <Animated.View entering={FadeIn} style={[StyleSheet.absoluteFill, styles.cameraOverlay]} pointerEvents="box-none">
                        {/* Top Bar - Back button removed */}
                        <View style={styles.topBar}>
                            {/* Drafts Button (Left) */}
                            <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={22} tint="dark">
                                <TouchableOpacity onPress={() => router.push('/story-drafts')} style={styles.iconBtnCircle} activeOpacity={0.85}>
                                    <Folder size={20} color={colors.text.primary} />
                                </TouchableOpacity>
                            </SafeLiquidGlass>

                            <View style={styles.topRightControls}>
                                <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={22} tint="dark">
                                    <TouchableOpacity onPress={toggleFlash} style={styles.iconBtnCircle} activeOpacity={0.85}>
                                        {flash === 'on' ? <Zap size={20} color="#FFE600" fill="#FFE600" /> : <ZapOff size={20} color={colors.text.primary} />}
                                    </TouchableOpacity>
                                </SafeLiquidGlass>

                                <SafeLiquidGlass style={styles.glassBtnCircle} blurIntensity={22} tint="dark">
                                    <TouchableOpacity onPress={requestClose} style={styles.iconBtnCircle} activeOpacity={0.85}>
                                        <X size={20} color={colors.text.primary} />
                                    </TouchableOpacity>
                                </SafeLiquidGlass>
                            </View>
                        </View>
                    </Animated.View>
                </View>

                {/* Camera Footer - Outside Card */}
                <View style={styles.cameraFooter}>
                    <View style={styles.bottomControls}>
                        {/* Shutter Button */}
                        <Animated.View style={[styles.shutterWrapper, captureButtonStyle]}>
                            <Pressable
                                onPress={mode === 'picture' ? takePicture : undefined}
                                onLongPress={mode === 'video' ? startRecording : undefined}
                                onPressOut={mode === 'video' ? stopRecording : undefined}
                                delayLongPress={200}
                                style={styles.shutterTouchable}
                            >
                                <Animated.View style={[styles.shutterRing, recordRingStyle]} />
                                <View style={[styles.shutterInner, { backgroundColor: mode === 'video' ? colors.status.error : '#fff' }]} />
                            </Pressable>
                        </Animated.View>

                        {/* Glass Bottom Row */}
                        <View style={styles.bottomActionRow}>
                            <TouchableOpacity onPress={pickFromGallery} style={styles.glassBtn}>
                                <SafeLiquidGlass style={styles.glassBaseIcon} blurIntensity={30} tint="dark">
                                    <View style={[styles.glassContent, { backgroundColor: withAlpha(colors.bg.primary, 0.4) }]}>
                                        {latestImage ? (
                                            <Image source={{ uri: latestImage as string }} style={styles.galleryThumb} />
                                        ) : (
                                            <ImageIcon size={22} color={colors.text.primary} />
                                        )}
                                    </View>
                                </SafeLiquidGlass>
                            </TouchableOpacity>

                            <View style={styles.modeSelectorGlass}>
                                <SafeLiquidGlass style={styles.glassBaseSelector} blurIntensity={30} tint="dark">
                                    <View style={[styles.modeSelectorContent, { backgroundColor: withAlpha(colors.bg.primary, 0.4) }]}>
                                        <TouchableOpacity onPress={() => setMode('picture')} style={[styles.modeBtn, mode === 'picture' && { backgroundColor: withAlpha('#fff', 0.2) }]}>
                                            <Text style={[styles.modeText, { color: mode === 'picture' ? colors.text.primary : colors.text.secondary }]}>PHOTO</Text>
                                        </TouchableOpacity>
                                        <TouchableOpacity onPress={() => setMode('video')} style={[styles.modeBtn, mode === 'video' && { backgroundColor: withAlpha('#fff', 0.2) }]}>
                                            <Text style={[styles.modeText, { color: mode === 'video' ? colors.text.primary : colors.text.secondary }]}>VIDEO</Text>
                                        </TouchableOpacity>
                                    </View>
                                </SafeLiquidGlass>
                            </View>

                            <TouchableOpacity onPress={toggleCamera} style={styles.glassBtn}>
                                <SafeLiquidGlass style={styles.glassBaseIcon} blurIntensity={30} tint="dark">
                                    <View style={[styles.glassContent, { backgroundColor: withAlpha(colors.bg.primary, 0.4) }]}>
                                        <RefreshIcon size={22} color={colors.text.primary} />
                                    </View>
                                </SafeLiquidGlass>
                            </TouchableOpacity>
                        </View>
                    </View>
                </View>
            </View>
        </GestureDetector>
    )
}

export default function StoryCameraScreen() {
    return <StoryCamera />
}

const styles = StyleSheet.create({
    container: { flex: 1 },
    nativeCamera: { flex: 1 },
    fullScreen: { flex: 1 },
    cardWrapper: {
        height: SCREEN_HEIGHT * 0.85,
        marginTop: Platform.OS === 'ios' ? 55 : 35,
        marginHorizontal: 10,
        borderRadius: 32,
        overflow: 'hidden',
        borderWidth: 1,
    },
    cameraOverlay: {
        flex: 1,
        paddingTop: 15,
    },
    focusRing: {
        position: 'absolute',
        width: 60,
        height: 60,
        borderRadius: 30,
        borderWidth: 1.5,
        borderColor: 'rgba(255, 255, 255, 0.9)',
        zIndex: 10,
    },
    cameraFooter: {
        flex: 1,
        justifyContent: 'flex-end',
        paddingBottom: Platform.OS === 'ios' ? 30 : 20,
    },
    topBar: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 14,
    },
    topRightControls: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 10,
    },
    glassBtnCircle: {
        width: 44,
        height: 44,
        borderRadius: 22,
        overflow: 'hidden',
    },
    iconBtnCircle: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
    },
    glassBaseIcon: {
        borderRadius: 20,
        overflow: 'hidden',
    },
    glassBaseSelector: {
        borderRadius: 22,
        overflow: 'hidden',
    },
    bottomControls: {
        alignItems: 'center',
    },
    shutterWrapper: {
        marginBottom: 30,
    },
    shutterTouchable: {
        width: 80,
        height: 80,
        alignItems: 'center',
        justifyContent: 'center',
    },
    shutterRing: {
        position: 'absolute',
        width: '100%',
        height: '100%',
        borderRadius: 40,
        borderWidth: 4,
    },
    shutterInner: {
        width: 62,
        height: 62,
        borderRadius: 31,
    },
    bottomActionRow: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        width: SCREEN_WIDTH,
        paddingHorizontal: 30,
    },
    // Glass Button Styles
    glassBtn: {
        borderRadius: 20,
        overflow: 'hidden',
    },
    glassContent: {
        width: 44,
        height: 44,
        alignItems: 'center',
        justifyContent: 'center',
    },
    galleryThumb: { width: '100%', height: '100%', borderRadius: 12 },

    // Mode Selector Glass
    modeSelectorGlass: {
        borderRadius: 22,
        overflow: 'hidden',
        position: 'relative',
        height: 44, // Match side buttons height
        justifyContent: 'center'
    },
    modeSelectorContent: {
        flexDirection: 'row',
        padding: 4,
        alignItems: 'center',
        height: '100%',
    },
    modeBtn: {
        paddingHorizontal: 16,
        paddingVertical: 6,
        borderRadius: 18,
        height: 36, // Vertical centering
        justifyContent: 'center'
    },
    modeText: {
        fontWeight: 'bold',
        fontSize: 12,
    },
    permButton: { padding: 12, borderRadius: 8 },
})
