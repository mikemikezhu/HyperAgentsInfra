#!/bin/bash
#SBATCH --job-name=ha-q38-smoke
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=h100:2
#SBATCH --cpus-per-task=12
#SBATCH --mem=96G
#SBATCH --time=5-00:00:00
#SBATCH --account=rrg-bengioy-ad
#SBATCH --output=%x-%j.out

set -euo pipefail

# Host-only launcher for the four Paper Review Qwen3.8 profiles and their
# smoke/formal phases.
#
# This file deliberately lives outside every source worktree.  The Apptainer
# backend uses --containall and binds only the generated repository and its
# private runtime directory, so neither MetaAgent nor TaskAgent can read or
# modify this launcher.

readonly launcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly infra_root="$(cd -- "$launcher_dir/../../.." && pwd)"

# The source SHAs are shared by every Fir profile and deliberately versioned
# outside the agent-visible HyperAgents source worktrees.
source "$infra_root/source_shas.env"

: "${COMMON_BASE_SHA:?COMMON_BASE_SHA is missing from source_shas.env}"
: "${GVF_SHA:?GVF_SHA is missing from source_shas.env}"
: "${SCRATCH:?Fir must provide SCRATCH}"
: "${PROJECT:?Fir must provide PROJECT}"

readonly common_base_sha="$COMMON_BASE_SHA"
readonly gvf_sha="$GVF_SHA"
readonly experiment_root="${HYPERAGENTS_EXPERIMENT_ROOT:-$SCRATCH/HyperAgents/experiments}"
readonly venv_path="${HYPERAGENTS_VENV_PATH:-/project/def-irina/mikezhu/venv}"
readonly model_path="${HYPERAGENTS_MODEL_PATH:-/project/def-irina/mikezhu/model/Qwen3.8-27B}"
readonly apptainer_image="${HYPERAGENTS_APPTAINER_IMAGE:-$SCRATCH/apptainer_images/hyperagents-text-eaa0a09.sif}"
readonly eval_seed_base="paper-review-qwen38-smoke-seed-0"
readonly max_model_len="262144"
readonly max_output_tokens="16384"
readonly max_num_seqs="8"
readonly request_timeout_seconds="3600"
readonly -a token_budgets=(
    6000000
    12000000
    24000000
    48000000
    96000000
    192000000
)
readonly checkpoint_smoke_budget="${token_budgets[0]}"

usage() {
    printf '%s\n' \
        "Usage:" \
        "  $0 <profile> calibrate" \
        "  $0 <profile> continue" \
        "  $0 <profile> checkpoint-smoke" \
        "  $0 <profile> long-run-start <max-generation>" \
        "  $0 <profile> long-run-resume <max-generation>" \
        "  $0 summary" \
        "" \
        "Profiles:" \
        "  original-full" \
        "  original-compressed10" \
        "  gvf-compressed10" \
        "  gvf-reason-compressed10"
}

