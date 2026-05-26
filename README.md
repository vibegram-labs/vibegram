# 💬 Vibe

> **Privacy-first decentralized chat platform with end-to-end encryption, native mobile apps, and peer-to-peer connectivity**

<div align="center">

[![GitHub Stars](https://img.shields.io/github/stars/Vibe-source/Vibe?style=flat-square)](https://github.com/Vibe-source/Vibe)
[![GitHub License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20Android%20%7C%20Web-blue?style=flat-square)](#)

[Features](#features) • [Architecture](#architecture) • [Getting Started](#getting-started) • [Contributing](#contributing)

</div>

---

## Features

🔐 **Military-Grade Encryption** — End-to-end encrypted messaging with zero server-side access. Uses TweetNaCl/libsodium for cryptographic operations.

📱 **Native Mobile Apps** — Dedicated iOS (Swift) and Android (Kotlin) apps with:
- Real-time push notifications
- Native call screens with video/audio
- Offline message queuing
- Optimized performance and battery usage

🌐 **Cross-Platform** — Seamless experience across:
- iOS app (App Store ready)
- Android app (Play Store ready)  
- Web client (TypeScript/React)

🔗 **Decentralized & Private** — Optional Tor integration for network anonymity. No analytics, no tracking, no telemetry.

⚡ **Real-Time Communication** — WebSocket-based architecture for:
- Instant messaging with delivery status
- Voice/video calls with low latency
- Typing indicators and read receipts
- Online presence awareness

📎 **Rich Media** — Built-in support for:
- GIF search and sharing (Giphy integration)
- Image uploads and encrypted storage
- File transfers with progress tracking
- Message reactions and threads

---

## Architecture

### System Overview

The Vibe platform is built on a **layered microservices architecture** with clear separation of concerns:

```
┌─────────────────────────────────────────────────────────┐
│                    CLIENT LAYER                          │
├──────────────────────┬──────────────────────┬────────────┤
│   iOS (Swift)        │  Android (Kotlin)    │  Web (TS)  │
│  - Native UI         │  - Native UI         │ - React    │
│  - Local Storage     │  - Local Storage     │ - SQLite   │
│  - Call Engine       │  - Call Engine       │ - WebRTC   │
└──────────────────────┴──────────────────────┴────────────┘
                          ▼
┌─────────────────────────────────────────────────────────┐
│              TRANSPORT & SECURITY LAYER                  │
├─────────────────────────────────────────────────────────┤
│  WebSocket (realtime) │  HTTPS (REST) │ TweetNaCl (E2EE) │
│  Message Serialization│ Auth Tokens   │ Key Exchange      │
└─────────────────────────────────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────┐
│                  API & BUSINESS LOGIC                    │
│              (Elixir/Phoenix Framework)                  │
├──────────────────┬──────────────┬──────────────────────┤
│  User Management │ Message Ops  │ Call Signaling       │
│  Auth (JWT)      │ Encryption   │ Media Upload         │
│  Profile Mgmt    │ Notifications│ Presence Tracking    │
└──────────────────┴──────────────┴──────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────┐
│              DATA PERSISTENCE LAYER                      │
├──────────────────────┬──────────────────────────────────┤
│   PostgreSQL DB      │  File Storage (Encrypted)        │
│  - User Data        │  - Media Uploads                   │
│  - Chat History     │  - Backups                         │
│  - Relationships    │  - Keys & Secrets                  │
└──────────────────────┴──────────────────────────────────┘
```

### Component Breakdown

**Frontend Layer (Client)**
- **iOS** (`/ios`) — SwiftUI-based native app with chat module, call engine, and push notifications
- **Android** (`/android`) — Kotlin-based native app mirroring iOS functionality with Jetpack Compose
- **Web** (`/client`) — React TypeScript SPA for desktop/browser access

**Backend Layer (Server)**
- **Elixir/Phoenix** (`/server`) — High-concurrency messaging platform with:
  - Real-time WebSocket connections via Phoenix Channels
  - RESTful API for authentication and file operations
  - Background job processing for notifications
  - Encrypted message storage and retrieval
  
**Data Layer**
- **PostgreSQL** — Persistent storage for users, messages (encrypted), metadata
- **File Storage** — Encrypted media uploads with secure access controls

### Data Flow Example

```
User A sends message to User B:

1. Client encrypts message with recipient's public key (E2EE)
2. Message sent via WebSocket to Phoenix Channel
3. Backend validates user & stores encrypted message
4. If User B offline: message queued in Redis
5. Push notification sent to User B's device
6. User B receives notification, fetches message
7. Client decrypts with private key
8. User B sees plaintext message (server never sees it)
```

### Security Architecture

- **End-to-End Encryption** — TweetNaCl Box (public-key cryptography)
- **Key Management** — Derived from user password using Argon2
- **Transport Security** — TLS/SSL for all HTTP connections
- **Authentication** — JWT tokens with refresh rotation
- **Data at Rest** — Encrypted file storage with separate encryption keys
- **Optional Anonymity** — Tor integration for network-level privacy

---

## Tech Stack

| Component | Technology | Purpose |
|-----------|-----------|---------|
| **iOS** | Swift 5.9, SwiftUI | Native iOS application |
| **Android** | Kotlin, Jetpack Compose | Native Android application |
| **Web** | React 18, TypeScript, Vite | Web client |
| **Backend** | Elixir 1.14, Phoenix 1.7 | High-concurrency API server |
| **Database** | PostgreSQL 14 | Primary data store |
| **Real-time** | WebSocket (Phoenix Channels) | Live messaging |
| **Encryption** | TweetNaCl.js / libsodium | E2EE cryptography |
| **Storage** | File system + Cloud | Media & backups |
| **Deployment** | Docker, Railway | Container orchestration |

---

## Getting Started

### Prerequisites
- **Elixir** 1.14+ & Erlang 25+
- **PostgreSQL** 14+
- **Node.js** 18+ (for web client)
- **Xcode** 14+ (for iOS development)
- **Android Studio** (for Android development)

### Quick Start

#### Backend
```bash
cd server
mix deps.get          # Install dependencies
mix ecto.create       # Create database
mix ecto.migrate      # Run migrations
mix phx.server        # Start at http://localhost:4000
```

#### Web Client
```bash
cd client
npm install
npm run dev           # Starts at http://localhost:5173
```

#### iOS
```bash
cd ios
pod install
open Vibe.xcworkspace
# Build in Xcode (Cmd+B)
```

#### Android
```bash
cd android
./gradlew assembleDebug  # Build debug APK
# Or open in Android Studio and run
```

---

## Project Structure

```
vibe/
├── android/              # Android Kotlin app
│   ├── app/             # Main application module
│   └── chat-module/     # Native chat implementation
├── ios/                 # iOS Swift app
│   ├── ChatModule/      # Chat functionality
│   └── Sources/         # SwiftUI screens & logic
├── server/              # Elixir/Phoenix backend
│   ├── lib/vibe/        # Business logic
│   ├── lib/vibe_web/    # API & WebSocket handlers
│   └── priv/repo/       # Database migrations
├── client/              # React web app
│   ├── src/             # TypeScript/React code
│   └── public/          # Static assets
├── mobile/              # Legacy React Native (archived)
├── scripts/             # Build & deployment helpers
├── docs/                # Documentation
├── Dockerfile           # Container definition
└── docker-compose.yml   # Local development setup
```

---

## Development Workflow

### Making Changes
1. Create feature branch: `git checkout -b feature/my-feature`
2. Make changes and test locally
3. Commit with clear messages: `git commit -m "feat: description"`
4. Push and create Pull Request

### Testing
```bash
# Backend tests
cd server
mix test

# Frontend tests (web)
cd client
npm test

# iOS tests
cd ios
xcodebuild test -scheme Vibe

# Android tests
cd android
./gradlew test
```

### Code Quality
- ESLint for TypeScript/JavaScript
- Credo for Elixir
- SwiftLint for Swift
- Ktlint for Kotlin

---

## Security & Privacy

🔒 **No Back Doors** — All cryptography is open-source and auditable

🔐 **Zero Knowledge** — Server cannot decrypt user messages

📊 **No Telemetry** — No analytics, tracking, or data collection

🛡️ **Regular Audits** — Security reviews and updates

🌐 **Optional Tor** — Connect via Tor for network-level anonymity

---

## Deployment

See `docs/deployment/` for detailed deployment guides for:
- **Docker** — Containerized deployment
- **Railway** — One-click deployment
- **Self-hosted** — On your own infrastructure

---

## Troubleshooting

**Issue:** WebSocket connection failing  
**Solution:** Ensure Phoenix is running and CORS is configured correctly

**Issue:** Encryption/decryption errors  
**Solution:** Check that NaCl libraries are properly installed

**Issue:** Push notifications not working  
**Solution:** Verify FCM (Android) and APNs (iOS) credentials are set

See `docs/troubleshooting/` for more solutions.

---

## Contributing

We welcome contributions! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes following our code style
4. Write tests for new functionality
5. Commit with descriptive messages
6. Push to your fork and create a Pull Request

**Contribution Guidelines:**
- Keep commits atomic and focused
- Write clear commit messages
- Add tests for new features
- Update documentation as needed
- Follow existing code style conventions

---

## Roadmap

- [ ] End-to-end encrypted voice calls
- [ ] Group chat with key sharing
- [ ] Message search and filtering
- [ ] Contact sync and backup
- [ ] Cloud storage integration
- [ ] Desktop clients (Electron)
- [ ] API for third-party integrations

---

## License

[Add your license here - e.g., MIT, GPL, etc.]

---

## Support & Community

- 📖 **Documentation:** See `/docs` directory
- 🐛 **Report Issues:** [GitHub Issues](https://github.com/Vibe-source/Vibe/issues)
- 💬 **Discussions:** [GitHub Discussions](https://github.com/Vibe-source/Vibe/discussions)
- 📧 **Contact:** [your-email@example.com]

---

## Acknowledgments

Built with ❤️ by the Vibe team. Special thanks to the open-source community.

---

**⭐ If you find Vibe useful, please consider starring the repository!**

*Last updated: 2026-05-26*
