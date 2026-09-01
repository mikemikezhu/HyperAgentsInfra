#!/bin/bash
#SBATCH --job-name=ha-pr-original-c10-q38
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=h100:2
#SBATCH --cpus-per-task=12
#SBATCH --mem=96G
#SBATCH --time=12:00:00
#SBATCH --account=rrg-bengioy-ad
#SBATCH --output=%x-%j.out

set -euo pipefail

readonly launcher_path="${SLURM_SUBMIT_DIR:?Submit this script from the HyperAgentsInfra root}/fir/paper-review/qwen3.8-27b/launcher.sh"

if [[ ! -x "$launcher_path" ]]; then
    echo "ERROR: launcher not found: $launcher_path" >&2
    echo "Submit this script from the HyperAgentsInfra repository root." >&2
    exit 1
fi

exec "$launcher_path" original-compressed10 "$@"
