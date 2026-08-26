#!/bin/bash
#
# リリースワークフローが必要とする GitHub Secrets を登録する。
#
# 署名資材（証明書・API キー）は他のアプリと同じ流儀で Dropbox に置いてあり、
# Developer ID 証明書は全アプリで同じものを共有している。
# 置き場を変えたい場合は環境変数 JPSTELLAVEIL_SECRETS_DIR で指定する。
#
# 使い方:
#   Tools/Release/setup_github_secrets.sh

set -euo pipefail

SECRETS_DIR="${JPSTELLAVEIL_SECRETS_DIR:-$HOME/Dropbox/アプリ/JPStellaVeil}"

if [ ! -d "$SECRETS_DIR" ]; then
    echo "エラー: 署名資材の置き場が見つかりません: $SECRETS_DIR" >&2
    exit 1
fi

if ! command -v gh > /dev/null; then
    echo "エラー: gh コマンドが必要です（brew install gh）" >&2
    exit 1
fi

P12_PATH="$SECRETS_DIR/証明書.p12"
P12_PASSWORD_PATH="$SECRETS_DIR/パスワード.txt"
ISSUER_ID_PATH="$SECRETS_DIR/IssuerID.txt"
KEY_ID_PATH="$SECRETS_DIR/キーID.txt"

# AuthKey_XXXX.p8 はキー ID がファイル名に入るため、名前を決め打ちできない。
KEY_PATH="$(find "$SECRETS_DIR" -maxdepth 1 -name 'AuthKey_*.p8' | head -1)"

for path in "$P12_PATH" "$P12_PASSWORD_PATH" "$ISSUER_ID_PATH" "$KEY_ID_PATH"; do
    if [ ! -f "$path" ]; then
        echo "エラー: ファイルが見つかりません: $path" >&2
        exit 1
    fi
done

if [ -z "$KEY_PATH" ]; then
    echo "エラー: AuthKey_*.p8 が $SECRETS_DIR にありません" >&2
    exit 1
fi

# テキストファイルは末尾の改行込みで保存されていることがある。
# そのまま渡すと notarytool が値を受け付けないので削っておく。
P12_PASSWORD="$(tr -d '\r\n' < "$P12_PASSWORD_PATH")"
ISSUER_ID="$(tr -d '\r\n' < "$ISSUER_ID_PATH")"
KEY_ID="$(tr -d '\r\n' < "$KEY_ID_PATH")"

echo "署名資材: $SECRETS_DIR"
echo "  証明書:   $(basename "$P12_PATH")"
echo "  API キー: $(basename "$KEY_PATH") (キー ID: $KEY_ID)"
echo
echo "GitHub Secrets を登録します..."

# Secrets 名は JPScreenShot / JPPhotoTools と同じ流儀に揃えてある。
base64 < "$P12_PATH" | tr -d '\n' | gh secret set DEVELOPER_ID_CERT_P12
base64 < "$KEY_PATH" | tr -d '\n' | gh secret set ASC_API_KEY_P8
printf '%s' "$P12_PASSWORD" | gh secret set DEVELOPER_ID_CERT_PASSWORD
printf '%s' "$KEY_ID"       | gh secret set ASC_KEY_ID
printf '%s' "$ISSUER_ID"    | gh secret set ASC_ISSUER_ID

echo
echo "登録済みの Secrets:"
gh secret list

echo
echo "完了しました。次のコマンドでリリースできます:"
echo "  npm run release"
