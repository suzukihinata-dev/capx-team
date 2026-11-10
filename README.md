# capx-team

CaP-X エージェントの本番コンテナ（提出イメージ）を、定義ファイルから再現できる形で作るためのリポジトリ。

- `env/` 環境担当が管理（変更は PR で環境担当のレビュー必須）
  - `base.def` 基盤イメージ（CUDA・PyTorch・推論サーバー・シミュレータ・評価コード）
  - `agent.def` 提出イメージ（基盤イメージ＋`agent/` のコード。重みは入れない）
  - `versions.submission.env` 版（ビルドの入力）／`versions.local.env` ローカル PC 固有の版／`images.lock` ビルド結果
  - `requirements/` シミュレータの依存（ハッシュ付きロック）
  - `jobs/` ジョブスクリプト（手動でも Slurm でも同じ手順。誰でも実行できる）
  - `tools/` 差分確認・照合・重み・軽量検査
  - `smoke/` シミュレータの最小エピソード
- `agent/` Agent 班が開発するエージェント
  - `models.lock` 評価時にマウントする重み（Hugging Face のリポジトリ・revision・path）
- `docs/` 手順書（[メンバー向け](docs/member-guide.md)、[環境担当向け](docs/env-maintainer.md)）

実行記録はこのリポジトリに入れない（リポジトリ外の保存先に置く）。出自は提出候補タグの注釈と `agent.sif` の `%labels` に残す。

## 最初に読むもの

- メンバー: [docs/member-guide.md](docs/member-guide.md)
- 環境担当: [docs/env-maintainer.md](docs/env-maintainer.md)

## コミットのルール

- コミットのメールは GitHub の非公開アドレス（`…@users.noreply.github.com`）にする。
- トークン・秘密鍵・イメージ・重みをコミットしない。PR の前に `bash env/tools/lightweight_checks.sh` を通す。
