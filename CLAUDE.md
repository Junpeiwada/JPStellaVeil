# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

JPStellaVeil は、現像済みの 16bit TIFF に星空用ソフトフィルター効果（星のグロー）を後から加える macOS ネイティブアプリ（SwiftUI + Metal）。「16bit のまま」「リニア空間で」「空だけに効かせて」「メタデータを完全に保つ」の 4 つを既定動作とする。

## コマンド

`.xcodeproj` は生成物で版管理していない。**`Sources/` や `Tests/` にファイルを追加・削除したら必ず `xcodegen generate` を実行する**こと。実行しないと新ファイルがビルド対象に入らず「テストを書いたのに実行されない」状態になる（実際に一度発生した）。

```sh
xcodegen generate    # project.yml から .xcodeproj を生成（前提: brew install xcodegen）

# ビルド・テスト・起動（npm 経由。依存パッケージは無く、単なるコマンドの入れ物）
npm run build        # xcodegen generate + Debug ビルド（-derivedDataPath dd）
npm run test         # xcodegen generate + 全テスト実行
npm run run          # ビルド済みアプリを起動（dd/Build/Products/Debug/JPStellaVeil.app）
npm run release -- 1.2.0   # リリース（タグを打つと GitHub Actions が署名・公証・DMG・appcast まで実行）

# 単一テストクラス / 単一テストの実行
xcodebuild test -project JPStellaVeil.xcodeproj -scheme JPStellaVeil -derivedDataPath dd \
  -only-testing:JPStellaVeilTests/GlowPipelineTests
xcodebuild test -project JPStellaVeil.xcodeproj -scheme JPStellaVeil -derivedDataPath dd \
  -only-testing:JPStellaVeilTests/GlowPipelineTests/testMethodName

# docs/ の見出しを変更したら目次を再生成（冪等）
python3 Tools/GenDocsToc/gen_toc.py docs/*.md
```

環境の前提: Metal Toolchain（`.metal` のコンパイルに必要。`xcodebuild -downloadComponent MetalToolchain`）、ExifTool（`brew install exiftool`。無いと該当テストは XCTSkip、アプリは警告表示で動作）。

### テストデータ

実画像テストは `/Volumes/RAID1-8T4/...` 配下の TIFF に直書きパスで依存する（`TIFFColorManagementTests.swift`、`TIFFImageIOServiceTests.swift`）。無い環境では XCTSkip される。**このテストファイルは書き換えないこと。**

### 動作確認用の環境変数

アプリ起動時の状態を環境変数で作れる（スクリーンショット取得・効果比較の自動化用）。`JPSTELLAVEIL_OPEN_FILE`（開く TIFF）、`JPSTELLAVEIL_ADD_PRESET`（fine / standard / wideHalo）、`JPSTELLAVEIL_AUTO_APPLY=1`、`JPSTELLAVEIL_DISPLAY_EXPOSURE`、`JPSTELLAVEIL_SPLIT`、`JPSTELLAVEIL_ZOOM`、`JPSTELLAVEIL_GLOW_ONLY=1`、`JPSTELLAVEIL_GENERATE_MASK=1`。詳細は README。

## アーキテクチャ

処理はすべて**リニア RGB** で行う（入力 TIFF のガンマを外して変換し、表示・書き出し時だけトーン変換を戻す）。プレビューは縮小せずフル解像度で処理し、書き出し時と同一のパイプラインを通す。

データフロー: `AppState`（Sources/App/、ObservableObject。UI 状態と `StellaVeilProject` を保持）→ `GlowProcessingController`（Sources/Processing/、デバウンス・キャンセル・レイヤー別グローのキャッシュ管理）→ `GlowPipeline`（Metal Compute。背景減算 → 閾値 → 空マスク → 4 成分ガウシアン PSF → Screen/Add 合成。タイル分割で実行し、タイルのマージンは 2 つのぼかし半径の和）→ `CanvasRenderer`（Sources/Rendering/、MetalKit でキャンバス描画・ズーム・スプリット比較・グローのみ表示）。

| ディレクトリ | 役割 |
|---|---|
| Sources/Domain/ | `StellaVeilProject`・`GlowLayer`・プリセットの Codable モデル |
| Sources/Imaging/ | 16bit TIFF の読み書き（ImageIO）・ICC プロファイル検査 |
| Sources/Masking/ | 空マスク生成（AppleScript 経由で Photoshop の「空を選択」を借りる。Scripts/sky_mask.jsx） |
| Sources/Metadata/ | ExifTool 実行・入出力メタデータの比較検証 |
| Sources/Presets/ | プリセット永続化（~/Library/Application Support/JPStellaVeil/Presets.json） |

メタデータ検証は書き出しの合否判定を兼ねる: まず ImageIO 出力をそのまま検証し、欠落があるときだけ ExifTool でコピーする（ExifTool 書き込みは不要な差分を持ち込むため）。保持対象に欠落・値の変化があれば**書き出し失敗として出力ファイルを消す**。

自動更新は Sparkle。`SUFeedURL` / `SUPublicEDKey` などの Info.plist キーは **project.yml の `info:` ブロックで生成**しているため、Info.plist 関連の変更は project.yml を編集して再生成する（JPStellaVeil-Info.plist は生成物）。

## ドキュメントの正本

仕様の正本は docs/ にある。実装で仕様を確定・変更したら該当ドキュメントを更新する。

- docs/技術仕様.md — 確定した技術仕様と決定理由の正本（色管理・メタデータ比較・処理パイプライン、ICC 比較や `read_write` テクスチャ回避などのハマりどころを含む）。実装前に一読の価値あり
- docs/UI.md — 画面構成の仕様
- docs/アーカイブ/ — 完了・凍結した実装計画と旧引き継ぎ資料。新機能の計画は impl-plan スキルで docs/ に新しい台帳を作る

「プロジェクト保存（.stellaveil）」と「空マスクの自前生成・手動補正」は検討のうえ**実装しないと決定済み**（2026-08-25）。提案しないこと。

## このプロジェクトの合意事項

- **各フェーズの完了時にアプリを起動してスクリーンショットで確認し、それからコミットする**（テストだけでは UI・描画の正しさを判定できないため）
- コミットメッセージの領域見出しはこのプロジェクトでは【画面側】【描画層】【演算層】【ドキュメント】等を使う
