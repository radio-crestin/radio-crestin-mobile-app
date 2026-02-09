# Radio Crestin - Flutter Mobile App

## Project Overview

Radio Crestin is a production Flutter app for streaming Romanian Christian radio stations. It supports background audio, CarPlay (iOS), Android Auto, NFC tag writing, deep linking, and push notifications. The app is live on both app stores.

**Version:** 1.3.2+56
**Min Android SDK:** 21 | **Min iOS:** (CocoaPods managed)
**API:** GraphQL at `https://api.radiocrestin.ro/v1/graphql` (public token auth)

---

## Architecture

### Dependency Injection
- **GetIt** for service location. All singletons registered in `main.dart`.
- Registration order matters: `ImageCacheService` before `AppAudioHandler` before `CarPlayService`.

### State Management
- **RxDart `BehaviorSubject`** streams centralized in `AppAudioHandler`.
- Widgets subscribe in `initState()`, dispose in `dispose()`. No Provider/Riverpod.
- Pattern:
  ```dart
  _subscriptions.add(audioHandler.currentStation.stream.listen((value) {
    setState(() { _station = value; });
  }));
  ```
- Always cancel subscriptions in `dispose()` to prevent leaks.

### Data Flow
```
GraphQL API --> AppAudioHandler (BehaviorSubject streams) --> UI Widgets
                     |                                           |
                     v                                           v
              ImageCacheService                          CarPlayService
              (disk cache)                          (iOS CarPlay / Android Auto)
```

### Key Services
| Service | File | Purpose |
|---------|------|---------|
| `AppAudioHandler` | `lib/appAudioHandler.dart` | Core audio + all app state. Polls stations every 5s. |
| `ImageCacheService` | `lib/services/image_cache_service.dart` | MD5-based disk image cache at `Documents/image_cache/` |
| `CarPlayService` | `lib/services/car_play_service.dart` | CarPlay (Swift) + Android Auto (Kotlin) integration |
| `ShareService` | `lib/services/share_service.dart` | GraphQL mutation for share links |

### Local Packages
- `packages/flutter_carplay/` - Custom CarPlay/Android Auto plugin with native Kotlin and Swift code.

---

## Design System

### Brand Colors
| Token | Hex | Usage |
|-------|-----|-------|
| `AppColors.primary` | `#E91E63` | Brand pink. Buttons, accents, bottom bar. |
| `AppColors.primaryLight` | `#F8BBD0` | Hover states, selections. |
| `AppColors.primaryDark` | `#8F0133` | Dark mode bottom bar, pressed states. |
| `AppColors.error` | `#D32F2F` | Error states. |
| `AppColors.success` | `Colors.green` | Online/success indicators. |
| `AppColors.offline` | `Colors.red` | Offline station indicator. |

### Theme Architecture
- **Material 3** enabled (`useMaterial3: true`) for both light and dark themes.
- Themes defined in `lib/theme.dart`. Light: `lightTheme`, Dark: `darkTheme`.
- Theme mode persisted via `ThemeManager` (`lib/theme_manager.dart`).
- Custom extension: `Theme.of(context).cardColorSelected` for selected station cards.
- Always use `AppColors` constants - never hardcode hex values in widgets.

### Light Theme
- Background: `#FAFAFA` | Surface: `#FFFFFF`
- Text: `#000000` (primary), `54% black` (secondary)
- Card: `#E4E4E4` at 54% opacity | Selected card: `#CFCFCF`

### Dark Theme
- Background: `#121212` | Surface: `#1E1E1E`
- Text: `#FFFFFF` (primary), `70% white` (secondary)
- Selected card: `#353535` | Bottom bar: `#75002C`

### Typography
- Material default font family (no custom font).
- App bar title: 19px, bold, `grey.shade800` (light) / `grey.shade200` (dark).
- Body text: Material `bodySmall`, `labelLarge`, `titleSmall` styles.

### Spacing & Layout
- Station list items: **105px** fixed height (`SliverFixedExtentList`).
- Station thumbnails: **70x70px**, rounded corners.
- Mini player thumbnail: **52px**.
- Standard padding: 8px (tight), 12px (medium), 16px (standard).
- Border radius: 4px (inputs), 12-16px (cards, dialogs).
- Icon size: 24px default.

---

## Animation Standards

### Required Animation Patterns

Every new UI component MUST use smooth transitions. No abrupt state changes.

**1. AnimatedSwitcher (Primary Pattern)**
Use for all content that changes dynamically (text, images, icons):
```dart
AnimatedSwitcher(
  duration: const Duration(milliseconds: 250),
  child: MyWidget(key: ValueKey(uniqueIdentifier)),
)
```
- Duration: **250ms** for content, **150ms** for icons/small elements.
- Always provide a unique `ValueKey` on the child.
- Used in: station thumbnails, song metadata, play button icons.

