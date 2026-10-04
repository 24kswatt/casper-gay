#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit nullglob
IFS=$'\n\t'

# Qwen3.8-27B + GLP-49 -> ModelOpt NVFP4 -> DFlash2-b32 -> SGLang
# Target: RunPod container based on lmsysorg/sglang:qwen38-27b,
#         RTX PRO 6000 Blackwell 96GB, /workspace on a >=200GB container disk.
#
# Safe to re-run: every expensive stage is validated before it is skipped.
# It never runs apt full-upgrade, never touches NVIDIA drivers/CUDA/Torch,
# and never uses nested Docker.

SCRIPT_VERSION="2026-10-04.1"

WORKSPACE="${WORKSPACE:-/workspace}"
STACK_DIR="${STACK_DIR:-$WORKSPACE/qwen-stack}"
MODELS_DIR="${MODELS_DIR:-$WORKSPACE/models}"
CACHE_DIR="${CACHE_DIR:-$WORKSPACE/cache}"
TMP_DIR="${TMP_DIR:-$WORKSPACE/tmp}"

HF_VENV="${HF_VENV:-$WORKSPACE/hf-venv}"
MERGE_VENV="${MERGE_VENV:-$WORKSPACE/merge-venv}"
MODELOPT_VENV="${MODELOPT_VENV:-$WORKSPACE/modelopt-venv}"

ADAPTER_REPO="${ADAPTER_REPO:-msuiche/Qwen3.8-27B-abliterated-cyber-GLP-49}"
DRAFT_REPO="${DRAFT_REPO:-JonasLoos/Qwen3.8-27B-DFlash2-b32}"
BASE_REPO="${BASE_REPO:-}"
BASE_REVISION="${BASE_REVISION:-1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0}"

BASE_DIR="$MODELS_DIR/Qwen3.8-27B-BF16"
ADAPTER_DIR="$MODELS_DIR/Qwen3.8-27B-abliterated-cyber-GLP-49"
MERGED_DIR="$MODELS_DIR/Qwen3.8-27B-BF16-GLP49"
NVFP4_DIR="$MODELS_DIR/Qwen3.8-27B-NVFP4-GLP49"
DRAFT_DIR="$MODELS_DIR/Qwen3.8-27B-DFlash2-b32"

MODELOPT_DIR="$STACK_DIR/Model-Optimizer"
MODELOPT_REPO="${MODELOPT_REPO:-https://github.com/NVIDIA/Model-Optimizer.git}"
MODELOPT_REF="${MODELOPT_REF:-}"

OVERLAY_DIR="$STACK_DIR/overlay"
OVERLAY_REPO="${OVERLAY_REPO:-https://github.com/MiaAI-Lab/Qwen3.8-27B-RTX-6000-PRO-SGLang-DSpark.git}"
OVERLAY_COMMIT="${OVERLAY_COMMIT:-c172405482871566033d4d8f5ac519e7a3ce1f79}"
SGLANG_SRC="${SGLANG_SRC:-/sgl-workspace/sglang/python/sglang}"

HF_HOME="${HF_HOME:-$CACHE_DIR/huggingface}"
SGLANG_CACHE_DIR="${SGLANG_CACHE_DIR:-$CACHE_DIR/sglang}"
FLASHINFER_WORKSPACE_DIR="${FLASHINFER_WORKSPACE_DIR:-$CACHE_DIR/flashinfer}"
CCACHE_DIR="${CCACHE_DIR:-$CACHE_DIR/ccache}"

CLEAN_BASE="${CLEAN_BASE:-1}"
CLEAN_BF16="${CLEAN_BF16:-1}"
AUTO_START="${AUTO_START:-1}"
USE_TMUX="${USE_TMUX:-1}"
ALLOW_UNSUPPORTED_GPU="${ALLOW_UNSUPPORTED_GPU:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
FLASH_JOBS="${FLASH_JOBS:-1}"
SERVER_START_TIMEOUT="${SERVER_START_TIMEOUT:-900}"
SERVER_PORT="${SERVER_PORT:-8000}"

INSTALL_SESSION="${INSTALL_SESSION:-qwen-install}"
SERVER_SESSION="${SERVER_SESSION:-qwen-server}"
API_KEY_FILE="$STACK_DIR/.sglang_api_key"
INSTALL_LOG="$STACK_DIR/install.log"
QUANT_LOG="$STACK_DIR/quantize.log"
SERVER_LOG32="$STACK_DIR/server-block32.log"
SERVER_LOG16="$STACK_DIR/server-block16.log"

ORIGINAL_ARGS=("$@")
CURRENT_STAGE="bootstrap"

usage() {
  cat <<'EOF'
Usage:
  bash install-qwen38-blackwell.sh [options]

Options:
  --no-start              Build everything but do not start SGLang.
  --no-tmux               Do not re-launch the installer inside tmux.
  --keep-base             Keep the original BF16 base after a validated merge.
  --keep-merged           Keep the merged BF16+GLP49 after validated NVFP4 export.
  --non-interactive       Never prompt. HF_TOKEN must already be exported if needed.
  --allow-unsupported-gpu Skip the Blackwell/VRAM safety check.
  --force-rebuild         Rebuild merge/NVFP4 even if a validated NVFP4 checkpoint exists.
  -h, --help              Show this help.

Useful environment variables:
  HF_TOKEN=...             Hugging Face token with accepted access to the gated GLP-49 repo.
  FLASH_JOBS=1             Parallel FlashAttention compile jobs (1 is safest).
  AUTO_START=0             Same as --no-start.
  CLEAN_BASE=0             Same as --keep-base.
  CLEAN_BF16=0             Same as --keep-merged.
  MODELOPT_REF=<git-ref>   Optional Model-Optimizer commit/tag. Existing clone is kept as-is.
  FORCE_REBUILD=1          Same as --force-rebuild.
EOF
}

