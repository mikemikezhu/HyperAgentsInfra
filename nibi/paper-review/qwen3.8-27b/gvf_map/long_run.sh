#!/bin/bash
#SBATCH --job-name=ha-pr-gvf-map-long-q38
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=h100:2
#SBATCH --cpus-per-task=12
#SBATCH --mem=96G
#SBATCH --time=1-12:00:00
#SBATCH --account=rrg-bengioy-ad
#SBATCH --output=%x-%j.out
set -euo pipefail
# One shared model service; two independent search processes. 192M is global.
readonly launcher="${SLURM_SUBMIT_DIR:?Submit from HyperAgentsInfra}/nibi/paper-review/qwen3.8-27b/launcher.sh"
exec "$launcher" gvf_map "${1:-long-run-start}" 1 192000000