configure_profile() {
    local requested_profile="$1"

    case "$requested_profile" in
        original-full)
            worktree_path="$experiment_root/paper-review-original-full-qwen38/source"
            expected_source_sha="$common_base_sha"
            run_id="paper_review_original_full_qwen38_smoke5"
            eval_samples="100"
            sampling_mode="head"
            selection_lambda="10"
            parent_selection="score_child_prop"
            vllm_port="18001"
            use_gvf="0"
            skip_staged_eval="0"
            ;;
        original-compressed10)
            worktree_path="$experiment_root/paper-review-original-compressed10-qwen38/source"
            expected_source_sha="$common_base_sha"
            run_id="paper_review_original_compressed10_qwen38_smoke5"
            eval_samples="10"
            sampling_mode="random_per_gen"
            selection_lambda="1"
            parent_selection="score_child_prop"
            vllm_port="18002"
            use_gvf="0"
            skip_staged_eval="1"
            ;;
        gvf-compressed10)
            worktree_path="$experiment_root/paper-review-gvf-compressed10-qwen38/source"
            expected_source_sha="$gvf_sha"
            run_id="paper_review_gvf_compressed10_qwen38_smoke5"
            eval_samples="10"
            sampling_mode="random_per_gen"
            selection_lambda="1"
            parent_selection="score_child_prop"
            vllm_port="18003"
            use_gvf="1"
            skip_staged_eval="1"
            ;;
        gvf-reason-compressed10)
            worktree_path="$experiment_root/paper-review-gvf-reason-compressed10-qwen38/source"
            expected_source_sha="$gvf_sha"
            run_id="paper_review_gvf_reason_compressed10_qwen38_smoke5"
            eval_samples="10"
            sampling_mode="random_per_gen"
            selection_lambda="1"
            parent_selection="reason_gvf"
            vllm_port="18004"
            use_gvf="1"
            skip_staged_eval="1"
            ;;
        *)
            echo "ERROR: unknown profile: $requested_profile" >&2
            usage >&2
            exit 2
            ;;
    esac

    if [[ "${phase:-}" == "checkpoint-smoke" ]]; then
        run_id="${run_id}_checkpoint_T${checkpoint_smoke_budget}"
    elif [[ "${phase:-}" == "long-run-start" || "${phase:-}" == "long-run-resume" ]]; then
        run_id="${run_id%_smoke5}_long_run1"
    fi

    run_output="$worktree_path/outputs/generate_${run_id}"
    private_output="${run_output}_private"
    train_baseline="$worktree_path/outputs/initial_paper_review_filtered_100_train_0"
    val_baseline="$worktree_path/outputs/initial_paper_review_filtered_100_val_0"
}

verify_generation_success() {
    local genid="$1"
    local gen_dir="$run_output/gen_${genid}"
    local metadata_path="$gen_dir/metadata.json"
    local patch_path="$gen_dir/agent_output/model_patch.diff"

    "$venv_path/bin/python" - "$metadata_path" "$patch_path" "$genid" <<'PY'
import json
import os
import sys

metadata_path, patch_path, genid = sys.argv[1:]

if not os.path.isfile(metadata_path):
    raise SystemExit(f"Generation {genid} metadata is missing: {metadata_path}")

with open(metadata_path, encoding="utf-8") as handle:
    metadata = json.load(handle)

if metadata.get("run_eval") is not True:
    raise SystemExit(f"Generation {genid} has run_eval != true")
if metadata.get("valid_parent") is not True:
    raise SystemExit(f"Generation {genid} has valid_parent != true")
if not os.path.isfile(patch_path) or os.path.getsize(patch_path) == 0:
    raise SystemExit(
        f"Generation {genid} lacks a non-empty canonical model_patch.diff: "
        f"{patch_path}"
    )

print(
    f"GENERATION_{genid}_VERIFIED: "
    "run_eval=true valid_parent=true canonical_patch=present"
)
PY
}

verify_search_completion() {
    local max_genid="$1"
    local archive_path="$run_output/archive.jsonl"

    "$venv_path/bin/python" - "$run_output" "$archive_path" "$max_genid" <<'PY'
import json
import os
import sys

run_output, archive_path, max_genid = sys.argv[1:]
max_genid = int(max_genid)

if not os.path.isfile(archive_path):
    raise SystemExit(f"Archive is missing: {archive_path}")

with open(archive_path, encoding="utf-8") as handle:
    records = [json.loads(line) for line in handle if line.strip()]

if not records or records[-1].get("current_genid") != max_genid:
    actual = records[-1].get("current_genid") if records else None
    raise SystemExit(
        f"Search stopped at generation {actual}; expected generation {max_genid}."
    )

expected_archive = ["initial", *range(1, max_genid + 1)]
if records[-1].get("archive") != expected_archive:
    raise SystemExit(
        "Final archive does not contain every expected generation: "
        f"{records[-1].get('archive')!r}"
    )

valid_candidates = []
for genid in range(1, max_genid + 1):
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

if not valid_candidates:
    raise SystemExit(
        "Search completed, but no currently valid evaluated generation has "
        "a non-empty canonical model_patch.diff."
    )

print(
    f"SEARCH_THROUGH_GENERATION_{max_genid}_VERIFIED: "
    f"valid_evaluated_candidates={valid_candidates}"
)
PY
}

