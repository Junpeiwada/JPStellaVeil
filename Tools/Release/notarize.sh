#!/bin/bash
#
# 対象を Apple の公証にかけ、結果（チケット）を対象へ埋め込む。
#
# .app と .dmg の両方を受け付ける。.app はそのままでは送れないので
# 一度 zip に固めて送り、チケットは元の .app へ埋め込む。
#
# .app 単体にもチケットを埋めておかないと、DMG から取り出したアプリを
# オフライン環境で初めて起動したときに Gatekeeper が判定できず弾かれる。
#
# 使い方:
#   Tools/Release/notarize.sh <対象パス> <AuthKey.p8> <キーID> <IssuerID>

set -euo pipefail

if [ $# -ne 4 ]; then
    echo "使い方: $0 <対象パス> <AuthKey.p8> <キーID> <IssuerID>" >&2
    exit 1
fi

TARGET="$1"
KEY_PATH="$2"
KEY_ID="$3"
ISSUER_ID="$4"

if [ ! -e "$TARGET" ]; then
    echo "エラー: 対象が見つかりません: $TARGET" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# .app はディレクトリなので、そのままでは公証に送れない。
# ditto の --keepParent で、署名を保ったまま zip に固める。
case "$TARGET" in
    *.app)
        UPLOAD_PATH="$WORK_DIR/$(basename "${TARGET%.app}").zip"
        /usr/bin/ditto -c -k --keepParent "$TARGET" "$UPLOAD_PATH"
        ;;
    *)
        UPLOAD_PATH="$TARGET"
        ;;
esac

echo "公証に送ります: $(basename "$TARGET")"

RESULT_JSON="$WORK_DIR/notarize.json"

# notarytool は審査結果が Invalid でも終了コード 0 を返すことがある。
# 成否の判断は必ず JSON の status で行う。
xcrun notarytool submit "$UPLOAD_PATH" \
    --key "$KEY_PATH" \
    --key-id "$KEY_ID" \
    --issuer "$ISSUER_ID" \
    --wait \
    --output-format json \
    > "$RESULT_JSON" || true

cat "$RESULT_JSON"
echo

read_field() {
    python3 -c "import json;print(json.load(open('$RESULT_JSON')).get('$1',''))" 2>/dev/null || echo ""
}

STATUS="$(read_field status)"
SUBMISSION_ID="$(read_field id)"

if [ "$STATUS" != "Accepted" ]; then
    echo "公証に失敗しました（status: ${STATUS:-不明}）" >&2
    if [ -n "$SUBMISSION_ID" ]; then
        echo "詳細ログ:" >&2
        xcrun notarytool log "$SUBMISSION_ID" \
            --key "$KEY_PATH" \
            --key-id "$KEY_ID" \
            --issuer "$ISSUER_ID" >&2 || true
    fi
    exit 1
fi

# チケットは zip ではなく、元の .app / .dmg に埋め込む。
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

echo "公証とチケットの埋め込みが完了しました: $(basename "$TARGET")"
