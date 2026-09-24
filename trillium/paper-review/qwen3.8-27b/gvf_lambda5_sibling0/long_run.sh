#!/bin/bash
#SBATCH --job-name=ha-pr-gvf-l5-s0-long-q38
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=4
#SBATCH --time=1-00:00:00
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

if [[ -n "$stop_token_budget" && -z "$generation_limit" ]]; then
    echo "ERROR: Trillium token-limited chains also require --max_generation; compute nodes cannot submit continuations." >&2
    exit 2
fi

if [[ "$#" -eq 0 ]]; then
    if [[ -n "${SLURM_JOB_ID:-}" ]]; then
        echo "ERROR: submit the job chain with bash from the Trillium GPU login node; use an explicit phase inside a job." >&2
        exit 2
    fi
    readonly infra_root="$(cd -- "$script_dir/../../../.." && pwd)"
    cd "$infra_root"

    previous_job_id=""
    job_chain=""
    generation_limit="${generation_limit:-30}"
    stop_limit_args=()
    if [[ -n "$stop_token_budget" ]]; then
        stop_limit_args=("$stop_token_budget" "$generation_limit")
    fi
    for (( segment_start=0; segment_start < generation_limit; segment_start+=5 ))
    do
        max_generation="$((segment_start + 5))"
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
                --job-name="ha-pr-a3-l5-s0-g${generation_range}-q38" \
                "$script_path" \
                "$phase" \
                "$max_generation" \
                "${stop_limit_args[@]}"
        )"
        job_id="${job_id%%;*}"
        job_chain="${job_chain:+$job_chain -> }$job_id"
        previous_job_id="$job_id"
    done

    printf 'A3 lambda=5 sibling=0: %s\n' "$job_chain"
    exit 0
fi

readonly launcher_path="${SLURM_SUBMIT_DIR:?Submit this script from the HyperAgentsInfra root}/trillium/paper-review/qwen3.8-27b/launcher.sh"

if [[ ! -x "$launcher_path" ]]; then
    echo "ERROR: launcher not found: $launcher_path" >&2
    echo "Submit this script from the HyperAgentsInfra repository root." >&2
    exit 1
fi

exec "$launcher_path" gvf_lambda5_sibling0 "$@"
