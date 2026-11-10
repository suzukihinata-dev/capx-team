#!/usr/bin/env python3
"""公式配布物とこちらの版の差分を一覧にする（E-06）。

  diff_versions.py --official <公式リポジトリ> [--ours .] [--format md|tsv]

入力（公式側。存在するものだけ読む）:
  pyproject.toml / uv.lock / requirements*.txt / environment.yml / *.def / Dockerfile*
こちら側:
  env/versions.submission.env と env/requirements/*.txt（ロック済みの版）
出力: 項目・本環境の版・公式の版・判定（一致／条件を満たす／一部の環境のみ一致／不一致／公式のみ／本環境のみ）の表。
こちらの pip の版は仮想環境（ロックファイル）ごとに表示する。
存在しない形式は読み飛ばし、その旨を出力する。終了コードは不一致・公式のみがあれば 1。
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    tomllib = None  # type: ignore[assignment]

NAME = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)(?:\[[^\]]*\])?\s*(==|>=|<=|~=|>|<|=)\s*([^\s;#,\\]+)")


def norm(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def parse_req_lines(lines: list[str]) -> dict[str, str]:
    out = {}
    for ln in lines:
        m = NAME.match(ln)
        if m:
            out[norm(m.group(1))] = (m.group(2) if m.group(2) != "==" else "") + m.group(3)
    return out


def official_items(root: Path, log: list[str]) -> dict[str, tuple[str, str]]:
    items: dict[str, tuple[str, str]] = {}

    def add(k: str, v: str, src: Path) -> None:
        items.setdefault(k, (v, str(src.relative_to(root))))

    found_any = False
    for f in sorted(root.rglob("requirements*.txt")):
        found_any = True
        for k, v in parse_req_lines(f.read_text(errors="replace").splitlines()).items():
            add(f"pip:{k}", v, f)
    for f in sorted(root.rglob("pyproject.toml")):
        found_any = True
        if tomllib is None:
            log.append(f"skip (tomllib なし): {f}")
            continue
        data = tomllib.loads(f.read_text())
        deps = data.get("project", {}).get("dependencies", [])
        for k, v in parse_req_lines(deps).items():
            add(f"pip:{k}", v, f)
        rp = data.get("project", {}).get("requires-python")
        if rp:
            add("python", rp, f)
    for f in sorted(root.rglob("uv.lock")):
        found_any = True
        if tomllib is None:
            continue
        for pkg in tomllib.loads(f.read_text()).get("package", []):
            if "version" in pkg:
                add(f"pip:{norm(pkg['name'])}", pkg["version"], f)
    for f in sorted(root.rglob("environment.y*ml")):
        found_any = True
        for ln in f.read_text().splitlines():
            ln = ln.strip().lstrip("- ").strip()
            m = re.match(r"^([A-Za-z0-9._-]+)\s*=+\s*([^\s=]+)", ln)
            if m:
                add(f"conda:{norm(m.group(1))}", m.group(2), f)
    for f in sorted(list(root.rglob("*.def")) + list(root.rglob("Dockerfile*"))):
        found_any = True
        for ln in f.read_text(errors="replace").splitlines():
            m = re.match(r"^\s*(?:From:|FROM)\s+(\S+)", ln)
            if m:
                add("base_image", m.group(1), f)
            for k, v in parse_req_lines(re.findall(r"(?:pip|uv pip) install[^\n]*?\s([A-Za-z0-9._-]+==[^\s]+)", ln)).items():
                add(f"pip:{k}", v, f)
    if not found_any:
        log.append("公式側に対象の形式（requirements*.txt / pyproject.toml / uv.lock / environment.yml / *.def / Dockerfile）が見つかりません")
    for kind in ("requirements*.txt", "pyproject.toml", "uv.lock", "environment.y*ml", "*.def", "Dockerfile*"):
        if not list(root.rglob(kind)):
            log.append(f"読み飛ばし（存在しない）: {kind}")
    return items


def our_items(ours: Path) -> dict[str, dict[str, str]]:
    """こちらの版。pip のパッケージは仮想環境（ロックファイル）ごとに持つ: {項目: {環境名: 版}}"""
    items: dict[str, dict[str, str]] = {}
    env = {}
    for ln in (ours / "env/versions.submission.env").read_text().splitlines():
        if "=" in ln and not ln.lstrip().startswith("#"):
            k, v = ln.split("=", 1)
            env[k.strip()] = v.strip()
    if env.get("BASE_IMAGE"):
        items["base_image"] = {"base": env["BASE_IMAGE"]}
    for key, name in (("ROBOSUITE_PYTHON", "robosuite"), ("LIBERO_PYTHON", "libero")):
        if env.get(key):
            items.setdefault("python", {})[name] = env[key]
    for f in sorted((ours / "env/requirements").glob("*.txt")):
        for k, v in parse_req_lines(f.read_text().splitlines()).items():
            items.setdefault(f"pip:{k}", {})[f.stem] = v
    return items


def vtuple(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in re.findall(r"\d+", v)[:4])


def satisfies(version: str, spec: str) -> bool | None:
    """spec（例: '>=1.10'、'1.2.3'）を version が満たすか。判定できなければ None。"""
    m = re.match(r"^(==|>=|<=|~=|>|<|=)?\s*(.+)$", spec.strip())
    if not m or not re.search(r"\d", m.group(2)) or not re.search(r"\d", version):
        return None
    op, want = m.group(1) or "==", m.group(2)
    a, b = vtuple(version), vtuple(want)
    if op in ("==", "="):
        return version.strip("=") == want or a == b
    return {">=": a >= b, "<=": a <= b, ">": a > b, "<": a < b, "~=": a >= b and a[:len(b) - 1] == b[:len(b) - 1]}[op]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--official", type=Path, required=True)
    ap.add_argument("--ours", type=Path, default=Path("."))
    ap.add_argument("--format", choices=["md", "tsv"], default="md")
    a = ap.parse_args()
    log: list[str] = []
    off = official_items(a.official, log)
    our = our_items(a.ours)
    rows = []
    for k in sorted(set(off) | set(our)):
        o = off.get(k, ("", ""))[0]
        mine = our.get(k, {})
        u = " / ".join(f"{v} ({e})" if len(mine) > 1 else v for e, v in mine.items())
        if k in off and mine:
            if k == "base_image":
                ok = [o == v for v in mine.values()]
            else:
                ok = [satisfies(v, o) for v in mine.values()]
            if all(x is True for x in ok):
                j = "一致" if not re.match(r"^(>=|<=|~=|>|<)", o) else "条件を満たす"
            elif any(x is True for x in ok):
                j = "一部の環境のみ一致"
            else:
                j = "不一致"
        elif k in off:
            j = "公式のみ"
        else:
            j = "本環境のみ"
        rows.append((k, u, o, j, off.get(k, ("", ""))[1]))
    if a.format == "md":
        print("| 項目 | 本環境の版 | 公式の版 | 判定 | 公式の出典 |\n|---|---|---|---|---|")
        for r in rows:
            print("| " + " | ".join(r) + " |")
    else:
        for r in rows:
            print("\t".join(r))
    for m in log:
        print(f"# {m}", file=sys.stderr)
    counts = {j: sum(1 for r in rows if r[3] == j) for j in ("一致", "条件を満たす", "一部の環境のみ一致", "不一致", "公式のみ", "本環境のみ")}
    print("# " + " ".join(f"{k}={v}" for k, v in counts.items()), file=sys.stderr)
    return 1 if counts["不一致"] or counts["公式のみ"] or counts["一部の環境のみ一致"] else 0


if __name__ == "__main__":
    sys.exit(main())
