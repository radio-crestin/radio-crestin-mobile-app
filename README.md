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

### Store uploads (TestFlight + Play internal)
Once a release is built and verified, push the dev versions to TestFlight and
Play Store's internal testing track via fastlane. Credentials stay in
1Password (`radio-crestin-app` vault) — fastlane reads them at upload time
through `op`, never from disk.

```bash
make deploy-ios             # build number +1, fresh app-store IPA, upload to TestFlight
                            # as the Apple ID signed in to Xcode (no 1Password/fastlane)
make deploy-android         # build number +1, fresh release AAB shown in Finder: drag it
                            # into Play Console -> Production (the command prints the link)
make deploy                 # build number +1 once, then both (same +N on both stores)

make release-stores         # all of the below in one go: bumps the build number (+1),
                            # commits it (no push), builds the app-store IPA + AAB, uploads both

make release-ios-appstore   # builds an app-store IPA (TestFlight requires this, not ad-hoc)
make upload-testflight      # uploads dist/radio-crestin-ios-appstore.ipa to TestFlight
                            # with the App Store Connect API key (1Password + fastlane)
make upload-testflight-xcode # uploads the iOS archive as the Xcode account instead
make upload-play-internal   # uploads dist/radio-crestin-android.aab to Play internal track
make upload-stores          # upload-testflight + upload-play-internal
```

Each store upload needs a higher build number than the previous one, so the
individual targets above need a `make bump-build` first; `release-stores` does
it for you. If an upload fails after its bump, retry with `make upload-stores`.

The `deploy-*` targets bump the build number by one and always rebuild before
uploading, so a stale artifact in `dist/` is never sent. `NO_BUMP=1` keeps the
build number: use it to retry an upload that failed after its bump, or to ship
the other platform with the same +N. Once the upload went through they commit
the new version in `pubspec.yaml` (`[<branch>] - bumped build number to X`, not
pushed; `make deploy` commits once, after both uploads), and a failed upload
leaves it uncommitted for the `NO_BUMP=1` retry. They refuse other uncommitted
changes so every upload matches a commit; `ALLOW_DIRTY=1` skips that check. `deploy-ios`
uploads through the Apple ID signed in to Xcode (Xcode → Settings →
Accounts), with `ios/ExportOptionsUpload.plist`, so it needs no API key.
`deploy-android` uploads nothing: it builds only the AAB, shows it in Finder
and commits the version once it is built; drag it into Play Console →
Production → Create new release. Only `upload-play-internal` and
`release-stores` need the 1Password + fastlane setup below. An upload is
not a release: submit the TestFlight build for review in App Store Connect.

**1Password items needed** (all in vault `radio-crestin-app`, secure note with
the value pasted into the `notesPlain` field):

| Item name | Source | Purpose |
|---|---|---|
| `appstore_connect_api_key.p8` | App Store Connect → Users and Access → Integrations → App Store Connect API → Generate API Key (download once) | TestFlight auth |
| `appstore_connect_key_id` | Same page, the 10-char Key ID | TestFlight auth |
| `appstore_connect_issuer_id` | Same page, the UUID at the top | TestFlight auth |
| `play_service_account.json` | Play Console → Setup → API access → Create service account → Download JSON, then grant it "Release manager" or "Admin" on this app | Play upload |

**One-time setup**:
```bash
brew install 1password-cli      # if you don't already have op
cd ios     && bundle install    # installs fastlane gem
cd android && bundle install    # installs fastlane gem
```

The Play service account also needs to be invited to the Play Console as a
user with permission on the `com.radiocrestin.radio_crestin` app — Play
Console → Users and permissions → Invite new users → paste the service
account email from the JSON.

### Crash symbols (PostHog dSYMs)
`make release-ios` and `make release-ios-appstore` upload the archive's
dSYMs to PostHog Error Tracking (project `radio-crestin-mobile-app`, EU), so
native iOS crashes show function names and lines instead of addresses. A
failed upload only prints a warning — retry with `make upload-dsyms-ios`.
Dart errors need no symbols (builds are not obfuscated).

**One-time setup** (per machine):
```bash
brew install posthog/tap/posthog-cli
posthog-cli --host https://eu.posthog.com login   # pick project radio-crestin-mobile-app
```
In CI, set `POSTHOG_CLI_API_KEY` (personal API key with `error tracking
write` + `organization read`) and `POSTHOG_CLI_PROJECT_ID=222020` instead.

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