verify_reached_checkpoints() {
    local max_genid="$1"
    local cumulative_tokens
    local budget
    local checkpoint_path
    local test_report
    local reached_count="0"

    cumulative_tokens="$(
        PYTHONDONTWRITEBYTECODE=1 \
        PYTHONPATH="$worktree_path" \
        "$venv_path/bin/python" -c \
            'import sys; from measurement.token_accounting import cumulative_total, scan_generation_token_totals; print(cumulative_total(scan_generation_token_totals(sys.argv[1])))' \
            "$run_output"
    )"

    for budget in "${token_budgets[@]}"
    do
        if (( budget > cumulative_tokens )); then
            break
        fi

        checkpoint_path="$private_output/checkpoints/checkpoint_T${budget}.json"
        test_report="$private_output/private_test_results/budget_${budget}_paper_review_0/paper_review/report.json"

        if [[ ! -f "$checkpoint_path" ]]; then
            echo "ERROR: reached token budget $budget lacks a frozen checkpoint." >&2
            exit 1
        fi
        if [[ ! -f "$test_report" ]]; then
            echo "ERROR: reached token budget $budget lacks its isolated held-out test report: $test_report" >&2
            exit 1
        fi
        reached_count="$((reached_count + 1))"
    done

    if [[ "$reached_count" -eq 0 ]]; then
        echo "ERROR: first token budget $checkpoint_smoke_budget was not reached by generation $max_genid." >&2
        exit 1
    fi

    echo "REACHED_CHECKPOINTS_VERIFIED=$reached_count"
}

summarize_one() {
    local requested_profile="$1"
    configure_profile "$requested_profile"
    printf '\nPROFILE=%s\nRUN_OUTPUT=%s\n' "$requested_profile" "$run_output"

    if [[ ! -d "$run_output" ]]; then
        echo "STATUS=missing calibration output"
        return
    fi

    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH="$worktree_path" \
    "$venv_path/bin/python" - "$run_output" <<'PY'
import json
import os
import sys

from measurement.token_accounting import (
    cumulative_total,
    read_selection_records,
    scan_generation_token_totals,
)

output_dir = os.path.abspath(sys.argv[1])
private_dir = output_dir + "_private"
totals = scan_generation_token_totals(output_dir)
records = read_selection_records(private_dir)
print(
    "TOKEN_TOTALS="
    + json.dumps(
        {str(key): value for key, value in totals.items()},
        sort_keys=True,
    )
)
print(f"CUMULATIVE_TOKENS={cumulative_total(totals)}")
print("SELECTION_RECORDS=" + json.dumps(records, sort_keys=True))
if records:
    print(f"FIRST_VALID_SELECTION_COST={records[0]['selection_cost_tokens']}")
else:
    print("FIRST_VALID_SELECTION_COST=UNAVAILABLE")
PY
}

if [[ "${1:-}" == "summary" ]]; then
    if [[ "$#" -ne 1 ]]; then
        usage >&2
        exit 2
    fi
    summarize_one original-full
    summarize_one original-compressed10
    summarize_one gvf-compressed10
    summarize_one gvf-reason-compressed10
    exit 0
fi

if [[ "$#" -lt 2 || "$#" -gt 3 ]]; then
    usage >&2
    exit 2
fi

readonly profile="$1"
readonly phase="$2"
configure_profile "$profile"

case "$phase" in
    calibrate)
        if [[ "$#" -ne 2 ]]; then
            usage >&2
            exit 2
        fi
        ;;
    continue)
        if [[ "$#" -ne 2 ]]; then
            usage >&2
            exit 2
        fi
        ;;
    checkpoint-smoke)
        if [[ "$#" -ne 2 ]]; then
            usage >&2
            exit 2
        fi
        ;;
    long-run-start|long-run-resume)
        if [[ "$#" -ne 3 || ! "$3" =~ ^[1-9][0-9]*$ ]]; then
            echo "ERROR: $phase requires one positive max generation." >&2
            usage >&2
            exit 2
        fi
        readonly max_generation_target="$3"
        ;;
    *)
        echo "ERROR: unknown phase: $phase" >&2
        usage >&2
        exit 2
        ;;
