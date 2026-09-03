#!/bin/bash
#SBATCH --job-name=ha-pr-gvf-c10-long-q38
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=h100:2
#SBATCH --cpus-per-task=12
#SBATCH --mem=96G
#SBATCH --time=1-12:00:00
#SBATCH --partition=gpubase_bygpu_b4
#SBATCH --account=rrg-bengioy-ad
#SBATCH --output=%x-%j.out

set -euo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_path="$script_dir/long_run.sh"

if [[ "$#" -eq 0 ]]; then
    readonly infra_root="$(cd -- "$script_dir/../../../.." && pwd)"
    cd "$infra_root"

    previous_job_id=""
    job_chain=""
    for max_generation in 10 20 30 40 50 60 70 80 90 100
    do
        if [[ "$max_generation" -eq 10 ]]; then
            phase="long-run-start"
            generation_range="0-10"
            dependency=()
        else
            phase="long-run-resume"
            generation_range="$((max_generation - 9))-$max_generation"
            dependency=(--dependency="afterok:${previous_job_id}")
        fi

        job_id="$(
            sbatch \
                --parsable \
                "${dependency[@]}" \
                --job-name="ha-pr-a3-g${generation_range}-q38" \
                "$script_path" \
                "$phase" \
                "$max_generation"
        )"
        job_id="${job_id%%;*}"
        job_chain="${job_chain:+$job_chain -> }$job_id"
        previous_job_id="$job_id"
    done

    printf 'A3: %s\n' "$job_chain"
    exit 0
fi

readonly launcher_path="${SLURM_SUBMIT_DIR:?Submit this script from the HyperAgentsInfra root}/rorqual/paper-review/qwen3.8-27b/launcher.sh"

if [[ ! -x "$launcher_path" ]]; then
    echo "ERROR: launcher not found: $launcher_path" >&2
    echo "Submit this script from the HyperAgentsInfra repository root." >&2
    exit 1
fi

exec "$launcher_path" gvf-compressed10 "$@"
