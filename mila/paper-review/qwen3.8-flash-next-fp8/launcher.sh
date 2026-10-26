#!/bin/bash
set -euo pipefail
set +x
umask 077

# Host-only Cairn entry point. Reuses the Nibi formal evaluation/search protocol;
# the existing service handles inference, so this launcher never starts vLLM.
readonly launcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$launcher_dir/source_shas.env"
: "${COMMON_BASE_SHA:?Freeze the reviewed remote-api/main commit in source_shas.env}"
: "${GVF_SHA:?Freeze the reviewed remote-api/gvf-hyperagents commit in source_shas.env}"
: "${STRUCTURED_HISTORY_SHA:?Freeze the reviewed remote-api/ha-structured-history commit in source_shas.env}"
: "${LITELLM_KEY:?Export the Mila API key in the submitting shell; never put it in this repository}"
: "${HYPERAGENTS_TOKENIZER_PATH:?Set a self-contained local Flash-Next tokenizer directory}"
: "${HYPERAGENTS_APPTAINER_IMAGE:?Set the separate text SIF containing the tokenizer dependencies}"
: "${SLURM_JOB_ID:?Run experiments inside a Slurm CPU allocation}"
: "${SLURM_TMPDIR:?The allocation must provide its private temporary directory}"

HYPERAGENTS_TOKENIZER_PATH="$(realpath -e "$HYPERAGENTS_TOKENIZER_PATH")"
HYPERAGENTS_APPTAINER_IMAGE="$(realpath -e "$HYPERAGENTS_APPTAINER_IMAGE")"

readonly experiment_root="${HYPERAGENTS_EXPERIMENT_ROOT:-$HOME/scratch/HyperAgents/experiments}"
readonly venv_path="${HYPERAGENTS_VENV_PATH:-$HOME/venv}"
readonly apptainer_image="$HYPERAGENTS_APPTAINER_IMAGE"
readonly common_base_sha="$COMMON_BASE_SHA"
readonly gvf_sha="$GVF_SHA"
readonly model="openai/Qwen/Qwen3.8-Flash-Next-FP8"
readonly api_base="http://cn-d003.server.mila.quebec:8080/v1"
readonly tokenizer_revision="236dfdf285828023ca3bcd3f37366c58a3469b13"
# Keep the Nibi sample seeds and measurement thresholds for the new backbone.
readonly eval_seed_base="paper-review-qwen38-smoke-seed-0"
readonly max_model_len="262144"
readonly max_output_tokens="16384"
readonly request_timeout_seconds="3600"
readonly eval_workers="1"
readonly -a token_budgets=(6000000 12000000 24000000 48000000 96000000 192000000)
readonly -a generation_checkpoints=(0 5 10 15 20 25 30)
readonly -a search_hour_checkpoints=(2 4 6 8 10 12)

usage() {
    echo "Usage: $0 <profile> long-run-start|long-run-resume <segment-end> [stop-token-budget] [--generation_limit N] [--early_stop true|false] [--early_stop_min_generations N] [--early_stop_patience N]" >&2
}

