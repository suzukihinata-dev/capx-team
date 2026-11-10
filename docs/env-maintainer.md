# 環境担当向け手順書

## 基盤イメージを更新する

1. `env/` を変える PR（`versions.submission.env`、`base.def`、`requirements/*.in` など）。
   - Python の依存を変えたらロックを作り直す:
     ```bash
     uv pip compile --python-version 3.12 --generate-hashes env/requirements/robosuite.in -o env/requirements/robosuite.txt
     uv pip compile --python-version 3.10 --generate-hashes env/requirements/libero.in    -o env/requirements/libero.txt
     ```
   - `env/jobs/` を変えたら `JOB_PROTOCOL_VERSION` を上げ、自動化用の固定スクリプトも同じ日に更新する。
2. マージ後、そのコミットでビルド: `bash env/jobs/build_base.sh --commit <sha> --tag base-YYYYMMDD.N`
3. 出力された1行を `env/images.lock` に追加する PR → マージ。
4. マージ後に配置: `bash env/jobs/place_base.sh --sif <build/base-….sif> --lock env/images.lock`
5. Slack の Agent 班チャンネルへ通知（タグと変更点）。
6. apt の版を固定する場合: `bash env/tools/make_apt_lock.sh <base.sif> > env/apt.lock` を PR。

順序を守る（images.lock のマージ前に images/ へ置かない）。images/ はチーム全員が書き込めるので、配置したファイルは書き込み不可にする（place_base.sh が行う）。

## 公式配布物に追従する（公式配布当日）

1. 公式リポジトリの URL とコミットを `versions.submission.env` の `OFFICIAL_REPO_URL`・`OFFICIAL_COMMIT` に書く。公式のファイルはこのリポジトリに入れない。
2. 差分確認: `python3 env/tools/diff_versions.py --official <公式リポジトリの clone> --ours .`
3. 公式がベースイメージを指定していれば、`BASE_IMAGE`・`BASE_IMAGE_DIGEST` を合わせる（digest で固定）。依存は `requirements/*.in` に反映してロック。
4. 評価コードのハッシュ一覧: `python3 env/tools/eval_code_hash.py make --root <公式> --paths <gateway のパス> <EnvClient のパス> > env/eval_code.sha256`
5. 上の「基盤イメージを更新する」の 2〜5。build_base.sh は評価コードのハッシュを照合する。

## 実行記録を移す

- 週1回と予選終了前日中に、`$CAPX_DATA/records/` を検査結果用の非公開リポジトリへ移す。`SHA256SUMS` も一緒に移す。

## ローカル PC のホスト基盤

- `sudo bash env/install-host.sh`（2回目以降は何も変わらないこと）、確認だけなら `bash env/install-host.sh --check`。
- ドライバは入れ替えない。docker・lxd・libvirt のグループに班長以外を入れない。
