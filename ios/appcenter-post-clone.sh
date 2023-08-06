#!/usr/bin/env bash
# Place this script in project/ios/appcenter-post-clone.sh
# Original file stored at
# https://github.com/microsoft/appcenter/blob/master/sample-build-scripts/flutter/ios-build/appcenter-post-clone.sh

# fail if any command fails
set -e
# debug log
set -x

cd ..
git clone -b stable https://github.com/flutter/flutter.git
export PATH=`pwd`/flutter/bin:$PATH

flutter channel stable
flutter doctor

echo "Installed flutter to `pwd`/flutter"

flutter -v pub get

function generate_new_config() {
    new_str=""
    while IFS=$'\n' read -r line; do
        if [[ "$line" == *"FLUTTER_TARGET"* ]]; then
            IFS='=' read -r key val <<< "$line"
            new_str="$new_str"$'\n'"$key"="$APP_TARGET""$2"
        else
            if [[ "$line" == *"FLUTTER_FRAMEWORK_DIR"* ]]; then
                IFS='=' read -r key val <<< "$line"
                new_str="$new_str"$'\n'"$key"="`pwd`/flutter/bin/cache/artifacts/engine/ios-release""$2"
            else
                if [ "$new_str" == '' ] ; then
                    new_str="$line"
                else
                    new_str="$new_str"$'\n'"$line"
                fi
            fi
        fi
    done < "$1"

    echo "$new_str" > "$1"
}

eval generate_new_config ios/Flutter/flutter_export_environment.sh '\"'
eval generate_new_config ios/Flutter/Generated.xcconfig

# Install ios tools
flutter precache --ios --no-android --no-universal