esac

if [[ -z "${SLURM_JOB_ID:-}" || -z "${SLURM_TMPDIR:-}" ]]; then
    echo "ERROR: experiment phases must run inside a Slurm allocation." >&2
    exit 1
fi

if [[ ! -d "$worktree_path" ]]; then
    echo "ERROR: missing worktree: $worktree_path" >&2
    exit 1
fi

if [[ "$(git -C "$worktree_path" rev-parse HEAD)" != "$expected_source_sha" ]]; then
    echo "ERROR: unexpected source SHA in $worktree_path" >&2
    git -C "$worktree_path" rev-parse HEAD >&2
    exit 1
fi

if [[ -n "$(git -C "$worktree_path" status --porcelain)" ]]; then
    echo "ERROR: source worktree is not clean: $worktree_path" >&2
    git -C "$worktree_path" status --short --branch >&2
    exit 1
fi

if [[ ! -x "$venv_path/bin/python" || ! -x "$venv_path/bin/vllm" ]]; then
    echo "ERROR: incomplete Python/vLLM environment: $venv_path" >&2
    exit 1
fi

if [[ ! -d "$model_path" ]]; then
    echo "ERROR: Qwen3.8 model directory is missing: $model_path" >&2
    exit 1
fi

if [[ ! -r "$apptainer_image" ]]; then
    echo "ERROR: Apptainer image is missing: $apptainer_image" >&2
    exit 1
fi

if [[ "$phase" == "calibrate" ]]; then
    for path in "$run_output" "$private_output" "$train_baseline" "$val_baseline"
    do
        if [[ -e "$path" ]]; then
            echo "ERROR: calibration target already exists: $path" >&2
            echo "Inspect it explicitly; this launcher never deletes or silently reuses partial output." >&2
            exit 1
        fi
    done
elif [[ "$phase" == "continue" ]]; then
    if [[ ! -f "$run_output/archive.jsonl" ]]; then
        echo "ERROR: generation-1 calibration is incomplete: $run_output" >&2
        exit 1
    fi
    verify_generation_success 1

    earliest_selection_cost="$(
        PYTHONDONTWRITEBYTECODE=1 \
        PYTHONPATH="$worktree_path" \
        "$venv_path/bin/python" -c \
            'import sys; from measurement.token_accounting import read_selection_records; records=read_selection_records(sys.argv[1]); print(records[0]["selection_cost_tokens"] if records else "")' \
            "$private_output"
    )"
    if [[ -z "$earliest_selection_cost" ]]; then
        echo "ERROR: calibration produced no parent-selection record." >&2
        exit 1
    fi
    if (( checkpoint_smoke_budget < earliest_selection_cost )); then
        echo "ERROR: first token budget $checkpoint_smoke_budget precedes the first valid selection at $earliest_selection_cost." >&2
        exit 1
    fi
elif [[ "$phase" == "checkpoint-smoke" ]]; then
    for path in "$run_output" "$private_output"
    do
        if [[ -e "$path" ]]; then
            echo "ERROR: checkpoint-smoke target already exists: $path" >&2
            echo "This launcher never deletes or resumes an integrated smoke." >&2
            exit 1
        fi
    done
    for baseline_dir in "$train_baseline" "$val_baseline"
    do
        for required_file in \
            predictions.csv \
            report.json \
            eval_manifest.json \
            measurement/token_log.jsonl
        do
            if [[ ! -f "$baseline_dir/$required_file" ]]; then
                echo "ERROR: checkpoint-smoke requires a complete baseline: $baseline_dir/$required_file" >&2
                exit 1
            fi
        done
    done