while (($#)); do
  case "$1" in
    --no-start) AUTO_START=0 ;;
    --no-tmux) USE_TMUX=0 ;;
    --keep-base) CLEAN_BASE=0 ;;
    --keep-merged) CLEAN_BF16=0 ;;
    --non-interactive) NONINTERACTIVE=1 ;;
    --allow-unsupported-gpu) ALLOW_UNSUPPORTED_GPU=1 ;;
    --force-rebuild) FORCE_REBUILD=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$WORKSPACE" "$STACK_DIR" "$MODELS_DIR" "$CACHE_DIR" "$TMP_DIR" \
         "$HF_HOME" "$SGLANG_CACHE_DIR" "$FLASHINFER_WORKSPACE_DIR" "$CCACHE_DIR"
touch "$INSTALL_LOG"
exec > >(tee -a "$INSTALL_LOG") 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '\n[%s] [OK] %s\n' "$(ts)" "$*"; }
info() { printf '\n[%s] [..] %s\n' "$(ts)" "$*"; }
warn() { printf '\n[%s] [!!] %s\n' "$(ts)" "$*" >&2; }
die() { printf '\n[%s] [ERR] %s\n' "$(ts)" "$*" >&2; exit 1; }

on_err() {
  local rc=$?
  printf '\n[%s] [ERR] stage=%s rc=%d line=%s command=%q\n' \
    "$(ts)" "$CURRENT_STAGE" "$rc" "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}" >&2
  printf '[ERR] Full installer log: %s\n' "$INSTALL_LOG" >&2
  exit "$rc"
}
trap on_err ERR
trap 'warn "Interrupted during stage: $CURRENT_STAGE"; exit 130' INT TERM

retry() {
  local tries="$1" delay="$2"; shift 2
  local n=1 rc=0
  while (( n <= tries )); do
    if "$@"; then return 0; fi
    rc=$?
    if (( n == tries )); then return "$rc"; fi
    warn "Command failed (attempt $n/$tries, rc=$rc). Retrying in ${delay}s..."
    sleep "$delay"
    ((n++))
  done
  return "$rc"
}

have() { command -v "$1" >/dev/null 2>&1; }

free_gib() {
  df -Pk "$WORKSPACE" | awk 'NR==2 {printf "%.0f\n", $4/1024/1024}'
}

oom_kills() {
  awk '$1=="oom_kill"{print $2}' /sys/fs/cgroup/memory.events 2>/dev/null || echo 0
}

dir_size_gib() {
  du -sk "$1" 2>/dev/null | awk '{printf "%.1f\n", $1/1024/1024}' || echo 0
}

valid_adapter() {
  [[ -s "$ADAPTER_DIR/adapter_config.json" ]] || return 1
  [[ -s "$ADAPTER_DIR/adapter_model.safetensors" ]] || return 1
}

valid_base() {
  [[ -s "$BASE_DIR/config.json" ]] || return 1
  compgen -G "$BASE_DIR/*.safetensors" >/dev/null || return 1
  local kib
  kib="$(du -sk "$BASE_DIR" 2>/dev/null | awk '{print $1}')"
  [[ "${kib:-0}" -gt 40000000 ]]
}

valid_merged() {
  [[ -s "$MERGED_DIR/config.json" ]] || return 1
  [[ -s "$MERGED_DIR/tokenizer_config.json" ]] || return 1
  [[ ! -e "$MERGED_DIR/adapter_config.json" ]] || return 1
  compgen -G "$MERGED_DIR/*.safetensors" >/dev/null || return 1
  local kib
  kib="$(du -sk "$MERGED_DIR" 2>/dev/null | awk '{print $1}')"
  [[ "${kib:-0}" -gt 40000000 ]]
}

valid_nvfp4() {
  [[ -s "$NVFP4_DIR/config.json" ]] || return 1
  compgen -G "$NVFP4_DIR/*.safetensors" >/dev/null || return 1
  local kib
  kib="$(du -sk "$NVFP4_DIR" 2>/dev/null | awk '{print $1}')"
  [[ "${kib:-0}" -gt 5000000 ]] || return 1
  python3 - "$NVFP4_DIR/config.json" <<'PY'
import json, sys
cfg=json.load(open(sys.argv[1], encoding="utf-8"))
q=cfg.get("quantization_config")
if not q:
    raise SystemExit(1)
s=json.dumps(q).lower()
if "nvfp4" not in s and "nv_fp4" not in s:
    raise SystemExit(1)
PY
}

valid_draft() {
  [[ -s "$DRAFT_DIR/config.json" ]] || return 1
  compgen -G "$DRAFT_DIR/*.safetensors" >/dev/null || return 1
  local kib
  kib="$(du -sk "$DRAFT_DIR" 2>/dev/null | awk '{print $1}')"
  [[ "${kib:-0}" -gt 500000 ]]
}

