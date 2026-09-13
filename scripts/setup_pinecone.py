#!/usr/bin/env python3
"""Safely inventory and resolve Pinecone storage for the banking demo.

The existing ``credit-card-information`` index is always read-only. Writes are
permitted only to the isolated demo index and its configured namespace.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import sys
import time
from pathlib import Path
from typing import Any, Iterable

from pinecone import Pinecone


class PineconeStop(RuntimeError):
    """A condition that requires stopping instead of making a risky change."""


def load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise PineconeStop(f"Invalid dotenv entry in {path}:{number}")
        key, raw_value = line.split("=", 1)
        parsed = shlex.split(raw_value, comments=True, posix=True)
        os.environ.setdefault(key.strip(), parsed[0] if parsed else "")


def require_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value or value == "ReplaceMe" or "在这里" in value or value == "<SECRET>":
        raise PineconeStop(f"Required setting {name} is missing or still a placeholder")
    return value


def as_dict(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    for method_name in ("to_dict", "model_dump"):
        method = getattr(value, method_name, None)
        if callable(method):
            converted = method()
            if isinstance(converted, dict):
                return converted
    try:
        return dict(value)
    except (TypeError, ValueError):
        return {}


def list_names(pc: Pinecone) -> list[str]:
    indexes = pc.list_indexes()
    names_method = getattr(indexes, "names", None)
    if callable(names_method):
        return list(names_method())
    payload = as_dict(indexes)
    return [item["name"] for item in payload.get("indexes", []) if isinstance(item, dict) and item.get("name")]


def describe(pc: Pinecone, name: str) -> dict[str, Any]:
    return as_dict(pc.describe_index(name))


def describe_stats(pc: Pinecone, name: str) -> dict[str, Any]:
    return as_dict(pc.Index(name).describe_index_stats())


def embed_metadata(description: dict[str, Any]) -> tuple[str | None, str | None]:
    embed = description.get("embed")
    if not isinstance(embed, dict):
        return None, None
    field_map = embed.get("field_map") if isinstance(embed.get("field_map"), dict) else {}
    return embed.get("model"), field_map.get("text")


def namespaces(stats: dict[str, Any]) -> list[str]:
    raw = stats.get("namespaces", {})
    if not isinstance(raw, dict):
        return []
    return list(raw)


def search_text(
    pc: Pinecone,
    index_name: str,
    namespace: str,
    text_field: str,
    query: str,
    top_k: int = 3,
) -> list[dict[str, Any]]:
    response = pc.Index(index_name).search(
        namespace=namespace,
        query={"inputs": {"text": query}, "top_k": top_k},
        fields=[text_field, "source", "title"],
    )
    payload = as_dict(response)
    result = payload.get("result", {})
    hits = result.get("hits", []) if isinstance(result, dict) else []
    return [hit for hit in hits if isinstance(hit, dict)]


def relevant(hits: list[dict[str, Any]], text_field: str) -> bool:
    text = " ".join(str(hit.get("fields", {}).get(text_field, "")) for hit in hits).lower()
    return "orbit" in text and ("cashback" in text or "cash back" in text)


def existing_reuse_candidate(
    pc: Pinecone,
    name: str,
    description: dict[str, Any],
    stats: dict[str, Any],
) -> tuple[str, str] | None:
    _, text_field = embed_metadata(description)
    if not text_field:
        return None
    candidates = namespaces(stats) or [""]
    query = "What are the cashback rewards offered by the Orbit Credit Card?"
    for namespace in candidates:
        try:
            hits = search_text(pc, name, namespace, text_field, query)
        except Exception as exc:
            print(f"Existing index text-query check failed in namespace {namespace!r}: {type(exc).__name__}")
            continue
        if relevant(hits, text_field):
            return namespace, text_field
    return None


def chunk_text(text: str, chunk_size: int = 1000, overlap: int = 200) -> list[str]:
    normalized = "\n\n".join(part.strip() for part in text.split("\n\n") if part.strip())
    chunks: list[str] = []
    start = 0
    while start < len(normalized):
        end = min(len(normalized), start + chunk_size)
        if end < len(normalized):
            split_at = max(normalized.rfind("\n", start, end), normalized.rfind(". ", start, end))
            if split_at > start + chunk_size // 2:
                end = split_at + 1
        chunks.append(normalized[start:end].strip())
        if end >= len(normalized):
            break
        start = max(start + 1, end - overlap)
    return [chunk for chunk in chunks if chunk]


def source_records(source_dir: Path, text_field: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for path in sorted(source_dir.glob("*.md")):
        for number, chunk in enumerate(chunk_text(path.read_text(encoding="utf-8"))):
            digest = hashlib.sha256(f"{path.name}:{number}:{chunk}".encode()).hexdigest()[:32]
            records.append(
                {
                    "_id": f"{path.stem}-{number}-{digest[:12]}",
                    text_field: chunk,
                    "source": path.name,
                    "title": path.stem.replace("-", " ").title(),
                    "content_sha256": digest,
                }
            )
    if not records:
        raise PineconeStop(f"No Markdown source documents found in {source_dir}")
    return records


def batches(records: list[dict[str, Any]], size: int = 50) -> Iterable[list[dict[str, Any]]]:
    for start in range(0, len(records), size):
        yield records[start : start + size]


def wait_ready(pc: Pinecone, name: str, deadline_seconds: int = 180) -> dict[str, Any]:
    deadline = time.monotonic() + deadline_seconds
    while time.monotonic() < deadline:
        description = describe(pc, name)
        status = description.get("status", {})
        if isinstance(status, dict) and status.get("ready") is True:
            return description
        time.sleep(5)
    raise PineconeStop(f"Timed out waiting for Pinecone index {name!r} to become ready")


def write_resolved(path: Path, index_name: str, namespace: str, text_field: str, reason: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f'PINECONE_INDEX_NAME="{index_name}"\n'
        f'PINECONE_NAMESPACE="{namespace}"\n'
        f'PINECONE_TEXT_FIELD="{text_field}"\n'
        f'PINECONE_RESOLUTION_REASON="{reason}"\n',
        encoding="utf-8",
    )
    path.chmod(0o600)


def inventory(pc: Pinecone, existing_name: str, demo_name: str, output: Path) -> dict[str, Any]:
    names = list_names(pc)
    report: dict[str, Any] = {"index_names": names, "indexes": {}}
    for name in (existing_name, demo_name):
        if name not in names:
            report["indexes"][name] = {"exists": False}
            continue
        description = describe(pc, name)
        stats = describe_stats(pc, name)
        model, text_field = embed_metadata(description)
        report["indexes"][name] = {
            "exists": True,
            "dimension": description.get("dimension"),
            "metric": description.get("metric"),
            "integrated_embedding_model": model,
            "text_field": text_field,
            "namespaces": namespaces(stats),
            "total_vector_count": stats.get("total_vector_count", 0),
            "status": description.get("status"),
        }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
    output.chmod(0o600)
    return report


def resolve(pc: Pinecone, root: Path, report: dict[str, Any]) -> tuple[str, str, str, str]:
    existing_name = require_env("PINECONE_EXISTING_INDEX")
    demo_name = require_env("PINECONE_DEMO_INDEX")
    desired_namespace = os.getenv("PINECONE_NAMESPACE", "bank-docs").strip() or "bank-docs"
    desired_model = os.getenv("PINECONE_EMBED_MODEL", "llama-text-embed-v2").strip()
    desired_field = os.getenv("PINECONE_TEXT_FIELD", "chunk_text").strip() or "chunk_text"
    names = report["index_names"]

    if existing_name in names:
        existing_description = describe(pc, existing_name)
        existing_stats = describe_stats(pc, existing_name)
        candidate = existing_reuse_candidate(pc, existing_name, existing_description, existing_stats)
        if candidate:
            namespace, text_field = candidate
            return existing_name, namespace, text_field, "existing integrated index passed read-only text retrieval"
        print(f"Preserving existing index {existing_name!r} as read-only; it is not a verified reusable text index.")

    if demo_name not in names:
        try:
            pc.create_index_for_model(
                name=demo_name,
                cloud=os.getenv("PINECONE_CLOUD", "aws"),
                region=os.getenv("PINECONE_REGION", "us-east-1"),
                embed={
                    "model": desired_model,
                    "field_map": {"text": desired_field},
                    "metric": "cosine",
                },
            )
        except Exception as exc:
            raise PineconeStop(
                f"Integrated embedding index creation failed; no OpenAI embedding fallback is allowed: "
                f"{type(exc).__name__}: {str(exc)[:500]}"
            ) from exc

    demo_description = wait_ready(pc, demo_name)
    actual_model, actual_field = embed_metadata(demo_description)
    if actual_model != desired_model or actual_field != desired_field:
        raise PineconeStop(
            f"Existing isolated index {demo_name!r} is incompatible: "
            f"model={actual_model!r}, text_field={actual_field!r}; expected {desired_model!r}/{desired_field!r}. "
            "It was not deleted or modified."
        )

    records = source_records(root / "app" / "source-docs" / "credit-cards", desired_field)
    index = pc.Index(demo_name)
    for batch in batches(records):
        index.upsert_records(desired_namespace, batch)
    print(f"Upserted {len(records)} stable records into isolated index {demo_name!r}/{desired_namespace!r}.")

    query = "What are the cashback rewards offered by the Orbit Credit Card?"
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        hits = search_text(pc, demo_name, desired_namespace, desired_field, query)
        if relevant(hits, desired_field):
            return demo_name, desired_namespace, desired_field, "isolated integrated-embedding index verified"
        time.sleep(5)
    raise PineconeStop("Isolated index did not return the expected Orbit document within 180 seconds")


def parse_args() -> argparse.Namespace:
    root_default = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("inventory", "resolve", "smoke"))
    parser.add_argument("--root", type=Path, default=root_default)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.root.resolve()
    try:
        load_env_file(root / ".deploy.env")
        load_env_file(root / ".secrets" / "runtime.env")
        pc = Pinecone(api_key=require_env("PINECONE_API_KEY"))
        existing_name = require_env("PINECONE_EXISTING_INDEX")
        demo_name = require_env("PINECONE_DEMO_INDEX")
        inventory_path = root / ".runtime" / "pinecone-inventory.json"
        report = inventory(pc, existing_name, demo_name, inventory_path)
        print(f"Pinecone inventory written to {inventory_path}")
        for name in (existing_name, demo_name):
            item = report["indexes"][name]
            print(
                f"{name}: exists={item.get('exists')}, dimension={item.get('dimension')}, "
                f"metric={item.get('metric')}, integrated_model={item.get('integrated_embedding_model')}, "
                f"namespaces={item.get('namespaces')}, vectors={item.get('total_vector_count')}"
            )
        if args.mode == "inventory":
            return 0
        if args.mode == "smoke":
            load_env_file(root / ".runtime" / "resolved-pinecone.env")
            index_name = require_env("PINECONE_INDEX_NAME")
            namespace = os.getenv("PINECONE_NAMESPACE", "bank-docs")
            text_field = os.getenv("PINECONE_TEXT_FIELD", "chunk_text")
            hits = search_text(
                pc,
                index_name,
                namespace,
                text_field,
                "What are the cashback rewards offered by the Orbit Credit Card?",
            )
            if not relevant(hits, text_field):
                raise PineconeStop("Retrieval smoke test did not find the expected Orbit cashback content")
            print(f"Pinecone retrieval smoke: PASS ({len(hits)} hits)")
            return 0

        index_name, namespace, text_field, reason = resolve(pc, root, report)
        resolved_path = root / ".runtime" / "resolved-pinecone.env"
        write_resolved(resolved_path, index_name, namespace, text_field, reason)
        print(f"Resolved Pinecone index: {index_name}")
        print(f"Resolved Pinecone namespace: {namespace or '<default>'}")
        print(f"Reason: {reason}")
        return 0
    except PineconeStop as exc:
        print(f"PINECONE STOP: {exc}", file=sys.stderr)
        return 2
    except Exception as exc:
        print(f"PINECONE STOP: {type(exc).__name__}: {str(exc)[:800]}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