configure_profile() {
    local requested_profile="$1"
    train_eval_samples=10
    val_eval_samples=50
    sampling_mode=random_per_gen
    selection_lambda=10
    parent_selection=score_child_prop
    use_gvf=0
    skip_staged_eval=1
    case "$requested_profile" in
        original-full)
            expected_source_sha="$common_base_sha"
            train_eval_samples=50
            sampling_mode=head
            skip_staged_eval=0
            ;;
        original-compressed10) expected_source_sha="$common_base_sha" ;;
        structured_history) expected_source_sha="$STRUCTURED_HISTORY_SHA" ;;
        gvf_lambda1_sibling0|gvf_lambda5_sibling0|gvf_lambda10_sibling0)
            expected_source_sha="$gvf_sha"
            use_gvf=1
            selection_lambda="${requested_profile#gvf_lambda}"
            selection_lambda="${selection_lambda%_sibling0}"
            sibling_count=0
            ;;
        gvf_reason_sibling0|gvf_reason_sibling1)
            expected_source_sha="$gvf_sha"
            use_gvf=1
            selection_lambda=1
            sibling_count="${requested_profile##*sibling}"
            parent_selection=reason_gvf
            ;;
        *) echo "ERROR: unknown profile: $requested_profile" >&2; exit 2 ;;
    esac
    worktree_path="$experiment_root/paper-review-${requested_profile}-qwen38-flash-next-fp8-cairn/source"
    run_id="paper_review_${requested_profile//-/_}_qwen38_flash_next_fp8_cairn_long_run1"
    run_output="$worktree_path/outputs/generate_${run_id}"
    private_output="${run_output}_private"
    train_baseline="$worktree_path/outputs/initial_paper_review_filtered_100_train_0"
    val_baseline="$worktree_path/outputs/initial_paper_review_filtered_100_val_0"
}

read_cumulative_tokens() {
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH="$worktree_path" \
    "$venv_path/bin/python" -c \
        'import sys; from measurement.token_accounting import cumulative_total, scan_generation_token_totals; print(cumulative_total(scan_generation_token_totals(sys.argv[1])))' \
        "$run_output"
}

read_search_status() {
    PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$worktree_path" \
    "$venv_path/bin/python" -m measurement.early_stopping "$run_output" \
        "${search_control_args[@]}" "${stop_args[@]}"
}

write_formal_results() {
    PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$worktree_path" \
    "$venv_path/bin/python" -m measurement.results_export "$run_output"
}

verify_search_completion() {
    local max_genid="$1"
    local archive_path="$run_output/archive.jsonl"
    local search_tokens="0"
    local stop_status
    stop_status="$(read_search_status)"

    if [[ -n "$stop_token_budget" ]]; then
        search_tokens="$(read_cumulative_tokens)"
    fi

    "$venv_path/bin/python" - "$run_output" "$archive_path" "$max_genid" "$stop_token_budget" "$search_tokens" "$phase" "$stop_status" <<'PY'
import json
import os
import sys

run_output, archive_path, max_genid, stop_budget, search_tokens, phase, stop_status = sys.argv[1:]
max_genid = int(max_genid)
budget_reached = bool(stop_budget) and int(search_tokens) >= int(stop_budget)

if not os.path.isfile(archive_path):
    raise SystemExit(f"Archive is missing: {archive_path}")

with open(archive_path, encoding="utf-8") as handle:
    records = [json.loads(line) for line in handle if line.strip()]

actual = records[-1].get("current_genid") if records else None
completed_genid = 0 if actual == "initial" else actual
if (
    not isinstance(completed_genid, int)
    or completed_genid > max_genid
    or (not budget_reached and stop_status != "stopped" and completed_genid != max_genid)
):
    raise SystemExit(
        f"Search stopped at generation {actual}; expected generation {max_genid}."
    )

expected_archive = ["initial", *range(1, completed_genid + 1)]
if records[-1].get("archive") != expected_archive:
    raise SystemExit(
        "Final archive does not contain every expected generation: "
        f"{records[-1].get('archive')!r}"
    )

valid_candidates = []
for genid in range(1, completed_genid + 1):
    gen_dir = os.path.join(run_output, f"gen_{genid}")
    metadata_path = os.path.join(gen_dir, "metadata.json")
    patch_path = os.path.join(gen_dir, "agent_output", "model_patch.diff")

    if not os.path.isfile(metadata_path):
        raise SystemExit(
            f"Generation {genid} metadata is missing: {metadata_path}"
        )

    with open(metadata_path, encoding="utf-8") as handle:
        metadata = json.load(handle)

    if (
        metadata.get("parent_agent_success") is True
        and metadata.get("run_eval") is True
        and metadata.get("valid_parent") is True
        and os.path.isfile(patch_path)
        and os.path.getsize(patch_path) > 0
    ):
        valid_candidates.append(genid)

if not valid_candidates and not stop_budget and phase not in ("long-run-start", "long-run-resume"):
    raise SystemExit(
        "Search completed, but no currently valid evaluated generation has "
        "a non-empty canonical model_patch.diff."
    )

print(
    f"SEARCH_THROUGH_GENERATION_{completed_genid}_VERIFIED: "
    f"valid_evaluated_candidates={valid_candidates}"
)
PY
}

