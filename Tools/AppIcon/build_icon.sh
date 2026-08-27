#!/bin/bash
# アプリアイコンを生成し、Assets.xcassets と .icns に展開する。
#   使い方: Tools/AppIcon/build_icon.sh [元画像]
#   元画像: AI 生成した 1024x1024 の正方形画像。指定するとマスター
#           (AppIcon-1024.png) を作り直す。省略時は既存のマスターから
#           各サイズを再展開するだけ。
#
# 元画像には生成時の角丸（角の黒み）が焼き込まれているため、
# 端を 60px ずつクロップして除去してから、macOS 標準のアイコングリッド
# （1024px 中、余白 100px・角丸半径 185px）でマスクし直す。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="$ROOT/Tools/AppIcon"
SET="$ROOT/Sources/Resources/Assets.xcassets/AppIcon.appiconset"
MASTER="$DIR/AppIcon-1024.png"

command -v magick >/dev/null || { echo "ImageMagick (magick) が必要です" >&2; exit 1; }

if [ $# -ge 1 ]; then
  SRC="$1"
  [ -f "$SRC" ] || { echo "元画像が見つかりません: $SRC" >&2; exit 1; }

  echo "==> マスター画像を生成 (source: $SRC)"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  # 端の焼き込み角丸を除去して 824x824 へ
  magick "$SRC" -gravity center -crop 904x904+0+0 +repage \
    -filter Lanczos -resize 824x824 "$TMP/square.png"
  # macOS 標準の角丸マスク（4倍解像度で描いてから縮小し、エッジをアンチエイリアスする）
  magick -size 3296x3296 xc:black -fill white \
    -draw "roundrectangle 0,0,3295,3295,740,740" \
    -filter Lanczos -resize 824x824 "$TMP/mask.png"
  magick "$TMP/square.png" "$TMP/mask.png" \
    -alpha off -compose CopyOpacity -composite "$TMP/rounded.png"
  # 1024x1024 の透明キャンバス中央（余白 100px）に配置
  magick -size 1024x1024 xc:none "$TMP/rounded.png" \
    -gravity center -compose Over -composite "$MASTER"
else
  [ -f "$MASTER" ] || { echo "マスターがありません: $MASTER（元画像を引数で渡してください）" >&2; exit 1; }
  echo "==> 既存のマスターを使用: $MASTER"
fi

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
