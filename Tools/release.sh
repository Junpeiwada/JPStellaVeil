#!/usr/bin/env bash
#
# release.sh — ローカルから 1 コマンドでリリースを発火する。
#
#   Tools/release.sh <version> [-y]
#   例: Tools/release.sh 1.2.0
#
# バージョンを省略して実行すると、現在のバージョンを表示したうえで、パッチを 1 つ
# 上げた値を既定値として尋ねる（Enter だけで確定できる）。VSCode の npm パネルから
# クリック実行する場合はこの経路になる。
#
# やること:
#   1. project.yml の MARKETING_VERSION を <version> に更新
#   2. xcodegen が入っていれば再生成して yml の妥当性を早期検証（.xcodeproj は Git 管理外）
#   3. project.yml をコミット
#   4. タグ v<version> を打って push（main と タグ の両方）
#   → GitHub Actions の Release ワークフローが自動で署名・公証・DMG 作成・配布まで実行する。
#
# CURRENT_PROJECT_VERSION（ビルド番号）は CI が run 番号で上書きするため手動更新は不要。
# 詳細は docs/リリース手順.md を参照。
set -euo pipefail

# --- リポジトリルートへ移動（Tools/ からでもルートからでも動くように）---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

PROJECT_YML="project.yml"
ASSUME_YES=0

# --- 引数パース ---
VERSION=""
for arg in "$@"; do
  case "${arg}" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help)
      # 先頭のバナーコメントブロックだけを表示（本文中の # コメントは出さない）。
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
      exit 0 ;;
    -*) echo "エラー: 不明なオプション: ${arg}" >&2; exit 1 ;;
    *)  VERSION="${arg}" ;;
  esac
done

# --- 現在のバージョンを読む ---
# 次に何番を打つか決める材料なので、入力を尋ねる前に読む。
if [ ! -f "${PROJECT_YML}" ]; then
  echo "エラー: ${PROJECT_YML} が見つかりません。" >&2
  exit 1
fi
CURRENT="$(grep -E '^\s*MARKETING_VERSION:' "${PROJECT_YML}" | head -1 | sed -E 's/.*"([^"]*)".*/\1/')"

# 既定値はパッチを 1 つ上げた版。現在の値が X.Y.Z 形式で読めたときだけ提示する。
SUGGESTED=""
if [[ "${CURRENT}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  SUGGESTED="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$(( BASH_REMATCH[3] + 1 ))"
fi

# バージョン未指定なら、端末なら対話で尋ねる（VSCode の npm パネルからクリック実行した
# 場合など引数を渡せないケース向け）。端末でなければエラーにする。
if [ -z "${VERSION}" ]; then
  if [ -t 0 ]; then
    echo "現在のバージョン: ${CURRENT:-不明}"
    if [ -n "${SUGGESTED}" ]; then
      printf "リリースするバージョンを入力 [%s]: " "${SUGGESTED}"
      read -r VERSION
      VERSION="${VERSION:-${SUGGESTED}}"   # 空入力なら既定値を採る
    else
      printf "リリースするバージョンを入力してください（例: 1.2.0）: "
      read -r VERSION
    fi
  fi
fi
if [ -z "${VERSION}" ]; then
  echo "エラー: バージョンを指定してください（例: Tools/release.sh 1.2.0）" >&2
  exit 1
fi

# --- バージョン形式チェック（セマンティックな X.Y.Z）---
if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "エラー: バージョンは X.Y.Z 形式で指定してください（例: 1.2.0）。指定値: ${VERSION}" >&2
  exit 1
fi
TAG="v${VERSION}"

# --- 事前チェック ---
BRANCH="$(git branch --show-current)"
if [ "${BRANCH}" != "main" ]; then
  echo "警告: 現在のブランチは '${BRANCH}' です（通常は main でリリースします）。" >&2
fi

# ワーキングツリーが汚れていると、意図しない変更を巻き込んでコミットしてしまう。
if [ -n "$(git status --porcelain)" ]; then
  echo "エラー: コミットされていない変更があります。先に整理してから実行してください:" >&2
  git status --short >&2
  exit 1
fi

# タグの二重発行を防ぐ。
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "エラー: タグ ${TAG} は既に存在します。" >&2
  exit 1
fi

echo "現在のバージョン: ${CURRENT:-不明}"
echo "新しいバージョン: ${VERSION}（タグ ${TAG}）"

# 番号を戻す・据え置くのはたいてい打ち間違い。タグ重複チェックでは拾えないので警告する
# （配信順が壊れるだけで発火自体は可能なため、止めずに判断を委ねる）。
if [ -n "${CURRENT}" ] && [ "${VERSION}" = "${CURRENT}" ]; then
  echo "警告: 指定バージョンは現在と同じです（${CURRENT}）。" >&2
elif [ -n "${CURRENT}" ] \
  && [ "$(printf '%s\n%s\n' "${CURRENT}" "${VERSION}" | sort -V | tail -1)" = "${CURRENT}" ]; then
  echo "警告: 指定バージョン ${VERSION} は現在の ${CURRENT} より古いです。" >&2
fi

# --- 発射確認（push はリリースを本番発火するため）---
if [ "${ASSUME_YES}" -ne 1 ]; then
  printf "この内容でリリースを発火します。よろしいですか？ [y/N] "
  read -r ANSWER
  case "${ANSWER}" in
    y|Y|yes|YES) ;;
    *) echo "中止しました。"; exit 0 ;;
  esac
fi

# --- 1. MARKETING_VERSION を更新（BSD/macOS sed）---
sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*)\"[^\"]*\"/\1\"${VERSION}\"/" "${PROJECT_YML}"
echo "→ ${PROJECT_YML} の MARKETING_VERSION を ${VERSION} に更新しました。"

# --- 2. xcodegen があれば再生成（yml の妥当性を早期検証。.xcodeproj は Git 管理外）---
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >/dev/null
  echo "→ xcodegen generate 実行済み（プロジェクトを再生成）。"
else
  echo "→ xcodegen 未インストールのためローカル再生成はスキップ（CI 側で生成されます）。"
fi

# --- 3. コミット ---
# 初回リリースや、先にバージョンを上げてあった場合は差分が出ない。
# その状態で git commit すると失敗して止まるので、変更があるときだけコミットする。
git add "${PROJECT_YML}"
if git diff --cached --quiet; then
  echo "→ ${PROJECT_YML} に変更がないため、コミットはスキップします（バージョン据え置き）。"
else
  git commit -m "${TAG} へバージョンを上げる"
  echo "→ project.yml をコミットしました。"
fi

# --- 4. タグを打って push ---
git tag "${TAG}"
git push origin "${BRANCH}"
git push origin "${TAG}"
echo "→ ${BRANCH} と ${TAG} を push しました。"

echo ""
echo "✅ リリースを発火しました。GitHub の Actions → Release ワークフローの完了を確認してください。"
echo "   完了すると Release ページに署名・公証済みの DMG が添付されます。"
