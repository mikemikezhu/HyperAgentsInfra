#!/bin/bash
#SBATCH --job-name=ha-pr-val-diagnostic-q38
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=h100:2
#SBATCH --cpus-per-task=12
#SBATCH --mem=96G
#SBATCH --time=12:00:00
#SBATCH --account=rrg-bengioy-ad
#SBATCH --output=%x-%j.out

set -euo pipefail

# One profile per job. This is an offline diagnostic, never an evolution phase.
if [[ "$#" -ne 3 ]]; then
    echo "Usage: sbatch $0 <profile> <token-budget> <validation-samples>" >&2
    echo "Submit from the HyperAgentsInfra repository root." >&2
    exit 2
fi
readonly profile="$1" budget="$2" samples="$3"
# Slurm executes a spooled script, so BASH_SOURCE cannot locate the repository.
: "${SLURM_JOB_ID:?Submit this script with sbatch}"
: "${SLURM_SUBMIT_DIR:?Submit from the HyperAgentsInfra repository root}"
readonly infra_root="$SLURM_SUBMIT_DIR"
source "$infra_root/source_shas.env"
case "$profile" in
    original-compressed10) expected_sha="$COMMON_BASE_SHA" ;;
    gvf-compressed10-lambda1|gvf-compressed10-lambda5|gvf-compressed10-lambda10|gvf-reason-compressed10)
        expected_sha="$GVF_SHA" ;;
    *) echo "ERROR: unsupported diagnostic profile: $profile" >&2; exit 2 ;;
