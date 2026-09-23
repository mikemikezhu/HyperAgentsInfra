#!/bin/bash
#SBATCH --job-name=ha-pr-gvf-l5-s1-long-q38
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
if [[ "${1:-}" == --* ]]; then
    while [[ "$#" -gt 0 ]]; do
        if [[ "$#" -lt 2 || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
            echo "Usage: bash $script_path [--max_generation <generations>] [--stop_token_budget <tokens>]" >&2
            exit 2
        fi
        case "$1" in
            --max_generation|--max-generation) generation_limit="$2" ;;
            --stop_token_budget|--stop-token-budget) stop_token_budget="$2" ;;
            *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
        esac
        shift 2
    done
fi

if [[ -n "$stop_token_budget" ]]; then
    first_generation_target=10
    generation_limit_args=()
    if [[ -n "$generation_limit" ]]; then
        generation_limit_args=("$generation_limit")
        if (( generation_limit < first_generation_target )); then
            first_generation_target="$generation_limit"
        fi
    fi
    readonly infra_root="$(cd -- "$script_dir/../../../.." && pwd)"
    cd "$infra_root"
    job_id="$(
        sbatch \
            --parsable \
            --job-name="ha-pr-a3-l5-s1-g0-$first_generation_target-q38" \
            "$script_path" \
            long-run-start \
            "$first_generation_target" \
            "$stop_token_budget" \
            "${generation_limit_args[@]}"
    )"
    printf 'A3 lambda=5 sibling=1 token budget %s: %s\n' "$stop_token_budget" "${job_id%%;*}"
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
                --job-name="ha-pr-a3-l5-s1-g${generation_range}-q38" \
                "$script_path" \
                "$phase" \
                "$max_generation"
        )"
        job_id="${job_id%%;*}"
        job_chain="${job_chain:+$job_chain -> }$job_id"
        previous_job_id="$job_id"
    done

    printf 'A3 lambda=5 sibling=1: %s\n' "$job_chain"
    exit 0
fi

readonly launcher_path="${SLURM_SUBMIT_DIR:?Submit this script from the HyperAgentsInfra root}/nibi/paper-review/qwen3.8-27b/launcher.sh"

if [[ ! -x "$launcher_path" ]]; then
    echo "ERROR: launcher not found: $launcher_path" >&2
    echo "Submit this script from the HyperAgentsInfra repository root." >&2
    exit 1
fi

exec "$launcher_path" gvf_lambda5_sibling1 "$@"
