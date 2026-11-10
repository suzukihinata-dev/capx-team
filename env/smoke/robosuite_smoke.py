"""Robosuite の最小エピソード（画面なし・EGL 描画）。/opt/venvs/robosuite の Python で実行する。
最後の行に結果の JSON を出す。"""
import argparse
import json
import os
import time

os.environ.setdefault("MUJOCO_GL", "egl")
import numpy as np  # noqa: E402
import robosuite as suite  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--steps", type=int, default=20)
ap.add_argument("--seed", type=int, default=0)
a = ap.parse_args()

t0 = time.time()
env = suite.make(
    "Lift", robots="Panda",
    has_renderer=False, has_offscreen_renderer=True, use_camera_obs=True,
    camera_names="agentview", camera_heights=84, camera_widths=84,
    control_freq=20, horizon=a.steps + 5, seed=a.seed,
)
obs = env.reset()
low, high = env.action_spec
rng = np.random.default_rng(a.seed)
reward = 0.0
for _ in range(a.steps):
    obs, r, done, _info = env.step(rng.uniform(low, high))
    reward += float(r)
img = obs["agentview_image"]
env.close()
print(json.dumps({"sim": "robosuite", "version": suite.__version__, "steps": a.steps,
                  "image_shape": list(img.shape), "image_nonzero": bool(img.any()),
                  "reward_sum": round(reward, 4), "seconds": round(time.time() - t0, 2)}))
