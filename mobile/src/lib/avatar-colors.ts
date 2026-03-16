export type AvatarVariant = "user" | "saved";
export type AvatarGradient = readonly [string, string];

export interface AvatarGradientSet {
  light: AvatarGradient;
  dark: AvatarGradient;
}

const clampChannel = (value: number) => Math.max(0, Math.min(255, Math.round(value)));

const hashString = (input: string) => {
  let hash = 0;
  for (let index = 0; index < input.length; index += 1) {
    hash = (hash * 31 + input.charCodeAt(index)) >>> 0;
  }
  return hash;
};

const isDarkTheme = (theme: string) => theme === "dark";

const rgbToHex = (r: number, g: number, b: number) =>
  `#${[r, g, b]
    .map((channel) => clampChannel(channel).toString(16).padStart(2, "0"))
    .join("")}`.toUpperCase();

const hexToRgb = (hexColor: string) => {
  const normalized = hexColor.trim().replace(/^#/, "");
  const value = normalized.length === 3
    ? normalized.split("").map((channel) => `${channel}${channel}`).join("")
    : normalized;
  if (value.length !== 6) {
    return [127, 127, 127] as const;
  }

  return [
    parseInt(value.slice(0, 2), 16),
    parseInt(value.slice(2, 4), 16),
    parseInt(value.slice(4, 6), 16),
  ] as const;
};

const hslToRgb = (h: number, s: number, l: number) => {
  if (s === 0) {
    const value = clampChannel(l * 255);
    return [value, value, value] as const;
  }

  const hueToRgb = (p: number, q: number, t: number) => {
    let nextT = t;
    if (nextT < 0) nextT += 1;
    if (nextT > 1) nextT -= 1;
    if (nextT < 1 / 6) return p + (q - p) * 6 * nextT;
    if (nextT < 1 / 2) return q;
    if (nextT < 2 / 3) return p + (q - p) * (2 / 3 - nextT) * 6;
    return p;
  };

  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;

  return [
    clampChannel(hueToRgb(p, q, h + 1 / 3) * 255),
    clampChannel(hueToRgb(p, q, h) * 255),
    clampChannel(hueToRgb(p, q, h - 1 / 3) * 255),
  ] as const;
};

const gradientToSurfaceColor = (
  [startHex, endHex]: AvatarGradient,
  alpha: number,
) => {
  const [startR, startG, startB] = hexToRgb(startHex);
  const [endR, endG, endB] = hexToRgb(endHex);
  const mix = 0.44;
  const r = clampChannel(startR * (1 - mix) + endR * mix);
  const g = clampChannel(startG * (1 - mix) + endG * mix);
  const b = clampChannel(startB * (1 - mix) + endB * mix);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
};

export const getSavedMessagesAvatarGradient = (theme: string): AvatarGradient =>
  isDarkTheme(theme)
    ? ["#4DD9E5", "#2BA5B5"]
    : ["#2BA5B5", "#007A7C"];

export const getSavedMessagesAvatarGradientSet = (): AvatarGradientSet => ({
  light: getSavedMessagesAvatarGradient("light"),
  dark: getSavedMessagesAvatarGradient("dark"),
});

export const getUserAvatarGradient = (
  seed: string | null | undefined,
  theme: string,
): AvatarGradient => {
  const normalizedSeed = (seed || "avatar").trim().toLowerCase();
  const hash = hashString(normalizedSeed);
  const hue = (hash % 360) / 360;
  const hueShift = ((((hash >>> 9) % 24) - 12) / 360);
  const saturation = isDarkTheme(theme) ? 0.66 : 0.60;
  const startLightness = isDarkTheme(theme) ? 0.66 : 0.56;
  const endLightness = isDarkTheme(theme) ? 0.46 : 0.40;
  const start = hslToRgb(hue, saturation, startLightness);
  const endHue = (hue + hueShift + 1) % 1;
  const end = hslToRgb(endHue, saturation + 0.04, endLightness);

  return [
    rgbToHex(...start),
    rgbToHex(...end),
  ];
};

export const getAvatarGradient = (
  seed: string | null | undefined,
  theme: string,
  variant: AvatarVariant = "user",
): AvatarGradient =>
  variant === "saved"
    ? getSavedMessagesAvatarGradient(theme)
    : getUserAvatarGradient(seed, theme);

export const getAvatarGradientSet = (
  seed: string | null | undefined,
  variant: AvatarVariant = "user",
): AvatarGradientSet => ({
  light: getAvatarGradient(seed, "light", variant),
  dark: getAvatarGradient(seed, "dark", variant),
});

export const getAvatarSurfaceColor = (
  seed: string | null | undefined,
  theme: string,
  alphaOverride?: number,
  variant: AvatarVariant = "user",
) => {
  const alpha = alphaOverride ?? (isDarkTheme(theme) ? 0.34 : 0.22);
  return gradientToSurfaceColor(getAvatarGradient(seed, theme, variant), alpha);
};