CURRENT_STAGE="system checks"
[[ $EUID -eq 0 ]] || die "Run this installer as root inside the RunPod container."
[[ -d /sgl-workspace/sglang ]] || die "Expected SGLang base image layout /sgl-workspace/sglang. Use lmsysorg/sglang:qwen38-27b or set SGLANG_SRC manually."

info "Installer version: $SCRIPT_VERSION"
info "Workspace: $WORKSPACE ($(free_gib) GiB currently free)"
if findmnt -n -o TARGET,FSTYPE "$WORKSPACE" 2>/dev/null | grep -q '^/workspace '; then
  info "/workspace appears to be a separate mount."
else
  warn "/workspace is not detected as a separate mount; on RunPod this may be ephemeral container storage. Do not terminate the Pod until artifacts are copied elsewhere."
fi

CURRENT_STAGE="apt bootstrap"
export DEBIAN_FRONTEND=noninteractive
retry 3 5 apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl wget jq git git-lfs tmux openssl \
  python3 python3-venv python3-dev \
  build-essential ninja-build cmake ccache
git lfs install --system >/dev/null 2>&1 || true
log "Minimal OS dependencies ready. No apt upgrade, driver, CUDA, Torch, or nested Docker changes were made."

# Re-launch once inside tmux so SSH disconnects do not kill long compiles/quantization.
if [[ "$USE_TMUX" == 1 && -z "${TMUX:-}" && "${QWEN_INSTALL_IN_TMUX:-0}" != 1 ]]; then
  CURRENT_STAGE="tmux handoff"
  if tmux has-session -t "$INSTALL_SESSION" 2>/dev/null; then
    warn "tmux session '$INSTALL_SESSION' already exists; attaching instead of starting a duplicate installer."
    exec tmux attach-session -t "$INSTALL_SESSION"
  fi
  script_path="$(readlink -f "${BASH_SOURCE[0]}")"
  [[ -f "$script_path" ]] || die "Cannot self-relaunch in tmux because script path is not a regular file. Re-run with --no-tmux or save the script first."
  printf -v quoted_script '%q' "$script_path"
  quoted_args=""
  for a in "${ORIGINAL_ARGS[@]}"; do
    printf -v q '%q' "$a"
    quoted_args+=" $q"
  done
  info "Re-launching installer inside tmux session '$INSTALL_SESSION'. Detach with Ctrl+B then D."
  exec tmux new-session -s "$INSTALL_SESSION" \
    "export QWEN_INSTALL_IN_TMUX=1; bash $quoted_script$quoted_args"
fi

CURRENT_STAGE="GPU preflight"
GPU_INFO="$(python3 - <<'PY'
import torch
if not torch.cuda.is_available():
    raise SystemExit("CUDA unavailable")
p=torch.cuda.get_device_properties(0)
print(f"name={p.name}")
print(f"vram_gib={p.total_memory/1024**3:.1f}")
print(f"cc={p.major}.{p.minor}")
print(f"torch={torch.__version__}")
print(f"cuda={torch.version.cuda}")
PY
)" || die "PyTorch/CUDA preflight failed in the SGLang base image."
printf '%s\n' "$GPU_INFO"
if [[ "$ALLOW_UNSUPPORTED_GPU" != 1 ]]; then
  GPU_CC="$(awk -F= '$1=="cc"{print $2}' <<<"$GPU_INFO")"
  GPU_VRAM="$(awk -F= '$1=="vram_gib"{print int($2)}' <<<"$GPU_INFO")"
  [[ "$GPU_CC" == "12.0" ]] || die "Expected Blackwell SM120 (compute capability 12.0), got $GPU_CC. Set ALLOW_UNSUPPORTED_GPU=1 only if you know the recipe is compatible."
  (( GPU_VRAM >= 80 )) || die "Expected >=80 GiB VRAM for this 262K/block32 setup, detected ${GPU_VRAM} GiB."
fi
log "GPU preflight passed."

CURRENT_STAGE="Hugging Face environment"
if [[ ! -x "$HF_VENV/bin/python" ]]; then
  python3 -m venv "$HF_VENV"
fi
"$HF_VENV/bin/python" -m pip install -q -U pip setuptools wheel
"$HF_VENV/bin/python" -m pip install -q -U 'huggingface_hub>=1.5,<2.0'
export HF_HOME
export HUGGINGFACE_HUB_CACHE="$HF_HOME/hub"

hf_snapshot() {
  local repo="$1" dest="$2" rev="${3:-}"
  HF_REPO="$repo" HF_DEST="$dest" HF_REV="$rev" \
  "$HF_VENV/bin/python" - <<'PY'
import os
from huggingface_hub import snapshot_download
repo=os.environ["HF_REPO"]
dest=os.environ["HF_DEST"]
rev=os.environ.get("HF_REV") or None
token=os.environ.get("HF_TOKEN") or None
print(f"Downloading/resuming {repo} -> {dest}" + (f" @ {rev}" if rev else ""))
snapshot_download(
    repo_id=repo,
    revision=rev,
    local_dir=dest,
    token=token,
)
PY
}

