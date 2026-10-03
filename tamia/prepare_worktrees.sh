#!/bin/bash
set -euo pipefail

# Run on TamIA after cloning both repositories. Never reset existing worktrees.
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly infra_root="$(cd -- "$script_dir/.." && pwd)"
: "${SCRATCH:?TamIA must provide SCRATCH}"
readonly repo="$SCRATCH/HyperAgents/HyperAgents"
readonly experiment_root="${HYPERAGENTS_EXPERIMENT_ROOT:-$SCRATCH/HyperAgents/experiments}"
source "$infra_root/source_shas.env"

for revision in "$COMMON_BASE_SHA" "$GVF_SHA" "$STRUCTURED_HISTORY_SHA"; do
    git -C "$repo" cat-file -e "${revision}^{commit}"
done

for script in "$script_dir"/paper-review/qwen3.8-27b/*/long_run.sh; do
    profile="$(basename -- "$(dirname -- "$script")")"
    case "$profile" in
        original-full|original-compressed10) revision="$COMMON_BASE_SHA" ;;
        structured_history) revision="$STRUCTURED_HISTORY_SHA" ;;
        gvf_*) revision="$GVF_SHA" ;;
        *) echo "ERROR: unknown profile: $profile" >&2; exit 1 ;;
    esac
    source_path="$experiment_root/paper-review-${profile}-qwen38/source"
    if [[ -e "$source_path" ]]; then
        if [[ "$(git -C "$source_path" rev-parse --show-toplevel)" != "$(realpath "$source_path")" ||
              "$(git -C "$source_path" rev-parse HEAD)" != "$revision" ||
              -n "$(git -C "$source_path" status --porcelain)" ]]; then
            echo "ERROR: existing source must be a clean worktree at $revision: $source_path" >&2
            exit 1
        fi
    else
        mkdir -p "$(dirname -- "$source_path")"
        git -C "$repo" worktree add --detach "$source_path" "$revision"
    fi
    mkdir -p "$source_path/outputs"
    printf 'PREPARED: %s -> %s\n' "$profile" "$revision"
done

printf 'TAMIA_WORKTREES_PREPARED; existing outputs were preserved.\n'
