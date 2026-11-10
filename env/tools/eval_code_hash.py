#!/usr/bin/env python3
"""評価コード（gateway / EnvClient）が改変されていないことを SHA-256 で確かめる。

  eval_code_hash.py make   --root <公式リポジトリ> --paths <対象のパス...> > env/eval_code.sha256
  eval_code_hash.py verify --root <確認したい場所> --list env/eval_code.sha256

対象のパスは公式配布後に決める（ファイルでもディレクトリでもよい）。一覧には相対パスと SHA-256 だけを書き、
公式のファイル本文はリポジトリに入れない。
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path


def files_under(root: Path, rel: str) -> list[Path]:
    p = root / rel
    if p.is_file():
        return [p]
    if p.is_dir():
        return sorted(x for x in p.rglob("*") if x.is_file() and "__pycache__" not in x.parts)
    sys.exit(f"見つかりません: {p}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["make", "verify"])
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--paths", nargs="*", default=[])
    ap.add_argument("--list", type=Path)
    a = ap.parse_args()
    if a.cmd == "make":
        if not a.paths:
            sys.exit("--paths を指定してください")
        for rel in a.paths:
            for f in files_under(a.root, rel):
                print(f"{hashlib.sha256(f.read_bytes()).hexdigest()}  {f.relative_to(a.root)}")
        return 0
    assert a.list, "--list を指定してください"
    bad = 0
    n = 0
    for line in a.list.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        want, rel = line.split(None, 1)
        f = a.root / rel.strip()
        n += 1
        if not f.is_file():
            print(f"MISSING {rel}")
            bad += 1
        elif hashlib.sha256(f.read_bytes()).hexdigest() != want:
            print(f"CHANGED {rel}")
            bad += 1
    print(f"checked={n} ng={bad}")
    return 0 if bad == 0 and n > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