elif [[ "$phase" == "long-run-start" ]]; then
    for path in "$run_output" "$private_output"
    do
        if [[ -e "$path" ]]; then
            echo "ERROR: formal long-run target already exists: $path" >&2
            echo "This launcher never deletes or silently reuses formal output." >&2
            exit 1
        fi
    done
    for baseline_dir in "$train_baseline" "$val_baseline"
    do
        for required_file in \
            predictions.csv \
            report.json \
            eval_manifest.json \
            measurement/token_log.jsonl
        do
            if [[ ! -f "$baseline_dir/$required_file" ]]; then
                echo "ERROR: formal long run requires a complete baseline: $baseline_dir/$required_file" >&2
                exit 1
            fi
        done
    done
else
    if [[ ! -f "$run_output/archive.jsonl" ]]; then
        echo "ERROR: formal long-run output cannot be resumed: $run_output" >&2
        exit 1
    fi
    completed_generation="$(
        "$venv_path/bin/python" -c \
            'import json, sys; records=[json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]; print(records[-1]["current_genid"] if records else "")' \
            "$run_output/archive.jsonl"
    )"
    if [[ ! "$completed_generation" =~ ^[0-9]+$ ]]; then
        echo "ERROR: formal long-run archive has no completed numeric generation." >&2
        exit 1
    fi
    if (( completed_generation >= max_generation_target )); then
        echo "ERROR: formal long run already reached generation $completed_generation; requested target is $max_generation_target." >&2
        exit 1
    fi
fi

module load apptainer/1.4.5
source "$venv_path/bin/activate"

cd "$worktree_path"

gpu_count="$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)"
if [[ "$gpu_count" -ne 2 ]]; then
    echo "ERROR: expected exactly two visible GPUs, found $gpu_count." >&2
    exit 1
fi

if ss -ltn "sport = :$vllm_port" | tail -n +2 | grep -q .; then
    echo "ERROR: vLLM port $vllm_port is already in use on $(hostname)." >&2
    exit 1
fi

export LD_LIBRARY_PATH="$VIRTUAL_ENV/lib/python3.11/site-packages/nvidia/cu13/lib:${LD_LIBRARY_PATH:-}"
export HF_HUB_OFFLINE="1"
export TRANSFORMERS_OFFLINE="1"
export VLLM_USE_FLASHINFER_SAMPLER="0"

export HYPERAGENTS_MODEL="openai/qwen3.8-27b"
export HYPERAGENTS_TASK_MODEL="openai/qwen3.8-27b"
export HYPERAGENTS_META_MODEL="openai/qwen3.8-27b"
export HYPERAGENTS_API_BASE="http://127.0.0.1:${vllm_port}/v1"
export HYPERAGENTS_API_KEY="EMPTY"
export HYPERAGENTS_MAX_TOKENS="$max_output_tokens"
export HYPERAGENTS_THINKING_MODE="on"
export HYPERAGENTS_REQUEST_TIMEOUT="$request_timeout_seconds"
export LITELLM_LOCAL_MODEL_COST_MAP="True"
export PYTHONDONTWRITEBYTECODE="1"

export HYPERAGENTS_APPTAINER_IMAGE="$apptainer_image"
export HYPERAGENTS_APPTAINER_RUNTIME="$SLURM_TMPDIR/hyperagents-apptainer-runtime/${profile}-${phase}"

mkdir --parents \
    "$worktree_path/outputs/manual_logs" \
    "$HYPERAGENTS_APPTAINER_RUNTIME"

readonly vllm_log="$worktree_path/outputs/manual_logs/qwen38-${profile}-${phase}-${SLURM_JOB_ID}.log"

vllm_command=(
    "$VIRTUAL_ENV/bin/vllm"
    serve
    "$model_path"
    --host "127.0.0.1"
    --port "$vllm_port"
    --served-model-name "qwen3.8-27b"
    --tensor-parallel-size "2"
    --dtype "bfloat16"
    --max-model-len "$max_model_len"
    --gpu-memory-utilization "0.9"
    --max-num-seqs "$max_num_seqs"
    --seed "0"
    --enforce-eager
    --language-model-only
    --reasoning-parser "qwen3"
    --enable-auto-tool-choice
    --tool-call-parser "qwen3_coder"
    --gdn-prefill-backend "triton"
)

