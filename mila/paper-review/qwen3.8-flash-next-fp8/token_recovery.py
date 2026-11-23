"""Host-side recovery for the pinned Mila token searches."""
from functools import partial
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import sys
from contextlib import contextmanager, redirect_stdout


class CheckpointError(BaseException):
    """Stop this job if a durable checkpoint cannot be trusted or written."""


@contextmanager
def checkpoint_io():
    try:
        yield
    except Exception as error:
        raise CheckpointError(str(error)) from error


def atomic_json(path, value):
    temporary = path.with_suffix(".pending")
    temporary.write_text(json.dumps(value))
    temporary.replace(path)


def repair_jsonl(path):
    """Only an interrupted final append can be discarded."""
    if not path.exists():
        return []
    data = path.read_bytes()
    lines = data.splitlines(keepends=True)
    rows = []
    for index, line in enumerate(lines):
        try:
            rows.append(json.loads(line))
        except (ValueError, UnicodeError):
            if index != len(lines) - 1 or line.endswith(b"\n"):
                raise
            lines.pop()
            break
    if data and not data.endswith(b"\n"):
        tmp = path.with_suffix(".repair")
        tmp.write_bytes(b"".join(x.rstrip(b"\n") + b"\n" for x in lines))
        tmp.replace(path)
    return rows


def update_metadata(output_dir, genid, changes):
    path = Path(output_dir) / f"gen_{genid}" / "metadata.json"
    if path.exists():
        metadata = json.loads(path.read_text())
        atomic_json(path, dict(metadata, **changes))


def repair_usage_tail(path):
    """Complete or discard only a torn final call; never rescan a multi-GB log."""
    if not path.is_file() or path.is_symlink():
        return
    with path.open("rb+") as handle:
        end = handle.seek(0, os.SEEK_END)
        if not end:
            return
        handle.seek(end - 1)
        if handle.read(1) == b"\n":
            return
        start = end
        while start > 0:
            block = max(0, start - 8192)
            handle.seek(block)
            offset = handle.read(start - block).rfind(b"\n")
            if offset >= 0:
                start = block + offset + 1
                break
            start = block
        handle.seek(start)
        try:
            json.loads(handle.read())
        except (ValueError, UnicodeError):
            handle.truncate(start)
        else:
            handle.write(b"\n")


@contextmanager
def atomic_writer(path, mode, *args, **kwargs):
    path = Path(path)
    temporary = path.with_name(path.name + ".pending")
    with temporary.open(mode, *args, **kwargs) as handle:
        yield handle
    temporary.replace(path)


def install_gvf_writes():
    # The pinned writers validate and merge the old records. Keep those rules;
    # change only publication so a killed merge leaves the previous row readable.
    from gvf import archive_io, qa_runner
    from gvf.constants import QA_RECORD_FILE_NAME

    def open_record(path, mode="r", *args, **kwargs):
        if mode == "w" and Path(path).name in (QA_RECORD_FILE_NAME, "qa_answers.json"):
            return atomic_writer(path, mode, *args, **kwargs)
        return open(path, mode, *args, **kwargs)

    archive_io.open = qa_runner.open = open_record


def install_map_writes():
    from utils import docker_utils

    install_gvf_writes()
    native_copy = docker_utils.copy_from_container

    def copy_artifact(container, source_path, dest_path, verbose=True):
        if str(source_path) == "/tmp/question_output.json" and Path(dest_path).name in ("propose.json", "select.json"):
            target = Path(dest_path)
            temporary = target.with_suffix(".pending")
            native_copy(container, source_path, temporary, verbose=verbose)
            temporary.replace(target)
        else:
            return native_copy(container, source_path, dest_path, verbose=verbose)

    docker_utils.copy_from_container = copy_artifact


