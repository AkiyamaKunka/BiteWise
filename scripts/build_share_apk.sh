#!/usr/bin/env bash
# Build the APK we hand to other people.
#
# One arm64 APK, deliberately: the default fat APK carries THREE copies
# of the Flutter engine (arm64 + armeabi-v7a + x86_64 ≈ 58 MB of the
# 60 MB). Every real phone is arm64; x86_64 exists only for emulators.
# The arm64 APK is ~22 MB — a 65% smaller file to send over WeChat.
#
# --target-platform android-arm64, not --split-per-abi: Flutter gives a
# split APK the versionCode 2000 + the build number, which then never
# upgrades to or from the Play build or the GitHub release APK (release.yml
# builds this same way). app/build.gradle.kts drops the plugins' libraries
# for the other ABIs, so a 32-bit phone refuses the APK instead of crashing.
#
# Signed with the upload key only when app/android/key.properties exists;
# otherwise with the debug key, and Android will not install it over a
# release from GitHub (or the other way round) without an uninstall. Its
# versionCode is pubspec's +N, below every CI build (100 and up), so it also
# cannot replace a GitHub release APK in place.
set -euo pipefail
cd "$(dirname "$0")/.."/app
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

flutter build apk --release --target-platform android-arm64
OUT="build/app/outputs/flutter-apk/app-release.apk"
VERSION="$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)"
DEST="$HOME/Desktop/Chopstats-share/Chopstats-$VERSION.apk"
mkdir -p "$(dirname "$DEST")"
cp "$OUT" "$DEST"
ls -lh "$DEST"
echo "arm64 build ready: $DEST"
echo "NOTE: arm64 only — correct for every phone since ~2017. Emulators"
echo "and ancient 32-bit devices need: flutter build apk --release --split-per-abi"
echo "(app-armeabi-v7a-release.apk; it cannot upgrade in place from this one)."