check_adapter_access() {
  HF_REPO="$ADAPTER_REPO" "$HF_VENV/bin/python" - <<'PY'
import os, sys
from huggingface_hub import HfApi
repo=os.environ["HF_REPO"]
token=os.environ.get("HF_TOKEN") or None
try:
    HfApi().model_info(repo, token=token)
except Exception as e:
    print(f"{type(e).__name__}: {e}", file=sys.stderr)
    raise SystemExit(1)
PY
}

if [[ "$FORCE_REBUILD" == 1 ]] || ! valid_nvfp4; then
if [[ "$FORCE_REBUILD" == 1 ]] || ! valid_merged; then
  CURRENT_STAGE="GLP-49 gated access"
  if ! valid_adapter; then
    if [[ -z "${HF_TOKEN:-}" ]]; then
      if [[ "$NONINTERACTIVE" == 1 ]]; then
        die "$ADAPTER_REPO is gated. Export HF_TOKEN after accepting its model terms, then re-run."
      fi
      warn "$ADAPTER_REPO is gated. Accept its terms on Hugging Face, then provide a token with read access."
      read -rsp "HF_TOKEN (input hidden): " HF_TOKEN
      printf '\n'
      export HF_TOKEN
    fi
    check_adapter_access || die "HF_TOKEN cannot access $ADAPTER_REPO. The gated model terms may not be accepted yet."
    retry 3 10 hf_snapshot "$ADAPTER_REPO" "$ADAPTER_DIR"
  else
    info "Adapter already present; skipping gated download."
  fi

  if [[ -z "$BASE_REPO" ]]; then
    BASE_REPO="$(python3 - "$ADAPTER_DIR/adapter_config.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1], encoding="utf-8"))
print(j.get("base_model_name_or_path") or "")
PY
)"
    BASE_REPO="${BASE_REPO:-Qwen/Qwen3.8-27B}"
  fi

  CURRENT_STAGE="base model download"
  if ! valid_base; then
    free_now="$(free_gib)"
    if (( free_now < 110 )); then
      warn "Only ${free_now} GiB free before the BF16 download/merge. The 200GB RunPod container disk is strongly recommended."
    fi
    retry 3 15 hf_snapshot "$BASE_REPO" "$BASE_DIR" "$BASE_REVISION"
  else
    info "BF16 base already present; skipping download."
  fi

  CURRENT_STAGE="merge environment"
  if [[ ! -x "$MERGE_VENV/bin/python" ]]; then
    python3 -m venv --system-site-packages "$MERGE_VENV"
  fi
  "$MERGE_VENV/bin/python" -m pip install -q -U pip setuptools wheel
  "$MERGE_VENV/bin/python" -m pip install -q -U peft accelerate safetensors

  cat > "$STACK_DIR/merge_glp49.py" <<'PY'
import os, shutil, torch
from transformers import AutoModelForImageTextToText, AutoTokenizer
from peft import PeftModel

base=os.environ["BASE_DIR"]
adapter=os.environ["ADAPTER_DIR"]
out=os.environ["MERGED_DIR"]

print("Loading BF16 base:", base)
model=AutoModelForImageTextToText.from_pretrained(
    base,
    torch_dtype=torch.bfloat16,
    low_cpu_mem_usage=True,
    trust_remote_code=True,
)
print("Loading GLP-49 adapter:", adapter)
model=PeftModel.from_pretrained(model, adapter)
print("Merging adapter into base...")
model=model.merge_and_unload(progressbar=True, safe_merge=True)

if os.path.exists(out):
    shutil.rmtree(out)
os.makedirs(out, exist_ok=True)

print("Saving merged checkpoint:", out)
model.save_pretrained(
    out,
    safe_serialization=True,
    max_shard_size="4GB",
)
tok=AutoTokenizer.from_pretrained(base, trust_remote_code=True)
tok.save_pretrained(out)
print("MERGE COMPLETE")
PY

  CURRENT_STAGE="GLP-49 merge"
  if [[ -d "$MERGED_DIR" ]]; then
    warn "Removing incomplete merged output: $MERGED_DIR"
    rm -rf "$MERGED_DIR"
  fi
  BASE_DIR="$BASE_DIR" ADAPTER_DIR="$ADAPTER_DIR" MERGED_DIR="$MERGED_DIR" \
    "$MERGE_VENV/bin/python" "$STACK_DIR/merge_glp49.py"

  valid_merged || die "Merged checkpoint validation failed. The original BF16 base has NOT been deleted."
  log "GLP-49 successfully baked into BF16 checkpoint ($(dir_size_gib "$MERGED_DIR") GiB)."

  if [[ "$CLEAN_BASE" == 1 && -d "$BASE_DIR" ]]; then
    info "Merged checkpoint validated; deleting original BF16 base to free disk."
    rm -rf "$BASE_DIR"
    sync
  fi
else
  log "Validated merged BF16+GLP49 checkpoint already exists; skipping base download and merge."
fi

CURRENT_STAGE="ModelOpt source"
if [[ ! -d "$MODELOPT_DIR/.git" ]]; then
  retry 3 10 git clone "$MODELOPT_REPO" "$MODELOPT_DIR"
  if [[ -n "$MODELOPT_REF" ]]; then
    git -C "$MODELOPT_DIR" fetch --depth 1 origin "$MODELOPT_REF"
    git -C "$MODELOPT_DIR" checkout --detach FETCH_HEAD
  fi
