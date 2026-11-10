# 環境担当向け手順書

## 基盤イメージを更新する

1. `env/` を変える PR（`versions.submission.env`、`base.def`、`requirements/*.in` など）。
   - Python の依存を変えたらロックを作り直す:
     ```bash
     uv pip compile --python-version 3.12 --python-platform x86_64-manylinux_2_28 --generate-hashes env/requirements/robosuite.in -o env/requirements/robosuite.txt
     uv pip compile --python-version 3.10 --python-platform x86_64-manylinux_2_28 --generate-hashes --emit-index-url --index-strategy unsafe-best-match env/requirements/libero.in -o env/requirements/libero.txt
     ```
   - `env/jobs/` を変えたら `JOB_PROTOCOL_VERSION` を上げ、自動化用の固定スクリプトも同じ日に更新する。
2. マージ後、そのコミットでビルド: `bash env/jobs/build_base.sh --commit <sha> --tag base-YYYYMMDD.N`
3. 出力された1行を `env/images.lock` に追加する PR → マージ。
4. マージ後に配置: `bash env/jobs/place_base.sh --sif <build/base-YYYYMMDD.N.sif> --lock env/images.lock`
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

## Slack 通知の文面雛形

基盤イメージを配置したとき（Agent 班チャンネル）:

```
【基盤イメージ更新】base-YYYYMMDD.N を配置しました
- 元コミット: <env/ のコミット 12 桁>（env/images.lock に記録済み）
- 変更点: <公式配布への追従 / 依存の追加 など1〜2行>
- 置き場所: $CAPX_DATA/images/base-YYYYMMDD.N.sif
- 影響: 開発モードは次回から新しいイメージを使ってください。統合ビルドは images.lock の最後の行を自動で使います。
```

提出候補を作ったとき:

```
【提出候補】sub-YYYYMMDD.N
- 元コミット: <12 桁> / 基盤: base-YYYYMMDD.N
- 統合ビルドとスモークテスト: 合格（実行記録: records/<コミット>/<ジョブID>-…）
- 重み: <models.lock の要約>
- 提出判断はリーダーが行います。
```

通知文には参加者限定の情報・トークン・メンバーのアカウント名を書かない。

## 班長の Mac からの接続（E-08）

- Mac から Linux PC へは Tailscale の名前で ssh する（`ssh suzukihinata-dev@suzukihinata-gpu`）。
- ファイルの同期は git を基本にする。Mac で作業したら GitHub と Linux PC のベアリポジトリ（`~/capx/capx-team.git`）に push し、Linux PC の作業用 clone で pull する。
- GMO へは Mac から班長の鍵で接続する（Linux PC からの GMO 接続は保留中）。
