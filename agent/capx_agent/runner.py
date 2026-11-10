"""提出イメージの入口（骨組み）。

構成（要件定義書 §4.6）:
  1. 推論サーバー（vLLM）を1つ起動する
  2. 準備完了（/health）まで待つ
  3. 試行を並列に実行する。各試行は新しいプロセスと新しい一時ディレクトリで動かし、終了時に消す
     （試行をまたいだ情報の持ち越しをしない。推論サーバーの prefix cache の共有は可）

評価コードが試行をどう起動するかは公式配布後に確定するため、ここでは試行の中身を仮のものにしている。
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from . import models

SYSTEM_PYTHON = os.environ.get("CAPX_SERVER_PY", "/usr/bin/python3")


def log(msg: str) -> None:
    print(f"[capx-runner {time.strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


def start_server(model_path: str, port: int, gpu_util: float, max_len: int, log_path: Path) -> "subprocess.Popen[bytes]":
    cmd = [
        SYSTEM_PYTHON, "-m", "vllm.entrypoints.openai.api_server",
        "--model", model_path, "--served-model-name", "capx",
        "--host", "127.0.0.1", "--port", str(port),
        "--gpu-memory-utilization", str(gpu_util), "--max-model-len", str(max_len),
        "--disable-log-requests",
    ]
    log("start server: " + " ".join(cmd))
    f = open(log_path, "w")
    return subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT, start_new_session=True)


def wait_ready(port: int, proc: "subprocess.Popen[bytes]", timeout: float) -> float:
    t0 = time.time()
    while time.time() - t0 < timeout:
        if proc.poll() is not None:
            raise RuntimeError(f"推論サーバーが終了しました（code={proc.returncode}）")
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as r:
                if r.status == 200:
                    return time.time() - t0
        except OSError:
            pass
        time.sleep(1)
    raise TimeoutError("推論サーバーの準備が時間内に終わりませんでした")


def run_trial(i: int, args: argparse.Namespace, base_tmp: Path) -> dict[str, object]:
    tdir = Path(tempfile.mkdtemp(prefix=f"trial{i:03d}-", dir=base_tmp))
    env = {k: v for k, v in os.environ.items() if k in ("PATH", "LANG", "LC_ALL", "MUJOCO_GL", "PYOPENGL_PLATFORM",
                                                        "CAPX_ROBOSUITE_PY", "CAPX_LIBERO_PY", "LIBERO_CONFIG_PATH",
                                                        "NVIDIA_VISIBLE_DEVICES", "CUDA_VISIBLE_DEVICES")}
    env.update(HOME=str(tdir), TMPDIR=str(tdir), XDG_CACHE_HOME=str(tdir / ".cache"))
    cmd = [sys.executable, "-m", "capx_agent.trial", "--trial-id", str(i), "--sim", args.sim,
           "--steps", str(args.steps), "--endpoint", "" if args.no_server else f"http://127.0.0.1:{args.port}"]
    t0 = time.time()
    p = subprocess.run(cmd, env=env, cwd=tdir, capture_output=True, text=True, timeout=args.trial_timeout)
    dt = time.time() - t0
    res: dict[str, object]
    try:
        res = json.loads(p.stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError):
        res = {"ok": False, "error": (p.stderr or p.stdout)[-2000:]}
    res.update(trial=i, seconds=round(dt, 2), returncode=p.returncode, tmpdir=str(tdir))
    shutil.rmtree(tdir, ignore_errors=True)
    res["tmpdir_removed"] = not tdir.exists()
    return res


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="CaP-X runner (skeleton)")
    ap.add_argument("--trials", type=int, default=4)
    ap.add_argument("--parallel", type=int, default=2)
    ap.add_argument("--sim", choices=["none", "robosuite", "libero"], default="none")
    ap.add_argument("--steps", type=int, default=5)
    ap.add_argument("--model-index", type=int, default=0, help="models.lock の何番目のモデルを使うか")
    ap.add_argument("--port", type=int, default=18000)
    ap.add_argument("--gpu-memory-utilization", type=float, default=0.30)
    ap.add_argument("--max-model-len", type=int, default=2048)
    ap.add_argument("--server-timeout", type=float, default=900)
    ap.add_argument("--trial-timeout", type=float, default=600)
    ap.add_argument("--no-server", action="store_true", help="推論サーバーを起動しない（構成確認用）")
    ap.add_argument("--out", type=Path, default=None, help="結果 JSON の出力先（省略時は標準出力）")
    args = ap.parse_args(argv)

    summary: dict[str, object] = {"trials": args.trials, "parallel": args.parallel, "sim": args.sim}
    base_tmp = Path(tempfile.mkdtemp(prefix="capx-run-"))
    server = None
    try:
        if not args.no_server:
            entry = models.load()[args.model_index]
            if not Path(entry.path).is_dir():
                raise FileNotFoundError(f"重みがマウントされていません: {entry.path}（models.lock: {entry.repo}@{entry.revision}）")
            server = start_server(entry.path, args.port, args.gpu_memory_utilization, args.max_model_len,
                                  base_tmp / "server.log")
            summary["model"] = {"repo": entry.repo, "revision": entry.revision, "path": entry.path}
            summary["server_ready_seconds"] = round(wait_ready(args.port, server, args.server_timeout), 2)
            log(f"server ready in {summary['server_ready_seconds']}s")
        t0 = time.time()
        with ThreadPoolExecutor(max_workers=args.parallel) as ex:
            results: list[dict[str, object]] = list(ex.map(lambda i: run_trial(i, args, base_tmp), range(args.trials)))
        summary["trials_seconds"] = round(time.time() - t0, 2)
        summary["results"] = results
        summary["all_ok"] = all(r.get("ok") for r in results)
        summary["isolation_ok"] = (len({r["tmpdir"] for r in results}) == len(results)
                                   and all(r["tmpdir_removed"] for r in results))
    except Exception as e:  # noqa: BLE001
        summary["all_ok"] = False
        summary["error"] = f"{type(e).__name__}: {e}"
        if server is not None and (base_tmp / "server.log").exists():
            summary["server_log_tail"] = (base_tmp / "server.log").read_text(errors="replace")[-3000:]
    finally:
        if server is not None and server.poll() is None:
            os.killpg(server.pid, signal.SIGTERM)
            try:
                server.wait(timeout=60)
            except subprocess.TimeoutExpired:
                os.killpg(server.pid, signal.SIGKILL)
        shutil.rmtree(base_tmp, ignore_errors=True)
    text = json.dumps(summary, ensure_ascii=False, indent=2)
    if args.out:
        args.out.write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0 if summary.get("all_ok") and summary.get("isolation_ok", True) else 1


if __name__ == "__main__":
    sys.exit(main())