def repair_map(run):
    from gvf.backfill import reset_to_commit

    # The MAP coordinator journals each operation and holds its original root
    # commit. An interrupted mutation can leave the disposable checkout dirty.
    for marker in (run / "islands").glob("*/bootstrap/ready.json"):
        ready = json.loads(marker.read_text())
        root = marker.parent / "gen_initial" / "hyperagents"
        if (Path(ready["root"]).resolve() != root.resolve() or not root.resolve().is_relative_to(run)
                or (root / ".git").is_symlink() or not (root / ".git").is_dir()
                or not re.fullmatch("[0-9a-f]{40}", ready["commit"])):
            raise ValueError(f"Invalid MAP bootstrap checkpoint: {marker}")
        # The parent allocation is terminal and this run holds the exclusive lock.
        # A killed git operation can leave its private checkout locked.
        (root / ".git" / "index.lock").unlink(missing_ok=True)
        reset_to_commit(str(root), ready["commit"])
    for log in run.rglob("token_log*.jsonl"):
        if log.resolve().is_relative_to(run):
            repair_usage_tail(log)


def repair_generation(run):
    from generate_loop import record_completed_evaluation
    from measurement.search_time import SearchClock

    private = Path(str(run) + "_private")
    archive = repair_jsonl(run / "archive.jsonl")
    evaluations = repair_jsonl(private / "evaluation_records.jsonl")
    repair_jsonl(private / "selection_records.jsonl")
    intent = private / "token_archive_intent.json"
    if intent.is_file():
        row = json.loads(intent.read_text())
        if not archive or archive[-1] != row:
            previous = archive[-1]["archive"] if archive else []
            if row["archive"] != previous + [row["current_genid"]]:
                raise ValueError("Archive does not match its pending generation")
            with (run / "archive.jsonl").open("a") as out:
                out.write(json.dumps(row) + "\n")
            archive.append(row)
    if not archive:
        if evaluations:
            raise ValueError("Evaluation history exists without its generation archive")
        return "bootstrap"
    latest = archive[-1]["current_genid"]
    next_gen = 1 if latest == "initial" else latest + 1
    journal = private / "token_progress" / f"gen_{next_gen}"
    measurement = run / f"gen_{next_gen}" / "measurement"
    for log in measurement.glob("token_log*.jsonl"):
        repair_usage_tail(log)
    if journal.is_dir():
        repair_usage_tail(journal / "usage.jsonl")
        # The native engine checks the budget before resuming an in-flight
        # child. Restore its unpublished charges when that same child re-enters;
        # selector costs and previously archived evaluations remain visible.
        for name in ("token_log.jsonl", "token_log_qa.jsonl"):
            log = measurement / name
            if log.exists():
                log.replace(journal / name)
    if latest == "initial":
        evaluated = True
    else:
        metadata = json.loads((run / f"gen_{latest}" / "metadata.json").read_text())
        if not metadata["parent_agent_success"]:
            update_metadata(run, metadata["parent_genid"], {"valid_parent": False})
        evaluated = metadata["run_eval"]
    if evaluated and not any(row["version_id"] == latest for row in evaluations):
        # No later search takes place between archive append and the corresponding
        # native evaluation record. Use the engine's own score and cost definition.
        record_completed_evaluation(str(run), ["paper_review"], latest, SearchClock(str(private)))
    return "resume"


def run_baseline(arguments):
    from domains import eval_sampling
    from measurement import TOKEN_LOG_DIR_NAME, TOKEN_LOG_FILE_NAME
    import pandas as pd

    # The pinned harness resumes finished rows from predictions.csv. Publish its
    # per-row writes atomically so a killed write cannot become a prediction.
    target = (Path(arguments[arguments.index("--output_dir") + 1])
              / arguments[arguments.index("--run_id") + 1] / "predictions.csv")
    repair_usage_tail(target.parent / TOKEN_LOG_DIR_NAME / TOKEN_LOG_FILE_NAME)
    native_csv = pd.DataFrame.to_csv

    def save_csv(frame, path=None, *args, **kwargs):
        if not isinstance(path, (str, Path)) or Path(path) != target:
            return native_csv(frame, path, *args, **kwargs)
        temp = target.with_suffix(".pending")
        native_csv(frame, temp, *args, **kwargs)
        temp.replace(target)

    def save_manifest(directory, manifest):
        path = Path(eval_sampling.manifest_path(directory))
        path.parent.mkdir(parents=True, exist_ok=True)
        atomic_json(path, manifest)
        return str(path)

    pd.DataFrame.to_csv = save_csv
    eval_sampling.write_eval_manifest = save_manifest
    sys.argv = ["domains.harness", *arguments]
    runpy.run_module("domains.harness", run_name="__main__")


