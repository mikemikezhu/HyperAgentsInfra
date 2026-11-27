"""Mila token-run status (26376e4), using the local experiment's stopping protocol."""

import argparse
import json
import sys
from pathlib import Path

from measurement.held_out import checkpoint_tests_complete, materialize_checkpoint_tests
from measurement.early_stopping import read_final_checkpoint, search_status


def check_formal_test_config(checkpoint):
    config = checkpoint["test_config"]
    if config["num_samples"] != 50 or config["repeats"] != 3:
        raise ValueError(f"Checkpoint {checkpoint['budget']} requires 50 held-out samples and three repeats")


def finished_status(testing, unavailable):
    if testing:
        return "testing"
    if unavailable:
        print(f"No eligible recommendation at token checkpoints {sorted(unavailable)}", file=sys.stderr)
    return "complete"


def map_status(private, budgets):
    with (private / "state.json").open() as handle:
        state = json.load(handle)
    if state["status"] == "searching":
        return "searching"
    if state["status"] != "finished":
        raise ValueError(f"Unexpected MAP search status {state['status']!r}")
    checkpoints = list(state["checkpoints"].values())
    token_budgets = {cp["budget"] for cp in checkpoints if cp["kind"] == "tokens"}
    if set(budgets) != token_budgets:
        raise ValueError(f"Finished MAP search has unexpected token checkpoints: {sorted(token_budgets)}")

    testing = False
    unavailable = []
    for cp in checkpoints:
        status = cp["test_status"]
        if status == "no_candidate":
            if cp["kind"] == "tokens":
                unavailable.append(cp["budget"])
        elif status == "pending":
            testing = True
        elif status == "complete":
            check_formal_test_config(cp["test"])
            if not checkpoint_tests_complete(private, cp["test"]):
                raise ValueError(f"Invalid completed MAP checkpoint: {cp['kind']} {cp['budget']}")
        else:
            raise ValueError(f"Unexpected checkpoint test status: {status!r}")
    return finished_status(testing, unavailable)


def single_island_status(run, private, budgets, hour_budgets, generations, domain, stopping):
    from measurement.token_accounting import (
        cumulative_total, read_evaluation_records, scan_generation_token_totals,
    )

    total = cumulative_total(scan_generation_token_totals(run))
    status = search_status(run, stop_token_budget=budgets[-1], **stopping)
    finished = status["stop_reason"] is not None
    with (private / "search_time.json").open() as handle:
        seconds = json.load(handle)["search_seconds"]
    records = read_evaluation_records(private)
    thresholds = [
        ("T", budget, "evaluation_cost_tokens", budget)
        for budget in budgets if budget <= total
    ] + [
        ("H", hour, "evaluation_search_seconds", hour * 3600)
        for hour in hour_budgets if hour * 3600 <= seconds
    ] + [
        ("G", generation, "evaluation_generation", generation)
        for generation in generations if generation <= status["completed_generation"]
    ]
    testing = False
    unavailable = []
    for prefix, budget, field, limit in thresholds:
        if not any(record.get(field, float("inf")) <= limit for record in records):
            message = f"No eligible recommendation at {prefix}{budget}"
            if prefix == "T":
                unavailable.append(budget)
            print(message, file=sys.stderr)
            continue
        path = private / "checkpoints" / f"checkpoint_{prefix}{budget}.json"
        with path.open() as handle:
            checkpoint = json.load(handle)
        if checkpoint["budget"] != budget:
            raise ValueError(f"Incorrect frozen budget in {path}")
        check_formal_test_config(checkpoint)
        if not checkpoint_tests_complete(private, checkpoint, [domain]):
            if not materialize_checkpoint_tests(private, checkpoint):
                testing = True
            elif not checkpoint_tests_complete(private, checkpoint, [domain]):
                testing = True
    if finished and stopping["early_stop"]:
        final = read_final_checkpoint(run)
        if final is None:
            raise ValueError("Stopped search lacks its frozen final measurement")
        check_formal_test_config(final)
        if not checkpoint_tests_complete(private, final, [domain]):
            materialize_checkpoint_tests(private, final)
            testing |= not checkpoint_tests_complete(private, final, [domain])
    if not finished:
        return "searching"
    return finished_status(testing, unavailable)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    parser.add_argument("profile")
    parser.add_argument("--tokens", nargs="+", type=int, required=True)
    parser.add_argument("--hours", nargs="+", type=int, required=True)
    parser.add_argument("--generations", nargs="+", type=int, required=True)
    parser.add_argument("--domain", required=True)
    parser.add_argument("--early_stop", choices=("true", "false"), required=True)
    parser.add_argument("--early_stop_min_generations", type=int, required=True)
    parser.add_argument("--early_stop_patience", type=int, required=True)
    parser.add_argument("--generation_limit", type=int)
    args = parser.parse_args()
    private_dir = Path(str(args.run) + "_private")
    if args.profile == "gvf_map":
        print(map_status(private_dir, args.tokens))
    else:
        stopping = dict(early_stop=args.early_stop == "true",
                        early_stop_min_generations=args.early_stop_min_generations,
                        early_stop_patience=args.early_stop_patience,
                        generation_limit=args.generation_limit)
        print(single_island_status(args.run, private_dir, args.tokens, args.hours,
                                   args.generations, args.domain, stopping))