else
  info "Existing Model-Optimizer clone found at $MODELOPT_DIR; keeping its current HEAD for reproducibility."
  if [[ -n "$MODELOPT_REF" ]]; then
    git -C "$MODELOPT_DIR" fetch --depth 1 origin "$MODELOPT_REF"
    git -C "$MODELOPT_DIR" checkout --detach FETCH_HEAD
  fi
fi
MODELOPT_HEAD="$(git -C "$MODELOPT_DIR" rev-parse HEAD)"
info "Model-Optimizer HEAD: $MODELOPT_HEAD"

CURRENT_STAGE="ModelOpt environment"
if [[ ! -x "$MODELOPT_VENV/bin/python" ]]; then
  python3 -m venv --system-site-packages "$MODELOPT_VENV"
fi
"$MODELOPT_VENV/bin/python" -m pip install -q -U pip setuptools wheel packaging ninja

# Install the repo's HF-PTQ requirements, but intentionally exclude flash-attn:
# build isolation was the failure mode seen on this image because it could not import torch.
REQ="$MODELOPT_DIR/examples/hf_ptq/requirements.txt"
if [[ -f "$REQ" ]]; then
  FILTERED_REQ="$TMP_DIR/modelopt-hf-ptq-requirements.no-flash.txt"
  grep -Eiv '^[[:space:]]*(flash-attn|flash_attn|torch|torchvision|torchaudio|triton|nvidia-modelopt|modelopt)([<>=~! ;].*)?$' "$REQ" > "$FILTERED_REQ" || true
  if [[ -s "$FILTERED_REQ" ]]; then
    "$MODELOPT_VENV/bin/python" -m pip install -q -r "$FILTERED_REQ"
  fi
else
  warn "ModelOpt HF-PTQ requirements file not found; installing the known runtime dependencies explicitly."
  "$MODELOPT_VENV/bin/python" -m pip install -q -U \
    accelerate datasets deepspeed peft compressed-tensors fire psutil zstandard scipy
fi

# The source checkout and the imported ModelOpt MUST match. Do not use the system wheel
# for these examples. Editable install + PYTHONPATH handles the duplicate system package.
"$MODELOPT_VENV/bin/python" -m pip install -q -e "$MODELOPT_DIR" --no-deps
export PYTHONPATH="$MODELOPT_DIR${PYTHONPATH:+:$PYTHONPATH}"

CURRENT_STAGE="FlashAttention"
flash_ok=0
if PYTHONPATH="$PYTHONPATH" "$MODELOPT_VENV/bin/python" - <<'PY'
import flash_attn
from packaging.version import Version
v=Version(flash_attn.__version__.split("+")[0])
print("FlashAttention:", flash_attn.__version__)
raise SystemExit(0 if v >= Version("2.8.3") else 1)
PY
then
  flash_ok=1
fi

if [[ "$flash_ok" != 1 ]]; then
  info "FlashAttention >=2.8.3 not available in the ModelOpt venv. Building 2.8.3.post1 for SM120."
  export FLASH_ATTN_CUDA_ARCHS=120
  export MAX_JOBS="$FLASH_JOBS"
  export CMAKE_BUILD_PARALLEL_LEVEL="$FLASH_JOBS"
  export MAKEFLAGS="-j$FLASH_JOBS"
  export NVCC_THREADS=2
  export TMPDIR="$TMP_DIR"
  export CCACHE_DIR
  oom_before="$(oom_kills)"
  set +e
  "$MODELOPT_VENV/bin/python" -m pip install -v \
    'flash-attn==2.8.3.post1' --no-build-isolation \
    2>&1 | tee "$STACK_DIR/flash-attn-build.log"
  flash_rc=${PIPESTATUS[0]}
  set -e
  if (( flash_rc != 0 )); then
    oom_after="$(oom_kills)"
    if (( oom_after > oom_before )); then
      die "FlashAttention build failed and cgroup oom_kill increased ($oom_before -> $oom_after). Re-run with FLASH_JOBS=1 after increasing host RAM."
    fi
    die "FlashAttention build failed (rc=$flash_rc). See $STACK_DIR/flash-attn-build.log"
  fi
fi

(
  cd /tmp
  MODELOPT_EXPECTED="$MODELOPT_DIR" PYTHONPATH="$PYTHONPATH" "$MODELOPT_VENV/bin/python" - <<'PY'
import os, pathlib, torch, flash_attn, modelopt
import modelopt.torch.models
from modelopt.recipe import ModelOptAutoQuantizeRecipe, ModelOptPTQRecipe, load_recipe
expected=pathlib.Path(os.environ["MODELOPT_EXPECTED"]).resolve()
m=pathlib.Path(modelopt.__file__).resolve()
mm=pathlib.Path(modelopt.torch.models.__file__).resolve()
if expected not in m.parents or expected not in mm.parents:
    raise SystemExit(f"WRONG MODELOPT IMPORT: {m} / {mm}; expected checkout under {expected}")
print("ModelOpt:", m)
print("Models:", mm)
print("Torch:", torch.__version__)
print("CUDA:", torch.version.cuda)
print("GPU:", torch.cuda.get_device_name(0))
print("FlashAttention:", flash_attn.__version__)
print("ModelOpt preflight: OK")
PY
)