def copy_tree(source, destination, previous=None, exclude_usage=False):
    # Published snapshots never share writable inodes with a live container.
    # Unchanged files can share inodes between two host-private snapshots.
    destination.mkdir(parents=True, exist_ok=True)
    command = ["rsync", "-a", "--checksum", "--delete"]
    if previous is not None:
        command.extend(["--link-dest", str(previous)])
    if exclude_usage:
        command.extend(["--exclude", "/hyperagents-measurement/"])
    subprocess.run([*command, str(source) + "/", str(destination) + "/"], check=True)


def install_token_backend(run):
    from utils import apptainer_utils, gl_utils
    from measurement import DEFAULT_TOKEN_LOG_PATH
    from utils.constants import REPO_NAME

    if (Path.cwd() / "gvf" / "archive_io.py").is_file():
        install_gvf_writes()
    base = apptainer_utils.ApptainerContainer
    seed = run / "gen_initial" / REPO_NAME
    progress = Path(str(run) + "_private") / "token_progress"

    class TokenContainer(base):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.journal = None
            self.scratch_repo = None
            if self.repo_path != seed:
                return
            # Applying parent patches in the pinned adapter normally edits the
            # bootstrap checkout in place. A killed container cannot clean it.
            scratch = self.runtime_dir.parent / (self.runtime_dir.name + "-repo")
            copy_tree(seed, scratch)
            self.repo_path = self.scratch_repo = scratch
            if not re.fullmatch(r"gen_[0-9]+", self.runtime_dir.name):
                return
            self.journal = progress / self.runtime_dir.name
            self.journal.mkdir(parents=True, exist_ok=True)
            for name in ("token_log.jsonl", "token_log_qa.jsonl"):
                saved = self.journal / name
                if saved.exists():
                    directory = run / self.runtime_dir.name / "measurement"
                    directory.mkdir(parents=True, exist_ok=True)
                    saved.replace(directory / name)
            self.step = 0
            # Keep even the usage of a killed attempt. The native finalizer copies
            # this same cumulative ledger into the generation's measured total.
            self.runtime_dir = self.journal / "live"
            if self.runtime_dir.exists():
                shutil.rmtree(self.runtime_dir)
            self.runtime_dir.mkdir()
            self.home_dir = self.runtime_dir / "home"
            self.home_dir.mkdir()
            ledger = self.journal / "usage.jsonl"
            ledger.touch(exist_ok=True)
            visible = self.runtime_dir / Path(DEFAULT_TOKEN_LOG_PATH).relative_to("/tmp")
            visible.parent.mkdir()
            os.link(ledger, visible)

        def remove(self, force=True):
            super().remove(force=force)
            if self.scratch_repo is not None and self.scratch_repo.exists():
                shutil.rmtree(self.scratch_repo)

        def exec_run(self, cmd, workdir=f"/{REPO_NAME}"):
            if (self.journal is None or not isinstance(cmd, (list, tuple))
                    or list(cmd[:1]) != ["timeout"] or len(cmd) < 4
                    or cmd[2] != "python" or not (
                        "--base_commit" in cmd and "--outdir" in cmd
                        or list(cmd[3:5]) == ["-m", "domains.harness"]
                    )):
                return super().exec_run(cmd, workdir)
            with checkpoint_io():
                self.step += 1
                stage = self.journal / f"step-{self.step}"
                identity = list(cmd)
                if "--base_commit" in identity:
                    # Reconstructing identical parent patches can give Git a new
                    # commit timestamp. Compare the actual tree for this invocation.
                    index = identity.index("--base_commit") + 1
                    identity[index] = subprocess.check_output(
                        ["git", "-C", str(self.repo_path), "rev-parse", identity[index] + "^{tree}"],
                        text=True).strip()
                if "--dataset_path" in identity:
                    dataset = self._host_path(identity[identity.index("--dataset_path") + 1])
                    identity.append(hashlib.sha256(dataset.read_bytes()).hexdigest())
                if stage.exists():
                    if json.loads((stage / "command.json").read_text()) != identity:
                        raise RuntimeError(f"Saved token stage has different inputs: {stage}")
                    copy_tree(stage / "repo", self.repo_path)
                    copy_tree(stage / "runtime", self.runtime_dir, exclude_usage=True)
                    return apptainer_utils.ApptainerExecResult(0, (stage / "stdout").read_bytes())

            result = super().exec_run(cmd, workdir)
            if result.exit_code == 0:
                with checkpoint_io():
                    pending = self.journal / "publishing"
                    if pending.exists():
                        shutil.rmtree(pending)
                    pending.mkdir()
                    previous = self.journal / f"step-{self.step - 1}"
                    for name, live in (("repo", self.repo_path), ("runtime", self.runtime_dir)):
                        prior = previous / name
                        copy_tree(live, pending / name, prior if prior.exists() else None,
                                  exclude_usage=name == "runtime")
                    (pending / "command.json").write_text(json.dumps(identity))
                    (pending / "stdout").write_bytes(result.output)
                    pending.rename(stage)
            return result

    # Only this dedicated process runs the adapter. Smoke, MAP, and other
    # launchers import their original pinned Apptainer implementation.
    native_archive = gl_utils.update_and_save_archive

    def publish_generation(output_dir, archive, new_node):
        # Write the intent first. Even a torn final JSONL append can now be
        # completed without launching this mutation or scoring it twice.
        row = {"current_genid": new_node, "archive": [*archive, new_node]}
        atomic_json(Path(str(run) + "_private") / "token_archive_intent.json", row)
        return native_archive(output_dir, archive, new_node)

    gl_utils.update_and_save_archive = publish_generation
    apptainer_utils.ApptainerContainer = TokenContainer
    gl_utils.update_node_metadata = update_metadata


