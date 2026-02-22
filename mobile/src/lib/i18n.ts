import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';
import * as Localization from 'expo-localization';
import { I18nManager } from 'react-native';

// Enable RTL layout support for languages like Persian
I18nManager.allowRTL(true);

const resources = {
    en: {
        translation: {
            "tabs": {
                "home": "Home",
                "contacts": "Contacts",
                "calls": "Calls",
                "chats": "Chats",
                "settings": "Settings",
                "vibe": "vibe"
            },
            "settings": {
                "title": "Settings",
                "edit": "Edit",
                "account": "ACCOUNT",
                "editProfile": "Edit Profile",
                "savedMessages": "Saved Messages",
                "yourQr": "Your QR",
                "connectionManager": "Connection Manager",
                "privacySecurity": "PRIVACY & SECURITY",
                "privacy": "Privacy",
                "secretKey": "Secret Key",
                "notifications": "NOTIFICATIONS"
            },
            "auth": {
                "welcomeBack": "Welcome\nBack",
                "connectFreely": "Connect freely. Chat securely.",
                "enterSecretKey": "Enter your unique Secret Key to restore your session.",
                "secretKeyLabel": "Secret Key",
                "signIn": "Sign In",
                "noAccount": "Don't have an account?",
                "createOne": "Create One",
                "createAccount": "Create\nAccount",
                "rhythmPrivateVibing": "Connect to the rhythm of secure, private vibing.",
                "chooseUsername": "Choose a username",
                "signUp": "Sign Up",
                "alreadyHaveAccount": "Already have an account?"
            }
        }
    },
    fa: {
        translation: {
            "tabs": {
                "home": "خانه",
                "contacts": "مخاطبین",
                "calls": "تماس‌ها",
                "chats": "گفتگوها",
                "settings": "تنظیمات",
                "vibe": "وایب"
            },
            "settings": {
                "title": "تنظیمات",
                "edit": "ویرایش",
                "account": "حساب کاربری",
                "editProfile": "ویرایش پروفایل",
                "savedMessages": "پیام‌های ذخیره شده",
                "yourQr": "کد QR شما",
                "connectionManager": "مدیریت اتصال",
                "privacySecurity": "حریم خصوصی و امنیت",
                "privacy": "حریم خصوصی",
                "secretKey": "کلید امنیتی",
                "notifications": "اعلان‌ها"
            },
            "auth": {
                "welcomeBack": "خوش\nآمدید",
                "connectFreely": "آزادانه متصل شوید. امن گفتگو کنید.",
                "enterSecretKey": "برای بازیابی نشست خود، کلید امنیتی منحصر به فرد خود را وارد کنید.",
                "secretKeyLabel": "کلید امنیتی",
                "signIn": "ورود",
                "noAccount": "حساب کاربری ندارید؟",
                "createOne": "ایجاد کنید",
                "createAccount": "ایجاد\nحساب",
                "rhythmPrivateVibing": "به ریتم وایب امن و خصوصی متصل شوید.",
                "chooseUsername": "یک نام کاربری انتخاب کنید",
                "signUp": "ثبت‌نام",
                "alreadyHaveAccount": "قبلاً حساب کاربری داشته‌اید؟"
            }
        }
    }
};

const languageCode = Localization.getLocales()[0].languageCode;

i18n
    .use(initReactI18next)
    .init({
        resources,
        lng: languageCode || 'en',
        fallbackLng: 'en',
        interpolation: {
            escapeValue: false,
        },
        react: {
            useSuspense: false,
        }
    });

export default i18n;