**2. Optimistic Intent Pattern (AnimatedPlayButton)**
The `AnimatedPlayButton` (`lib/widgets/animated_play_button.dart`) uses a two-layer approach:
- **Layer 1 - User Intent:** Instant visual feedback on tap (optimistic).
- **Layer 2 - Stream Truth:** Actual audio_service state. Wins after 3s grace period.
- Shows `CircularProgressIndicator` during buffering.
- Skip buttons call `notifyWillPlay()` to set optimistic state.

**3. SlidingUpPanel**
- Full-screen player opens via `SlidingUpPanel2` with `CustomPanelController`.
- Manages drag state via `isDraggable` flag.
- Smooth transition between mini player and full player.

**4. Implicit Animations**
Use for color, size, and opacity changes:
- `AnimatedContainer` for card selection highlights.
- `AnimatedOpacity` for fade-in/out of overlays.

### Animation Rules
- Minimum duration: **150ms** (micro-interactions), Maximum: **400ms** (layout transitions).
- Always use `const Duration(...)` - never dynamic durations.
- Use `Curves.easeInOut` as default curve. `Curves.fastOutSlowIn` for entrances.
- Never animate layout properties that trigger relayout (prefer `Transform`, `Opacity`).
- Loading spinners: `CircularProgressIndicator` with `strokeWidth: 2.5` and brand color.

---

## File Structure

```
lib/
  main.dart                          # Entry point, DI setup, init orchestration
  appAudioHandler.dart               # Central state + audio service handler
  theme.dart                         # Light/dark ThemeData + AppColors
  theme_manager.dart                 # Theme persistence
  utils.dart                         # Global utilities (displayImage, etc.)
  constants.dart                     # API endpoint, auth token
  globals.dart                       # Runtime globals (FCM token, device ID)
  tracking.dart                      # Firebase Analytics
  performance_monitor.dart           # Performance profiling (no-op in release)
  resilient_hive_store.dart          # GraphQL cache with fallback
  graphql_to_rest_interceptor.dart   # GraphQL-to-REST bridge
  types/
    Station.dart                     # Station model wrapping GraphQL type
  services/
    image_cache_service.dart         # Disk image cache
    car_play_service.dart            # CarPlay + Android Auto
    share_service.dart               # Share link mutation
  components/
    FullAudioPlayer.dart             # Full-screen player (sliding panel)
    MiniAudioPlayer.dart             # Bottom mini player bar
    StationsList.dart                # Station list with sticky headers
    SelectDialog.dart                # Reusable search/select dialog
  pages/
    HomePage.dart                    # Main page (tabs + sliding panel)
    SettingsPage.dart                # Settings screen
    WriteNfcTag.dart                 # NFC tag writing
  widgets/
    animated_play_button.dart        # Two-layer optimistic play/pause button
    share_handler.dart               # Share dialog UI
    share_promotion_card.dart        # Share link promotion card
    share_utils.dart                 # Share message formatting
  utils/
    PositionRetainedScrollPhysics.dart
    share_utils.dart
  queries/
    *.graphql.dart                   # Generated GraphQL code (DO NOT EDIT)
```

---

## Code Quality Standards

### Naming Conventions
- **Files:** PascalCase for widgets/pages (`HomePage.dart`), snake_case for services/utils (`image_cache_service.dart`).
- **Classes:** PascalCase. State classes: `_MyWidgetState` (private) or `MyWidgetState` (public when exposed).
- **Streams:** Use noun form for `BehaviorSubject` names: `stations`, `currentStation`, `favoriteStationSlugs`.
- **Constants:** `_gracePeriod`, `_maxConcurrent` (private with underscore).

### Widget Rules
1. Prefer `const` constructors wherever possible.
2. Use `super.key` in constructors (not `Key? key`).
3. Dispose ALL subscriptions, timers, and controllers in `dispose()`.
4. Use `if (mounted)` before `setState()` in async callbacks.
5. Extract reusable widgets to `lib/widgets/`. Page-specific widgets stay in the page file.
6. Use `ValueKey` on `AnimatedSwitcher` children for correct animation.

### State Management Rules
1. All app-wide state lives in `AppAudioHandler` as `BehaviorSubject` streams.
2. Local UI state (panel position, scroll offset) stays in `State` classes.
3. Never directly mutate `BehaviorSubject.value` - use `.add()`.
4. Always seed `BehaviorSubject` with an initial value.
5. Persistence: `SharedPreferences` for simple values, Hive for GraphQL cache.

### Performance Rules
1. Use `SliverFixedExtentList` for long lists (not `ListView.builder`).
2. Use `ExtendedImage` with caching - never raw `Image.network`.
3. Image cache: Check `ImageCacheService.getCachedPath()` before network fetch.
4. Throttle concurrent image downloads (max 5 via `ImageCacheService`).
5. Defer non-critical init to post-frame callbacks (see `CarPlayService`).
6. Use `PerformanceMonitor` for profiling (automatically no-op in release).

### Error Handling
1. GraphQL: Use `ResilientHiveStore` - auto-falls back to `InMemoryStore`.
2. Image loading: Graceful fallback chain: disk cache -> network -> placeholder.
3. Audio: `AnimatedPlayButton` handles buffering/failure states automatically.
4. Never let exceptions crash the app - wrap external calls in try/catch.
5. Firebase Crashlytics captures all Flutter and platform errors.

