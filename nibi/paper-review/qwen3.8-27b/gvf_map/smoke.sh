#!/bin/bash
#SBATCH --job-name=ha-pr-gvf-map-smoke-q38
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=h100:2
#SBATCH --cpus-per-task=12
#SBATCH --mem=96G
#SBATCH --time=06:00:00
#SBATCH --account=rrg-bengioy-ad
#SBATCH --output=%x-%j.out
set -euo pipefail
readonly launcher="${SLURM_SUBMIT_DIR:?Submit from HyperAgentsInfra}/nibi/paper-review/qwen3.8-27b/launcher.sh"
exec "$launcher" gvf_map map-smoke
