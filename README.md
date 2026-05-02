<p align="center">
  <a href="https://github.com/iosifnicolae2/radio-crestin-app">
    <img src="https://github.com/iosifnicolae2/radio-crestin-app/blob/main/assets/icons/ic_logo_filled.png" alt="Radio Crestin logo" width="200" />
  </a>
</p>
<h1 align="center">Radio Crestin App 🎧</h1>
<br>
<p align="center">
  <a href="https://play.google.com/store/apps/details?id=com.radiocrestin.radio_crestin&hl=en_US" target="_blank">
    <img alt="playstore image" src="https://radiocrestin.ro/images/playstore.svg" width="150" height="46"/>
  </a>
  <a href="https://apps.apple.com/app/6451270471" target="_blank">
    <img alt="appstore image" src="https://radiocrestin.ro/images/appstore.svg" width="150" height="46"/>
  </a>
  <a href="https://appgallery.huawei.com/app/C109055331" target="_blank">
    <img alt="huawei image" src="https://radiocrestin.ro/images/appgallery.svg" width="150" height="46"/>
  </a>
</p>

Feel free to contribute to this project or get in touch with us at: contact@radio-crestin.com

Obs. This project can be used only by Christian organizations for non-commercial purposes.

![Group 18](https://github.com/iosifnicolae2/radio-crestin-app/assets/43387542/2d89a06e-f8fb-40a9-9f20-c1e04568a208)


## Setup development environment
- install brew
```bash
brew install --cask flutter

```

## Releases

All builds happen **locally** on the developer machine — no CI, no signing
secrets stored in GitHub Actions. Artifacts are uploaded to a GitHub Release
via the `gh` CLI.

### Prerequisites
- macOS host with Xcode + valid Apple Developer signing for iOS / macOS / tvOS.
- `android/key.properties` and `android/app/radio-crestin-app-keystore.jks`
  pulled from 1Password (gitignored).
- `gh` CLI authenticated (`gh auth login`).
- Optional: a Windows host with Flutter desktop enabled to produce the EXE.

### Two-stage flow: prerelease → promote
Releases are created as **prereleases first** so the dev team can test before
the build is exposed at `/releases/latest`. Once a prerelease has been
verified, run `make promote` to flip it to public.

```bash
make release            # bump + commit pubspec, build android+ios+macos+apple-tv,
                        # tag v<version>, push tag, create GH prerelease, upload artifacts
                        # (devs can pull via tag URL; not yet at /releases/latest)

make promote            # once verified, flips prerelease=false on the current
                        # tag so /releases/latest serves it to end users
```

### Step-by-step
```bash
make release-help       # list every release target

make bump-build         # 1.5.0+77 → 1.5.0+78  (or bump-patch / bump-minor)
make commit-version     # commits pubspec bump and pushes
make release-android    # APK + AAB to dist/
make release-ios        # ad-hoc IPA to dist/
make release-macos      # unsigned DMG to dist/
make release-apple-tv   # tvOS IPA to dist/
make tag-release        # creates v<version> tag and pushes it
make publish            # creates GH prerelease, uploads everything in dist/
make promote            # flips prerelease → latest
```

### Windows EXE (separate machine)
On a Windows host with Flutter desktop support enabled:
```bash
make release-windows    # produces dist/radio-crestin-windows.zip
make publish            # uploads to the same release tag from earlier
```

### Latest-release download links (stable URLs)
The release artifacts use stable filenames so the GitHub
`/releases/latest/download/<file>` redirect works:

| Platform | Download |
|----------|----------|
| Android APK | https://github.com/radio-crestin/radio-crestin-mobile-app/releases/latest/download/radio-crestin-android.apk |
| Android AAB (Play upload) | https://github.com/radio-crestin/radio-crestin-mobile-app/releases/latest/download/radio-crestin-android.aab |
| iOS IPA (ad-hoc) | https://github.com/radio-crestin/radio-crestin-mobile-app/releases/latest/download/radio-crestin-ios.ipa |
| macOS DMG | https://github.com/radio-crestin/radio-crestin-mobile-app/releases/latest/download/radio-crestin-macos.dmg |
| Windows zip | https://github.com/radio-crestin/radio-crestin-mobile-app/releases/latest/download/radio-crestin-windows.zip |
| Apple TV IPA | https://github.com/radio-crestin/radio-crestin-mobile-app/releases/latest/download/radio-crestin-tvos.ipa |

`make latest-links` reprints these on demand.

### Apple TV (`apple_tv/`)
The tvOS app is a separate native SwiftUI Xcode project, not a Flutter target.
`apple_tv/ExportOptions.plist` is committed with team `2KNY2RZVGC` and
`method=development` — adjust to `ad-hoc` or `app-store` when ready to
distribute beyond registered dev devices. `make release-apple-tv` is included
in `make release-mac-platforms` and `make release`.

### Disabling Xcode Cloud
This repo does **not** use Xcode Cloud (no `ci_scripts/` or `.xcode-cloud/`).
If Xcode Cloud is enabled in App Store Connect for this app, disable it from
the App Store Connect web UI — that setting lives outside the repo.

### Phone-only details — legacy notes
- Android signing config: `android/key.properties` (1Password →
  `radio_crestin_key.properties`) plus the keystore at
  `android/app/radio-crestin-app-keystore.jks`.
- iOS signing: open `ios/Runner.xcworkspace`, select target `Runner`,
  pick your team under **Signing & Capabilities** with **Automatically
  manage signing** enabled. See https://docs.flutter.dev/deployment/ios.