# If an older abandoned flash-attn build is still compiling in /tmp while a valid module
# is already installed, terminate only those stale compiler processes before PTQ.
mapfile -t stale_pids < <(
  ps -eo pid=,args= |
    awk '/\/tmp\/pip-install-.*flash-attn/ && /(nvcc|ccache|ninja)/ {print $1}'
)
if ((${#stale_pids[@]})); then
  warn "Found stale FlashAttention compiler PIDs after a valid install: ${stale_pids[*]}"
  for p in "${stale_pids[@]}"; do kill "$p" 2>/dev/null || true; done
  sleep 2
fi

RECIPE="$MODELOPT_DIR/modelopt_recipes/models/Qwen/Qwen3.8-27B/ptq/nvfp4_w4a4_mlp_fp8_attn_local_hessian.yaml"
[[ -s "$RECIPE" ]] || die "Required Qwen3.8 NVFP4 Local-Hessian recipe is missing: $RECIPE"

CURRENT_STAGE="NVFP4 quantization"
cat > "$STACK_DIR/quantize.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
export CUDA_VISIBLE_DEVICES=0
export HF_HOME=$(printf '%q' "$HF_HOME")
export PYTHONPATH=$(printf '%q' "$MODELOPT_DIR")"\${PYTHONPATH:+:\$PYTHONPATH}"
cd $(printf '%q' "$MODELOPT_DIR")
exec $(printf '%q' "$MODELOPT_VENV/bin/python") \
  examples/hf_ptq/hf_ptq.py \
  --pyt_ckpt_path $(printf '%q' "$MERGED_DIR") \
  --recipe $(printf '%q' "$RECIPE") \
  --dataset nemotron-post-training-v3 \
  --calib_size 512 \
  --calib_seq 2048 \
  --batch_size 1 \
  --export_path $(printf '%q' "$NVFP4_DIR")
EOF
chmod +x "$STACK_DIR/quantize.sh"

if [[ "$FORCE_REBUILD" != 1 ]] && valid_nvfp4; then
  log "Validated NVFP4 checkpoint already exists ($(dir_size_gib "$NVFP4_DIR") GiB); skipping PTQ."
else
  [[ -d "$MERGED_DIR" ]] && valid_merged || die "Cannot quantize: merged BF16+GLP49 checkpoint is missing or invalid."
  if [[ -d "$NVFP4_DIR" ]]; then
    if [[ "$FORCE_REBUILD" == 1 ]]; then
      warn "FORCE_REBUILD=1: removing existing NVFP4 output: $NVFP4_DIR"
    else
      warn "Removing incomplete NVFP4 output before retry: $NVFP4_DIR"
    fi
    rm -rf "$NVFP4_DIR"
  fi
  info "Starting NVFP4 Local-Hessian PTQ. Calibration uses Nemotron datasets; this can take tens of minutes."
  oom_before="$(oom_kills)"
  set +e
  "$STACK_DIR/quantize.sh" 2>&1 | tee "$QUANT_LOG"
  quant_rc=${PIPESTATUS[0]}
  set -e
  if (( quant_rc != 0 )); then
    oom_after="$(oom_kills)"
    if (( oom_after > oom_before )); then
      die "Quantization failed and oom_kill increased ($oom_before -> $oom_after). Merged BF16 checkpoint was preserved. See $QUANT_LOG"
    fi
    die "Quantization failed (rc=$quant_rc). Merged BF16 checkpoint was preserved. See $QUANT_LOG"
  fi
  valid_nvfp4 || die "PTQ process exited 0 but NVFP4 checkpoint validation failed. Merged BF16 checkpoint was preserved."
  log "NVFP4 export validated ($(dir_size_gib "$NVFP4_DIR") GiB)."
fi

if [[ "$CLEAN_BF16" == 1 && -d "$MERGED_DIR" ]] && valid_nvfp4; then
  info "NVFP4 checkpoint validated; deleting the 51GB merged BF16 checkpoint."
  rm -rf "$MERGED_DIR"
  sync
fi

else
  log "Validated NVFP4 checkpoint already exists ($(dir_size_gib "$NVFP4_DIR") GiB); skipping merge, ModelOpt, FlashAttention build, and PTQ."
fi

CURRENT_STAGE="DFlash2 draft"
if valid_draft; then
  log "DFlash2-b32 draft already present ($(dir_size_gib "$DRAFT_DIR") GiB)."
else
  [[ -d "$DRAFT_DIR" ]] && rm -rf "$DRAFT_DIR"
  retry 3 10 hf_snapshot "$DRAFT_REPO" "$DRAFT_DIR"
  valid_draft || die "DFlash2-b32 download completed but validation failed."
fi

CURRENT_STAGE="DFlash2 overlay"
if [[ ! -d "$OVERLAY_DIR/.git" ]]; then
  retry 3 10 git clone --filter=blob:none "$OVERLAY_REPO" "$OVERLAY_DIR"
fi
if ! git -C "$OVERLAY_DIR" cat-file -e "${OVERLAY_COMMIT}^{commit}" 2>/dev/null; then
  git -C "$OVERLAY_DIR" fetch --depth 1 origin "$OVERLAY_COMMIT"
fi
git -C "$OVERLAY_DIR" checkout -q --detach "$OVERLAY_COMMIT"

PATCH="$OVERLAY_DIR/patch/sglang"
FILES=(
  srt/models/dflash.py
  kernels/ops/speculative/dflash.py
  srt/speculative/dflash_utils.py
  srt/speculative/dflash_worker_v2.py
  srt/speculative/dflash_info.py
  srt/speculative/dflash_info_v2.py
  srt/speculative/draft_worker_common.py
  srt/speculative/spec_utils.py
  srt/mem_cache/allocation_sizing.py
  srt/layers/moe/utils.py
  srt/layers/logprob_processor.py
)
for f in "${FILES[@]}"; do
  [[ -s "$PATCH/$f" ]] || die "Overlay is missing required file: $f"
done

BACKUP_DIR="$STACK_DIR/sglang-overlay-backup"
mkdir -p "$BACKUP_DIR"
for f in "${FILES[@]}"; do
  src="$PATCH/$f"
  dst="$SGLANG_SRC/$f"
  if [[ -e "$dst" && ! -e "$BACKUP_DIR/$f" ]]; then
    mkdir -p "$(dirname "$BACKUP_DIR/$f")"
    cp -a "$dst" "$BACKUP_DIR/$f"
  fi
  if [[ -e "$dst" ]] && cmp -s "$src" "$dst"; then
    continue
  fi
  install -D -m 0644 "$src" "$dst"
done
log "DFlash2 overlay applied (${#FILES[@]} files, commit $OVERLAY_COMMIT)."

CURRENT_STAGE="server scripts"
if [[ ! -s "$API_KEY_FILE" ]]; then
  umask 077
  openssl rand -hex 32 > "$API_KEY_FILE"
  chmod 600 "$API_KEY_FILE"
  log "Generated a new SGLang API key at $API_KEY_FILE (not printed to logs)."
fi

cat > "$STACK_DIR/start-server.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
BLOCK="\${1:-32}"
case "\$BLOCK" in 16|32) ;; *) echo "Block must be 16 or 32" >&2; exit 2 ;; esac
KEY_FILE=$(printf '%q' "$API_KEY_FILE")
[[ -s "\$KEY_FILE" ]] || { echo "Missing API key file: \$KEY_FILE" >&2; exit 1; }
export SGLANG_API_KEY="\$(<"\$KEY_FILE")"
export HF_HOME=$(printf '%q' "$HF_HOME")
export SGLANG_CACHE_DIR=$(printf '%q' "$SGLANG_CACHE_DIR")
export FLASHINFER_WORKSPACE_DIR=$(printf '%q' "$FLASHINFER_WORKSPACE_DIR")
exec python3 -m sglang.launch_server \
  --model-path $(printf '%q' "$NVFP4_DIR") \
  --served-model-name qwen \
  --trust-remote-code \
  --api-key "\$SGLANG_API_KEY" \
  --speculative-algorithm DFLASH \
  --speculative-draft-model-path $(printf '%q' "$DRAFT_DIR") \
  --speculative-num-draft-tokens "\$BLOCK" \
  --speculative-dflash-block-size "\$BLOCK" \
  --speculative-draft-model-quantization unquant \
  --speculative-draft-attention-backend triton \
  --attention-backend triton \
  --min-free-slots-delay 1 \
  --kv-cache-dtype fp8_e4m3 \
  --mem-fraction-static 0.90 \
  --context-length 262144 \
  --max-running-requests 1 \
  --mamba-radix-cache-strategy extra_buffer \
  --chunked-prefill-size 2048 \
  --reasoning-parser qwen3 \
  --tool-call-parser qwen3_coder \
  --default-chat-template-kwargs '{"reasoning_effort":"medium"}' \
  --sampling-defaults model \
  --watchdog-timeout 1800 \
  --host 0.0.0.0 \
  --port $(printf '%q' "$SERVER_PORT")
EOF
chmod +x "$STACK_DIR/start-server.sh"

cat > "$STACK_DIR/test-api.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
KEY="\$(<$(printf '%q' "$API_KEY_FILE"))"
BASE="http://127.0.0.1:$(printf '%q' "$SERVER_PORT")"
echo "=== /v1/models ==="
curl -fsS "\$BASE/v1/models" -H "Authorization: Bearer \$KEY" | jq
echo
echo "=== chat completion ==="
curl -fsS "\$BASE/v1/chat/completions" \
  -H "Authorization: Bearer \$KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model":"qwen",
    "messages":[{"role":"user","content":"Explain Windows IRQL and why pageable memory must not be touched at DISPATCH_LEVEL."}],
    "max_tokens":512,
    "temperature":0.2
  }' | jq
