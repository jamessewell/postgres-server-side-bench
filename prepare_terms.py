#!/usr/bin/env python3
"""Convert the benchmarker's JSON termset to COPY-ready rows."""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path
from typing import Any


STYLES = ("conjunction", "disjunction", "phrase")


def parse_query_ids(value: str) -> list[int] | None:
    if not value:
        return None
    parts = value.split(",")
    if any(not part.isdigit() or int(part) <= 0 for part in parts):
        raise ValueError("query IDs must be comma-separated positive integers")
    ids = [int(part) for part in parts]
    if len(set(ids)) != len(ids):
        raise ValueError("query IDs must be distinct")
    return ids


def shuffled(entries: list[tuple[int, str, str]], seed: int) -> None:
    """Match benchmarks/queries.js's unsigned 32-bit LCG shuffle."""
    state = seed & 0xFFFFFFFF
    for index in range(len(entries) - 1, 0, -1):
        state = (1664525 * state + 1013904223) & 0xFFFFFFFF
        other = int((state / 0x100000000) * (index + 1))
        entries[index], entries[other] = entries[other], entries[index]


def load_entries(
    contents: dict[str, Any] | list[Any],
    backend: str,
    query_style: str,
    seed: int,
    query_ids_value: str = "",
) -> list[tuple[int, str, str]]:
    if backend not in ("tin", "paradedb"):
        raise ValueError(f"unsupported backend: {backend}")
    if query_style not in (*STYLES, "mixed"):
        raise ValueError(f"unsupported query style: {query_style}")
    if seed < 0 or seed > 0xFFFFFFFF:
        raise ValueError("seed must be between 0 and 4294967295")

    query_ids = parse_query_ids(query_ids_value)
    selected_ids = set(query_ids) if query_ids is not None else None

    # Hacker News uses the benchmarker's original flat JSON string array. It
    # has no engine-specific syntax variants, so each value is a ParadeDB
    # match-any query and its one-based position is its stable source ID.
    if isinstance(contents, list):
        if not contents:
            raise ValueError("flat termset must contain at least one query")
        if query_style != "disjunction":
            raise ValueError("flat termsets only support disjunction query style")

        entries: list[tuple[int, str, str]] = []
        for source_id, query_text in enumerate(contents, start=1):
            if not isinstance(query_text, str) or not query_text.strip():
                raise ValueError(
                    "every flat termset entry must be a nonempty string"
                )
            if selected_ids is None or source_id in selected_ids:
                entries.append((source_id, "disjunction", query_text))

        if query_ids is not None:
            missing = [
                query_id for query_id in query_ids if query_id > len(contents)
            ]
            if missing:
                raise ValueError(
                    "query IDs not found in termset: " + ",".join(map(str, missing))
                )
        if not entries:
            raise ValueError("term selection is empty")

        shuffled(entries, seed)
        return entries

    if not isinstance(contents, dict):
        raise ValueError("termset must be an object or a flat string array")
    records = contents.get("queries")
    if not isinstance(records, list) or not records:
        raise ValueError("termset must contain a nonempty queries array")

    seen_ids: set[int] = set()
    entries: list[tuple[int, str, str]] = []
    styles = STYLES if query_style == "mixed" else (query_style,)

    for record in records:
        if not isinstance(record, dict):
            raise ValueError("every query record must be an object")
        source_id = record.get("source_id")
        if not isinstance(source_id, int) or source_id <= 0:
            raise ValueError("every query record needs a positive integer source_id")
        if selected_ids is not None and source_id not in selected_ids:
            continue
        seen_ids.add(source_id)

        engines = record.get("engines")
        engine = engines.get(backend) if isinstance(engines, dict) else None
        if not isinstance(engine, dict):
            raise ValueError(f"source {source_id} has no {backend} query forms")

        for style in styles:
            key = "match" if backend == "paradedb" else style
            query_text = engine.get(key)
            if not isinstance(query_text, str):
                raise ValueError(
                    f"source {source_id} has no string {backend}/{key} query"
                )
            entries.append((source_id, style, query_text))

    if query_ids is not None:
        missing = [query_id for query_id in query_ids if query_id not in seen_ids]
        if missing:
            raise ValueError(
                "query IDs not found in termset: " + ",".join(map(str, missing))
            )
    if not entries:
        raise ValueError("term selection is empty")

    shuffled(entries, seed)
    return entries


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--termset", required=True, type=Path)
    parser.add_argument("--backend", required=True, choices=("tin", "paradedb"))
    parser.add_argument(
        "--query-style", required=True, choices=(*STYLES, "mixed")
    )
    parser.add_argument("--seed", required=True, type=int)
    parser.add_argument("--query-ids", default="")
    parser.add_argument("--run-id", required=True, type=int)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.run_id <= 0:
        parser.error("--run-id must be positive")

    try:
        with args.termset.open(encoding="utf-8") as handle:
            contents = json.load(handle)
        entries = load_entries(
            contents,
            args.backend,
            args.query_style,
            args.seed,
            args.query_ids,
        )
    except (OSError, json.JSONDecodeError, ValueError) as error:
        parser.error(str(error))

    writer = csv.writer(sys.stdout, lineterminator="\n")
    for term_no, (source_id, style, query_text) in enumerate(entries, start=1):
        writer.writerow((args.run_id, term_no, source_id, style, query_text))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
