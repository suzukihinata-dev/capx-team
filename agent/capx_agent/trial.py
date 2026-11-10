"""1試行（仮の中身）。runner から新しいプロセス・新しい一時ディレクトリで起動される。

- 推論サーバーに1回問い合わせる（--endpoint が空なら省略）
- --sim を指定した場合は、シミュレータの最小エピソードを別プロセス（シミュレータ用の仮想環境）で動かす
- 最後の行に結果の JSON を1行で出す
試行の外に状態を残さない（書き込みは HOME=TMPDIR=試行専用ディレクトリのみ）。
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.request

SMOKE = {
    "robosuite": ("CAPX_ROBOSUITE_PY", "/opt/capx/env/smoke/robosuite_smoke.py"),
    "libero": ("CAPX_LIBERO_PY", "/opt/capx/env/smoke/libero_smoke.py"),
}


def ask(endpoint: str, trial_id: int) -> str:
    body = json.dumps({
        "model": "capx",
        "messages": [{"role": "user", "content": f"Trial {trial_id}: reply with the single word READY."}],
        "max_tokens": 8, "temperature": 0,
    }).encode()
    req = urllib.request.Request(endpoint + "/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)["choices"][0]["message"]["content"].strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--trial-id", type=int, required=True)
    ap.add_argument("--endpoint", default="")
    ap.add_argument("--sim", default="none")
    ap.add_argument("--steps", type=int, default=5)
    a = ap.parse_args()
    out: dict[str, object] = {"ok": True, "home": os.environ.get("HOME")}
    try:
        if a.endpoint:
            out["llm_reply"] = ask(a.endpoint, a.trial_id)
        if a.sim != "none":
            pyvar, script = SMOKE[a.sim]
            p = subprocess.run([os.environ[pyvar], script, "--steps", str(a.steps), "--seed", str(a.trial_id)],
                               capture_output=True, text=True, timeout=500)
            if p.returncode != 0:
                raise RuntimeError(p.stderr[-1500:])
            out["sim"] = json.loads(p.stdout.strip().splitlines()[-1])
    except Exception as e:  # noqa: BLE001
        out.update(ok=False, error=f"{type(e).__name__}: {e}")
    print(json.dumps(out, ensure_ascii=False))
    return 0 if out["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
