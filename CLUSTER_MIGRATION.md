# Cluster Migration

## 1. Clone repositories

```bash
mkdir -p /path/to/scratch/HyperAgents

git clone \
    https://github.com/mikemikezhu/HyperAgents.git \
    /path/to/scratch/HyperAgents/HyperAgents

git clone \
    https://github.com/mikemikezhu/HyperAgentsInfra.git \
    /path/to/scratch/HyperAgents/HyperAgentsInfra
```

## 2. Create the Python environment

```bash
module load python/3.11.5
python --version

mkdir -p /path/to/persistent/project/directory

python -m venv \
    /path/to/persistent/project/directory/venv

source \
    /path/to/persistent/project/directory/venv/bin/activate
```

## 3. Install uv and dependencies

```bash
curl -LsSf https://astral.sh/uv/0.12.1/install.sh \
| env UV_INSTALL_DIR="$VIRTUAL_ENV/bin" UV_NO_MODIFY_PATH=1 sh

mkdir -p /path/to/scratch/uv-cache

cd /path/to/scratch/HyperAgents/HyperAgentsInfra

UV_CACHE_DIR=/path/to/scratch/uv-cache \
uv pip install \
    --link-mode=copy \
    --torch-backend=cu130 \
    -r requirements.txt
```

## 4. Download Qwen3.8-27B

```bash
mkdir -p \
    /path/to/persistent/project/directory/model/Qwen3.8-27B \
    /path/to/scratch/huggingface-cache

HF_HOME=/path/to/scratch/huggingface-cache \
hf download \
    Qwen/Qwen3.8-27B \
    --local-dir /path/to/persistent/project/directory/model/Qwen3.8-27B
```

## 5. Transfer the Apptainer image

```bash
mkdir -p /path/to/scratch/apptainer_images

rsync \
    -ah \
    --info=progress2 \
    "<user>@<source-cluster>:/path/to/hyperagents-text-eaa0a09.sif" \
    /path/to/scratch/apptainer_images/hyperagents-text-eaa0a09.sif

module load apptainer/1.4.5

apptainer exec \
    /path/to/scratch/apptainer_images/hyperagents-text-eaa0a09.sif \
    bash -lc \
    'python --version; patch --version | head -1; dot -V'
```

## 6. Create experiment worktrees

```bash
source \
    /path/to/scratch/HyperAgents/HyperAgentsInfra/source_shas.env

git -C /path/to/scratch/HyperAgents/HyperAgents fetch origin \
    main \
    gvf-hyperagents

mkdir -p \
    /path/to/scratch/HyperAgents/experiments/paper-review-original-full-qwen38 \
    /path/to/scratch/HyperAgents/experiments/paper-review-original-compressed10-qwen38 \
    /path/to/scratch/HyperAgents/experiments/paper-review-gvf-compressed10-qwen38 \
    /path/to/scratch/HyperAgents/experiments/paper-review-gvf-reason-compressed10-qwen38

git -C /path/to/scratch/HyperAgents/HyperAgents worktree add \
    --detach \
    /path/to/scratch/HyperAgents/experiments/paper-review-original-full-qwen38/source \
    "$COMMON_BASE_SHA"

git -C /path/to/scratch/HyperAgents/HyperAgents worktree add \
    --detach \
    /path/to/scratch/HyperAgents/experiments/paper-review-original-compressed10-qwen38/source \
    "$COMMON_BASE_SHA"

git -C /path/to/scratch/HyperAgents/HyperAgents worktree add \
    --detach \
    /path/to/scratch/HyperAgents/experiments/paper-review-gvf-compressed10-qwen38/source \
    "$GVF_SHA"

git -C /path/to/scratch/HyperAgents/HyperAgents worktree add \
    --detach \
    /path/to/scratch/HyperAgents/experiments/paper-review-gvf-reason-compressed10-qwen38/source \
    "$GVF_SHA"
```

## 7. Run host preflight

```bash
cd /path/to/scratch/HyperAgents/HyperAgentsInfra

bash -n \
    "/path/to/scratch/HyperAgents/HyperAgentsInfra/<fir-nibi-or-rorqual>/paper-review/qwen3.8-27b/launcher.sh"

for script_path in \
    "/path/to/scratch/HyperAgents/HyperAgentsInfra/<fir-nibi-or-rorqual>"/paper-review/qwen3.8-27b/*/*.sh
do
    bash -n "$script_path"
done

test -x /path/to/persistent/project/directory/venv/bin/python \
    && echo "OK: Python"

test -x /path/to/persistent/project/directory/venv/bin/vllm \
    && echo "OK: vLLM"

test -f /path/to/persistent/project/directory/model/Qwen3.8-27B/config.json \
    && echo "OK: Qwen model"

module load apptainer/1.4.5
apptainer --version

test -s /path/to/scratch/apptainer_images/hyperagents-text-eaa0a09.sif \
    && echo "OK: Apptainer SIF"

git diff --check

echo "HOST_PREFLIGHT_COMPLETE"
```

## 8. Submit one-generation smoke

```bash
export HYPERAGENTS_EXPERIMENT_ROOT="/path/to/scratch/HyperAgents/experiments"
export HYPERAGENTS_VENV_PATH="/path/to/persistent/project/directory/venv"
export HYPERAGENTS_MODEL_PATH="/path/to/persistent/project/directory/model/Qwen3.8-27B"
export HYPERAGENTS_APPTAINER_IMAGE="/path/to/scratch/apptainer_images/hyperagents-text-eaa0a09.sif"

cd /path/to/scratch/HyperAgents/HyperAgentsInfra

sbatch \
    --time=08:00:00 \
    "/path/to/scratch/HyperAgents/HyperAgentsInfra/<fir-nibi-or-rorqual>/paper-review/qwen3.8-27b/gvf-reason-compressed10/smoke.sh" \
    calibrate

squeue \
    -u "$USER" \
    --format="%.18i %.32j %.2t %.12M %.12l %.6D %R"
```
