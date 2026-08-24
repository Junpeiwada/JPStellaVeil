#!/bin/bash
# sky_mask.sh -- Photoshop の「空を選択」で空マスクを生成する
#
# 使い方:
#   ./sky_mask.sh <入力画像> <出力マスク> [長辺px] [参照JPEG]
#
#   出力マスクの拡張子で形式が決まる:
#     .tif / .tiff → 16bit グレースケール TIFF（入力が 16bit の場合）
#     .png         →  8bit グレースケール PNG
#   長辺px を省略または 0 にするとフル解像度で出力する。
#   参照JPEG を指定すると、マスクと同じ寸法の元画像も書き出す（目視確認用）。
#
# 例:
#   ./sky_mask.sh input.tif mask.tif
#   ./sky_mask.sh input.tif mask.png 2048 ref.jpg
#
# 終了コード: 0=成功 / 1=失敗（標準出力に JSON 形式のエラーが出る）

set -u

if [ $# -lt 2 ]; then
    sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JSX="$SCRIPT_DIR/sky_mask.jsx"
[ -f "$JSX" ] || { echo "sky_mask.jsx が見つからない: $JSX" >&2; exit 1; }

IN="$1"
[ -f "$IN" ] || { echo "入力ファイルが見つからない: $IN" >&2; exit 1; }
IN="$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")"

OUT="$2"
OUT_DIR="$(dirname "$OUT")"
mkdir -p "$OUT_DIR" || exit 1
OUT="$(cd "$OUT_DIR" && pwd)/$(basename "$OUT")"

LONG_EDGE="${3:-0}"

REF="${4:-}"
if [ -n "$REF" ]; then
    REF_DIR="$(dirname "$REF")"
    mkdir -p "$REF_DIR" || exit 1
    REF="$(cd "$REF_DIR" && pwd)/$(basename "$REF")"
fi

# インストールされている最新の Photoshop を選ぶ
APP="$(ls -d /Applications/Adobe\ Photoshop\ * 2>/dev/null | sort | tail -1)"
[ -n "$APP" ] || { echo "Photoshop が見つからない" >&2; exit 1; }
APP_NAME="$(basename "$APP")"

# AppleScript 文字列リテラル用にエスケープする
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

RESULT=$(osascript <<APPLESCRIPT
with timeout of 3600 seconds
  tell application "$(esc "$APP_NAME")"
    do javascript (file POSIX file "$(esc "$JSX")") with arguments {"$(esc "$IN")", "$(esc "$OUT")", "$(esc "$LONG_EDGE")", "$(esc "$REF")"}
  end tell
end timeout
APPLESCRIPT
) || { echo "Photoshop の呼び出しに失敗した" >&2; exit 1; }

echo "$RESULT"
case "$RESULT" in
    *'"ok":true'*) exit 0 ;;
    *) exit 1 ;;
esac
