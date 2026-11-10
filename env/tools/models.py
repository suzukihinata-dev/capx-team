#!/usr/bin/env python3
"""models.lock の操作（標準ライブラリのみ。取得だけ huggingface_hub を使う）。

  models.py check      --lock agent/models.lock
  models.py fetch      --lock agent/models.lock --cache DIR   重みを DIR/<repo>/<revision>/ に取得（要ネットワーク）
  models.py binds      --lock agent/models.lock --cache DIR   apptainer の --bind 引数（読み取り専用）を1行ずつ出力
  models.py submission --lock agent/models.lock --image-repo ORG/REPO --image-revision SHA [--image-path agent.sif]
                                                              submission.yaml を標準出力へ
  models.py sha        --lock agent/models.lock                models.lock の SHA-256
取得には Hugging Face の読み取りトークンを ~/.config/capx/hf_token に置く（gated / 非公開の場合）。
"""
from __future__ import annotations

import argparse
import hashlib
import os
import sys
from pathlib import Path


def load(lock: Path) -> list[tuple[str, str, str, bool]]:
    out = []
    for n, raw in enumerate(lock.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        p = line.split()
        if len(p) not in (3, 4) or (len(p) == 4 and p[3] != "gated"):
            sys.exit(f"{lock}:{n}: 形式エラー: {raw}")
        if len(p[1]) != 40 or any(c not in "0123456789abcdef" for c in p[1]):
            sys.exit(f"{lock}:{n}: revision は40桁の SHA: {p[1]}")
        if not p[2].startswith("/models/"):
            sys.exit(f"{lock}:{n}: path は /models/ 配下: {p[2]}")
        out.append((p[0], p[1], p[2], len(p) == 4))
    if len({e[2] for e in out}) != len(out):
        sys.exit(f"{lock}: path が重複しています")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["check", "fetch", "binds", "submission", "sha"])
    ap.add_argument("--lock", type=Path, default=Path("agent/models.lock"))
    ap.add_argument("--cache", type=Path, default=Path(os.environ.get("CAPX_DATA", Path.home() / "capx-data")) / "models")
    ap.add_argument("--image-repo", default="")
    ap.add_argument("--image-revision", default="")
    ap.add_argument("--image-path", default="agent.sif")
    a = ap.parse_args()
    entries = load(a.lock)

    if a.cmd == "check":
        print(f"OK: {len(entries)} models")
    elif a.cmd == "sha":
        print(hashlib.sha256(a.lock.read_bytes()).hexdigest())
    elif a.cmd == "binds":
        for repo, rev, path, _ in entries:
            src = a.cache / repo / rev
            if not src.is_dir():
                sys.exit(f"重みが未取得です: {src}（models.py fetch を先に実行）")
            print(f"--bind={src}:{path}:ro")
    elif a.cmd == "fetch":
        from huggingface_hub import snapshot_download  # 取得時のみ必要
        tokf = Path(os.environ.get("CAPX_TOKEN_DIR", Path.home() / ".config/capx")) / "hf_token"
        token = tokf.read_text().strip() if tokf.is_file() else None
        for repo, rev, _path, _gated in entries:
            dest = a.cache / repo / rev
            if dest.is_dir() and any(dest.iterdir()):
                print(f"skip (exists): {dest}")
                continue
            snapshot_download(repo_id=repo, revision=rev, local_dir=dest, token=token)
            print(f"fetched: {repo}@{rev} -> {dest}")
    elif a.cmd == "submission":
        if not a.image_repo or len(a.image_revision) != 40:
            sys.exit("--image-repo と 40桁の --image-revision が必要です")
        lines = ["image:", f"  repo: {a.image_repo}", f"  revision: {a.image_revision}", f"  path: {a.image_path}", "weights:"]
        for repo, rev, path, gated in entries:
            lines += [f"  - repo: {repo}", f"    revision: {rev}", f"    path: {path}"]
            if gated:
                lines.append("    gated: true")
        print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