---

## UX Guidelines

### Interactions
- **Tap station** -> Immediately starts playing (optimistic UI on play button).
- **Tap mini player** -> Slides up full player panel.
- **Swipe down full player** -> Returns to station list.
- **Long-press favorite** -> `like_button` animation with haptic feedback.
- **Pull-to-refresh** -> Refreshes station data from API.
- **Share** -> Blur backdrop dialog with social channel options.

### Feedback Principles
1. **Instant response:** Every tap must produce immediate visual feedback (optimistic UI, ripple, or animation).
2. **Loading states:** Show spinners for network operations. Never leave the user staring at a static screen.
3. **Graceful degradation:** If a station is offline, show status indicator but keep it in the list. If images fail, show fallback.
4. **No empty states:** Always show last-known data while refreshing. Use `cacheAndNetwork` GraphQL policy.
5. **Smooth transitions:** All content changes use `AnimatedSwitcher`. No visual jumps.

### Platform Behavior
- iOS: Respect safe areas, status bar insets, CarPlay integration.
- Android: Material ripple effects, Android Auto browsable media.
- Both: Background audio continues when app is in background or screen is off.

---

## Testing

### Test Location
- Unit tests: `test/` directory.
- Test helpers: `test/helpers/station_factory.dart` for mock station creation.

### Test Patterns
```dart
// Mock SharedPreferences
SharedPreferences.setMockInitialValues({'key': 'value'});

// Use BehaviorSubject for testable state
final subject = BehaviorSubject<Station?>.seeded(null);

// Verify stream emissions
expect(subject.stream, emitsInOrder([null, station]));
```

### What to Test
- State transitions in `AppAudioHandler` (favorites, navigation, filtering).
- Model serialization/deserialization (`Station.dart`).
- Utility functions (`utils.dart`).
- Service logic in isolation (mock HTTP/GraphQL).

### Running Tests
```bash
flutter test                    # All tests
flutter test test/favorites_test.dart  # Single file
flutter analyze                 # Static analysis
```

---

## Build & Run

```bash
flutter pub get                 # Install dependencies
flutter run                     # Debug run
flutter run --release           # Release run
flutter build apk --release     # Android APK
flutter build ios --release     # iOS build

# Code generation (GraphQL types)
dart run build_runner build --delete-conflicting-outputs

# Regenerate icons/splash
flutter pub run flutter_launcher_icons
flutter pub run flutter_native_splash:create
```

---

## GraphQL

### Generated Code - DO NOT EDIT
All files in `lib/queries/*.graphql.dart` and `lib/queries/schema.graphql.dart` are auto-generated by `graphql_codegen`. Edit the `.graphql` files and regenerate.

### Cache Strategy
- **Policy:** `cacheAndNetwork` with `mergeOptimistic` reread.
- **Storage:** `ResilientHiveStore` (Hive-backed with InMemory fallback).
- **Polling:** `watchQuery` with 5-second poll interval for live station data.

### REST Interceptor
`GraphQLToRestInterceptorLink` bridges GraphQL queries to REST endpoints when configured. Adds cache-busting timestamps and performance monitoring.

---

## Native Integration Checklist

When modifying CarPlay or Android Auto features:
- **iOS (Swift):** `packages/flutter_carplay/ios/` - CarPlay templates and delegates.
- **Android (Kotlin):** `packages/flutter_carplay/android/` - Media browsing and `FAAHelpers.kt` for image loading.
- **Dart bridge:** `lib/services/car_play_service.dart` - Orchestrates both platforms.
- **Image paths:** Native code must handle both `https://` URLs and `file://` cached paths.
- **Method channel:** `com.radiocrestin.nowplaying_buttons` for iOS CarPlay button events.

---

## Security

- **NEVER commit API keys, tokens, or credentials.** Scan staged files before every commit.
- The GraphQL auth token `"Token public"` is intentionally public (read-only API).
- Firebase config files (`firebase_options.dart`, `google-services.json`, `GoogleService-Info.plist`) are safe to commit per Firebase documentation.
- Do not log sensitive user data (device IDs, FCM tokens) in release builds.

---

## Common Pitfalls

1. **Don't edit `*.graphql.dart` files** - they are generated. Edit `.graphql` sources and run `build_runner`.
2. **GetIt registration order** - `ImageCacheService` must be registered before `AppAudioHandler`.
3. **Multi-engine conflicts** - CarPlay/Android Auto spawn separate Flutter engines. `ResilientHiveStore` handles concurrent Hive access.
4. **BehaviorSubject disposal** - Always cancel stream subscriptions. Leaks cause stale `setState()` calls on disposed widgets.
5. **Image cache paths** - `Station.artUri` returns `file://` URIs when cached. Native code (`FAAHelpers.kt`) must detect and handle both URL schemes.
6. **Pre-existing test issue** - `packages/flutter_carplay/example/test/widget_test.dart` has a missing import error. This is not related to the main app.
