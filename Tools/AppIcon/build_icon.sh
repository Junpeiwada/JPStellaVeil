#!/bin/bash
# アプリアイコンを生成し、Assets.xcassets と .icns に展開する。
#   使い方: Tools/AppIcon/build_icon.sh [バリアント]
#   バリアント: A=ヴェールあり（採用） / B=ミニマル / C=小さな星あり
set -euo pipefail

VARIANT="${1:-A}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="$ROOT/Tools/AppIcon"
SET="$ROOT/Sources/Resources/Assets.xcassets/AppIcon.appiconset"
MASTER="$DIR/AppIcon-1024.png"

command -v magick >/dev/null || { echo "ImageMagick (magick) が必要です" >&2; exit 1; }

echo "==> マスター画像を生成 (variant $VARIANT)"
swift "$DIR/gen_icon.swift" "$VARIANT" "$MASTER"

echo "==> Assets.xcassets へ展開"
rm -rf "$SET"
mkdir -p "$SET"
# actool は「1エントリ1ファイル」でないと一部のサイズを取りこぼすため、
# 同じ内容でもエントリごとに別ファイルとして書き出す。
emit() { magick "$MASTER" -filter Lanczos -resize "${2}x${2}" "$SET/$1"; }
emit icon_16x16.png       16
emit icon_16x16@2x.png    32
emit icon_32x32.png       32
emit icon_32x32@2x.png    64
emit icon_128x128.png     128
emit icon_128x128@2x.png  256
emit icon_256x256.png     256
emit icon_256x256@2x.png  512
emit icon_512x512.png     512
emit icon_512x512@2x.png  1024

cat > "$SET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "==> .icns を生成"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
cp "$SET"/icon_*.png "$ICONSET/"
rm -f "$ICONSET/Contents.json"
iconutil -c icns "$ICONSET" -o "$DIR/AppIcon.icns"

echo "==> 完了: $MASTER / $SET / $DIR/AppIcon.icns"
