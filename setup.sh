#!/usr/bin/env bash
# One-time environment setup. Safe to re-run: every step is skipped when already done.
# Linux (Pop!_OS / Ubuntu / Debian), macOS, or Windows 11 via WSL2 (run inside the Ubuntu shell).
set -euo pipefail
cd "$(dirname "$0")"

PY=3.12   # 3.13 still lags for torch/numba wheels
have() { command -v "$1" >/dev/null 2>&1; }

# 1. system tools: ffmpeg (pip builds are missing filters we use) and wget (panns_inference downloads its model with it)
missing=""
for t in ffmpeg wget; do have "$t" || missing="$missing $t"; done
if [ -n "$missing" ]; then
  if have apt-get; then sudo apt-get update && sudo apt-get install -y $missing
  elif have brew; then brew install $missing
  else echo "missing:$missing; install them and re-run"; exit 1
  fi
fi

# 2. uv: creates the venv and downloads Python $PY itself if the system lacks it
if ! have uv; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

# 3. venv: created once, then only checked
if [ ! -x .venv/bin/python ]; then
  uv venv --python "$PY" .venv
else
  echo "venv exists, reusing .venv"
fi
VPY=.venv/bin/python

# 4. torch: on Linux without an NVIDIA GPU, pull the CPU wheel (~200 MB) instead of the CUDA one (~2.5 GB)
if [ "$(uname -s)" = Linux ] && ! have nvidia-smi; then
  uv pip install --python "$VPY" torch --index-url https://download.pytorch.org/whl/cpu
fi

# 5. everything else (no-op when already satisfied)
uv pip install --python "$VPY" -r requirements.txt

# 6. doctor: fail loudly if anything the tools rely on is missing
"$VPY" - <<'PYEOF'
import importlib, subprocess, sys
print(f"python {sys.version.split()[0]}  venv {sys.prefix}")
ff = subprocess.run
ver = ff(["ffmpeg", "-version"], capture_output=True, text=True).stdout.split()[2]
filters = ff(["ffmpeg", "-hide_banner", "-filters"], capture_output=True, text=True).stdout
need = "xfade setpts tpad crop zoompan minterpolate scdet signalstats tile loudnorm sidechaincompress adelay amix ebur128 astats lut3d curves noise fps scale concat".split()
missing = [f for f in need if f" {f} " not in filters]
print(f"ffmpeg {ver}  missing filters: {missing or 'none'}")
assert not missing, "ffmpeg build lacks required filters"
if " drawtext " not in filters: print("note: no drawtext filter; Pillow draws text instead")
encs = ff(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True).stdout
hw = [e for e in ("h264_nvenc", "hevc_nvenc", "h264_vaapi", "h264_videotoolbox", "hevc_videotoolbox") if e in encs]
print(f"hardware encoders: {hw or 'none (libx264 fallback)'}")
for mod in ["numpy", "cv2", "scenedetect", "librosa", "soundfile", "torch", "beat_this", "PIL", "panns_inference"]:
    m = importlib.import_module(mod)
    print(f"  {mod:16s} {getattr(m, '__version__', 'ok')}")
for mod in ["faster_whisper", "mlx_whisper"]:
    try: importlib.import_module(mod); print(f"  {mod:16s} ok")
    except ImportError: pass
import torch
dev = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
print(f"torch device: {dev}")
print("setup ok")
PYEOF
