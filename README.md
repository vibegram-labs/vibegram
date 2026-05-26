# Vibegram

> **A privacy-centric, decentralized communication platform featuring end-to-end encryption, native mobile architectures, and peer-to-peer connectivity.**

[Features](https://www.google.com/search?q=%23features) • [Architecture](https://www.google.com/search?q=%23architecture) • [Getting Started](https://www.google.com/search?q=%23getting-started) • [Contributing](https://www.google.com/search?q=%23contributing)

---

## Features

### Cryptographic Security

* **End-to-End Encryption:** Zero-knowledge architecture ensuring absolute message privacy. Cryptographic primitives are implemented via TweetNaCl/libsodium.
* **Metadata Privacy:** Designed to minimize data footprints, with optional Tor routing infrastructure for network-level anonymity.

### Native Engineering

* **Dedicated iOS Client:** Built natively using Swift and SwiftUI, featuring optimized local storage and native call screen integration.
* **Dedicated Android Client:** Architected natively using Kotlin and Jetpack Compose, maximizing battery efficiency and background processing performance.
* **Web Client:** Fully responsive, type-safe web implementation engineered with TypeScript and React.

### Real-Time Infrastructure

* **Low-Latency Transport:** Distributed messaging framework powered by WebSockets for instantaneous delivery status, typing awareness, and presence states.
* **Media and Signaling Engine:** Optimized pipelines for file transfers, real-time audio/video signaling via WebRTC, and interactive messaging threads.

---

## Architecture

### System Topology

The platform implements a decoupled, layered microservices topology optimized for high concurrency and fault isolation:

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
└──────────────────┴──────────────────────────────────┘

```

### Component Breakdown

* **Frontend Engine:** Divided into discrete repositories by platform target: `/ios` (SwiftUI native), `/android` (Kotlin native), and `/client` (React SPA).
* **Backend Core:** Located in `/server`, leveraging Elixir and the Phoenix Framework to handle massive concurrent WebSocket connections via Phoenix Channels.
* **Storage Layer:** Relies on PostgreSQL for relational metadata persistence alongside an encrypted file storage module for media components.

### Execution Flow: Secure Message Transmission

```
[User A]                               [Backend]                               [User B]
   │                                       │                                       │
   │ 1. Encrypt via Recipient Public Key   │                                       │
   ├──────────────────────────────────────>│                                       │
   │ 2. Emit payload over WebSocket        │                                       │
   │                                       │ 3. Evaluate state & persist payload   │
   │                                       ├──────────────────────────────────────>│
   │                                       │ 4. Push over active socket channel    │
   │                                       │    (or queue fallback notification)   │
   │                                       │                                       │ 5. Receive payload
   │                                       │                                       │ 6. Decrypt via Private Key

```

---

## Tech Stack

| Layer | Component | Description |
| --- | --- | --- |
| **iOS** | Swift, SwiftUI | Native Client Application |
| **Android** | Kotlin, Jetpack Compose | Native Client Application |
| **Web** | React, TypeScript, Vite | Web Platform Interface |
| **Backend** | Elixir, Phoenix Framework | High-Concurrency Event & API Server |
| **Database** | PostgreSQL | Relational Database Engine |
| **Real-time** | Phoenix Channels (WebSockets) | Live State Broadcast Pipeline |
| **Cryptography** | TweetNaCl, libsodium | End-to-End Encryption Layer |
| **Containerization** | Docker | Environment Standardization |

---

## Getting Started

### System Prerequisites

* Elixir 1.14+ / Erlang 25+
* PostgreSQL 14+
* Node.js 18+
* Xcode 14+ (for iOS compilation)
* Android Studio (for Android compilation)

### Initialization Sequence

#### Backend Services

```bash
cd server
mix deps.get
mix ecto.create
mix ecto.migrate
mix phx.server

```

#### Web Client

```bash
cd client
npm install
npm run dev

```

#### iOS Environment

```bash
cd ios
pod install
open Vibe.xcworkspace

```

#### Android Environment

```bash
cd android
./gradlew assembleDebug

```

---

## Project Structure

```
vibe/
├── android/              # Android native codebase
│   ├── app/             # Application configuration
│   └── chat-module/     # Native core messenger modules
├── ios/                 # iOS native codebase
│   ├── ChatModule/      # Encryption and signaling drivers
│   └── Sources/         # SwiftUI interface definitions
├── server/              # Elixir application runtime
│   ├── lib/vibe/        # Core business rules
│   ├── lib/vibe_web/    # Endpoint and protocol routing
│   └── priv/repo/       # Database schemas and migrations
├── client/              # React single-page client
│   ├── src/             # Application components
│   └── public/          # Static distribution assets
├── scripts/             # Automation tools and delivery helpers
├── docs/                # Architecture specifications
├── Dockerfile           # Base container image properties
└─ docker-compose.yml   # Multi-container declaration

```

---

## Quality Assurance & Verification

### Execution of Test Suites

```bash
# Backend Verification
cd server && mix test

# Web Client Verification
cd client && npm test

# iOS Scheme Verification
cd ios && xcodebuild test -scheme Vibe

# Android Verification
cd android && ./gradlew test

```

### Formatting Standards

The codebase enforces automated styling standards across all boundary layers:

* **TypeScript:** ESLint
* **Elixir:** Credo
* **Swift:** SwiftLint
* **Kotlin:** Ktlint

---

## Security Paradigm

* **Zero Server Ledger:** The infrastructure functions entirely on a zero-knowledge paradigm; private keys reside strictly within hardware-isolated device storage.
* **Auditability:** The cryptography implementation relies on transparent, un-modified open-source libraries.
* **No Telemetry Tracking:** The platform explicitly bars data aggregation, usage analytics, or system logging.

---

## Deployment Architectures

Comprehensive deployment manifests are documented within the `/docs/deployment/` directory, detailing requirements for:

* Standard Docker Containerization
* High-Availability Infrastructure Hosting
* Self-Hosted Bare Metal Environments

---

## Project Roadmap

* [ ] End-to-end encrypted multi-party voice signaling
* [ ] Distributed group key exchange protocols
* [ ] Encrypted local search indices
* [ ] Hardware key pairing and localized backup restoration
* [ ] Secure cloud storage integration matrices
* [ ] Native Desktop distributions via Electron

---

## Contributing

Contributions are reviewed via structured Pull Requests. Please review the specific guidelines before submission:

1. Fork the codebase repository.
2. Isolate changes within a distinct feature branch: `git checkout -b feature/implementation-name`.
3. Provide granular, atomic commits utilizing conventional commit standards.
4. Verify execution of all localized test suites prior to submission.
5. Open a Pull Request targeting the primary upstream branch.

---

## License

This project is licensed under the terms specified in the [LICENSE](https://www.google.com/search?q=LICENSE) file.

---

## Project Documentation

* **Technical Specifications:** Located within the `/docs` path.
* **Issue Tracking:** Available through the primary code repository interface.
* **Defect Reporting:** Please submit structured tickets via the designated reporting tool.