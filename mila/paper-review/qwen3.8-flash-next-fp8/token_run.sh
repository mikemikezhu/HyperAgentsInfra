#!/bin/bash
#SBATCH --job-name=ha-pr-token-cairn
#SBATCH --partition=unkillable-cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=1-12:00:00
#SBATCH --output=%x-%j.out

set -euo pipefail
# Slurm reads #SBATCH before the script can inspect the profile. Select the
# baseline override when submitting, including submissions from a timeout watcher.
case "${1:-}" in
    --submit|--submit-afterok)
        submit_args=(--parsable)
        if [[ "$1" == --submit-afterok ]]; then
            submit_args+=(--kill-on-invalid-dep=yes --dependency="afterok:${SLURM_JOB_ID:?missing predecessor job ID}")
        fi
        shift
        case "${1:?missing token profile}" in
            original-full|original-compressed10) submit_args+=(--cpus-per-task=1) ;;
        esac
        exec sbatch "${submit_args[@]}" "$0" "$@"
        ;;
esac
exec "${SLURM_SUBMIT_DIR:?Submit from the HyperAgentsInfra root}/mila/paper-review/qwen3.8-flash-next-fp8/launcher.sh" --token-run "$@"
