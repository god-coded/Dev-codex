#!/usr/bin/env bash
#
# build_apk.sh — one-command APK builder for the modded Telegram client.
#
# On a Linux/macOS machine (or Windows via WSL2) this script will, in order:
#   1. Install a JDK 17 (Temurin, into ~/jdk17 — no sudo needed)
#   2. Install the Android command-line tools + SDK 36 + NDK 27.2 + CMake
#   3. Clone Telegram (with submodules) — or reuse an existing clone
#   4. Apply the in-call music + voice booster/EQ patches
#   5. Build the debug APK (auto-signed, installable on your device)
#   6. Print the path to the finished APK
#
# Usage:
#   ./build_apk.sh
#
# Optional environment variables:
#   API_ID / API_HASH    override the credentials baked into BuildVars.java
#   APP_PACKAGE          e.g. com.yourname.telegrammod  (default: org.telegram.messenger)
#   SHALLOW=1            clone with --depth 1 (faster, less disk, slightly riskier)
#   SKIP_CLONE=1         reuse ./TelegramMusic if it already exists
#
# Requirements: 64-bit OS, 16 GB+ RAM, ~60 GB free disk, curl, unzip, git.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${REPO:-$HERE/TelegramMusic}"
SDK="${SDK:-$HOME/android-sdk}"
JDK="${JDK:-$HOME/jdk17}"

echo "======================================================"
echo " Telegram mod APK builder"
echo "======================================================"

# ---------- sanity checks ----------
if [ "$(nproc 2>/dev/null || echo 2)" -lt 4 ]; then
  echo "WARNING: fewer than 4 CPU cores detected — the native build will be slow."
fi
RAM_MB=$(free -m 2>/dev/null | awk '/Mem:/{print $2}' || echo 0)
if [ "$RAM_MB" != "0" ] && [ "$RAM_MB" -lt 12000 ]; then
  echo "WARNING: less than 12 GB RAM detected (${RAM_MB} MB). The build may run out of memory."
fi
for tool in curl git unzip; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: '$tool' is required."; exit 1; }
done

# ---------- 1. JDK 17 ----------
if ! command -v "$JDK/bin/java" >/dev/null 2>&1; then
  echo "==> Installing JDK 17 (Temurin) to $JDK ..."
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)  JDK_URL="https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse" ;;
    Linux-aarch64) JDK_URL="https://api.adoptium.net/v3/binary/latest/17/ga/linux/aarch64/jdk/hotspot/normal/eclipse" ;;
    Darwin-x86_64) JDK_URL="https://api.adoptium.net/v3/binary/latest/17/ga/mac/x64/jdk/hotspot/normal/eclipse" ;;
    Darwin-arm64)  JDK_URL="https://api.adoptium.net/v3/binary/latest/17/ga/mac/aarch64/jdk/hotspot/normal/eclipse" ;;
    *) echo "ERROR: unsupported OS/arch: $(uname -s)/$(uname -m)"; exit 1 ;;
  esac
  curl -L -o /tmp/jdk17.tar.gz "$JDK_URL"
  rm -rf "$JDK" && mkdir -p "$JDK"
  tar -xzf /tmp/jdk17.tar.gz -C "$JDK" --strip-components=1
fi
export JAVA_HOME="$JDK"
export PATH="$JAVA_HOME/bin:$PATH"
echo "==> Java: $("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"

# ---------- 2. Android SDK / NDK / CMake ----------
if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  echo "==> Downloading Android command-line tools ..."
  case "$(uname -s)" in
    Linux)  CLT_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" ;;
    Darwin) CLT_URL="https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip" ;;
    *) echo "ERROR: unsupported OS"; exit 1 ;;
  esac
  curl -L -o /tmp/clt.zip "$CLT_URL"
  mkdir -p "$SDK/cmdline-tools"
  unzip -q -o /tmp/clt.zip -d /tmp/clt
  mv /tmp/clt/cmdline-tools "$SDK/cmdline-tools/latest"
fi
export ANDROID_HOME="$SDK"
export ANDROID_SDK_ROOT="$SDK"
SDKMAN="$SDK/cmdline-tools/latest/bin/sdkmanager"

yes | "$SDKMAN" --sdk_root="$SDK" --licenses >/dev/null 2>&1 || true
echo "==> Installing SDK packages (this downloads ~3 GB) ..."
"$SDKMAN" --sdk_root="$SDK" --install \
  "platform-tools" \
  "platforms;android-36" \
  "build-tools;36.0.0" \
  "ndk;27.2.12479018" \
  "cmake;3.22.1"

# ---------- 3. clone ----------
if [ "${SKIP_CLONE:-0}" != "1" ] && [ ! -f "$REPO/TMessagesProj/build.gradle" ]; then
  echo "==> Cloning Telegram (this is the big download) ..."
  if [ "${SHALLOW:-0}" = "1" ]; then
    git clone --recurse-submodules --depth 1 --shallow-submodules https://github.com/DrKLO/Telegram.git "$REPO"
  else
    git clone --recurse-submodules https://github.com/DrKLO/Telegram.git "$REPO"
  fi
fi
[ -f "$REPO/TMessagesProj/build.gradle" ] || { echo "ERROR: repo missing at $REPO"; exit 1; }

# ---------- 4. apply patches ----------
echo "==> Applying the music-player + voice-booster patches ..."
"$HERE/apply_patches.sh" "$REPO"

# ---------- 5. credentials / package ----------
if [ -n "${API_ID:-}" ] && [ -n "${API_HASH:-}" ]; then
  echo "==> Overriding API_ID / API_HASH from environment ..."
  sed -i.bak -E "s/public static int APP_ID = [0-9]+;/public static int APP_ID = ${API_ID};/" \
      "$REPO/TMessagesProj/src/main/java/org/telegram/messenger/BuildVars.java"
  sed -i.bak -E "s#public static String APP_HASH = \"[^\"]*\";#public static String APP_HASH = \"${API_HASH}\";#" \
      "$REPO/TMessagesProj/src/main/java/org/telegram/messenger/BuildVars.java"
fi
if [ -n "${APP_PACKAGE:-}" ]; then
  echo "==> Setting package name to $APP_PACKAGE ..."
  sed -i.bak "s/^APP_PACKAGE=.*/APP_PACKAGE=${APP_PACKAGE}/" "$REPO/gradle.properties"
fi
echo "sdk.dir=$SDK" > "$REPO/local.properties"

# ---------- 6. build ----------
echo "==> Building the debug APK (first build can take 1–3 hours) ..."
cd "$REPO"
./gradlew :TMessagesProj_App:assembleDebug --stacktrace

# ---------- 7. done ----------
APK=$(find "$REPO/TMessagesProj_App/build/outputs/apk" -name "*.apk" | head -1)
echo ""
echo "======================================================"
echo " DONE ✅"
echo "======================================================"
if [ -n "$APK" ]; then
  echo "APK: $APK"
  echo ""
  echo "Install it on your phone:"
  echo "  adb install -r \"$APK\""
  echo "  (or copy it to the device and open it)"
else
  echo "Couldn't find the APK — check the gradle output above for errors."
fi
