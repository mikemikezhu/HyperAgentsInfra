#!/bin/bash
#SBATCH --job-name=ha-pr-gvf-map-cairn
#SBATCH --partition=unkillable-cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=1-12:00:00
#SBATCH --output=%x-%j.out

set -euo pipefail
readonly launcher_path="${SLURM_SUBMIT_DIR:?Submit from the HyperAgentsInfra root}/mila/paper-review/qwen3.8-flash-next-fp8/launcher.sh"
exec "$launcher_path" --token-run gvf_map "${1:-long-run-start}"
