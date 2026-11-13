#!/usr/bin/env bash
# =============================================================================
# build-apk.sh — 构建 Android debug APK（薄封装，不做任何 Flutter 配置改动）
#
#   bash scripts/build-apk.sh            # debug
#   bash scripts/build-apk.sh --release  # release（需自备签名）
#
# 产物：dist/dsh-pocket-<versionName>-<versionCode>.apk（例 dist/dsh-pocket-1.3.7-22.apk，
#       版本取自 packages/app/pubspec.yaml 的 `version:`）；原始产物仍留在
#       packages/app/build/app/outputs/flutter-apk/app-<mode>.apk
# 退出码：0 成功；1 目录缺失 / flutter 缺失 / 构建失败
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/packages/app"

MODE="debug"
case "${1:-}" in
  --release) MODE="release" ;;
  --debug | "") MODE="debug" ;;
  -h | --help)
    sed -n '2,12p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "未知参数: $1（只支持 --debug / --release）" >&2
    exit 2
    ;;
esac

if [ ! -d "$APP_DIR" ]; then
  echo "ERROR: 找不到 $APP_DIR —— App 工程尚未创建（W2 负责 packages/app）。" >&2
  exit 1
fi
if [ ! -f "$APP_DIR/pubspec.yaml" ]; then
  echo "ERROR: $APP_DIR 里没有 pubspec.yaml，不是一个 Flutter 工程。" >&2
  exit 1
fi
if ! command -v flutter >/dev/null 2>&1; then
  echo "ERROR: PATH 里没有 flutter。安装 Flutter SDK 后重试（flutter doctor 先过）。" >&2
  exit 1
fi

echo "== flutter build apk --$MODE =="
echo "   工程: $APP_DIR"
(cd "$APP_DIR" && flutter build apk "--$MODE")

APK="$APP_DIR/build/app/outputs/flutter-apk/app-$MODE.apk"
echo
if [ ! -f "$APK" ]; then
  echo "ERROR: 构建结束但没找到产物 $APK" >&2
  ls -la "$APP_DIR/build/app/outputs/flutter-apk/" 2>/dev/null || true
  exit 1
fi

# 归档到 dist/：文件名跟这里已有的历史包一致
#   dsh-pocket-<versionName>-<versionCode>.apk，例如 dsh-pocket-1.3.4-19.apk
VERSION_LINE="$(grep -m1 '^version:' "$APP_DIR/pubspec.yaml" | sed 's/^version:[[:space:]]*//')"
if [ -z "$VERSION_LINE" ]; then
  echo "ERROR: $APP_DIR/pubspec.yaml 里没读到 version:" >&2
  exit 1
fi
VERSION_NAME="${VERSION_LINE%%+*}"
VERSION_CODE="${VERSION_LINE#*+}"
if [ "$VERSION_CODE" = "$VERSION_LINE" ]; then
  echo "ERROR: pubspec 的 version 缺 +build 号：$VERSION_LINE" >&2
  exit 1
fi

DIST_DIR="$ROOT/dist"
mkdir -p "$DIST_DIR"
OUT="$DIST_DIR/dsh-pocket-$VERSION_NAME-$VERSION_CODE.apk"
cp -f "$APK" "$OUT"

SIZE="$(du -h "$OUT" 2>/dev/null | cut -f1 || echo '?')"
echo "APK OK: $OUT ($SIZE)"
echo "原始产物: $APK"
echo "安装: adb install -r \"$OUT\""
