#!/bin/bash
#SBATCH --job-name=ha-pr-history-long-q38
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=h100:2
#SBATCH --cpus-per-task=12
#SBATCH --mem=96G
#SBATCH --time=1-12:00:00
#SBATCH --account=rrg-bengioy-ad
#SBATCH --output=%x-%j.out

set -euo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_path="$script_dir/long_run.sh"

# Global limits are distinct from each job's generation endpoint.
generation_limit=""
stop_token_budget=""
early_stop="false"
early_stop_min_generations="10"
early_stop_patience="5"
if [[ "${1:-}" == --* ]]; then
    while [[ "$#" -gt 0 ]]; do
        if [[ "$#" -lt 2 ]]; then
            echo "Usage: bash $script_path [--max_generation <generations>] [--stop_token_budget <tokens>] [--early_stop true|false] [--early_stop_min_generations <generations>] [--early_stop_patience <attempts>]" >&2
            exit 2
        fi
        if [[ "$1" == --early_stop || "$1" == --early-stop ]]; then
            [[ "$2" == true || "$2" == false ]] || { echo "ERROR: early_stop must be true or false" >&2; exit 2; }
        elif [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; then
            echo "ERROR: $1 requires a positive integer" >&2
            exit 2
        fi
        case "$1" in
            --max_generation|--max-generation) generation_limit="$2" ;;
            --stop_token_budget|--stop-token-budget) stop_token_budget="$2" ;;
            --early_stop|--early-stop) early_stop="$2" ;;
            --early_stop_min_generations|--early-stop-min-generations) early_stop_min_generations="$2" ;;
            --early_stop_patience|--early-stop-patience) early_stop_patience="$2" ;;
            *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
        esac
        shift 2
    done
fi

search_control_args=(
    --early_stop "$early_stop"
    --early_stop_min_generations "$early_stop_min_generations"
    --early_stop_patience "$early_stop_patience"
)

if [[ -n "$stop_token_budget" ]]; then
    first_generation_target=10
    generation_limit_args=()
    if [[ -n "$generation_limit" ]]; then
        generation_limit_args=(--generation_limit "$generation_limit")
        if (( generation_limit < first_generation_target )); then
            first_generation_target="$generation_limit"
        fi
    fi
    readonly infra_root="$(cd -- "$script_dir/../../../.." && pwd)"
    cd "$infra_root"
    job_id="$(
        sbatch \
            --parsable \
            --job-name="ha-pr-a5-g0-$first_generation_target-q38" \
            "$script_path" \
            long-run-start \
            "$first_generation_target" \
            "$stop_token_budget" \
            "${generation_limit_args[@]}" \
            "${search_control_args[@]}"
    )"
    printf 'A5 token budget %s: %s\n' "$stop_token_budget" "${job_id%%;*}"
    exit 0
fi

if [[ "$#" -eq 0 ]]; then
    readonly infra_root="$(cd -- "$script_dir/../../../.." && pwd)"
    cd "$infra_root"

    previous_job_id=""
    job_chain=""
    generation_limit="${generation_limit:-30}"
    for (( segment_start=0; segment_start < generation_limit; segment_start+=10 ))
    do
        max_generation="$((segment_start + 10))"
        if (( max_generation > generation_limit )); then
            max_generation="$generation_limit"
        fi
        if [[ "$segment_start" -eq 0 ]]; then
            phase="long-run-start"
            generation_range="0-$max_generation"
            dependency=()
        else
            phase="long-run-resume"
            generation_range="$((segment_start + 1))-$max_generation"
            dependency=(--dependency="afterok:${previous_job_id}")
        fi

        job_id="$(
            sbatch \
                --parsable \
                "${dependency[@]}" \
                --job-name="ha-pr-a5-g${generation_range}-q38" \
                "$script_path" \
                "$phase" \
                "$max_generation" \
                --generation_limit "$generation_limit" \
                "${search_control_args[@]}"
        )"
        job_id="${job_id%%;*}"
        job_chain="${job_chain:+$job_chain -> }$job_id"
        previous_job_id="$job_id"
    done

    printf 'A5: %s\n' "$job_chain"
    exit 0
fi

readonly launcher_path="${SLURM_SUBMIT_DIR:?Submit this script from the HyperAgentsInfra root}/rorqual/paper-review/qwen3.8-27b/launcher.sh"

if [[ ! -x "$launcher_path" ]]; then
    echo "ERROR: launcher not found: $launcher_path" >&2
    echo "Submit this script from the HyperAgentsInfra repository root." >&2
    exit 1
fi

exec "$launcher_path" structured_history "$@"
