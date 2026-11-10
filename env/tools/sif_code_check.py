#!/usr/bin/env python3
"""提出イメージ内のコードが、元コミットのコードと一致するかを確かめる（ルール集の .sif とコードの照合用）。

  sif_code_check.py --sif agent.sif --src <元コミットを展開した agent/> --inside /opt/capx/agent

.sif の SHA-256 は再ビルドで変わるため使わず、ファイルごとの SHA-256 一覧を比べる。
ビルド時に生じるファイル（__pycache__ など）は比較から除く。
"""
from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
from pathlib import Path

IGNORE_PARTS = {"__pycache__", ".venv", ".pytest_cache"}


def local_manifest(root: Path) -> dict[str, str]:
    out = {}
    for p in sorted(root.rglob("*")):
        if p.is_file() and not (IGNORE_PARTS & set(p.relative_to(root).parts)):
            out[str(p.relative_to(root))] = hashlib.sha256(p.read_bytes()).hexdigest()
    return out


def sif_manifest(sif: str, inside: str) -> dict[str, str]:
    script = (
        "import hashlib,os,sys\n"
        f"root={inside!r}\n"
        "for d,dn,fn in os.walk(root):\n"
        "  dn[:]=[x for x in dn if x not in ('__pycache__','.venv','.pytest_cache')]\n"
        "  for f in fn:\n"
        "    p=os.path.join(d,f); print(hashlib.sha256(open(p,'rb').read()).hexdigest(), os.path.relpath(p,root))\n"
    )
    app = os.environ.get("APPTAINER", "apptainer")
    r = subprocess.run([app, "exec", "--containall", sif, "python3", "-c", script],
                       capture_output=True, text=True, check=True)
    return {line.split(" ", 1)[1]: line.split(" ", 1)[0] for line in r.stdout.splitlines() if line.strip()}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sif", required=True)
    ap.add_argument("--src", type=Path, required=True)
    ap.add_argument("--inside", default="/opt/capx/agent")
    a = ap.parse_args()
    want, have = local_manifest(a.src), sif_manifest(a.sif, a.inside)
    missing = sorted(set(want) - set(have))
    extra = sorted(set(have) - set(want))
    diff = sorted(k for k in set(want) & set(have) if want[k] != have[k])
    for k in missing:
        print(f"MISSING {k}")
    for k in extra:
        print(f"EXTRA   {k}")
    for k in diff:
        print(f"DIFF    {k}")
    print(f"files={len(want)} missing={len(missing)} extra={len(extra)} diff={len(diff)}")
    return 0 if not (missing or extra or diff) else 1


if __name__ == "__main__":
    sys.exit(main())
