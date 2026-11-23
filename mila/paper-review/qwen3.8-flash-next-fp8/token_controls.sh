# Shared by the Mila 192M token profiles. Sourced by launcher.sh.
submit_continuation() {
    # Wrappers locate the shared launcher relative to SLURM_SUBMIT_DIR.
    local next_job_id
    cd "$launcher_dir/../../.."
    next_job_id="$(sbatch --parsable --kill-on-invalid-dep=yes --dependency="afterok:$SLURM_JOB_ID" \
        "$launcher_dir/token_run.sh" "$profile" long-run-resume "$SLURM_JOB_ID")"
    echo "CONTINUATION_JOB=${next_job_id%%;*} PROFILE=$profile"
}

long_run_status() {
    PYTHONPATH="$worktree_path" "$venv_path/bin/python" "$launcher_dir/long_run_status.py" \
        "$run_output" "$profile" --tokens "${token_budgets[@]}" --hours "${search_hour_checkpoints[@]}"
}

allocation_end_time() {
    if [[ "${SLURM_JOB_END_TIME:-}" =~ ^[1-9][0-9]*$ ]]; then
        echo "$SLURM_JOB_END_TIME"
    else
        local job
        job="$(scontrol show job -o "$SLURM_JOB_ID")" || return 1
        if [[ "$job" =~ [[:space:]]EndTime=([^[:space:]]+) ]]; then
            date -d "${BASH_REMATCH[1]}" +%s
        else
            echo "ERROR: Slurm did not supply an allocation end time" >&2
            return 1
        fi
    fi
}

# Check between durable units. Duration is measured on the current allocation.
# Allow 25% headroom over the slower of the last two units.
continue_in_allocation() {
    local now="$1" duration="$2" previous="$3" deadline="$4" retry_delay="$5"
    local estimated="$duration"
    if (( previous > estimated )); then estimated="$previous"; fi
    local remaining=$((deadline - now))
    local needed=$((retry_delay + (estimated * 5 + 3) / 4))
    echo "ALLOCATION_REMAINING_SECONDS=$remaining NEXT_UNIT_REQUIRED_SECONDS=$needed"
    (( remaining >= needed ))
}

