"""LIBERO の最小エピソード（画面なし・EGL 描画）。/opt/venvs/libero の Python で実行する。
最後の行に結果の JSON を出す。"""
import argparse
import json
import os
import time

os.environ.setdefault("MUJOCO_GL", "egl")
os.environ.setdefault("NUMBA_CACHE_DIR", os.path.join(os.environ.get("TMPDIR", "/tmp"), "numba-cache"))
os.environ.setdefault("PYOPENGL_PLATFORM", "egl")
import numpy as np  # noqa: E402
from libero.libero import benchmark, get_libero_path  # noqa: E402
from libero.libero.envs import OffScreenRenderEnv  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--steps", type=int, default=20)
ap.add_argument("--seed", type=int, default=0)
ap.add_argument("--suite", default="libero_spatial")
ap.add_argument("--task", type=int, default=0)
a = ap.parse_args()

t0 = time.time()
bench = benchmark.get_benchmark_dict()[a.suite]()
task = bench.get_task(a.task)
bddl = os.path.join(get_libero_path("bddl_files"), task.problem_folder, task.bddl_file)
env = OffScreenRenderEnv(bddl_file_name=bddl, camera_heights=128, camera_widths=128)
env.seed(a.seed)
env.reset()
init_states = bench.get_task_init_states(a.task)
obs = env.set_init_state(init_states[a.seed % len(init_states)])
for _ in range(a.steps):
    obs, r, done, _info = env.step(np.zeros(7))
img = obs["agentview_image"]
env.close()
print(json.dumps({"sim": "libero", "suite": a.suite, "task": task.language, "steps": a.steps,
                  "image_shape": list(img.shape), "image_nonzero": bool(img.any()),
                  "seconds": round(time.time() - t0, 2)}))