verify_reached_checkpoints() {
    local max_genid="$1"

    PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$worktree_path" \
    "$venv_path/bin/python" - "$run_output" "$private_output" "$max_genid" \
        "$phase" "$stop_token_budget" "${checkpoint_budgets[*]}" \
        "${generation_checkpoints[*]}" "${search_hour_checkpoints[*]}" "$early_stop" "$(read_search_status)" <<'PY'
import json
import os
import sys

from measurement.early_stopping import read_final_checkpoint
from measurement.held_out import checkpoint_tests_complete, materialize_checkpoint_tests
from measurement.token_accounting import (
    cumulative_total, read_evaluation_records, scan_generation_token_totals,
)

run_output, private_dir, max_genid, phase, stop_budget, tokens, generations, hours, early_stop, stop_status = sys.argv[1:]
with open(os.path.join(run_output, "archive.jsonl"), encoding="utf-8") as handle:
    archive = [json.loads(line) for line in handle if line.strip()][-1]
last_generation = archive["current_genid"]
completed = 0 if last_generation == "initial" else int(last_generation)
cumulative = cumulative_total(scan_generation_token_totals(run_output))
dimensions = [("T", list(map(int, tokens.split())), cumulative, "evaluation_cost_tokens", 1)]
if phase in ("long-run-start", "long-run-resume"):
    with open(os.path.join(private_dir, "search_time.json"), encoding="utf-8") as handle:
        search_seconds = json.load(handle)["search_seconds"]
    dimensions += [
        ("G", list(map(int, generations.split())), completed, "evaluation_generation", 1),
        ("H", list(map(float, hours.split())), search_seconds / 3600,
         "evaluation_search_seconds", 3600),
    ]
records = read_evaluation_records(private_dir)
reached_count = 0
for prefix, budgets, reached, field, scale in dimensions:
    for budget in budgets:
        if budget > reached:
            continue
        if not any(record.get(field, float("inf")) <= budget * scale for record in records):
            print(f"CHECKPOINT_{prefix}{budget:g}_UNAVAILABLE: no evaluation completed within threshold")
            continue
        label = f"{budget:g}" if prefix == "H" else str(budget)
        checkpoint_path = os.path.join(private_dir, "checkpoints", f"checkpoint_{prefix}{label}.json")
        if not os.path.isfile(checkpoint_path):
            raise SystemExit(f"Reached checkpoint lacks a frozen record: {checkpoint_path}")
        with open(checkpoint_path, encoding="utf-8") as handle:
            checkpoint = json.load(handle)
        if not checkpoint_tests_complete(private_dir, checkpoint, ["paper_review"]):
            materialize_checkpoint_tests(private_dir, checkpoint)
        if not checkpoint_tests_complete(private_dir, checkpoint, ["paper_review"]):
            raise SystemExit(f"Reached checkpoint has incomplete isolated held-out tests: {checkpoint_path}")
        reached_count += 1
if reached_count == 0 and not stop_budget and phase not in ("long-run-start", "long-run-resume"):
    raise SystemExit(f"No checkpoint was reached by generation {max_genid}.")
if early_stop == "true" and stop_status == "stopped":
    final = read_final_checkpoint(run_output)
    if final is None:
        raise SystemExit("Stopped search lacks its frozen final measurement")
    if not checkpoint_tests_complete(private_dir, final, ["paper_review"]):
        materialize_checkpoint_tests(private_dir, final)
    if not checkpoint_tests_complete(private_dir, final, ["paper_review"]):
        raise SystemExit("Final isolated held-out tests are incomplete")
    print("FINAL_MEASUREMENT_VERIFIED")
print(f"REACHED_CHECKPOINTS_VERIFIED={reached_count}")
PY
}

