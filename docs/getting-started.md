# Getting Started

## Prerequisites

### All Platforms
- Git 2.40+
- 8GB RAM minimum
- 10GB disk space

### Backend (Server)
- **Elixir** 1.14+
- **Erlang** 25+
- **PostgreSQL** 14+

### Web Client
- **Node.js** 18+
- **npm** 9+ or **yarn** 3+

### iOS
- **macOS** 12+
- **Xcode** 14+
- **CocoaPods** 1.11+

### Android
- **Android Studio** Flamingo+
- **JDK** 17+
- **Android SDK** 26+

---

## Development Environment Setup

### 1. Clone Repository

```bash
git clone https://github.com/Vibe-source/Vibe.git
cd Vibe
```

### 2. Backend Setup

```bash
cd server

# Install dependencies
mix deps.get

# Create and migrate database
mix ecto.create
mix ecto.migrate

# Start development server
mix phx.server
```

Server will be available at `http://localhost:4000`

**Common Issues:**
- PostgreSQL not running: `brew services start postgresql`
- Database exists: `mix ecto.drop` then create again
- Port 4000 in use: `mix phx.server -p 4001`

### 3. Web Client Setup

```bash
cd client

# Install dependencies
npm install

# Start development server
npm run dev
```

Web app will be available at `http://localhost:5173`

**Development Commands:**
```bash
npm run build    # Production build
npm run lint     # Run ESLint
npm test         # Run tests
npm run preview  # Preview production build
```

### 4. iOS Setup

```bash
cd ios

# Generate Xcode project from XcodeGen config
xcodegen generate

# Install CocoaPods dependencies
pod install

# Open workspace
open Vibe.xcworkspace
```

**In Xcode:**
1. Select "Vibegram" scheme (top left)
2. Choose simulator or connected device
3. Press Cmd+R to build and run

**Common Issues:**
- CocoaPods outdated: `pod repo update`
- Swift compilation errors: Clean build folder (Cmd+Shift+K)
- iOS version mismatch: Adjust deployment target in project.yml

### 5. Android Setup

```bash
cd android

# Build debug APK
./gradlew assembleDebug

# Install on connected device
./gradlew installDebug

# Or use Android Studio
# 1. Open android/ folder in Android Studio
# 2. Wait for Gradle sync
# 3. Click Run (Shift+F10)
```

**Common Issues:**
- Gradle sync failing: File → Invalidate Caches
- Emulator not starting: Try different AVD or physical device
- Build fails: `./gradlew clean build`

---

## Environment Configuration

### Backend (.env)

Create `server/.env.local`:

```env
DATABASE_URL=postgres://user:password@localhost/vibe_dev
SECRET_KEY_BASE=your-secret-key
CORS_ORIGIN=http://localhost:5173
PHX_PORT=4000
```

### Web Client (.env)

Create `client/.env.local`:

```env
VITE_API_URL=http://localhost:4000
VITE_WS_URL=ws://localhost:4000/socket
```

### iOS

Update `ios/project.yml` with your development team:

```yaml
settings:
  base:
    DEVELOPMENT_TEAM: YOUR_TEAM_ID
```

---

## Testing

### Backend Tests

```bash
cd server

# Run all tests
mix test

# Run specific test file
mix test test/vibe_web/controllers/user_controller_test.exs

# Watch mode
mix test.watch
```

### Web Tests

```bash
cd client

# Run tests
npm test

# Watch mode
npm test -- --watch

# Coverage report
npm test -- --coverage
```

### iOS Tests

```bash
cd ios

# Run tests in Xcode
xcodebuild test -scheme Vibe -destination 'platform=iOS Simulator,name=iPhone 14'

# Or in Xcode: Cmd+U
```

### Android Tests

```bash
cd android

# Run unit tests
./gradlew test

# Run instrumented tests (requires emulator)
./gradlew connectedAndroidTest
```

---

## Development Workflow

### Creating a Feature

```bash
# 1. Create feature branch
git checkout -b feature/my-feature

# 2. Make changes and test locally
# 3. Commit with clear messages
git commit -m "feat: add user authentication"

# 4. Push and create Pull Request
git push origin feature/my-feature
```

### Code Style

- **Elixir**: Run `mix credo` before committing
- **TypeScript**: ESLint runs on save
- **Swift**: SwiftLint enforces style
- **Kotlin**: Ktlint with spotless

### Debugging

**Backend**
```bash
# IEx shell with running server
iex -S mix phx.server

# Inspect queries in development
# (logs shown in server console)
```

**Web**
```bash
# DevTools: F12 or right-click → Inspect
# Network tab shows API calls
# Console logs from client
```

**iOS**
```bash
# Xcode Debugger: Cmd+B then click breakpoint
# Console: View → Debug Area
# Network: Use proxy like Proxyman
```

**Android**
```bash
# Android Studio Debugger
# Run → Debug 'app'
# Logcat: View → Tool Windows → Logcat
```

---

## Connecting All Components

### Local Development

Once all three are running:

1. **Backend**: `http://localhost:4000`
2. **Web**: `http://localhost:5173`
3. **iOS Simulator**: Configured to use `localhost:4000`
4. **Android Emulator**: Configured to use `10.0.2.2:4000`

### Testing Flow

```
Web Client → API Server → PostgreSQL
              ↕
        WebSocket Channel
              ↕
       iOS/Android Clients
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Port already in use | Use different port: `mix phx.server -p 4001` |
| Database connection failed | Check PostgreSQL is running and credentials match |
| npm install slow | Clear npm cache: `npm cache clean --force` |
| Pod install fails | Update CocoaPods: `sudo gem install cocoapods` |
| Gradle sync stuck | Invalidate caches in Android Studio |
| WebSocket connection fails | Check CORS and server is running |

---

## Next Steps

- Read [Architecture](architecture.md) to understand the system
- Explore [API Reference](api.md) for endpoints
- Check [Contributing](contributing.md) for development guidelines
- See [Deployment](deployment.md) for production setup
