import React, { useState, useEffect } from 'react';
import { View, TextInput, Text, StyleSheet, TextInputProps, I18nManager } from 'react-native';
import Animated, { useSharedValue, useAnimatedStyle, withTiming, interpolate, interpolateColor } from 'react-native-reanimated';
import { useThemeStore } from '../../lib/stores/theme-store';

interface FloatInputProps extends TextInputProps {
    label: string;
    error?: string;
    containerStyle?: any;
    labelColor?: string;
}

const FloatInput = ({ label, value, error, containerStyle, labelColor, ...props }: FloatInputProps) => {
    const { colors } = useThemeStore();
    const [isFocused, setIsFocused] = useState(false);
    const isRTL = I18nManager.isRTL;

    // Check if value is truly present (handling undefined/null)
    const hasValue = value !== undefined && value !== null && value.length > 0;

    const focusAnim = useSharedValue(0);

    useEffect(() => {
        focusAnim.value = withTiming(isFocused || hasValue ? 1 : 0, { duration: 200 });
    }, [isFocused, hasValue]);

    const activeLabelColor = labelColor || colors.primary;
    const inactiveLabelColor = colors.textSecondary;

    const labelStyle = useAnimatedStyle(() => {
        return {
            position: 'absolute',
            [isRTL ? 'right' : 'left']: 12,
            top: interpolate(focusAnim.value, [0, 1], [23, 2]),
            fontSize: interpolate(focusAnim.value, [0, 1], [15, 12]),
            color: interpolateColor(focusAnim.value, [0, 1], [inactiveLabelColor, activeLabelColor]),
            zIndex: 1,
            backgroundColor: focusAnim.value > 0.1 ? colors.background : 'transparent',
            paddingHorizontal: 6,
            borderRadius: 8,
        };
    });

    return (
        <View style={[styles.container, containerStyle]}>
            <Animated.Text allowFontScaling={false} style={[styles.label, labelStyle]} pointerEvents="none">
                {label}
            </Animated.Text>
            <TextInput
                {...props}
                value={value}
                style={[
                    styles.input,
                    {
                        color: colors.text,
                        borderColor: error ? colors.danger : (isFocused ? activeLabelColor : colors.border),
                        textAlign: isRTL ? 'right' : 'left',
                    }
                ]}
                placeholderTextColor="transparent"
                onFocus={() => setIsFocused(true)}
                onBlur={() => setIsFocused(false)}
            />
            {error ? <Text style={[styles.errorText, { color: colors.danger, textAlign: isRTL ? 'right' : 'left' }]}>{error}</Text> : null}
        </View>
    );
};

const styles = StyleSheet.create({
    container: {
        marginBottom: 20,
        position: 'relative',
        width: '100%',
        paddingTop: 10,
    },
    label: {
        fontWeight: '500',
        letterSpacing: 0.2,
    },
    input: {
        height: 46,
        borderWidth: 1,
        borderRadius: 23,
        paddingHorizontal: 16,
        paddingTop: 0,
        paddingBottom: 0,
        fontSize: 16,
        fontWeight: '500',
    },
    errorText: {
        fontSize: 13,
        marginTop: 10,
        marginHorizontal: 8,
        fontWeight: '500',
    }
});

export default FloatInput;