vllm_pid=""

cleanup_vllm() {
    if [[ -n "${vllm_pid:-}" ]] && kill -0 "$vllm_pid" 2>/dev/null; then
        echo "Stopping vLLM PID $vllm_pid"
        kill "$vllm_pid" 2>/dev/null || true
        wait "$vllm_pid" 2>/dev/null || true
    fi
}

trap cleanup_vllm EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"${vllm_command[@]}" >"$vllm_log" 2>&1 &
vllm_pid="$!"

echo "PROFILE=$profile"
echo "PHASE=$phase"
echo "WORKTREE=$worktree_path"
echo "SOURCE_SHA=$expected_source_sha"
echo "RUN_OUTPUT=$run_output"
echo "VLLM_PORT=$vllm_port"
echo "VLLM_MAX_NUM_SEQS=$max_num_seqs"
echo "REQUEST_TIMEOUT_SECONDS=$request_timeout_seconds"
echo "VLLM_PID=$vllm_pid"
echo "VLLM_LOG=$vllm_log"

vllm_ready="0"
for attempt in $(seq 1 180)
do
    if ! kill -0 "$vllm_pid" 2>/dev/null; then
        echo "ERROR: vLLM exited before becoming ready." >&2
        tail -n 120 "$vllm_log" >&2
        exit 1
    fi

    models_response="$(
        curl --silent --show-error --fail \
            "http://127.0.0.1:${vllm_port}/v1/models" \
            2>/dev/null || true
    )"

    if [[ "$models_response" == *"qwen3.8-27b"* && "$models_response" == *"$max_model_len"* ]]; then
        vllm_ready="1"
        echo "$models_response"
        echo "VLLM_API_READY"
        break
    fi

    if (( attempt == 1 || attempt % 6 == 0 )); then
        printf 'Waiting for vLLM: attempt %s/180\n' "$attempt"
    fi
    sleep 10
done

if [[ "$vllm_ready" != "1" ]]; then
    echo "ERROR: vLLM did not become ready within 30 minutes." >&2
    tail -n 120 "$vllm_log" >&2
    exit 1
fi

if ! grep -q "Application startup complete" "$vllm_log"; then
    echo "ERROR: vLLM API answered but the startup-complete marker is absent." >&2
    tail -n 120 "$vllm_log" >&2
    exit 1
fi

if grep -q "FlashInfer GDN prefill is JIT-compiled" "$vllm_log"; then
    echo "ERROR: vLLM used the unwanted FlashInfer GDN JIT path." >&2
    exit 1
fi

if ! grep -q "Using Triton/FLA GDN prefill kernel" "$vllm_log"; then
    echo "ERROR: vLLM did not confirm the Triton/FLA GDN prefill backend." >&2
    exit 1
fi

generate_args=(
    --domains paper_review
    --eval_samples "$eval_samples"
    --eval_workers 1
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
        --max_questions 8
        --qa_context_chars 60000
    )
fi

run_initial_baseline_split() {
    local split="$1"
    local subset="_filtered_100_${split}"
    local baseline_name="initial_paper_review${subset}_0"
    local seed

    seed="$(
        "$VIRTUAL_ENV/bin/python" -c \
            'import sys; from domains.eval_sampling import compute_eval_seed; print(compute_eval_seed(sys.argv[1], "paper_review", 0, sys.argv[2]))' \
            "$eval_seed_base" "$split"
    )"

    echo "Starting initial $split baseline with seed $seed at $(date --iso-8601=seconds)"
    "$VIRTUAL_ENV/bin/python" -m domains.harness \
        --output_dir "$worktree_path/outputs" \
        --run_id "$baseline_name" \
        --domain paper_review \
        --num_samples "$eval_samples" \
        --num_workers 1 \
        --subset "$subset" \
        --sampling_mode "$sampling_mode" \
        --eval_seed "$seed" \
        --split "$split" \
        --generation 0

    "$VIRTUAL_ENV/bin/python" -m domains.report \
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

    "$VIRTUAL_ENV/bin/python" - "$run_output" "$eval_samples" <<'PY'
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

