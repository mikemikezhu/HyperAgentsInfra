# Trillium Paper Review

The 11 profiles under `paper-review/qwen3.8-27b/` mirror Rorqual. Source revisions
still come from the shared `source_shas.env`; sampling, selection, checkpoints,
three-repeat held-out testing and result reuse are unchanged.

## Resources

- One full H100 node: `--nodes=1 --gpus-per-node=4`, account `rrg-bengioy-ad`.
- One vLLM server, tensor parallelism 4, `max_num_seqs=16`.
- Initial train/validation baselines and subsequent evaluations use 16 workers.
- Five generations per segment; each job requests 24 hours. The first segment
  also includes generation 0 and its tests. This is a time limit, not a guarantee
  that five generations finish within it.
- Let Trillium choose the partition and allocate CPU/RAM with the full node;
  do not copy `--gres`, `--mem` or other clusters' partition names.

See the [Trillium Quickstart](https://docs.alliancecan.ca/wiki/Trillium_Quickstart)
and [Mila's Trillium notes](https://docs.mila.quebec/technical_reference/clusters/drac/#trillium).
Submit from the GPU login node (`trillium-gpu.alliancecan.ca`), with Infra located
under scratch. Compute nodes cannot submit continuation jobs. Home/project are
read-only there; the launcher directs runtime caches to `SLURM_TMPDIR` and uses
offline model loading.

## Prepare assets and source worktrees

Follow [Cluster Migration](../CLUSTER_MIGRATION.md) on Trillium. Rebuild the venv
there rather than copying another cluster's venv. Default paths are:

| Asset | Default path | Optional override |
| --- | --- | --- |
| Experiment worktrees | `$SCRATCH/HyperAgents/experiments` | `HYPERAGENTS_EXPERIMENT_ROOT` |
| Python/vLLM venv | `/project/rrg-bengioy-ad/mikezhu/venv` | `HYPERAGENTS_VENV_PATH` |
| Model | `/project/rrg-bengioy-ad/mikezhu/model/Qwen3.8-27B` | `HYPERAGENTS_MODEL_PATH` |
| Container | `$SCRATCH/apptainer_images/hyperagents-text-eaa0a09.sif` | `HYPERAGENTS_APPTAINER_IMAGE` |

Prepare dependencies, complete model shards, the container and all requested
profile worktrees before submitting. Check that `StdEnv/2023` and
`apptainer/1.4.5` are available. The launcher does not download or install them.

## Smoke check

From the Infra root on the GPU login node, first submit one calibration job:

```bash
cd "$SCRATCH/HyperAgents/HyperAgentsInfra"
sbatch --time=08:00:00 \
    trillium/paper-review/qwen3.8-27b/gvf_lambda1_sibling1/smoke.sh calibrate
```

This starts TP=4, evaluates the initial train/validation baselines and generation
1, and checks the existing data-isolation rules. It does not validate formal
three-repeat checkpoint tests or establish the runtime of a five-generation
segment. Calibration uses the profile's initial-baseline directories, so use
separate smoke worktrees/output roots or archive smoke outputs before a fresh
formal run, as with the other clusters.

## Formal run

To queue one complete 30-generation experiment, run **bash**, not `sbatch`, on
the login node:

```bash
cd "$SCRATCH/HyperAgents/HyperAgentsInfra"
bash trillium/paper-review/qwen3.8-27b/gvf_lambda1_sibling1/long_run.sh
```

This submits six `afterok`-linked jobs with cumulative generation endpoints
5, 10, 15, 20, 25 and 30. Each method has its own chain and output directory.
Replace the profile directory to run another method; submit each chain once.
The wrapper changes to the Infra root before submission, preserving
`SLURM_SUBMIT_DIR` for the compute-node entrypoint.

To apply a token stop as well, explicitly bound the pre-submitted chain:

```bash
bash trillium/paper-review/qwen3.8-27b/gvf_lambda1_sibling1/long_run.sh \
    --max_generation 30 --stop_token_budget 48000000
```

Search stops at whichever limit is reached first, using the existing checkpoint
selection and test logic. Later queued segments exit without starting vLLM once
the search and tests are complete; they are not automatically cancelled. A
token-only, dynamically growing chain is not supported on Trillium because it
would require job submission from a compute node.

Alternatively, to submit just the first five generations for timing:

```bash
sbatch trillium/paper-review/qwen3.8-27b/gvf_lambda1_sibling1/long_run.sh \
    long-run-start 5
```

After that job finishes successfully, continue explicitly with
`long-run-resume 10`, then 15, etc.; do not invoke a fresh full chain against the
same outputs. If a segment fails or times out, its `afterok` successors do not
run automatically. Inspect the existing output and resume explicitly rather
than assuming that 24-hour timeout recovery is automatic.
