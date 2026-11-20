#!/bin/bash
set -euo pipefail

# The same detached-worktree preparation used by tamia/prepare_worktrees.sh,
# scoped to the new tasks; existing Paper Review worktrees are never updated.
readonly infra_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$#" -lt 2 || "$#" -gt 3 ]]; then
    echo "Usage: bash $0 <cluster> <imo-grading|search-arena|paper-review> [profile]" >&2
    exit 2
fi
readonly cluster="$1"
readonly task="$2"
readonly requested_profile="${3:-}"
case "$cluster" in
    nibi|rorqual|fir|tamia|trillium) ;;
    *) echo "ERROR: unsupported cluster: $cluster" >&2; exit 2 ;;
esac
case "$task" in
    imo-grading) source "$infra_root/source_shas_imo_grading.env" ;;
    search-arena) source "$infra_root/source_shas_search_arena.env" ;;
    paper-review)
        [[ "$cluster" == nibi && "$requested_profile" == gvf_map ]] || {
            echo "ERROR: Paper Review preparation here is scoped to nibi paper-review gvf_map" >&2; exit 2;
        }
        source "$infra_root/source_shas.env"
        : "${GVF_MAP_SHA:?Pin the reviewed GVF-MAP commit first}"
        ;;
    *) echo "ERROR: unsupported task: $task" >&2; exit 2 ;;
esac
: "${SCRATCH:?SCRATCH is required}"
: "${COMMON_BASE_SHA:?Pin the reviewed main commit before preparing worktrees}"
: "${GVF_SHA:?Pin the reviewed gvf-hyperagents commit before preparing worktrees}"
: "${STRUCTURED_HISTORY_SHA:?Pin the reviewed ha-structured-history commit before preparing worktrees}"
readonly repo="$SCRATCH/HyperAgents/HyperAgents"
readonly experiment_root="${HYPERAGENTS_EXPERIMENT_ROOT:-$SCRATCH/HyperAgents/experiments}"

for revision in "$COMMON_BASE_SHA" "$GVF_SHA" "$STRUCTURED_HISTORY_SHA"; do
    git -C "$repo" cat-file -e "${revision}^{commit}"
done

for script in "$infra_root/$cluster/$task/qwen3.8-27b"/*/long_run.sh; do
    profile="$(basename -- "$(dirname -- "$script")")"
    [[ -z "$requested_profile" || "$profile" == "$requested_profile" ]] || continue
    case "$profile" in
        original-full|original-compressed10) revision="$COMMON_BASE_SHA" ;;
        structured_history) revision="$STRUCTURED_HISTORY_SHA" ;;
        gvf_map) revision="${GVF_MAP_SHA:?GVF_MAP_SHA is required for gvf_map only}" ;;
        gvf_*) revision="$GVF_SHA" ;;
        *) echo "ERROR: unknown profile: $profile" >&2; exit 1 ;;
    esac
    source_path="$experiment_root/$task-${profile}-qwen38/source"
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

printf '%s_WORKTREES_PREPARED; existing outputs were preserved.\n' "$task"