EOF
chmod +x "$STACK_DIR/test-api.sh"

cat > "$STACK_DIR/benchmark.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
export QWEN_API_KEY="\$(<$(printf '%q' "$API_KEY_FILE"))"
export QWEN_URL="http://127.0.0.1:$(printf '%q' "$SERVER_PORT")/v1/chat/completions"
python3 - <<'PY'
import json, os, time, urllib.request
payload={
    "model":"qwen",
    "messages":[{"role":"user","content":"Give a detailed technical explanation of Windows IRQL, DPCs, APCs, spin locks, pageable memory and the most common driver bugs involving them."}],
    "max_tokens":2048,
    "temperature":0.2,
}
data=json.dumps(payload).encode()
req=urllib.request.Request(
    os.environ["QWEN_URL"], data=data,
    headers={
        "Authorization":"Bearer "+os.environ["QWEN_API_KEY"],
        "Content-Type":"application/json",
    },
)
t0=time.perf_counter()
with urllib.request.urlopen(req, timeout=1800) as r:
    obj=json.load(r)
dt=time.perf_counter()-t0
usage=obj.get("usage") or {}
n=usage.get("completion_tokens")
print(f"elapsed_s={dt:.3f}")
print(f"completion_tokens={n}")
if isinstance(n,(int,float)) and dt>0:
    print(f"end_to_end_tok_s={n/dt:.2f}")
