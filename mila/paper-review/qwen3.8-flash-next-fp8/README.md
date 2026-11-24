# Paper Review with Cairn

This entry point uses `openai/Qwen/Qwen3.8-Flash-Next-FP8` through the existing
LiteLLM client at `http://cn-d003.server.mila.quebec:8080/v1`. It requests CPU
resources and does not start vLLM or load model weights.

## Before running

The model-specific `source_shas.env` pins each method's reviewed adaptation commit.
Fetch those commits on Mila, then run `prepare_worktrees.sh` there.
Do not use the repository-root 27B pins for these experiments.

Required environment settings, inherited from the submitting shell:

- `LITELLM_KEY`: the existing Mila API credential. Do not save it in this repo,
  pass it as a command-line argument, or print it.
- `HYPERAGENTS_APPTAINER_IMAGE`: a separately built text SIF from the adapted
  GVF branch's `Dockerfile.text` / `requirements-text.txt`, also usable by the
  other methods. Keep the existing 27B SIF intact.
- `HYPERAGENTS_TOKENIZER_PATH`: a self-contained local directory of tokenizer
  files from revision `236dfdf285828023ca3bcd3f37366c58a3469b13` of
  `Qwen/Qwen3.8-Flash-Next-FP8`. Include its configuration, tokenizer data and
  `chat_template.jinja`; materialize HF cache symlinks before using this directory
  as the container's read-only bind mount. No model weights are needed.

The host environment defaults to `~/venv` (override with
`HYPERAGENTS_VENV_PATH`). It must have the text runtime and tokenizer dependencies;
the separately built container has its own environment. Singularity 3.7.1 is
loaded by the launcher. No environment or image is installed by these scripts.

## Experiment layout and submission

Source worktrees are detached at their pinned commits under:

```text
~/scratch/HyperAgents/experiments/
    paper-review-<profile>-qwen38-flash-next-fp8-cairn/source/
```

The four main profiles use the following Paper Review protocols.

| Profile | Train / validation | Search |
| --- | --- | --- |
| `original-full` | 50 / 50 | Original sampling and staged evaluation |
| `original-compressed10` | 10 / 50 | Compressed baseline, random per generation |
| `gvf_lambda5_sibling0` | 10 / 50 | GVF, selection λ=5, zero siblings |
| `gvf_map` | 10 / 50 | Two islands, shared batch per round |

The original and compressed baselines use selection λ=10. Comparing the
compressed baseline with the main GVF arm therefore varies both GVF and
selection sharpness. The existing sibling-free GVF λ=10 profile provides
the matched-λ comparison. A sibling-free λ=1 profile is also available.

Each profile gets **192M search tokens per run**. Report held-out performance
at **6M, 12M, 24M, 48M, 96M and 192M**. Both MAP islands share the same budget.
Held-out evaluations use 50 samples and three repeats, outside the search budget.
The launcher also retains the MAP 2/4/6/8/10/12 active-search-hour checkpoints.
Token thresholds are checked at the engine's accounting boundaries. In-flight work can
finish beyond 192M. Recommendations use only evaluations eligible at each threshold.
A threshold with no eligible recommendation is reported as unavailable and cannot
be completed with a later version.

The common token-run wrapper requests 36 hours on `unkillable-cpu`, 2 CPUs and 8 GB, with
one evaluation worker (one per island for MAP). Submit a profile once from the
Infra root, for example:

```bash
sbatch mila/paper-review/qwen3.8-flash-next-fp8/token_run.sh gvf_lambda5_sibling0
```

Within the allocation the launcher repeatedly advances one generation or one MAP
round. After each unit, it checks search and held-out results. It starts another
unit if Slurm's remaining time covers 1.25 times the slower of the last two unit
durations. Otherwise it submits the same profile with
`afterok:<current job ID>` and the successor continues from its archive or MAP
state. MAP can start its final held-out tests in the same allocation. Repeated pending test
attempts are spaced by at least one minute and use the same time check. Once the results are
complete, the current job exits immediately. The estimate cannot guarantee that
an unusually slow generation, round or held-out evaluation will fit.