early_stop="false"
early_stop_min_generations="10"
early_stop_patience="5"
generation_limit=""
positional_args=()
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --early_stop|--early_stop_min_generations|--early_stop_patience|--generation_limit)
            option="$1"
            if [[ "$#" -lt 2 ]]; then
                echo "ERROR: $option requires a value" >&2
                exit 2
            fi
            if [[ "$option" == --early_stop ]]; then
                [[ "$2" == true || "$2" == false ]] || { echo "ERROR: early_stop must be true or false" >&2; exit 2; }
            elif [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "ERROR: $option requires a positive integer" >&2
                exit 2
            fi
            case "$option" in
                --early_stop) early_stop="$2" ;;
                --early_stop_min_generations) early_stop_min_generations="$2" ;;
                --early_stop_patience) early_stop_patience="$2" ;;
                --generation_limit) generation_limit="$2" ;;
            esac
            shift 2
            ;;
        --*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
        *) positional_args+=("$1"); shift ;;
    esac
done
set -- "${positional_args[@]}"

if [[ "$#" -lt 2 || "$#" -gt 5 ]]; then
    usage >&2
    exit 2
fi

readonly profile="$1"
readonly phase="$2"
readonly stop_token_budget="${4:-}"
generation_limit="${5:-$generation_limit}"
configure_profile "$profile"

case "$phase" in
    long-run-start|long-run-resume)
        if [[ "$#" -lt 3 || ! "$3" =~ ^[1-9][0-9]*$ ]]; then
            echo "ERROR: $phase requires a positive segment endpoint and optional token/generation limits." >&2
            usage >&2
            exit 2
        fi
        max_generation_target="$3"
        if [[ "$#" -ge 4 ]]; then
            if [[ ! "$stop_token_budget" =~ ^[1-9][0-9]*$ || " ${token_budgets[*]} " != *" $stop_token_budget "* ]]; then
                echo "ERROR: stop token budget must be one of: ${token_budgets[*]}" >&2
                exit 2
            fi
        fi
        if [[ -n "$generation_limit" ]]; then
            if [[ ! "$generation_limit" =~ ^[1-9][0-9]*$ ]]; then
                echo "ERROR: generation limit must be a positive integer." >&2
                exit 2
            fi
            if (( max_generation_target > generation_limit )); then
                max_generation_target="$generation_limit"
            fi
        fi
        readonly max_generation_target
        ;;
    *)
        echo "ERROR: unknown phase: $phase" >&2
        usage >&2
        exit 2
        ;;
esac

if [[ -z "$generation_limit" && -z "$stop_token_budget" ]]; then
    generation_limit="$max_generation_target"
fi
readonly early_stop early_stop_min_generations early_stop_patience generation_limit
early_stop_args=(
    --early_stop "$early_stop"
    --early_stop_min_generations "$early_stop_min_generations"
    --early_stop_patience "$early_stop_patience"
)
search_control_args=("${early_stop_args[@]}")
if [[ -n "$generation_limit" ]]; then
    search_control_args+=(--generation_limit "$generation_limit")
fi

checkpoint_budgets=()
stop_args=()
for budget in "${token_budgets[@]}"
do
    if [[ -z "$stop_token_budget" ]] || (( budget <= stop_token_budget )); then
        checkpoint_budgets+=("$budget")
    fi
done
if [[ -n "$stop_token_budget" ]]; then
    stop_args=(--stop_token_budget "$stop_token_budget")
fi

