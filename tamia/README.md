# TamIA Paper Review

The 11 profiles mirror the other clusters: A1, A2, six A3 lambda/sibling
combinations, two A4 sibling combinations, and A5. All use the shared
`source_shas.env`. This directory changes resource allocation and serving
concurrency, not the search algorithms, prompts, sampling or evidence access.

## Resources and limits

| Setting | Value |
| --- | --- |
| Allocation | One full node, `--gpus-per-node=h200:8` |
| Account | `aip-bengioy` |
| CPU / host RAM | 64 CPUs, `--mem=0` (all node memory) |
| Walltime | 24 hours per job |
| vLLM | TP=8, DP=1, bfloat16 |
| `max_num_seqs` | 64 |
| `max_num_batched_tokens` | 16384; chunked prefill enabled |
| Evaluation / initial-baseline workers | 50 |
| Context / GPU memory utilization | 262144 tokens / 0.9 |
| Formal segment size | Eight generations; first segment also evaluates initial |

TamIA allocates whole GPU nodes and requires an `aip-` account. See the
[Alliance TamIA documentation](https://docs.alliancecan.ca/wiki/TamIA) and
[Mila PAICE documentation](https://docs.mila.quebec/technical_reference/clusters/paice/).
Do not copy other clusters' partition names. Compute nodes have no Internet
access; download assets and install dependencies on the login node beforehand.

These are requested limits, not a guarantee that eight generations finish in
24 hours or that 64 maximum-length requests fit in GPU memory. A3/A4 QA reads,
backfill and generated policies make runtime variable; A1 has additional risk
because of its larger training evaluation. Include startup, initial evaluation
and every checkpoint test when measuring segment duration, not only active
search time. Aim for about 20 hours to leave headroom under the 24-hour limit.

Keep `--enforce-eager`, the Triton GDN prefill backend, existing thinking/output
budgets and library pins. CUDA Graph and prefix-caching experiments are not
part of this configuration. Runtime caches, FlashInfer workspace, vLLM
configuration and Matplotlib configuration use writable `SLURM_TMPDIR` paths.

## Prepare the workspace

Follow [Cluster Migration](../CLUSTER_MIGRATION.md), cloning the repositories
to `$SCRATCH/HyperAgents/HyperAgents` and `$SCRATCH/HyperAgents/HyperAgentsInfra`.
Use personal scratch for the venv and model as well: this migration does not
depend on project storage access or its limited remaining file quota.
For mikezhu, `$SCRATCH` is `/scratch/m/mikezhu`; keep `$SCRATCH` in commands
rather than copying another cluster's absolute paths. Rebuild the venv on TamIA;
do not copy a venv from a different cluster.

| Asset | Default path | Optional override |
| --- | --- | --- |
| A1/A2 development repository | `$SCRATCH/HyperAgents/HyperAgents` | — |
| A3/A4 development worktree | `$SCRATCH/HyperAgents/HyperAgents-gvf` | — |
| A5 development worktree | `$SCRATCH/HyperAgents/HyperAgents-structured-history` | — |
| Infrastructure repository | `$SCRATCH/HyperAgents/HyperAgentsInfra` | — |
| Experiment worktrees | `$SCRATCH/HyperAgents/experiments` | `HYPERAGENTS_EXPERIMENT_ROOT` |
| Python/vLLM venv | `$SCRATCH/HyperAgents/venv` | `HYPERAGENTS_VENV_PATH` |
| Model | `$SCRATCH/HyperAgents/model/Qwen3.8-27B` | `HYPERAGENTS_MODEL_PATH` |
| Container | `$SCRATCH/apptainer_images/hyperagents-text-eaa0a09.sif` | `HYPERAGENTS_APPTAINER_IMAGE` |

All 11 profiles, including start, resume and smoke phases, share these defaults.
Each experiment keeps its own `paper-review-<profile>-qwen38/source/outputs`;
the venv, model and container are shared, not copied into each worktree.
Existing `HYPERAGENTS_*` path overrides still take precedence: check that any
exported values match this layout before preparation or submission.
The compute account remains `aip-bengioy`; using it does not require storing
files in its project directory or grant access to that directory.

Before running the migration guide's installation and download commands, set
these caches in the same login shell (not just inside a temporary `bash` session):

```bash
export UV_CACHE_DIR="$SCRATCH/uv-cache"
export HF_HOME="$SCRATCH/huggingface-cache"
export HF_HUB_CACHE="$HF_HOME/hub"
mkdir -p "$UV_CACHE_DIR" "$HF_HUB_CACHE"
```

These are installation/download caches, not the model directory. During jobs,
the launcher sets runtime caches under `$SLURM_TMPDIR/hyperagents-cache`,
FlashInfer's workspace to `$SLURM_TMPDIR/flashinfer`, and Matplotlib/vLLM
configuration to `$SLURM_TMPDIR/hyperagents-config/{matplotlib,vllm}`.
Keep experiment outputs on scratch, not in these job-temporary directories.

Check both space and file-count quotas after installation and before formal
runs; logs and installation caches also consume quota. Scratch assets remain
subject to the site's retention policy, so keep code and important results
backed up outside scratch. Only use project overrides after verifying both
access and sufficient quota.

From the TamIA login node, after fetching the pinned revisions:

```bash
cd "$SCRATCH/HyperAgents/HyperAgentsInfra"
git -C "$SCRATCH/HyperAgents/HyperAgents" fetch origin
bash tamia/prepare_worktrees.sh
```

This creates 11 detached experiment worktrees with their own `source/outputs`.
Existing clean worktrees at the pinned revision are reused; existing outputs
are never removed. An existing dirty or differently pinned source is rejected,
not reset. The script does not install assets, submit jobs or certify GPU
readiness. The launcher retains the existing checks against reusing a formal
run's output directories.

For separate debugging worktrees in a newly cloned workspace, optionally run:

```bash
git -C "$SCRATCH/HyperAgents/HyperAgents" worktree add \
    --track -b gvf-hyperagents \
    "$SCRATCH/HyperAgents/HyperAgents-gvf" origin/gvf-hyperagents
git -C "$SCRATCH/HyperAgents/HyperAgents" worktree add \
    --track -b ha-structured-history \
    "$SCRATCH/HyperAgents/HyperAgents-structured-history" origin/ha-structured-history
```

The main clone is the A1/A2 development workspace. Never edit experiment source
worktrees during a run or update their pins midway through a submitted chain.

## Checks and calibration

From the Infra root, syntax checks do not submit jobs:

```bash
bash -n tamia/prepare_worktrees.sh
bash -n tamia/paper-review/qwen3.8-27b/launcher.sh
for script in tamia/paper-review/qwen3.8-27b/*/*.sh; do
    bash -n "$script"
done
sbatch --test-only \
    tamia/paper-review/qwen3.8-27b/gvf_lambda1_sibling1/long_run.sh \
    long-run-start 8 --generation_limit 30 --early_stop false
```

`--test-only` checks scheduling, not CUDA compatibility, inference, memory usage
or experiment duration. An optional actual one-generation calibration is:

```bash
sbatch --time=08:00:00 \
    tamia/paper-review/qwen3.8-27b/gvf_lambda1_sibling1/smoke.sh calibrate
```

Calibration also writes initial train/validation baselines. Use a separate
`HYPERAGENTS_EXPERIMENT_ROOT` with its own prepared worktrees, or explicitly
archive calibration outputs before a fresh formal run. It does not exercise
all formal checkpoint tests or prove that eight generations fit in 24 hours.

## Formal submission and continuation

Run **bash**, not `sbatch`, on the login node to submit a complete chain:

```bash
cd "$SCRATCH/HyperAgents/HyperAgentsInfra"
bash tamia/paper-review/qwen3.8-27b/gvf_lambda1_sibling1/long_run.sh \
    --max_generation 30 --early_stop false
```

This pre-submits four `afterok` jobs ending at G8, G16, G24 and G30. The first
runs initial + G1-8, then G9-16, G17-24 and G25-30. All 11 profiles use the same
segment size. Existing G0/5/10/15/20/25/30, token and active-search-hour test
checkpoints are unchanged; segment ends do not add new test checkpoints.
Tests still use 50 samples and three repeats. Validation/test feedback remains
host-private under the existing source-code isolation rules.

To submit all profiles, once each, from the Infra root:

```bash
for script in tamia/paper-review/qwen3.8-27b/*/long_run.sh; do
    bash "$script" --max_generation 30 --early_stop false
done
```

A1 is included for directory parity but has not been timed at this allocation;
omit `original-full` from submission if only A2-A5 are wanted. To use a different
authorized account for a whole chain, the existing Slurm environment mechanism
can override the script directives, for example `SBATCH_ACCOUNT=aip-irina bash
tamia/paper-review/qwen3.8-27b/gvf_lambda1_sibling1/long_run.sh`.

A token stop can be combined with an explicit generation cap:

```bash
bash tamia/paper-review/qwen3.8-27b/gvf_lambda1_sibling1/long_run.sh \
    --max_generation 30 --stop_token_budget 48000000
```

Token-only unbounded chains are intentionally not supported: all continuations
are pre-submitted from the login node, without adding compute-node submission.
Later jobs exit without starting vLLM after the search and required tests finish.

For one segment only, use `sbatch .../long_run.sh long-run-start 8
--generation_limit 30 --early_stop false`; after successful completion, resume
with `long-run-resume 16`, then 24 and 30, preserving the same global cap and
any token stop. Do not start another full chain against the same outputs.
If a job fails or times out, `afterok` successors do not run automatically.
Inspect its output and recover explicitly using the existing resume mechanism;
this change does not add automatic walltime recovery.
