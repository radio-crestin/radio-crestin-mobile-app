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

## Create an Android release
1. Copy `radio_crestin_key.properties` from 1Password into `android/key.properties`
2. Copy `radio-crestin-app-keystore.jks` from 1Password into `android/app/radio_crestin_key.jks`
3. Run `flutter build appbundle --release` to build the APK

## Create an iOS release
1. Open the project in Xcode
2. Select the target `Runner` and go to the `Signing & Capabilities` tab
3. Select your team and make sure the `Automatically manage signing` is checked
4. Run `flutter build ios --release` to build the iOS app
