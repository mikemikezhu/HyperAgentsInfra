# Ported from Mila token_controls.sh (26376e4). Shared by Nibi, Fir and Rorqual.
# Resource requests stay in each profile's existing long_run.sh.
token_continuation_args() {
    token_next_args=()
    if [[ "$profile" != gvf_map ]]; then
        token_next_args=(1 "$stop_token_budget")
    fi
    token_next_args+=(--token_parent_job "$SLURM_JOB_ID" "${search_control_args[@]}")
}

submit_continuation() {
    # Wrappers locate the shared launcher relative to SLURM_SUBMIT_DIR.
    local next_job_id
    cd "$infra_root"
    token_continuation_args
    next_job_id="$(sbatch --parsable --kill-on-invalid-dep=yes \
        --dependency="afterok:$SLURM_JOB_ID" "$token_wrapper" \
        long-run-resume "${token_next_args[@]}")"
    echo "CONTINUATION_JOB=${next_job_id%%;*} PROFILE=$profile"
}

long_run_status() {
    PYTHONPATH="$worktree_path" "$venv_path/bin/python" "$token_helper_dir/long_run_status.py" \
        "$run_output" "$profile" --domain "$token_domain" \
        --tokens "${checkpoint_budgets[@]}" --hours "${search_hour_checkpoints[@]}" \
        --generations "${generation_checkpoints[@]}" "${search_control_args[@]}"
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

lock_token_run() {
    # Serialize jobs for one run. Keep the lock outside the private directory so
    # checking a fresh start does not create the very output it rejects.
    mkdir -p "$worktree_path/outputs"
    exec {run_lock}>"${private_output}.lock"
    flock -n "$run_lock" || { echo "Another job owns this token run" >&2; exit 1; }
    if [[ -n "$token_parent_job" ]]; then
        if [[ "$(cat "$private_output/token_job" 2>/dev/null)" != "$token_parent_job" ]]; then
            echo "Skipping superseded continuation for job $token_parent_job"
            exit 0
        fi
    fi
}

arm_timeout_recovery() {
    # Register before any baseline, search or held-out work. On success Slurm
    # cancels this impossible dependency; the watcher filters all other states.
    mkdir -p "$private_output"
    printf '%s\n' "$SLURM_JOB_ID" > "$private_output/token_job.new"
    mv "$private_output/token_job.new" "$private_output/token_job"
    token_continuation_args
    # Use the submitted account, not a scheduler-expanded GPU-only association.
    local account
    account="$(sed -n 's/^#SBATCH --account=//p' "$token_wrapper")"
    [[ -n "$account" ]] || { echo "ERROR: token wrapper has no account" >&2; exit 1; }
    (cd "$infra_root" && sbatch --parsable --kill-on-invalid-dep=yes \
        --account="$account" \
        --dependency="afternotok:$SLURM_JOB_ID" "$token_helper_dir/timeout_recovery.sh" \
        "$SLURM_JOB_ID" "$token_wrapper" "${token_next_args[@]}")
}

run_single_island_unit() {
    "$VIRTUAL_ENV/bin/python" "$token_helper_dir/token_recovery.py" search "$run_output" \
        "${run_args[@]}" --max_generation "$generation_target" \
        --token_budgets "${checkpoint_budgets[@]}" --stop_token_budget "$stop_token_budget" \
        "${checkpoint_args[@]}" "${search_control_args[@]}" \
        --test_eval_samples 50 --test_eval_repeats 3 \
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
            "$VIRTUAL_ENV/bin/python" "$token_helper_dir/token_recovery.py" repair-map "$run_output"
        fi
        if [[ "$phase" != long-run-start && -f "$private_output/state.json" ]]; then
            status="$(long_run_status)"
        fi
    else
        if [[ "$phase" == long-run-start ]]; then
            bootstrap=true
        elif [[ "$phase" == long-run-recover ]]; then
            recovery_mode="$("$VIRTUAL_ENV/bin/python" "$token_helper_dir/token_recovery.py" repair "$run_output" "$token_domain")"
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
        if [[ "$profile" != gvf_map && -n "$generation_limit" ]] && (( generation_target > generation_limit )); then
            generation_target="$generation_limit"
        fi
        started="$(date +%s)"
        prior_status="$status"
        if [[ "$profile" == gvf_map ]]; then
            unit_args=(--max_rounds_this_job 1)
            if [[ "$status" == searching ]]; then unit_args+=(--defer_test); fi
            "$VIRTUAL_ENV/bin/python" "$token_helper_dir/token_recovery.py" map-search "$run_output" \
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
            "$VIRTUAL_ENV/bin/python" "$token_helper_dir/token_recovery.py" release "$run_output"
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
