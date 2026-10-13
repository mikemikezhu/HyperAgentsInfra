## Requirements

- Linux
- Python 3.11
- NVIDIA GPU with a CUDA 13-compatible driver
- Apptainer 1.4.5
- Graphviz development libraries

## Installation

```bash
python3.11 -m venv .venv
source .venv/bin/activate
```

```bash
curl -LsSf https://astral.sh/uv/0.12.1/install.sh \
| env UV_INSTALL_DIR="$VIRTUAL_ENV/bin" UV_NO_MODIFY_PATH=1 sh
```

```bash
uv pip install \
    --torch-backend=cu130 \
    -r requirements.txt
```

## Model

```bash
hf download \
    Qwen/Qwen3.8-27B \
    --local-dir /path/to/Qwen3.8-27B
```

## Formal search stopping and results

On Nibi, Rorqual and Fir, A1/A3/A4 run five generations per job and request
36 hours; A2/A5 retain ten generations per job and 36 hours. Trillium retains
five generations per job and 24 hours for all methods. [TamIA](tamia/README.md)
uses eight H200 GPUs, TP=8, 50 evaluation workers and eight generations per
24-hour job for all methods. The first job also runs generation 0.
These segment sizes apply to both generation-limited chains and
token-budget continuations.

Each Paper Review `long_run.sh` disables validation early stopping by default,
with a global cap of 30 generations. If explicitly enabled, early stopping uses
10 warmup generations and patience 5. Generations 1–10 update the best selection score without consuming
patience. After warmup, only a strict improvement resets patience; ties, lower
scores, and completed failed attempts each consume one step. Failed attempts
remain `None`, not zero. Scores retain the existing staged-evaluation adjustment.

To explicitly enable early stopping from the Infra root:

```bash
bash nibi/paper-review/qwen3.8-27b/original-compressed10/long_run.sh \
    --max_generation 30 \
    --early_stop true \
    --early_stop_min_generations 10 \
    --early_stop_patience 5
```

The default `--early_stop false` retains the original search/checkpoint behavior.
An explicitly configured `--stop_token_budget` still applies. All segments
receive the same stopping parameters; patience is recovered in Python from
the archive and host-private evaluation records, not maintained in shell.
For manually submitted segments, pass `--generation_limit N` after the phase
and segment endpoint to distinguish the global cap from the current job's end.
Smoke and calibration phases explicitly disable early stopping.

With early stopping enabled, stopping freezes the best completed version,
breaking score ties by latest completion. The final measurement uses the
existing held-out protocol (3 repeats × 50 samples) and reuses an earlier test
group only for the same version and test configuration. Its private record is
`generate_<run_id>_private/checkpoints/checkpoint_final.json`.
Already-submitted dependent jobs exit successfully before loading the model
when search and measurements are complete. A manual resume after an interrupted
final test finishes missing measurements without further evolution. Real test
or infrastructure failures are not treated as successful completion.

Each formal run exports `generate_<run_id>_private/results.txt` alongside its
existing private results. It contains per-generation selection scores,
best-so-far scores, one test-ID ordering, and per-example correctness lists for
each complete measurement group, in repeat order. IDs, not CSV completion
order, align the lists. Failed generations are `None`; incomplete test groups
are not filled with zeros. Token labels such as `6M` affect only this text file,
not checkpoint paths or budget calculations. Reused groups are the same repeats,
not additional independent measurements. Validation/test results never enter
agent-visible history through this export.

## IMO Grading and Search Arena

All five clusters provide `imo-grading/qwen3.8-27b/` and
`search-arena/qwen3.8-27b/` beside their existing Paper Review directories.
Each task has the same 11 profiles, `smoke.sh`, `long_run.sh`, and launcher
layout. GPU count, parallelism, worker count, time limits and segment sizes
match that cluster's Paper Review scripts. The initial TaskAgent prompt,
scorers and method settings are unchanged. The default is 30 generations,
early stopping disabled, A1 train/validation samples 50/50, other methods
10/50, and held-out measurements of 50 samples repeated three times.

### Data and environment