if [[ ! -d "$worktree_path" || "$(git -C "$worktree_path" rev-parse HEAD)" != "$expected_source_sha" ]]; then
    echo "ERROR: prepare the detached experiment worktree at its reviewed source SHA: $worktree_path" >&2
    exit 1
fi
if git -C "$worktree_path" symbolic-ref -q HEAD >/dev/null; then
    echo "ERROR: experiment source must be a detached worktree" >&2
    exit 1
fi
if [[ -n "$(git -C "$worktree_path" status --porcelain)" ]]; then
    echo "ERROR: experiment source worktree is not clean: $worktree_path" >&2
    exit 1
fi
if [[ ! -x "$venv_path/bin/python" || ! -r "$apptainer_image" ]]; then
    echo "ERROR: configured Python environment or text SIF is missing" >&2
    exit 1
fi
if [[ ! -r "$HYPERAGENTS_TOKENIZER_PATH/tokenizer_config.json" || ! -r "$HYPERAGENTS_TOKENIZER_PATH/chat_template.jinja" ]]; then
    echo "ERROR: configured tokenizer directory must include its official chat template" >&2
    exit 1
fi

if [[ "$phase" == long-run-start ]]; then
    for path in "$run_output" "$private_output" "$train_baseline" "$val_baseline"; do
        if [[ -e "$path" ]]; then
            echo "ERROR: new-run output already exists: $path" >&2
            exit 1
        fi
    done
elif [[ ! -f "$run_output/archive.jsonl" ]]; then
    echo "ERROR: no completed archive to resume: $run_output" >&2
    exit 1
fi

module load singularity/3.7.1
source "$venv_path/bin/activate"
cd "$worktree_path"

export HYPERAGENTS_MODEL="$model"
export HYPERAGENTS_TASK_MODEL="$model"
export HYPERAGENTS_META_MODEL="$model"
export HYPERAGENTS_API_BASE="$api_base"
export HYPERAGENTS_API_KEY="$LITELLM_KEY"
export HYPERAGENTS_MAX_TOKENS="$max_output_tokens"
export HYPERAGENTS_THINKING_MODE="on"
export HYPERAGENTS_REQUEST_TIMEOUT="$request_timeout_seconds"
export HYPERAGENTS_TOKEN_COUNTER="local"
export HYPERAGENTS_TOKENIZER_PATH
export HYPERAGENTS_MAX_MODEL_LEN="$max_model_len"
export HYPERAGENTS_CONTAINER_EXECUTABLE="singularity"
export HYPERAGENTS_APPTAINER_RUNTIME="$SLURM_TMPDIR/hyperagents-apptainer-runtime/${profile}-${phase}"
export LITELLM_LOCAL_MODEL_COST_MAP="True"
export PYTHONDONTWRITEBYTECODE="1"
# A remote backbone has no local model-weight directory.
unset HYPERAGENTS_TEST_MODEL_PATH LITELLM_DROP_PARAMS
mkdir -p "$HYPERAGENTS_APPTAINER_RUNTIME"

# Record only public settings. On resume, a different deployment/configuration
# is a new experiment, not a continuation of these checkpoints.
"$VIRTUAL_ENV/bin/python" - "$private_output" "$phase" "$expected_source_sha" "$profile" "$tokenizer_revision" "$eval_workers" <<'PYCONFIG'
import hashlib
import json
import os
import sys
from pathlib import Path

