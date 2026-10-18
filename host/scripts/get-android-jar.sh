#!/usr/bin/env bash
# Fetch an android.jar for building the host when no Android SDK is installed.
# Downloads the API 30 prebuilt from the Android Open Source Project (Gitiles
# serves files base64-encoded), as Suwayomi-Server's getAndroid.sh does.
#
#   host/scripts/get-android-jar.sh [dest]      # default: host/lib/android.jar
#   ./gradlew shadowJar -Ptachi.androidJar=host/lib/android.jar
set -euo pipefail
API=${ANDROID_API:-30}
COMMIT=${ANDROID_PREBUILTS_COMMIT:-refs/heads/main}
DEST=${1:-"$(cd "$(dirname "$0")/.." && pwd)/lib/android.jar"}
URL="https://android.googlesource.com/platform/prebuilts/sdk/+/${COMMIT}/${API}/public/android.jar?format=TEXT"
mkdir -p "$(dirname "$DEST")"
echo "downloading android.jar (API $API) -> $DEST" >&2
curl -fsSL "$URL" | base64 --decode > "$DEST.tmp"
mv "$DEST.tmp" "$DEST"
unzip -l "$DEST" | tail -1 >&2