if __name__ == "__main__":
    action, run_arg, *arguments = sys.argv[1:]
    run = Path(run_arg).resolve()
    sys.path.insert(0, str(Path.cwd()))
    if action == "repair":
        # Native score recording may log to stdout. Reserve stdout for the phase.
        with redirect_stdout(sys.stderr):
            phase = repair_generation(run)
        print(phase)
    elif action == "map-search":
        import generate_map_loop
        # Spawn workers import this initializer by module name. The coordinator
        # also merges QA records when migrating versions between islands.
        from token_recovery import install_map_writes as initialize_worker
        install_gvf_writes()
        generate_map_loop.ProcessPoolExecutor = partial(
            generate_map_loop.ProcessPoolExecutor, initializer=initialize_worker)
        generate_map_loop.run_search(generate_map_loop.parse_args(arguments))
    elif action == "repair-map":
        repair_map(run)
    elif action == "release":
        progress = Path(str(run) + "_private") / "token_progress"
        if progress.exists():
            shutil.rmtree(progress)
    elif action == "baseline":
        run_baseline(arguments)
    elif action == "search":
        install_token_backend(run)
        sys.argv = ["generate_loop.py", *arguments]
        runpy.run_module("generate_loop", run_name="__main__")
    else:
        raise ValueError(f"Unknown action: {action}")
