# Install and set up Radio Crestin on every device

How a listener installs the app and turns on its extras, one section per device type.
Open it when writing a release, answering "how do I get it on my …?", or when a platform's install path changes.

Every release's notes link here, and the release presentation and video end with these sections, so
keep it true for the version being released (see [README.md](README.md)).

<!-- say: Here is how to get Radio Crestin on each of your devices. -->

## iPhone and iPad

<!-- say: On iPhone and iPad, install Radio Crestin from the App Store. Open it, tap a station, and it plays, also with the screen locked. To add a widget, touch and hold the Home Screen, tap Edit, then Add Widget, and pick Radio Crestin. And you can ask Siri: play R V E Constanta on Radio Crestin. -->

Needs iOS 15 or later.

1. Install **Radio Crestin** from the [App Store](https://apps.apple.com/app/6451270471).
2. Open it and tap a station: it plays at once, and keeps playing with the screen locked or in another app.
3. **Widgets:** touch and hold the Home Screen → **Edit** → **Add Widget** → **Radio Crestin**. Pick
   **Acum ascult** (small or medium: the song playing, with play/pause and previous/next) or **Favorite**
   (medium: one tap starts a favorite). From iOS 17 the buttons work without opening the app.
4. **Siri:** say "Hey Siri, play *RVE Constanța* on Radio Creștin". "My favorites" plays your favorites;
   no station name resumes the last one.
5. **Settings** (gear icon on Home): **Încărcare în avans** (Live, 2 or 5 minutes behind live, so a weak
   signal goes unheard), **Conexiune instabilă**, **Folosește MP3 cu prioritate**, theme and auto start.

## Android phone and tablet

<!-- say: On an Android phone or tablet, install Radio Crestin from Google Play. You can also download the A P K from the GitHub release and allow your browser to install apps. Tap a station to play. The notification keeps the controls at hand, with the screen off. -->

Needs Android 7.0 or later.

1. Install **Radio Crestin** from [Google Play](https://play.google.com/store/apps/details?id=com.radiocrestin.radio_crestin).
   Without Google Play: download
   [`radio-crestin-android.apk`](https://github.com/radio-crestin/radio-crestin-mobile-app/releases/latest/download/radio-crestin-android.apk),
   open it, and allow your browser to **install unknown apps** when Android asks.
2. Open it and tap a station. Play, pause, next and previous stay in the notification and on the lock screen.
3. Allow notifications when asked, so playback keeps its controls while the screen is off.
4. **Settings** (gear icon on Home): the same options as on iPhone, including **Încărcare în avans** and
   **Folosește MP3 cu prioritate**.

## Android TV and Google TV

<!-- say: On Android TV and Google TV, find Radio Crestin in the Play Store on the TV, or install the A P K with an app like Downloader. Move with the remote's arrows and press OK to play. Your favorite stations show up on the TV's home screen too. -->

1. On the TV, open the **Play Store**, search **Radio Crestin** and install it.
   Not listed on your TV? Install the **Downloader** app, enter the APK link from
   [the Android section](#android-phone-and-tablet), and allow Downloader to install apps.
2. Open **Radio Crestin** from the apps row. Move with the remote's arrows; **OK** plays the focused station.
3. Your favorite stations appear as a channel on the TV's home screen.

## Apple TV

<!-- say: On Apple TV, open the App Store and search for Radio Crestin. It is the same app as on iPhone. Click a station to play it. Click and hold a card to add it to your favorites. In Settings you can choose how far behind live to listen. -->

Needs tvOS 17 or later.

1. On the Apple TV, open the **App Store**, search **Radio Crestin** and install it (the same app as on iPhone).
2. Click a station to play it; the remote's **Play/Pause** works everywhere, also from the system Now Playing.
3. Click and hold a card to add it to or remove it from **Favorite**.
4. **Settings → Încărcare în avans**: Live, 2 or 5 minutes, as on the phone.

## Mac

<!-- say: On a Mac, get Radio Crestin from the Mac App Store. Or download the D M G from the GitHub release, and drag the app to Applications. The first time, macOS may ask you to confirm it in Privacy and Security. -->

Needs macOS 13 or later.

1. Install **Radio Crestin** from the Mac App Store (search *Radio Crestin*).
   Or download
   [`radio-crestin-macos.dmg`](https://github.com/radio-crestin/radio-crestin-mobile-app/releases/latest/download/radio-crestin-macos.dmg),
   open it and drag **Radio Crestin** to **Applications**.
2. The DMG build is not notarized: if macOS says it can't check the app, open **System Settings → Privacy &
   Security** and click **Open Anyway** next to Radio Crestin.
3. Play from the station grid; the player bar has volume and mute, and the menu bar, Dock menu and
   keyboard shortcuts control playback.

## Windows

<!-- say: On Windows, download the zip from the GitHub release, extract it, and open radio crestin dot exe. If Windows SmartScreen warns you, click More info, then Run anyway. -->

Needs 64-bit Windows 10 or 11.

1. Download
   [`radio-crestin-windows.zip`](https://github.com/radio-crestin/radio-crestin-mobile-app/releases/latest/download/radio-crestin-windows.zip)
   and extract it to a folder of your choice (keep every file together).
2. Open **radio_crestin.exe**. If SmartScreen shows "Windows protected your PC", click **More info →
   Run anyway** (the app is not code-signed yet).
3. Optional: right-click `radio_crestin.exe` → **Pin to Start** or **Pin to taskbar**.

## CarPlay

<!-- say: For CarPlay, install the app on your iPhone, then connect the iPhone to the car, with a cable or wirelessly. Radio Crestin appears on the car's screen, with Favorite and Categories tabs. You can also press the car's voice button and ask Siri for a station. -->

1. Install the app on the iPhone (see [iPhone and iPad](#iphone-and-ipad)) and open it once.
2. Connect the iPhone to the car, by cable or wirelessly. **Radio Crestin** appears on the CarPlay screen.
   Not there? On the iPhone: **Settings → General → CarPlay →** your car **→ Customize**, and add it.
3. Two tabs: **Favorite** and **Categorii** (starting with **Toate radiourile**). Next and previous stay
   within the list you started from.
4. Press the car's voice button: "Play *Radio Vocea Evangheliei* on Radio Creștin".

## Android Auto

<!-- say: For Android Auto, install Radio Crestin from Google Play, then connect the phone to the car. Radio Crestin is in the Android Auto app list. If you installed the A P K instead, turn on Unknown sources in Android Auto's developer settings, or the app won't show up. -->

1. Install the app from Google Play on the phone (see [Android phone and tablet](#android-phone-and-tablet))
   and open it once.
2. Connect the phone to the car. **Radio Crestin** is in the Android Auto app list; tabs **Favorite**,
   **Toate stațiile** and **Categorii**, with 👍 ♡ 👎 on Now Playing.
3. Installed from the APK instead of Google Play? Android Auto hides it until you allow it: open the
   **Android Auto** settings, tap **Version** ten times to unlock developer mode, then **⋮ → Developer
   settings → Unknown sources**.

## Chromecast, Google Home speakers and AirPlay

<!-- say: To listen on a Chromecast, a Google speaker, or an AirPlay speaker, tap the cast button at the top of Home or of the player. The phone and the speaker must be on the same Wi-Fi. On iPhone, allow Local Network access the first time. -->

1. Put the phone and the speaker or TV on the same Wi-Fi.
2. Tap the cast button at the top of Home or of the full player: **Ascultă pe alt dispozitiv** lists the
   Chromecast and Google Home devices found; tap **Conectează**.
3. On iPhone, allow **Local Network** access the first time. Denied it earlier? The sheet's
   **Deschide Setările** button takes you to the switch.
4. **AirPlay**, the TV app and the car are listed under **SAU** in the same sheet.

## Linux

<!-- slides: skip -->

There is no ready-made Linux package yet. Developers can build it from source with
`fvm flutter build linux --release` (see the [README](../README.md)).
