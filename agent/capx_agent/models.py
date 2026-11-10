"""models.lock の読み取り（標準ライブラリのみ）。"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path

DEFAULT_LOCK = Path(__file__).resolve().parent.parent / "models.lock"


@dataclass(frozen=True)
class ModelEntry:
    repo: str
    revision: str
    path: str
    gated: bool = False


def load(lock: Path = DEFAULT_LOCK) -> list[ModelEntry]:
    entries: list[ModelEntry] = []
    for n, raw in enumerate(lock.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) not in (3, 4) or (len(parts) == 4 and parts[3] != "gated"):
            raise ValueError(f"{lock}:{n}: '<repo> <revision> <path> [gated]' の形式ではありません")
        repo, rev, path = parts[:3]
        if len(rev) != 40 or any(c not in "0123456789abcdef" for c in rev):
            raise ValueError(f"{lock}:{n}: revision は 40 桁の SHA にしてください: {rev}")
        if not path.startswith("/models/"):
            raise ValueError(f"{lock}:{n}: path は /models/ 配下にしてください: {path}")
        entries.append(ModelEntry(repo, rev, path, len(parts) == 4))
    return entries


def lock_sha256(lock: Path = DEFAULT_LOCK) -> str:
    return hashlib.sha256(lock.read_bytes()).hexdigest()