if [[ "$phase" == "calibrate" ]]; then
    run_initial_baseline_split train
    run_initial_baseline_split val

    echo "Starting generation-1 calibration at $(date --iso-8601=seconds)"
    "$VIRTUAL_ENV/bin/python" generate_loop.py \
        --run_id "$run_id" \
        --max_generation 1 \
        --output_dir_parent "$worktree_path/outputs" \
        "${generate_args[@]}"

    verify_generation_success 1
    verify_generated_repository
    summarize_one "$profile"
    echo "CALIBRATION_COMPLETED_AND_VERIFIED"
elif [[ "$phase" == "continue" ]]; then
    echo "Resuming generations 2-5 with token budgets ${token_budgets[*]} at $(date --iso-8601=seconds)"
    "$VIRTUAL_ENV/bin/python" generate_loop.py \
        --max_generation 5 \
        --resume_from "$run_output" \
        --token_budgets "${token_budgets[@]}" \
        --test_eval_samples 10 \
        "${generate_args[@]}"

    verify_search_completion 5
    verify_reached_checkpoints 5

    verify_generated_repository
    summarize_one "$profile"
    echo "SMOKE_GENERATIONS_1_TO_5_AND_CHECKPOINT_COMPLETED"
elif [[ "$phase" == "checkpoint-smoke" ]]; then
    echo "Starting fresh generations 1-5 with token budgets ${token_budgets[*]} at $(date --iso-8601=seconds)"
    "$VIRTUAL_ENV/bin/python" generate_loop.py \
        --run_id "$run_id" \
        --max_generation 5 \
        --output_dir_parent "$worktree_path/outputs" \
        --token_budgets "${token_budgets[@]}" \
        --test_eval_samples 10 \
        "${generate_args[@]}"

    verify_search_completion 5
    verify_reached_checkpoints 5

    verify_generated_repository
    summarize_one "$profile"
    echo "FRESH_GENERATIONS_1_TO_5_AND_CHECKPOINT_COMPLETED"
elif [[ "$phase" == "long-run-start" ]]; then
    echo "Starting fresh formal generations 1-$max_generation_target with token budgets ${token_budgets[*]} at $(date --iso-8601=seconds)"
    "$VIRTUAL_ENV/bin/python" generate_loop.py \
        --run_id "$run_id" \
        --max_generation "$max_generation_target" \
        --output_dir_parent "$worktree_path/outputs" \
        --token_budgets "${token_budgets[@]}" \
        --test_eval_samples 100 \
        "${generate_args[@]}"

    verify_search_completion "$max_generation_target"
    verify_reached_checkpoints "$max_generation_target"
    verify_generated_repository
    summarize_one "$profile"
    echo "FORMAL_LONG_RUN_THROUGH_GENERATION_${max_generation_target}_COMPLETED"
else
    echo "Resuming formal generations $((completed_generation + 1))-$max_generation_target with token budgets ${token_budgets[*]} at $(date --iso-8601=seconds)"
    "$VIRTUAL_ENV/bin/python" generate_loop.py \
        --max_generation "$max_generation_target" \
        --resume_from "$run_output" \
        --token_budgets "${token_budgets[@]}" \
        --test_eval_samples 100 \
        "${generate_args[@]}"

    verify_search_completion "$max_generation_target"
    verify_reached_checkpoints "$max_generation_target"
    verify_generated_repository
    summarize_one "$profile"
    echo "FORMAL_LONG_RUN_THROUGH_GENERATION_${max_generation_target}_COMPLETED"
fi

if [[ -n "$(git -C "$worktree_path" status --porcelain)" ]]; then
    echo "ERROR: source worktree changed during the experiment." >&2
    git -C "$worktree_path" status --short --branch >&2
    exit 1
fi

echo "Finished at $(date --iso-8601=seconds)"