private, phase, source_sha, profile, revision, workers = sys.argv[1:]
def sha256(path):
    with open(path, "rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()

tokenizer = Path(os.environ["HYPERAGENTS_TOKENIZER_PATH"])
config = {
    "source_sha": source_sha,
    "profile": profile,
    "eval_workers": int(workers),
    "tokenizer_revision": revision,
    "tokenizer_sha256": {name: sha256(tokenizer / name) for name in (
        "tokenizer.json", "tokenizer_config.json", "chat_template.jinja",
    )},
    "container_sha256": sha256(os.environ["HYPERAGENTS_APPTAINER_IMAGE"]),
    "settings": {key: os.environ[key] for key in (
        "HYPERAGENTS_MODEL", "HYPERAGENTS_TASK_MODEL", "HYPERAGENTS_META_MODEL",
        "HYPERAGENTS_API_BASE", "HYPERAGENTS_MAX_TOKENS", "HYPERAGENTS_THINKING_MODE",
        "HYPERAGENTS_REQUEST_TIMEOUT", "HYPERAGENTS_TOKEN_COUNTER", "HYPERAGENTS_MAX_MODEL_LEN",
    )},
}
path = Path(private) / "inference_config.json"
if phase == "long-run-resume":
    if json.loads(path.read_text()) != config:
        raise SystemExit("Inference configuration changed; use a separate experiment directory")
else:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x") as handle:
        json.dump(config, handle, indent=2)
PYCONFIG

echo "PROFILE=$profile"
echo "PHASE=$phase"
echo "SOURCE_SHA=$expected_source_sha"
echo "MODEL=$model"
echo "RUN_OUTPUT=$run_output"

generate_args=(
    --domains paper_review
    --train_eval_samples "$train_eval_samples"
    --val_eval_samples "$val_eval_samples"
    --eval_workers "$eval_workers"
    --parent_selection "$parent_selection"
    --sampling_mode "$sampling_mode"
    --eval_seed_base "$eval_seed_base"
    --selection_lambda "$selection_lambda"
    --optimize_option only_agent
    --execution_backend apptainer
    --apptainer_image "$HYPERAGENTS_APPTAINER_IMAGE"
    --apptainer_runtime_dir "$HYPERAGENTS_APPTAINER_RUNTIME"
)

if [[ "$skip_staged_eval" == "1" ]]; then
    generate_args+=(--skip_staged_eval)
fi

if [[ "$use_gvf" == "1" ]]; then
    generate_args+=(
        --lineage_depth 3
        --sibling_count "$sibling_count"
        --max_questions 4
        --qa_context_chars 80000
    )
fi

checkpoint_args=(
    --generation_checkpoints "${generation_checkpoints[@]}"
    --search_hour_checkpoints "${search_hour_checkpoints[@]}"
)
baseline_timer=(
    "$VIRTUAL_ENV/bin/python" -m measurement.search_time
    --private_dir "$private_output" --
)

run_initial_baseline_split() {
    local split="$1"
    local num_samples="$train_eval_samples"
    if [[ "$split" == "val" ]]; then
        num_samples="$val_eval_samples"
    fi
    local subset="_filtered_100_${split}"
    local baseline_name="initial_paper_review${subset}_0"
    local seed

    seed="$(
        "$VIRTUAL_ENV/bin/python" -c \
            'import sys; from domains.eval_sampling import compute_eval_seed; print(compute_eval_seed(sys.argv[1], "paper_review", 0, sys.argv[2]))' \
            "$eval_seed_base" "$split"
    )"

    echo "Starting initial $split baseline with seed $seed at $(date --iso-8601=seconds)"
    "${baseline_timer[@]}" "$VIRTUAL_ENV/bin/python" -m domains.harness \
        --output_dir "$worktree_path/outputs" \
        --run_id "$baseline_name" \
        --domain paper_review \
        --num_samples "$num_samples" \
        --num_workers "$eval_workers" \
        --subset "$subset" \
        --sampling_mode "$sampling_mode" \
        --eval_seed "$seed" \
        --split "$split" \
        --generation 0

    "${baseline_timer[@]}" "$VIRTUAL_ENV/bin/python" -m domains.report \
        --domain paper_review \
        --dname "$worktree_path/outputs/$baseline_name"
}

