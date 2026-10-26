#!/bin/bash
set -euo pipefail

# Run on Mila after fetching the reviewed adaptation commits. Never reset existing worktrees.
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly repo="${HYPERAGENTS_SOURCE_REPO:-$HOME/scratch/HyperAgents/HyperAgents}"
readonly experiment_root="${HYPERAGENTS_EXPERIMENT_ROOT:-$HOME/scratch/HyperAgents/experiments}"
source "$script_dir/source_shas.env"
: "${COMMON_BASE_SHA:?Fill the reviewed main adaptation commit}"
: "${GVF_SHA:?Fill the reviewed GVF adaptation commit}"
: "${STRUCTURED_HISTORY_SHA:?Fill the reviewed structured-history adaptation commit}"

for revision in "$COMMON_BASE_SHA" "$GVF_SHA" "$STRUCTURED_HISTORY_SHA"; do
    if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
        echo "ERROR: source pins must be full commit SHAs" >&2
        exit 1
    fi
    git -C "$repo" cat-file -e "${revision}^{commit}"
done

for script in "$script_dir"/*/long_run.sh; do
    profile="$(basename -- "$(dirname -- "$script")")"
    case "$profile" in
        original-full|original-compressed10) revision="$COMMON_BASE_SHA" ;;
        structured_history) revision="$STRUCTURED_HISTORY_SHA" ;;
        gvf_*) revision="$GVF_SHA" ;;
        *) echo "ERROR: unknown profile: $profile" >&2; exit 1 ;;
    esac
    source_path="$experiment_root/paper-review-${profile}-qwen38-flash-next-fp8-cairn/source"
    if [[ -e "$source_path" ]]; then
        if [[ "$(git -C "$source_path" rev-parse --show-toplevel)" != "$(realpath "$source_path")" ||
              "$(git -C "$source_path" rev-parse HEAD)" != "$revision" ||
              -n "$(git -C "$source_path" status --porcelain)" ]]; then
            echo "ERROR: existing source must be a clean worktree at $revision: $source_path" >&2
            exit 1
        fi
        if git -C "$source_path" symbolic-ref -q HEAD >/dev/null; then
            echo "ERROR: experiment source must be detached: $source_path" >&2
            exit 1
        fi
    else
        mkdir -p "$(dirname -- "$source_path")"
        git -C "$repo" worktree add --detach "$source_path" "$revision"
    fi
    mkdir -p "$source_path/outputs"
    printf 'PREPARED: %s -> %s\n' "$profile" "$revision"
done

printf 'MILA_CAIRN_WORKTREES_PREPARED; existing outputs were preserved.\n'
