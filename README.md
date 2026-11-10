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

## GitHub の運用（Gitflow）

ブランチの分岐とマージは Gitflow に従う。

| ブランチ | 役割 | 派生元 | マージ先・方法 |
|---|---|---|---|
| `main` | 提出可能な状態だけを置く。提出候補のタグ `sub-YYYYMMDD.N` を打つ | ― | `release/*`・`hotfix/*` からの PR のみ（マージコミットで残す） |
| `develop` | 日々の開発の統合先。デフォルトブランチ | `main` から作成済み | `feature/*` の受け口 |
| `feature/<内容>` | 機能の追加・修正。1つの PR で1つの目的にする | `develop` | `develop` へ PR、squash and merge |
| `release/sub-YYYYMMDD.N` | 提出候補の確定と提出前検査 | `develop` | 検査合格後に `main` へ PR（マージコミット）、タグを打つ。`develop` にも反映 |
| `hotfix/<内容>` | 提出候補の不具合の緊急修正 | `main` | `main` へ PR、新しいタグ（同日なら `sub-YYYYMMDD.(N+1)`）を打つ。`develop` にも反映 |

手順:

1. `develop` から `feature/<内容>` を切り、開発モードで動作を確認する（[docs/member-guide.md](docs/member-guide.md) §1）。
2. `bash env/tools/lightweight_checks.sh` を通して PR を出す。レビューは、`agent/` の変更は Agent 班メンバー1人以上、`env/` の変更は環境担当の承認が必須。
3. マージしたらブランチを削除する。`feature/*` を長持ちさせない（長くなるなら PR を分ける）。
4. 提出候補を作るときは `develop` から `release/sub-YYYYMMDD.N` を切り、そのコミットで統合ビルド・スモークテスト・提出前検査をすべて合格させる。`release/*` の間は `env/` を変えない（変更が必要なら `develop` に戻して作り直す）。
5. `main` と `develop` に直接 push しない。すべてプルリクエスト(pull request)で行う。GitHub の保護ブランチ(protected branch)設定は Org 移管後に追加し、それまでは運用で守る。

決まり:

- GitHub のデフォルトブランチは `develop` とする。
- コミットメッセージは `<領域>: <要点>`（例: `runner: …`、`手順書: …`）。日本語でよい。
- git タグは提出候補の `sub-YYYYMMDD.N` のみ `main` に打つ。`base-YYYYMMDD.N` は `env/images.lock` に記録する基盤イメージの版名で、git タグではない。

## コミットのルール

- コミットのメールは GitHub の非公開アドレス（`…@users.noreply.github.com`）にする。
- トークン・秘密鍵・イメージ・重みをコミットしない。PR の前に `bash env/tools/lightweight_checks.sh` を通す。