configure_token_run() {
    readonly stop_token_budget="${token_budgets[-1]}"
    readonly profile="${1:?Pass the token experiment profile}"
    readonly phase="${2:-long-run-start}"
    case "$phase" in
        long-run-start) (( $# <= 2 )) || { usage; exit 2; } ;;
        long-run-resume) (( $# <= 2 )) || [[ $# == 3 && "$3" =~ ^[0-9]+$ ]] || { usage; exit 2; } ;;
        long-run-recover) [[ $# == 3 && "$3" =~ ^[0-9]+$ ]] || { usage; exit 2; } ;;
        *) usage; exit 2 ;;
    esac
    configure_profile "$profile"
    stop_args=(--stop_token_budget "$stop_token_budget")
    search_control_args=(--early_stop false)
}

lock_token_run() {
    # Serialize jobs for one run. Keep the lock outside the private directory so
    # checking a fresh start does not create the very output it rejects.
    mkdir -p "$worktree_path/outputs"
    exec {run_lock}>"${private_output}.lock"
    flock -n "$run_lock" || { echo "Another job owns this token run" >&2; exit 1; }
    if [[ $# == 3 ]]; then
        if [[ "$(cat "$private_output/token_job" 2>/dev/null)" != "$3" ]]; then
            echo "Skipping superseded continuation for job $3"
            exit 0
        fi
    fi
}

arm_timeout_recovery() {
    # Register before any baseline, search or held-out work. On success Slurm
    # cancels this impossible dependency; the watcher filters all other states.
    printf '%s\n' "$SLURM_JOB_ID" > "$private_output/token_job.new"
    mv "$private_output/token_job.new" "$private_output/token_job"
    (cd "$launcher_dir/../../.." && sbatch --parsable --kill-on-invalid-dep=yes \
        --dependency="afternotok:$SLURM_JOB_ID" "$launcher_dir/timeout_recovery.sh" \
        "$SLURM_JOB_ID" "$launcher_dir/token_run.sh" "$profile")
}

run_single_island_unit() {
    "$VIRTUAL_ENV/bin/python" "$launcher_dir/token_recovery.py" search "$run_output" \
        "${run_args[@]}" --max_generation "$generation_target" \
        --token_budgets "${token_budgets[@]}" --stop_token_budget "$stop_token_budget" \
        --search_hour_checkpoints "${search_hour_checkpoints[@]}" \
        --early_stop false --test_eval_samples 50 --test_eval_repeats 3 \
        "${generate_args[@]}"
}

run_token_search() {
    local deadline status bootstrap recovery_mode completed_generation generation_target
    local previous_duration first_unit started prior_status ended duration retry_delay
    local -a run_args unit_args
    deadline="$(allocation_end_time)"
    readonly deadline
    [[ "$deadline" =~ ^[1-9][0-9]*$ && "$deadline" -gt "$(date +%s)" ]] || {
        echo "ERROR: invalid Slurm allocation end time: $deadline" >&2; exit 1;
    }
    status=searching
    bootstrap=false
    if [[ "$profile" == gvf_map ]]; then
        if [[ "$phase" == long-run-recover ]]; then
            "$VIRTUAL_ENV/bin/python" "$launcher_dir/token_recovery.py" repair-map "$run_output"
        fi
        if [[ "$phase" != long-run-start && -f "$private_output/state.json" ]]; then
            status="$(long_run_status)"
        fi
    else
        if [[ "$phase" == long-run-start ]]; then
            bootstrap=true
        elif [[ "$phase" == long-run-recover ]]; then
            recovery_mode="$("$VIRTUAL_ENV/bin/python" "$launcher_dir/token_recovery.py" repair "$run_output")"
            if [[ "$recovery_mode" == bootstrap ]]; then bootstrap=true; fi
        fi
        if [[ "$bootstrap" == false ]]; then
            run_args=(--resume_from "$run_output")
            completed_generation="$("$VIRTUAL_ENV/bin/python" - "$run_output/archive.jsonl" <<'PY'
import json, sys
with open(sys.argv[1]) as archive:
    current = json.loads([line for line in archive if line.strip()][-1])["current_genid"]
print(0 if current == "initial" else int(current))
PY
    )"
        else
            run_args=(--run_id "$run_id" --output_dir_parent "$worktree_path/outputs")
            completed_generation=0
        fi
        generation_target=$((completed_generation + 1))
    fi

    previous_duration=0
    first_unit=true
    while [[ "$status" != complete ]]; do
        started="$(date +%s)"
        prior_status="$status"
        if [[ "$profile" == gvf_map ]]; then
            unit_args=(--max_rounds_this_job 1)
            if [[ "$status" == searching ]]; then unit_args+=(--defer_test); fi
            "$VIRTUAL_ENV/bin/python" "$launcher_dir/token_recovery.py" map-search "$run_output" \
                "${map_args[@]}" "${unit_args[@]}"
        else
            if [[ "$first_unit" == true && "$bootstrap" == true ]]; then
                run_initial_baseline_split train
                run_initial_baseline_split val
            fi
            run_single_island_unit
        fi

        status="$(long_run_status)"
        echo "FORMAL_LONG_RUN_STATUS=$status PROFILE=$profile"
        case "$status" in
            complete|searching|testing) ;;
            *) echo "ERROR: unexpected long-run status: $status" >&2; exit 1 ;;
        esac
        if [[ "$profile" != gvf_map ]]; then
            verify_search_completion "$generation_target"
            write_formal_results
            # The engine and its archive/test verifiers returned. Its active-unit
            # snapshots are no longer needed by the next generation.
            "$VIRTUAL_ENV/bin/python" "$launcher_dir/token_recovery.py" release "$run_output"
            if [[ "$first_unit" == true ]]; then verify_generated_repository; fi
            run_args=(--resume_from "$run_output")
            generation_target=$((generation_target + 1))
        fi
        [[ -z "$(git -C "$worktree_path" status --porcelain)" ]] || {
            echo "ERROR: source worktree changed." >&2; exit 1;
        }
        if [[ "$status" == complete ]]; then break; fi

        ended="$(date +%s)"
        duration=$((ended - started))
        retry_delay=0
        if [[ "$prior_status" == testing && "$status" == testing ]]; then retry_delay=60; fi
        if ! continue_in_allocation "$ended" "$duration" "$previous_duration" "$deadline" "$retry_delay"; then
            submit_continuation
            break
        fi
        if (( retry_delay > 0 )); then sleep "$retry_delay"; fi
        previous_duration="$duration"
        first_unit=false
    done
}
