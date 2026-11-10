#!/usr/bin/env python3
"""提出候補タグ（sub-YYYYMMDD.N）の注釈に書く出自を作る。新しいコミットは作らない。

  provenance.py --sif agent.sif --commit <sha> --models-lock agent/models.lock
出力をそのまま `git tag -a sub-YYYYMMDD.N <sha> -F -` に渡す。
"""
from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 24), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sif", required=True)
    ap.add_argument("--commit", required=True)
    ap.add_argument("--models-lock", required=True)
    a = ap.parse_args()
    app = os.environ.get("APPTAINER", "apptainer")
    labels = subprocess.run([app, "inspect", "--labels", a.sif], capture_output=True, text=True, check=True).stdout
    lab = dict(line.split(": ", 1) for line in labels.splitlines() if ": " in line)
    models = [ln.split("#", 1)[0].split() for ln in open(a.models_lock, encoding="utf-8")]
    models = [m for m in models if m]
    print(f"capx submission candidate {a.commit[:12]}")
    print()
    print(f"source_commit: {a.commit}")
    print(f"label_source_commit: {lab.get('org.capx.source_commit', '?')}")
    print(f"base_tag: {lab.get('org.capx.base_tag', '?')}")
    print(f"agent_sif_sha256: {sha256(a.sif)}")
    print(f"models_lock_sha256: {lab.get('org.capx.models_lock_sha256', '?')}")
    for m in models:
        print(f"weights: {m[0]}@{m[1]} -> {m[2]}")
    print(f"job_protocol_version: {lab.get('org.capx.job_protocol_version', '?')}")
    return 0 if lab.get("org.capx.source_commit") == a.commit else 1


if __name__ == "__main__":
    sys.exit(main())