At the start of each 192M job Slurm registers a five-minute CPU watcher with
`afternotok` and `--kill-on-invalid-dep=yes`. A successful job automatically
retires its watcher. On failure the watcher checks the parent allocation with
`sacct` (or the controller while accounting catches up). Only a confirmed `TIMEOUT` submits a fresh 36-hour allocation; a
cancellation or a program error ends that chain. The recovery checks the last
job ID under the run lock so a delayed watcher cannot resume a newer run.

For single-island token jobs, completed mutations and train/validation harness
calls have host-private checkpoints. Recovery restores their working state and
output, then retries the interrupted call. The original root remains clean,
usage from interrupted attempts remains in the search ledger, and the engine
uses its native scoring and checkpoint logic. Initial evaluations save each
prediction atomically. The generation archive and its evaluation record are
reconciled before continuing. Temporary snapshots on shared scratch are
released after a verified unit. MAP resumes its native island operations and
completed held-out repeats. GVF history updates and MAP question artifacts become
visible only after a complete write. An outstanding API request may have to run again.

Use `token_run.sh <profile>` for all nine token profiles. `gvf_map/long_run.sh`
also starts the MAP token run. The eight single-island `<profile>/long_run.sh`
scripts retain their published 12-hour generation/wallclock settings. As before,
use separate prepared experiment roots for independent runs of the same
profile. Smoke uses its original launcher path.

The alternative λ profiles, both reason-selector profiles and `structured_history`
share this scheduling and measurement protocol. The launcher records the
endpoint, source SHA, tokenizer hashes and SIF hash and checks them on resume.
Each method retains its own source, initial evaluation and output directories.
The single-island engine passes `iterations_left=0` to the meta-agent when
called for one generation at a time. The seed meta-agents ignore this optional
argument. An evolved meta-agent could read it.

## GVF-MAP smoke and long run

Submit the single smoke from the Infra root:

```bash
sbatch mila/paper-review/qwen3.8-flash-next-fp8/gvf_map/smoke.sh
```

This separate 2-hour job writes to an output ending in `_smoke`. It runs two
islands, one step per round, capacity two, two samples for each of train,
validation and test, and one test repeat. The two islands share a 6M search
token stop threshold and freeze recommendations at 1M/3M/6M. The smoke takes
one round, then invokes the engine again within the same allocation to finish.
There is no formal continuation submission from the smoke.

The MAP formal profile uses five steps per round, capacity eight, one
re-evaluation per step, alpha 0.2, beta 0.1, four candidate questions, up to two
features with at most three bins, lineage depth three and one migrant. Its
structured QA and call-level accounting come from the pinned
`remote-api/gvf-map-hyperagents` source. The two islands may issue concurrent
requests. The single-island profiles retain their original recommendation and
parent-selection rules.

## Model settings and remaining validation

Thinking-mode sampling is `temperature=1`, `top_p=.95`, `top_k=20`, `min_p=0`,
`presence_penalty=0`, `repetition_penalty=1`, with `preserve_thinking=true`.
The agent default effort is `xhigh`; Frozen QA remains `medium`, and the A4
selector remains `xhigh`. Existing output/thinking caps are retained:
16384/12288 for ordinary calls, 10240/6144 for QA, and 8192/6144 for the selector.
The ordinary thinking cap also remains bounded by three quarters of that call's
output cap. API-reported reasoning tokens are part of completion tokens, not an
additional charge in total-token accounting.

The configured 262144 context limit must match Cairn's actual deployment. The
earlier basic, tool-roundtrip and small grammar tests do not verify the complete
sampling combination, thinking caps, actual QA/parent grammars, multi-turn
tokenization or complete container execution. These remain deployment checks;
GVF-MAP additionally requires the actual MAP QA JSON schema to be accepted by
the endpoint, including multi-turn evidence reads and the existing one-correction
path. A small grammar test alone does not verify this.
As with the other profiles,
the scripts do not automatically probe the service, drop unsupported fields,
substitute another model or switch to local inference.

References: [model settings](https://huggingface.co/Qwen/Qwen3.8-Flash-Next-FP8),
[Mila partitions](https://docs.mila.quebec/technical_reference/clusters/mila/partitions/).
