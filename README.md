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

Each Paper Review `long_run.sh` enables validation early stopping by default.
The defaults are 10 warmup generations, patience 5, and a global cap of 30
generations. Generations 1–10 update the best selection score without consuming
patience. After warmup, only a strict improvement resets patience; ties, lower
scores, and completed failed attempts each consume one step. Failed attempts
remain `None`, not zero. Scores retain the existing staged-evaluation adjustment.

From the Infra root, for example:

```bash
bash nibi/paper-review/qwen3.8-27b/original-compressed10/long_run.sh \
    --max_generation 30 \
    --early_stop true \
    --early_stop_min_generations 10 \
    --early_stop_patience 5
```

Use `--early_stop false` to retain the original search/checkpoint behavior.
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