The sources below have been approved and downloaded. The six prepared
train/validation/test CSVs are synchronized across the three Nibi development
worktrees. IMO has 100 examples per split. Arena has 98 train, 97 validation
and 100 test examples after removing cross-split duplicate answer pairs;
all methods share these prepared splits.
IMO uses the official [GradingBench snapshot](https://raw.githubusercontent.com/google-deepmind/superhuman/c1ee02e03d4cdb2ab21cd01ac927d895f5287fc8/imobench/gradingbench.csv)
pinned by [HyperAgents' setup script](https://github.com/facebookresearch/HyperAgents/blob/main/domains/imo/setup.sh)
and the existing seed-42 stratified split. `Points` is used to select scores
0, 1, 6 and 7, then removed before export; `Reward` remains for host scoring.
Arena uses [Search Arena](https://huggingface.co/datasets/lmarena-ai/search-arena-v1-7k),
the dataset loaded by [HyperAgents' curator](https://github.com/facebookresearch/HyperAgents/blob/main/domains/search_arena/curate_subsets.py),
at revision `06865038ceb415c1942e58bff8f14150cbc9fbcd`, the existing English/non-tie
filter and the official `dataset_filtered_100_ids.json`. Complete answer pairs
are compared in either A/B order, retaining test over validation over train.
Only overlapping rows are removed, without replacement; test and the order
and labels of retained rows are unchanged. Its `winner` label remains for
host scoring. The existing trusted evaluator removes `Reward` or
`winner` from TaskAgent inputs; test measurements remain host-private.

Reuse the current Qwen3.8-27B weights, venv and
`hyperagents-text-eaa0a09.sif`. No additional model, judge API or Docker daemon
is required. The text image already contains datasets and scikit-learn for
data preparation. Full downloaded datasets and download caches do not belong
in the experiment source worktrees; only the prepared split CSVs are needed.

### Source pins and worktrees

New tasks read `source_shas_imo_grading.env` or `source_shas_search_arena.env`.
These pins are intentionally independent of the existing `source_shas.env`,
so preparing a new task does not change Paper Review continuations.
After reviewing and committing the source changes on `main`, `gvf-hyperagents`
and `ha-structured-history`, fill the corresponding three SHAs in both new
pin files. Empty pins prevent preparation and launcher execution; do not
submit jobs until the datasets, pins and clean detached worktrees are ready.

From the Infra root, prepare one task on the target cluster:

```bash
bash prepare_text_worktrees.sh nibi imo-grading
bash prepare_text_worktrees.sh nibi search-arena
```

Replace `nibi` with `rorqual`, `fir`, `tamia` or `trillium` as appropriate.
The script reuses `$SCRATCH/HyperAgents/HyperAgents` and prepares
`$SCRATCH/HyperAgents/experiments/<task>-<profile>-qwen38/source`, respecting
`HYPERAGENTS_EXPERIMENT_ROOT`. Existing mismatched or dirty worktrees are not
reset; existing results are preserved. Development worktrees, the venv,
model and container remain shared, while each task/profile has separate
source, output, runtime and service-port settings.

### Submission and results

After preparation, submit from the Infra root with the same interface:

```bash
bash nibi/imo-grading/qwen3.8-27b/original-full/long_run.sh --max_generation 30 --early_stop false
bash nibi/search-arena/qwen3.8-27b/original-full/long_run.sh --max_generation 30 --early_stop false
```

Choose the required profile and cluster instead of `original-full` and `nibi`.
`sbatch <cluster>/<task>/qwen3.8-27b/<profile>/smoke.sh calibrate` uses the
existing calibration workflow; no jobs are submitted by preparation.
The segment sizes are inherited starting points, not measured runtime
guarantees for the new tasks.

Each formal run writes `source/outputs/generate_<run_id>_private/results.txt`
using the existing format for validation, generation, token and active-search
wallclock measurements. The full path is
`<experiment_root>/<task>-<profile>-qwen38/source/outputs/generate_<run_id>_private/results.txt`.
Different tasks and profiles therefore never share a results file; continuation
segments of the same run update that run's file, as in Paper Review.
To re-export an existing run manually, use
`python -m measurement.results_export <run_output> --domain imo_grading`
or `--domain search_arena` from its source worktree. Omitting `--domain`
retains the Paper Review behavior. Notebook changes are separate from this
migration.