esac
[[ "$budget" =~ ^[1-9][0-9]*$ && "$samples" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: budget and validation sample count must be positive integers." >&2
    exit 2
}
(( samples <= 100 )) || { echo "ERROR: validation contains only 100 samples." >&2; exit 2; }
: "${SCRATCH:?Nibi must provide SCRATCH}"
: "${SLURM_TMPDIR:?Slurm must provide a private temporary directory}"

readonly experiment_root="${HYPERAGENTS_EXPERIMENT_ROOT:-$SCRATCH/HyperAgents/experiments}"
readonly source_dir="$experiment_root/paper-review-${profile}-qwen38/source"
readonly run_dir="$source_dir/outputs/generate_paper_review_${profile//-/_}_qwen38_long_run1"
readonly diagnostic_dir="$SCRATCH/HyperAgents/diagnostics/validation-T${budget}-n${samples}-${SLURM_JOB_ID}/$profile"
readonly runtime_dir="$SLURM_TMPDIR/validation-diagnostic-${profile}-${SLURM_JOB_ID}"
readonly venv_path="${HYPERAGENTS_VENV_PATH:-/home/mikezhu/projects/rrg-bengioy-ad/mikezhu/venv}"
readonly model_path="${HYPERAGENTS_MODEL_PATH:-/home/mikezhu/projects/rrg-bengioy-ad/mikezhu/model/Qwen3.8-27B}"
readonly apptainer_image="${HYPERAGENTS_APPTAINER_IMAGE:-$SCRATCH/apptainer_images/hyperagents-text-eaa0a09.sif}"
readonly port="$((20000 + SLURM_JOB_ID % 40000))"

[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$expected_sha" ]] || {
    echo "ERROR: diagnostic source SHA does not match source_shas.env." >&2; exit 1;
}
[[ -z "$(git -C "$source_dir" status --porcelain)" ]] || {
    echo "ERROR: diagnostic source worktree is not clean." >&2; exit 1;
}
module load apptainer/1.4.5
source "$venv_path/bin/activate"
export PYTHONDONTWRITEBYTECODE=1
cd "$source_dir"

run_diagnostic() {
    "$VIRTUAL_ENV/bin/python" - "$1" "$profile" "$budget" "$samples" \
        "$run_dir" "$diagnostic_dir" "$runtime_dir" "$apptainer_image" <<'PY'
import csv
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.request import urlopen
from pathlib import Path

from analysis.transfer_utils import choose_node_for_transfer
from measurement.token_accounting import read_evaluation_records, read_total_tokens
from utils.gl_utils import get_patch_files
from utils.trusted_eval import prepare_hidden_label_eval

phase, profile, budget, samples, run, destination, runtime, image = sys.argv[1:]
budget, samples = int(budget), int(samples)
run, destination = Path(run), Path(destination)
plan_path = destination / "candidates.json"
dataset = Path("domains/paper_review/dataset_filtered_100_val.csv")

def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

if phase == "prepare":
    # Completion records, not mutable parent-generation eligibility, define the pool.
    records = [record for record in read_evaluation_records(str(run) + "_private")
               if record["evaluation_cost_tokens"] <= budget]
    if not records:
        raise RuntimeError("No completed evaluations exist within this budget.")
    destination.mkdir(parents=True, exist_ok=False)
    live_repo = run / "gen_initial/hyperagents"
    roots = git(live_repo, "rev-list", "--max-parents=0", "HEAD").splitlines()
    if len(roots) != 1:
        raise RuntimeError("Expected one initial commit in the generated repository.")
    base = destination / "initial_snapshot"
    base.mkdir()
    # Never copy or reset the live evolution checkout, which may be mid-generation.
    with tempfile.TemporaryFile() as archive:
        subprocess.run(["git", "-C", str(live_repo), "archive", roots[0]],
                       stdout=archive, check=True)
        archive.seek(0)
        with tarfile.open(fileobj=archive) as contents:
            contents.extractall(base, filter="data")
    patches_dir = destination / "patches"
    patches_dir.mkdir()
    candidates = []
    for record in records:
        version = record["version_id"]
        if version != "initial" and not (run / f"gen_{version}/metadata.json").is_file():
            raise FileNotFoundError(f"Missing metadata for evaluated version {version}.")
        originals = get_patch_files(str(run), version)
        if version != "initial" and not originals:
            raise RuntimeError(f"Evaluated version {version} has no patch chain.")
        patches = []
        for original in originals:
            original = Path(original)
            sha = digest(original)
            frozen = patches_dir / f"{sha}.diff"
            if not frozen.exists():
                shutil.copyfile(original, frozen)
            patches.append({"path": str(frozen), "sha256": sha, "source": str(original)})
        candidates.append({**record, "patches": patches})
    # Use the same existing head-N sampler as run_eval, with no labels persisted.
    with tempfile.TemporaryDirectory(prefix="ha-validation-input-") as temporary:
        prepare_hidden_label_eval(
            domain="paper_review", subset="_filtered_100_val", num_samples=samples,
            dataset_path=str(Path(temporary) / "dataset.csv"),
            manifest_path=str(destination / "validation_manifest.json"), split="val",
        )
    plan = {"profile": profile, "budget": budget, "num_samples": samples,
            "source_sha": git(Path.cwd(), "rev-parse", "HEAD"),
            "initial_commit": roots[0], "initial_snapshot": str(base),
            "validation_sha256": digest(dataset), "candidates": candidates}
    plan_path.write_text(json.dumps(plan, indent=2) + "\n")
    print(f"Froze {len(candidates)} candidates: {plan_path}")
elif phase == "evaluate":
    from domains.run_eval import run_eval

    def check_service():
        # A dead inference service is not a valid zero-accuracy measurement.
        health_url = os.environ["HYPERAGENTS_API_BASE"].removesuffix("/v1") + "/health"
        with urlopen(health_url, timeout=10) as response:
            if response.status != 200:
                raise RuntimeError("The diagnostic vLLM service is unhealthy.")

    plan = json.loads(plan_path.read_text())
    if git(Path.cwd(), "rev-parse", "HEAD") != plan["source_sha"] or digest(dataset) != plan["validation_sha256"]:
        raise RuntimeError("Source or validation data changed after preparation.")
    expected = json.loads((destination / "validation_manifest.json").read_text())
    rows = []
    for candidate in plan["candidates"]:
        for patch in candidate["patches"]:
            if digest(patch["path"]) != patch["sha256"]:
                raise RuntimeError("A frozen patch changed after preparation.")
        version = candidate["version_id"]
        run_id = f"validation_{profile}_gen_{version}"
        check_service()
        run_eval(
            output_dir=str(destination / "evaluations"), domain="paper_review",
            run_id=run_id, num_samples=plan["num_samples"], num_workers=8,
            subset="_filtered_100_val",
            patch_files=[patch["path"] for patch in candidate["patches"]],
            copy_root_dir=plan["initial_snapshot"], execution_backend="apptainer",
            apptainer_image=image, apptainer_runtime_dir=runtime,
        )
        check_service()
        result = destination / "evaluations" / run_id
        manifest = json.loads((result / "paper_review/eval_manifest.json").read_text())
        report = json.loads((result / "paper_review/report.json").read_text())
        if (manifest["subset"] != "_filtered_100_val"
                or manifest["sample_ids"] != expected["sample_ids"]
                or report["total"] != plan["num_samples"]):
            raise RuntimeError(f"Validation sample mismatch for version {version}.")
        token_log = result / "measurement/token_log.jsonl"
        if not token_log.is_file():
            raise FileNotFoundError(f"Missing diagnostic token log: {token_log}")
        rows.append({"version_id": version,
                     "evaluation_cost_tokens": candidate["evaluation_cost_tokens"],
                     "original_validation": candidate["score"],
                     "diagnostic_validation": report["overall_accuracy"],
                     "diagnostic_tokens": read_total_tokens(str(token_log))})
    # Stable sorting preserves the existing latest-completed tie rule.
    old_order = choose_node_for_transfer(
        {row["version_id"]: row["original_validation"] for row in reversed(rows)},
        {}, method="max_score", top_n=len(rows))
    new_order = choose_node_for_transfer(
        {row["version_id"]: row["diagnostic_validation"] for row in reversed(rows)},
        {}, method="max_score", top_n=len(rows))
    for row in rows:
        row["original_rank"] = old_order.index(row["version_id"]) + 1
        row["diagnostic_rank"] = new_order.index(row["version_id"]) + 1
    with (destination / "summary.csv").open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    summary = {"original_selected_version": old_order[0],
               "diagnostic_selected_version": new_order[0],
               "diagnostic_tokens": sum(row["diagnostic_tokens"] for row in rows)}
    (destination / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary))
else:
    raise ValueError(f"Unknown diagnostic phase: {phase}")
PY
}

