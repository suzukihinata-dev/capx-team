# メンバー向け手順書（開発から取り込みまで）

## 0. 最初に1回だけ

1. GitHub
   - リポジトリへの参加招待を受ける。
   - コミットのメールを非公開アドレスにする: `git config user.email "<ID>+<ユーザー名>@users.noreply.github.com"`
2. GMO（計算環境）
   - 班長からの案内に従い、自分の Navi アカウントで初回ログインし、自分の PC で作った鍵を登録する。鍵・アカウントは共有しない。
3. トークン（GMO のホーム領域に置く。グループ領域・リポジトリ・イメージには置かない）
   - GitHub: fine-grained personal access token。対象リポジトリだけ、Contents の読み取りのみ、有効期限は予選終了まで。
   - Hugging Face: 読み取りトークン（必要なリポジトリのみ）。
   ```bash
   mkdir -p ~/.config/capx && chmod 700 ~/.config/capx
   install -m 600 /dev/null ~/.config/capx/github_token && vi ~/.config/capx/github_token
   install -m 600 /dev/null ~/.config/capx/hf_token     && vi ~/.config/capx/hf_token
   ```

## 1. 開発（開発モード）

- main からブランチを切る。
- 基盤イメージに自分のコードを差し込んで動かす（再ビルド不要）:
  ```bash
  BASE=$CAPX_DATA/images/<tag>.sif               # <tag> は env/images.lock の最後の行（base-YYYYMMDD.N）
  apptainer exec --nv --bind $PWD/agent:/opt/capx/agent $BASE \
    sh -c 'cd /opt/capx/agent && UV_PROJECT_ENVIRONMENT=$HOME/.capx-venv uv sync -q --frozen && $HOME/.capx-venv/bin/python -m capx_agent.runner --no-server'
  ```
- 重みを使う場合は、`python3 env/tools/models.py fetch` で取得し、`python3 env/tools/models.py binds` の出力を `apptainer exec` に足す。
- 注意: 開発モードで動いても合格ではない（手元の未コミットの依存でも動いてしまうため）。合格の判定は統合ビルド。

## 2. 依存を足すとき

- 軽い Python パッケージ: `agent/pyproject.toml` に書き、`cd agent && uv lock` で `uv.lock` を更新して PR に含める。
- CUDA・推論サーバー・シミュレータ・apt に関わるもの: 環境担当に依頼する（`env/` の変更）。
- コンテナの中で手で `pip install` した状態を前提にしない。

## 3. 重みを変えるとき

- 重み本体は Git にもイメージにも入れない。`agent/models.lock` に `<repo> <40桁の revision> /models/<名前>` を書く。

## 4. PR

1. `bash env/tools/lightweight_checks.sh`（CI が整うまでは手元で実行し、結果を PR に貼る）
2. レビューを受けて main にマージ

## 5. 統合ビルド（誰でも実行できる）

- 手元で編集したスクリプトではなく、**指定コミットの `env/jobs/`** を使う（スクリプト自身が一致を確かめ、違えば止まる）。
  ```bash
  git -C <作業ディレクトリ> checkout <main のコミット>
  CAPX_REPO_URL=https://github.com/<org>/<repo>.git CAPX_OPERATOR=<担当記号> \
    sbatch env/jobs/integration_build.sh --commit <コミット>
  # ローカル PC では sbatch の代わりに bash
  ```
- 計算ノードから GitHub に接続できない場合は、取得済みのディレクトリを `--source-dir` で渡す。
- 結果はリポジトリ外の `records/<コミット>/<ジョブID>-<日時>-*/` に残る。リポジトリにはコミットしない。

## 6. GMO の使い方の決まり

- 同時ログインは2人まで（暫定）。ジョブを投入したらすぐログアウトする。ジョブの状況はコーディネータ権限で確認する。
- ログインノードではインストール・大きなデータの転送・圧縮展開・学習や推論をしない。すべて計算ノードのジョブで行う。
