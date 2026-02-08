# Android Auto Favorites Lists & Song Metadata Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add favorite lists (separate sections), a favorite toggle action, and song metadata display to Android Auto via the flutter_carplay library, matching the CarPlay experience.

**Architecture:** Clone flutter_carplay locally inside this repo, switch the pubspec dependency to a path reference, then extend the library's Android Auto Dart models and Kotlin native code to support: (1) `Row.addAction` for a favorite toggle button, (2) `Row.addText` for song metadata subtitle, (3) two-section lists (Favorites + All Stations) with dynamic re-rendering via `setRootTemplate`. Since Android Auto's `Row` supports `addAction(Action)` with icons and `addText(CarText)` for subtitles, we can render favorites and metadata natively. We use `setRootTemplate` to rebuild the entire template when favorites or song metadata change (Android Auto doesn't support partial updates).

**Tech Stack:** Flutter/Dart, Kotlin (Android Car App Library 1.7.0), flutter_carplay (local fork)

---

## Task 1: Clone flutter_carplay into the repo

**Files:**
- Create: `packages/flutter_carplay/` (git clone)
- Modify: `pubspec.yaml` (change dependency to local path)

**Step 1: Clone the repository**

```bash
cd /Users/iosif/Documents/Projects/radio-crestin-mobile-app
mkdir -p packages
git clone https://github.com/oguzhnatly/flutter_carplay.git packages/flutter_carplay
```

**Step 2: Remove git history from cloned repo**

```bash
rm -rf packages/flutter_carplay/.git
```

**Step 3: Update pubspec.yaml to use local path**

In `pubspec.yaml`, change:
```yaml
flutter_carplay: ^1.2.3
```
to:
```yaml
flutter_carplay:
  path: packages/flutter_carplay
```

**Step 4: Verify it resolves**

```bash
flutter pub get
```

Expected: No errors, dependency resolves from local path.

**Step 5: Commit**

```bash
git add packages/flutter_carplay pubspec.yaml pubspec.lock
git commit -m "chore: vendor flutter_carplay locally for Android Auto customization"
```

---

## Task 2: Add `actions` support to AAListItem (Dart layer)

**Files:**
- Modify: `packages/flutter_carplay/lib/aa_models/list/list_item.dart`

**Step 1: Add actions field to AAListItem**

Replace the full file content of `packages/flutter_carplay/lib/aa_models/list/list_item.dart`:

```dart
import 'package:uuid/uuid.dart';

/// Represents an action button on an Android Auto list item row.
class AAListItemAction {
  final String title;
  final String? iconName; // Android resource name e.g. "ic_favorite"
  final Function()? onPress;

  AAListItemAction({
    required this.title,
    this.iconName,
    this.onPress,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'iconName': iconName,
        'onPress': onPress != null ? true : false,
      };
}

class AAListItem {
  /// Unique id of the object.
  final String _elementId;

  final String title;
  final String? subtitle;
  final String? imageUrl;
  final Function(Function() complete, AAListItem self)? onPress;
  final List<AAListItemAction> actions;

  AAListItem({
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.onPress,
    this.actions = const [],
  }) : _elementId = const Uuid().v4();

  String get uniqueId => _elementId;

  Map<String, dynamic> toJson() => {
        '_elementId': _elementId,
        'title': title,
        'subtitle': subtitle,
        'imageUrl': imageUrl,
        'onPress': onPress != null ? true : false,
        'actions': actions.map((a) => a.toJson()).toList(),
      };
}
```

**Step 2: Verify no Dart analysis errors**

```bash
cd packages/flutter_carplay && dart analyze lib/aa_models/list/list_item.dart
```

Expected: No errors.

**Step 3: Commit**

```bash
git add packages/flutter_carplay/lib/aa_models/list/list_item.dart
git commit -m "feat(flutter_carplay): add actions support to AAListItem Dart model"
```

---

## Task 3: Add `actions` support to FAAListItem (Kotlin native layer)

**Files:**
- Modify: `packages/flutter_carplay/android/src/main/kotlin/com/oguzhnatly/flutter_android_auto/models/list/FAAListItem.kt`
- Modify: `packages/flutter_carplay/android/src/main/kotlin/com/oguzhnatly/flutter_android_auto/FlutterAndroidAutoPlugin.kt`
- Modify: `packages/flutter_carplay/android/src/main/kotlin/com/oguzhnatly/flutter_android_auto/FAAEnums.kt`

**Step 1: Add FAAListItemAction model and update FAAListItem**

Replace `packages/flutter_carplay/android/src/main/kotlin/com/oguzhnatly/flutter_android_auto/models/list/FAAListItem.kt`:

```kotlin
package com.oguzhnatly.flutter_android_auto

data class FAAListItemAction(
    val title: String,
    val iconName: String? = null,
    val isOnPressListenerActive: Boolean,
) {
    companion object {
        fun fromJson(map: Map<String, Any?>): FAAListItemAction {
            val title = map["title"] as? String ?: ""
            val iconName = map["iconName"] as? String
            val isOnPressListenerActive = map["onPress"] as? Boolean ?: false
            return FAAListItemAction(title, iconName, isOnPressListenerActive)
        }
    }
}

data class FAAListItem(
    val elementId: String,
    val title: String,
    val subtitle: String? = null,
    val imageUrl: String? = null,
    val isOnPressListenerActive: Boolean,
    val actions: List<FAAListItemAction> = emptyList(),
) {
    companion object {
        fun fromJson(map: Map<String, Any?>): FAAListItem {
            val elementId = map["_elementId"] as? String ?: ""
            val title = map["title"] as? String ?: ""
            val subtitle = map["subtitle"] as? String
            val imageUrl = map["imageUrl"] as? String
            val isOnPressListenerActive = map["onPress"] as? Boolean ?: false
            val actionsRaw = map["actions"] as? List<*> ?: emptyList<Any>()
            val actions = actionsRaw.mapNotNull { raw ->
                (raw as? Map<String, Any?>)?.let { FAAListItemAction.fromJson(it) }
            }
            return FAAListItem(
                elementId, title, subtitle, imageUrl, isOnPressListenerActive, actions
            )
        }
    }
}
```

**Step 2: Add action event channel type to FAAEnums.kt**

Add `onListItemActionPressed` to the `FAAChannelTypes` enum in `packages/flutter_carplay/android/src/main/kotlin/com/oguzhnatly/flutter_android_auto/FAAEnums.kt`:

```kotlin
package com.oguzhnatly.flutter_android_auto

enum class FAAConnectionTypes {
    connected,
    background,
    disconnected,
}

enum class FAAChannelTypes {
    onAndroidAutoConnectionChange,
    setRootTemplate,
    forceUpdateRootTemplate,
    pushTemplate,
    popTemplate,
    popToRootTemplate,
    onListItemSelected,
    onListItemSelectedComplete,
    onScreenBackButtonPressed,
    onListItemActionPressed,
}
```

**Step 3: Update `createRowFromItem` in FlutterAndroidAutoPlugin.kt to render actions**

In `packages/flutter_carplay/android/src/main/kotlin/com/oguzhnatly/flutter_android_auto/FlutterAndroidAutoPlugin.kt`, replace the `createRowFromItem` method:

```kotlin
// Helper function to create a Row from an FAAListItem, avoiding code duplication
private suspend fun createRowFromItem(item: FAAListItem): Row {
    val rowBuilder = Row.Builder().setTitle(CarText.create(item.title))

    item.subtitle?.let { rowBuilder.addText(CarText.create(it)) }

    item.imageUrl?.let {
        loadCarImageAsync(it)?.let { carIcon ->
            rowBuilder.setImage(carIcon)
        }
    }

    if (item.isOnPressListenerActive) {
        rowBuilder.setOnClickListener {
            sendEvent(
                type = FAAChannelTypes.onListItemSelected.name,
                data = mapOf("elementId" to item.elementId)
            )
        }
    }

    // Add action buttons to the row
    for ((index, action) in item.actions.withIndex()) {
        val actionBuilder = Action.Builder()
            .setTitle(CarText.create(action.title))

        // Load icon if specified
        action.iconName?.let { iconName ->
            val context = AndroidAutoService.session?.carContext
            if (context != null) {
                val resId = context.resources.getIdentifier(
                    iconName, "drawable", context.packageName
                )
                if (resId != 0) {
                    val icon = androidx.core.graphics.drawable.IconCompat.createWithResource(
                        context, resId
                    )
                    actionBuilder.setIcon(CarIcon.Builder(icon).build())
                }
            }
        }

        if (action.isOnPressListenerActive) {
            actionBuilder.setOnClickListener {
                sendEvent(
                    type = FAAChannelTypes.onListItemActionPressed.name,
                    data = mapOf(
                        "elementId" to item.elementId,
                        "actionIndex" to index
                    )
                )
            }
        }

        rowBuilder.addAction(actionBuilder.build())
    }

    return rowBuilder.build()
}
```

Also add the import at the top of the file:
```kotlin
import androidx.core.graphics.drawable.IconCompat
```

**Step 4: Verify the Kotlin compiles**

```bash
cd /Users/iosif/Documents/Projects/radio-crestin-mobile-app && flutter build apk --debug 2>&1 | tail -20
```

Expected: Build succeeds (or at least no Kotlin compilation errors in the flutter_carplay module).

**Step 5: Commit**

```bash
git add packages/flutter_carplay/android/
git commit -m "feat(flutter_carplay): add Row action support in Android Auto native layer"
```

---

## Task 4: Handle action events in Dart controller & worker

**Files:**
- Modify: `packages/flutter_carplay/lib/controllers/android_auto_controller.dart`
- Modify: `packages/flutter_carplay/lib/android_auto_worker.dart`
- Modify: `packages/flutter_carplay/lib/constants/private_constants.dart` (if FAAChannelTypes defined there)

**Step 1: Check where FAAChannelTypes is defined in Dart**

Look in `packages/flutter_carplay/lib/constants/private_constants.dart` — it likely has the Dart-side enum. Add `onListItemActionPressed` to match the Kotlin enum.

**Step 2: Add action event handling to `android_auto_worker.dart`**

In the `switch (receivedChannelType)` block, add a new case:

```dart
case FAAChannelTypes.onListItemActionPressed:
  _androidAutoController.processFAAListItemActionChannel(
    event['data']['elementId'],
    event['data']['actionIndex'],
  );
  break;
```

**Step 3: Add `processFAAListItemActionChannel` to the controller**

In `packages/flutter_carplay/lib/controllers/android_auto_controller.dart`, add:

```dart
void processFAAListItemActionChannel(String elementId, int actionIndex) {
  for (final template in templateHistory) {
    if (template is AAListTemplate) {
      for (final section in template.sections) {
        for (final item in section.items) {
          if (item.uniqueId == elementId && actionIndex < item.actions.length) {
            item.actions[actionIndex].onPress?.call();
            return;
          }
        }
      }
    }
  }
}
```

**Step 4: Verify Dart analysis**

```bash
cd packages/flutter_carplay && dart analyze lib/
```

Expected: No errors.

**Step 5: Commit**

```bash
git add packages/flutter_carplay/lib/
git commit -m "feat(flutter_carplay): handle action button events from Android Auto"
```

---

## Task 5: Implement favorite lists and metadata in car_play_service.dart

**Files:**
- Modify: `lib/services/car_play_service.dart`

**Step 1: Rewrite `_setupAndroidAutoWithStations` to use two sections + actions + metadata**

Replace the `_setupAndroidAutoWithStations` method and add supporting methods:

```dart
void _setupAndroidAutoWithStations(List<Station> stations) {
  if (_androidAutoInitialized) {
    _log("Android Auto already initialized, skipping setup");
    return;
  }

  try {
    _log("Setting up Android Auto with ${stations.length} stations");

    // Sort stations alphabetically by title
    _sortedAndroidAutoStations = List<Station>.from(stations);
    _sortedAndroidAutoStations.sort(
      (a, b) => a.title.toString().compareTo(b.title.toString()),
    );

    _rebuildAndroidAutoTemplate();

    // Listen for favorites changes to rebuild the template
    _androidAutoFavoritesSubscription = _audioHandler.favoriteStationSlugs.stream.listen((_) {
      _rebuildAndroidAutoTemplate();
    });

    // Listen for station changes to update metadata
    _androidAutoStationSubscription = _audioHandler.currentStation.stream.listen((_) {
      _rebuildAndroidAutoTemplate();
    });

    _androidAutoInitialized = true;
    _log("Android Auto setup complete");
  } catch (e) {
    _log("Error setting up Android Auto: $e");
  }
}

void _rebuildAndroidAutoTemplate() {
  final favoriteSlugs = _audioHandler.favoriteStationSlugs.value;
  final currentSlug = _audioHandler.currentStation.value?.slug;

  // Build favorite stations list
  final favoriteStations = _sortedAndroidAutoStations
      .where((s) => favoriteSlugs.contains(s.slug))
      .toList();

  AAListItem _buildItem(Station station) {
    final isFavorite = favoriteSlugs.contains(station.slug);
    final isPlaying = station.slug == currentSlug;

    // Build subtitle with song metadata
    String? subtitle;
    if (isPlaying && station.songTitle != null && station.songTitle!.isNotEmpty) {
      subtitle = station.songArtist != null && station.songArtist!.isNotEmpty
          ? "${station.songArtist} - ${station.songTitle}"
          : station.songTitle;
    }

    return AAListItem(
      title: isPlaying ? "▶ ${station.title}" : station.title,
      subtitle: subtitle,
      imageUrl: station.thumbnailUrl,
      onPress: (complete, item) {
        _log("Android Auto: Station selected: ${station.title}");
        _audioHandler.carPlayPlaylist = List.from(_sortedAndroidAutoStations);
        _audioHandler.selectStation(station);
        complete();
        _audioHandler.play();
      },
      actions: [
        AAListItemAction(
          title: isFavorite ? "★" : "☆",
          onPress: () {
            _audioHandler.setStationIsFavorite(station, !isFavorite);
          },
        ),
      ],
    );
  }

  final List<AAListSection> sections = [];

  // Add favorites section if there are favorites
  if (favoriteStations.isNotEmpty) {
    sections.add(AAListSection(
      title: "Favorite",
      items: favoriteStations.map(_buildItem).toList(),
    ));
  }

  // Add all stations section
  sections.add(AAListSection(
    title: "Toate statiile",
    items: _sortedAndroidAutoStations.map(_buildItem).toList(),
  ));

  final listTemplate = AAListTemplate(
    title: "Radio Crestin",
    sections: sections,
  );

  FlutterAndroidAuto.setRootTemplate(template: listTemplate);
}
```

**Step 2: Add the new instance variables at class level**

Add these fields to the `CarPlayService` class:

```dart
// Android Auto state
List<Station> _sortedAndroidAutoStations = [];
StreamSubscription? _androidAutoFavoritesSubscription;
StreamSubscription? _androidAutoStationSubscription;
```

**Step 3: Update `dispose` to cancel new subscriptions**

```dart
_androidAutoFavoritesSubscription?.cancel();
_androidAutoStationSubscription?.cancel();
```

**Step 4: Remove `_androidAutoInitialized` guard from `_rebuildAndroidAutoTemplate`**

The `_rebuildAndroidAutoTemplate` method should NOT check `_androidAutoInitialized` since it's called for dynamic updates after initialization.

**Step 5: Verify build**

```bash
flutter build apk --debug 2>&1 | tail -20
```

Expected: Build succeeds.

**Step 6: Commit**

```bash
git add lib/services/car_play_service.dart
git commit -m "feat: add favorite lists, toggle actions, and song metadata to Android Auto"
```

---

## Task 6: Add favorite icon drawable resources for Android Auto

**Files:**
- Create: `android/app/src/main/res/drawable/ic_favorite.xml`
- Create: `android/app/src/main/res/drawable/ic_favorite_border.xml`

**Step 1: Create filled favorite icon**

Create `android/app/src/main/res/drawable/ic_favorite.xml`:

```xml
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FF0000"
        android:pathData="M12,21.35l-1.45,-1.32C5.4,15.36 2,12.28 2,8.5 2,5.42 4.42,3 7.5,3c1.74,0 3.41,0.81 4.5,2.09C13.09,3.81 14.76,3 16.5,3 19.58,3 22,5.42 22,8.5c0,3.78 -3.4,6.86 -8.55,11.54L12,21.35z"/>
</vector>
```

**Step 2: Create border favorite icon**

Create `android/app/src/main/res/drawable/ic_favorite_border.xml`:

```xml
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FFFFFF"
        android:pathData="M16.5,3c-1.74,0 -3.41,0.81 -4.5,2.09C10.91,3.81 9.24,3 7.5,3 4.42,3 2,5.42 2,8.5c0,3.78 3.4,6.86 8.55,11.54L12,21.35l1.45,-1.32C18.6,15.36 22,12.28 22,8.5 22,5.42 19.58,3 16.5,3zM12.1,18.55l-0.1,0.1 -0.1,-0.1C7.14,14.24 4,11.39 4,8.5 4,6.5 5.5,5 7.5,5c1.54,0 3.04,0.99 3.57,2.36h1.87C13.46,5.99 14.96,5 16.5,5c2,0 3.5,1.5 3.5,3.5 0,2.89 -3.14,5.74 -7.9,10.05z"/>
</vector>
```

**Step 3: Update Task 5's `_buildItem` to use icon names**

In the `actions` list of `_buildItem`, use icon resources instead of text symbols:

```dart
actions: [
  AAListItemAction(
    title: isFavorite ? "Unfavorite" : "Favorite",
    iconName: isFavorite ? "ic_favorite" : "ic_favorite_border",
    onPress: () {
      _audioHandler.setStationIsFavorite(station, !isFavorite);
    },
  ),
],
```

**Step 4: Commit**

```bash
git add android/app/src/main/res/drawable/ lib/services/car_play_service.dart
git commit -m "feat: add favorite icon drawables for Android Auto actions"
```

---

## Task 7: Test end-to-end on Android Auto emulator

**Step 1: Build and run**

```bash
flutter run -d <android_device>
```

**Step 2: Verify in Android Auto Desktop Head Unit or emulator**

- Launch Android Auto DHU
- Verify two sections appear: "Favorite" and "Toate statiile"
- Verify favorite toggle action buttons appear on each row
- Tap a station, verify playback starts
- Tap the favorite action, verify the template rebuilds with the station now in the Favorites section
- Verify song metadata (artist - title) appears as subtitle on the playing station
- Verify the playing station shows ▶ prefix

**Step 3: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix: Android Auto end-to-end testing adjustments"
```

---

## Important Notes

### Android Auto Row Constraints
- `Row.addAction()` requires Car API level 6+ (supported by `androidx.car.app:app:1.7.0`)
- A Row can have max 2 actions
- Actions with icons require the icon as an Android drawable resource (not a URL)
- A Row cannot have both a Toggle and Actions simultaneously

### Template Refresh Strategy
- Android Auto does NOT support partial list updates like CarPlay's `updateListTemplateSections`
- We call `FlutterAndroidAuto.setRootTemplate()` to fully rebuild the template on each change
- This causes a brief UI flash but is the only supported approach
- We debounce by only rebuilding when favorites or current station actually change

### Potential Issues
- `Row.addAction` might fail silently if the car's API level is too low — need to test on DHU
- Android Auto limits lists to ~12 items per section in some car head units — may need pagination for "Toate statiile"
- Icon resources must be in the **app's** `drawable` folder, not the library's, since `context.packageName` resolves to the app