# Freeze the candidate pool and immutable inputs before spending GPU inference time.
run_diagnostic prepare
[[ -f "$apptainer_image" && -d "$model_path" ]] || {
    echo "ERROR: model directory or Apptainer image is missing." >&2; exit 1;
}
[[ "$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)" -eq 2 ]] || {
    echo "ERROR: expected exactly two visible GPUs." >&2; exit 1;
}
[[ -z "$(ss -H -ltn "sport = :$port")" ]] || {
    echo "ERROR: diagnostic vLLM port is already occupied: $port" >&2; exit 1;
}
export LD_LIBRARY_PATH="$VIRTUAL_ENV/lib/python3.11/site-packages/nvidia/cu13/lib:${LD_LIBRARY_PATH:-}"
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 VLLM_USE_FLASHINFER_SAMPLER=0
export HYPERAGENTS_MODEL="openai/qwen3.8-27b"
export HYPERAGENTS_TASK_MODEL="$HYPERAGENTS_MODEL" HYPERAGENTS_META_MODEL="$HYPERAGENTS_MODEL"
export HYPERAGENTS_API_BASE="http://127.0.0.1:$port/v1" HYPERAGENTS_API_KEY=EMPTY
export HYPERAGENTS_MAX_TOKENS=16384 HYPERAGENTS_THINKING_MODE=on
export HYPERAGENTS_REQUEST_TIMEOUT=3600 LITELLM_LOCAL_MODEL_COST_MAP=True

vllm_pid=""
cleanup_vllm() {
    if [[ -n "$vllm_pid" ]] && kill -0 "$vllm_pid" 2>/dev/null; then
        kill "$vllm_pid"
        wait "$vllm_pid" || true
    fi
}
trap cleanup_vllm EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$VIRTUAL_ENV/bin/vllm" serve "$model_path" \
    --host 127.0.0.1 --port "$port" --served-model-name qwen3.8-27b \
    --tensor-parallel-size 2 --dtype bfloat16 --max-model-len 262144 \
    --gpu-memory-utilization 0.9 --max-num-seqs 8 --seed 0 --enforce-eager \
    --language-model-only --reasoning-parser qwen3 --enable-auto-tool-choice \
    --tool-call-parser qwen3_coder --gdn-prefill-backend triton \
    >"$diagnostic_dir/vllm.log" 2>&1 &
vllm_pid="$!"
ready=0
for attempt in $(seq 1 180); do
    kill -0 "$vllm_pid" 2>/dev/null || {
        tail -n 80 "$diagnostic_dir/vllm.log" >&2; exit 1;
    }
    response="$(curl --silent --fail --max-time 5 "$HYPERAGENTS_API_BASE/models" || true)"
    if [[ "$response" == *'"qwen3.8-27b"'* && "$response" == *262144* ]]; then
        ready=1
        break
    fi
    sleep 10
done
[[ "$ready" -eq 1 ]] || { echo "ERROR: vLLM did not become ready." >&2; exit 1; }
run_diagnostic evaluate
echo "VALIDATION_DIAGNOSTIC_COMPLETED: $diagnostic_dir/summary.csv"
