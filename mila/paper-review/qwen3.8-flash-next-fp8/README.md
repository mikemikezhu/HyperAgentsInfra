# Paper Review with Cairn

This entry point uses `openai/Qwen/Qwen3.8-Flash-Next-FP8` through the existing
LiteLLM client at `http://cn-d003.server.mila.quebec:8080/v1`. It requests CPU
resources and does not start vLLM or load model weights.

## Before running

The model-specific `source_shas.env` pins the three reviewed adaptation commits.
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

Each profile has a `long_run.sh` CPU wrapper. Submit from the Infra repository
root, passing `long-run-start <segment-end>` or `long-run-resume <segment-end>`.
The optional `--generation_limit N` is the global search endpoint, separate from
the segment endpoint. A fourth positional argument to the launcher (after the
profile, phase and endpoint) can select one of the existing token budgets.
Each submission runs one explicitly chosen segment; it does not submit a chain
or start the other profiles. Do not launch all profiles concurrently until the
shared API's permitted usage has been established.

The wrappers request `unkillable-cpu`, 2 CPUs, 8 GB and 12 hours. Formal evaluation
uses one worker initially; this is not a service-wide concurrency limiter and
does not restrict parallelism introduced by evolved agent code. Memory and
segment duration have not been measured on Mila.

The launcher retains Nibi's sample seeds, per-profile train/validation samples,
selection rules, G/T/H checkpoint thresholds and 50-sample, three-repeat tests.
It uses independent initial evaluations, outputs and private checkpoint records.
It records the endpoint, source SHA, tokenizer hashes and SIF hash without the
key, and requires the same inference configuration on resume. Flash-Next and
27B results are separate backbone conditions.

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
the scripts do not automatically probe the service, drop unsupported fields,
substitute another model or switch to local inference.

References: [model settings](https://huggingface.co/Qwen/Qwen3.8-Flash-Next-FP8),
[Mila partitions](https://docs.mila.quebec/technical_reference/clusters/mila/partitions/).
