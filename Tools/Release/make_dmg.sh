#!/bin/bash
#
# 署名済みの .app から配布用 DMG を作る。
#
# create-dmg などの外部ツールには依存せず、macOS 標準の hdiutil だけで組み立てる。
# CI（.github/workflows/release.yml）とローカルの両方から同じ手順で叩けるようにしてある。
#
# 使い方:
#   Tools/Release/make_dmg.sh <app のパス> <出力する dmg のパス>

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "使い方: $0 <app のパス> <出力する dmg のパス>" >&2
    exit 1
fi

APP_PATH="$1"
DMG_PATH="$2"
VOLUME_NAME="$(basename "${APP_PATH%.app}")"

if [ ! -d "$APP_PATH" ]; then
    echo "エラー: アプリが見つかりません: $APP_PATH" >&2
    exit 1
fi

# ステージング用の一時ディレクトリ。中身がそのまま DMG のルートになる。
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

cp -R "$APP_PATH" "$STAGING_DIR/"

# ドラッグ＆ドロップでインストールできるよう Applications への導線を置く。
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
mkdir -p "$(dirname "$DMG_PATH")"

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG_PATH"

echo "DMG を作成しました: $DMG_PATH"