verify_generated_repository() {
    local generated_repo="$run_output/gen_initial/hyperagents"

    if [[ ! -d "$generated_repo/.git" ]]; then
        echo "ERROR: generated repository lacks independent Git metadata." >&2
        exit 1
    fi
    if [[ -n "$(git -C "$generated_repo" remote)" ]]; then
        echo "ERROR: generated repository has a remote." >&2
        exit 1
    fi
    if [[ -n "$(git -C "$generated_repo" status --porcelain)" ]]; then
        echo "ERROR: generated repository is not clean." >&2
        git -C "$generated_repo" status --short --branch >&2
        exit 1
    fi
    if [[ -e "$generated_repo/project_status" || -e "$generated_repo/host_experiment_scripts" ]]; then
        echo "ERROR: host-only files leaked into the generated repository." >&2
        exit 1
    fi
    for forbidden_dataset in \
        dataset.csv \
        dataset_filtered_100_val.csv \
        dataset_filtered_100_test.csv
    do
        if [[ -e "$generated_repo/domains/paper_review/$forbidden_dataset" ]]; then
            echo "ERROR: validation/test data leaked into the generated repository: $forbidden_dataset" >&2
            exit 1
        fi
    done
    if [[ ! -e "$generated_repo/domains/paper_review/dataset_filtered_100_train.csv" ]]; then
        echo "ERROR: training data is missing from the generated repository." >&2
        exit 1
    fi

    if [[ "$use_gvf" == "1" ]]; then
        if [[ ! -d "$generated_repo/gvf" || ! -f "$generated_repo/question_module.py" ]]; then
            echo "ERROR: GVF profile lacks its required agent-visible GVF files." >&2
            exit 1
        fi
    else
        if [[ -e "$generated_repo/gvf" || -e "$generated_repo/question_module.py" ]]; then
            echo "ERROR: COMMON_BASE profile can see GVF-specific files." >&2
            exit 1
        fi
    fi

    "$VIRTUAL_ENV/bin/python" - "$run_output" "$val_eval_samples" <<'PY'
import json
import os
import sys

import pandas as pd

run_output = os.path.abspath(sys.argv[1])
expected_count = int(sys.argv[2])
val_dir = os.path.join(run_output, "gen_initial", "paper_review_eval_val")
predictions = pd.read_csv(os.path.join(val_dir, "predictions.csv"), dtype=str)
if set(predictions.columns) != {"question_id", "prediction"}:
    raise SystemExit(
        "Initial validation artifact is not label-free: "
        + repr(list(predictions.columns))
    )
manifest = json.load(open(os.path.join(val_dir, "eval_manifest.json"), encoding="utf-8"))
if manifest.get("num_samples") != expected_count:
    raise SystemExit(
        f"Initial validation manifest has {manifest.get('num_samples')} samples; "
        f"expected {expected_count}."
    )
print("INITIAL_VALIDATION_IS_LABEL_FREE")
PY
}

if [[ "$phase" == long-run-start ]]; then
    run_initial_baseline_split train
    run_initial_baseline_split val
    run_args=(--run_id "$run_id" --output_dir_parent "$worktree_path/outputs")
else
    run_args=(--resume_from "$run_output")
fi

"$VIRTUAL_ENV/bin/python" generate_loop.py \
    "${run_args[@]}" \
    --max_generation "$max_generation_target" \
    --token_budgets "${checkpoint_budgets[@]}" \
    "${stop_args[@]}" \
    "${checkpoint_args[@]}" \
    "${search_control_args[@]}" \
    --test_eval_samples 50 \
    --test_eval_repeats 3 \
    "${generate_args[@]}"

verify_search_completion "$max_generation_target"
verify_reached_checkpoints "$max_generation_target"
write_formal_results
verify_generated_repository
if [[ -n "$(git -C "$worktree_path" status --porcelain)" ]]; then
    echo "ERROR: source worktree changed during the experiment" >&2
    exit 1
fi
echo "FORMAL_LONG_RUN_SEGMENT_COMPLETED"
