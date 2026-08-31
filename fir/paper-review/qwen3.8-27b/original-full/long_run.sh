#!/bin/bash
#SBATCH --job-name=ha-pr-original-full-long-q38
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=h100:2
#SBATCH --cpus-per-task=12
#SBATCH --mem=96G
#SBATCH --time=5-00:00:00
#SBATCH --account=rrg-bengioy-ad
#SBATCH --output=%x-%j.out

set -euo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "$script_dir/../launcher.sh" original-full "$@"