choice=(obj.get("choices") or [{}])[0]
msg=choice.get("message") or {}
reasoning=msg.get("reasoning_content")
if reasoning:
    print("\\n=== reasoning ===\\n"+reasoning[:4000])
print("\\n=== answer ===\\n"+str(msg.get("content",""))[:8000])
PY
EOF
chmod +x "$STACK_DIR/benchmark.sh"

server_ready() {
  local key
  key="$(<"$API_KEY_FILE")"
  curl -fsS --max-time 3 \
    "http://127.0.0.1:$SERVER_PORT/v1/models" \
    -H "Authorization: Bearer $key" >/dev/null 2>&1
}

start_server_tmux() {
  local block="$1" logf="$2"
  tmux kill-session -t "$SERVER_SESSION" 2>/dev/null || true
  : > "$logf"
  local cmd
  printf -v cmd '%q %q 2>&1 | tee %q' "$STACK_DIR/start-server.sh" "$block" "$logf"
  tmux new-session -d -s "$SERVER_SESSION" "$cmd"
}

wait_server() {
  local timeout="$1" elapsed=0
  while (( elapsed < timeout )); do
    if server_ready; then return 0; fi
    if ! tmux has-session -t "$SERVER_SESSION" 2>/dev/null; then return 10; fi
    sleep 5
    ((elapsed+=5))
  done
  if tmux has-session -t "$SERVER_SESSION" 2>/dev/null; then
    return 20
  fi
  return 10
}

CURRENT_STAGE="final start"
if [[ "$AUTO_START" == 1 ]]; then
  if server_ready; then
    log "SGLang is already responding on port $SERVER_PORT; not starting a duplicate server."
  elif pgrep -af 'sglang\.launch_server' >/dev/null 2>&1; then
    warn "A different SGLang launch_server process already exists but is not healthy on port $SERVER_PORT. Not starting a second copy automatically."
    pgrep -af 'sglang\.launch_server' || true
  else
    info "Starting DFlash2 block32 in tmux session '$SERVER_SESSION'."
    start_server_tmux 32 "$SERVER_LOG32"
    if wait_server "$SERVER_START_TIMEOUT"; then
      log "SGLang block32 is ready."
    else
      rc=$?
      if [[ "$rc" == 10 ]]; then
        warn "Block32 server exited before becoming ready. Falling back to block16. Log: $SERVER_LOG32"
        start_server_tmux 16 "$SERVER_LOG16"
        if wait_server "$SERVER_START_TIMEOUT"; then
          log "SGLang block16 fallback is ready."
        else
          rc2=$?
          if [[ "$rc2" == 20 ]]; then
            warn "Block16 is still alive after ${SERVER_START_TIMEOUT}s but not ready yet. Leaving it running. Watch: tail -f $SERVER_LOG16"
          else
            die "Both block32 and block16 failed. Inspect $SERVER_LOG32 and $SERVER_LOG16"
          fi
        fi
      elif [[ "$rc" == 20 ]]; then
        warn "Block32 is still alive after ${SERVER_START_TIMEOUT}s but not ready yet. Leaving it running; no premature fallback. Watch: tail -f $SERVER_LOG32"
      fi
    fi
  fi
else
  info "AUTO_START=0. Start manually with: tmux new -s $SERVER_SESSION '$STACK_DIR/start-server.sh 32'"
fi

CURRENT_STAGE="summary"
printf '\n============================================================\n'
printf 'Qwen3.8 Blackwell setup complete\n'
printf '============================================================\n'
printf 'NVFP4 model : %s\n' "$NVFP4_DIR"
printf 'DFlash2     : %s\n' "$DRAFT_DIR"
printf 'API key file: %s (chmod 600; key intentionally not printed)\n' "$API_KEY_FILE"
printf 'Start       : %s 32\n' "$STACK_DIR/start-server.sh"
printf 'Test        : %s\n' "$STACK_DIR/test-api.sh"
printf 'Benchmark   : %s\n' "$STACK_DIR/benchmark.sh"
printf 'Server logs : %s / %s\n' "$SERVER_LOG32" "$SERVER_LOG16"
printf 'Install log : %s\n' "$INSTALL_LOG"
printf 'Disk        : %s GiB free\n' "$(free_gib)"
printf '============================================================\n'

if server_ready; then
  "$STACK_DIR/test-api.sh" || warn "Server is ready but the smoke test returned an error; inspect the server log."
fi
