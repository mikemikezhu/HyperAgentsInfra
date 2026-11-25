#!/bin/bash
#SBATCH --job-name=ha-token-timeout
#SBATCH --partition=unkillable-cpu
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --time=00:05:00
#SBATCH --output=%x-%j.out

set -euo pipefail
parent="${1:?missing parent job ID}"
wrapper="${2:?missing token wrapper}"
profile="${3:?missing token profile}"
[[ "$parent" =~ ^[0-9]+$ && -f "$wrapper" ]]
cd "${SLURM_SUBMIT_DIR:?missing submission directory}"

# Accounting can lag the dependency notification. Match only the allocation row.
for ((attempt=0; attempt<45; attempt++)); do
    rows="$(sacct -X -n -P -j "$parent" -o JobIDRaw,State%40)" || rows=""
    state="$(awk -F'|' -v id="$parent" '$1 == id {print $2; exit}' <<< "$rows")"
    case "$state" in
        ""|PENDING|RUNNING|COMPLETING|CONFIGURING|SUSPENDED)
            # A finished job may still be in the controller before sacct catches up.
            controller="$(scontrol show job -o "$parent" 2>/dev/null)" || controller=""
            if [[ " $controller " =~ [[:space:]]JobState=([^[:space:]]+) ]]; then
                state="${BASH_REMATCH[1]}"
            fi ;;
    esac
    case "$state" in
        TIMEOUT)
            job="$("$wrapper" --submit-afterok "$profile" long-run-recover "$parent")"
            echo "TIMEOUT_PARENT=$parent RECOVERY_JOB=$job"
            exit 0 ;;
        ""|PENDING|RUNNING|COMPLETING|CONFIGURING|SUSPENDED) sleep 5 ;;
        *) echo "No timeout recovery for $parent ($state)"; exit 0 ;;
    esac
done
echo "Could not establish terminal accounting state for job $parent" >&2
exit 1
