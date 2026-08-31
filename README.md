# HyperAgents experiment infrastructure

Host-only launchers for the Paper Review experiments. This repository must
remain outside every agent-visible HyperAgents source worktree. It contains no
model weights, virtual environment, Apptainer image, outputs, or private test
artifacts.

## Frozen source revisions

The exact COMMON_BASE and GVF revisions are defined in `source_shas.env`.
Every launcher verifies both the checked-out SHA and a clean worktree before
starting vLLM or an experiment.

## Fir layout

By default the Fir launcher expects:

```text
$SCRATCH/HyperAgents/experiments/<experiment>/source
$PROJECT/venv
$PROJECT/model/Qwen3.8-27B
$SCRATCH/apptainer_images/hyperagents-text-eaa0a09.sif
```

The first path can be overridden with `HYPERAGENTS_EXPERIMENT_ROOT`. The other
three can be overridden with `HYPERAGENTS_VENV_PATH`,
`HYPERAGENTS_MODEL_PATH`, and `HYPERAGENTS_APPTAINER_IMAGE`.

Do not copy an existing virtual environment between clusters. Rebuild it on
Fir. Download the model again, and copy or rebuild the Apptainer SIF.

## Create the Fir source worktrees

Clone the HyperAgents repository once, fetch both branches, then create four
clean detached worktrees from the frozen SHAs:

```bash
mkdir -p "$SCRATCH/HyperAgents/experiments"
git clone git@github.com:mikemikezhu/HyperAgents.git \
    "$SCRATCH/HyperAgents/HyperAgents"

git -C "$SCRATCH/HyperAgents/HyperAgents" fetch origin main gvf-hyperagents
source ./source_shas.env

git -C "$SCRATCH/HyperAgents/HyperAgents" worktree add --detach \
    "$SCRATCH/HyperAgents/experiments/paper-review-original-full-qwen38/source" \
    "$COMMON_BASE_SHA"
git -C "$SCRATCH/HyperAgents/HyperAgents" worktree add --detach \
    "$SCRATCH/HyperAgents/experiments/paper-review-original-compressed10-qwen38/source" \
    "$COMMON_BASE_SHA"
git -C "$SCRATCH/HyperAgents/HyperAgents" worktree add --detach \
    "$SCRATCH/HyperAgents/experiments/paper-review-gvf-compressed10-qwen38/source" \
    "$GVF_SHA"
git -C "$SCRATCH/HyperAgents/HyperAgents" worktree add --detach \
    "$SCRATCH/HyperAgents/experiments/paper-review-gvf-reason-compressed10-qwen38/source" \
    "$GVF_SHA"
```

Run these commands from the root of this infrastructure repository so that
`source ./source_shas.env` resolves correctly.

## Submit on Fir

The wrappers request two full H100 GPUs with Fir's documented
`--gpus-per-node=h100:2` syntax. They do not use any Rorqual-only partition.
The account is currently `rrg-bengioy-ad`; change it only if `sacctmgr` shows a
different valid Fir allocation.

Each profile must first create its cluster-local initial train/validation
baseline and generation-1 calibration:

```bash
cd fir/paper-review/qwen3.8-27b/original-compressed10
sbatch smoke.sh calibrate
```

After calibration succeeds, a fresh formal run can be submitted with:

```bash
sbatch long_run.sh long-run-start 50
```

Continue the same run in a dependent or later job with:

```bash
sbatch long_run.sh long-run-resume 100
```

Equivalent commands apply to `original-full`, `gvf-compressed10`, and
`gvf-reason-compressed10`. Output logs default to the directory from which
`sbatch` is invoked and are ignored by Git.

## Isolation rule

These scripts are host-only protocol infrastructure. Never copy this repository
inside a HyperAgents source worktree or generated repository. The launcher
continues to verify that host scripts, validation labels, and test labels are
absent from the generated agent-visible repository.
