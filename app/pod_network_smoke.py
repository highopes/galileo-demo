"""Run sanitized outbound checks from the deployed application Pod."""

from __future__ import annotations

import json
import os
import socket
import ssl
import urllib.error
import urllib.request
from urllib.parse import urlparse

from pinecone import Pinecone


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value or value == "ReplaceMe":
        raise RuntimeError(f"{name} is missing")
    return value


def dns_check(label: str, url: str) -> None:
    host = urlparse(url).hostname
    if not host:
        raise RuntimeError(f"{label} URL has no hostname")
    socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
    print(f"{label} DNS: PASS")


def https_get(label: str, url: str, headers: dict[str, str] | None = None) -> bytes:
    request = urllib.request.Request(url, headers=headers or {}, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=30, context=ssl.create_default_context()) as response:
            print(f"{label} HTTPS: PASS ({response.status})")
            return response.read()
    except urllib.error.HTTPError as exc:
        if label == "Splunk AO console" and exc.code in {401, 403}:
            print(f"{label} HTTPS: PASS ({exc.code}, reachable and access-controlled)")
            return b""
        raise


def main() -> int:
    model_base = required("APP_MODEL_BASE_URL").rstrip("/")
    console_url = required("SPLUNK_AO_CONSOLE_URL")
    dns_check("Application model", model_base)
    dns_check("Splunk AO console", console_url)
    dns_check("Pinecone control plane", "https://api.pinecone.io")

    payload = https_get(
        "Application model",
        f"{model_base}/models",
        {"Authorization": f"Bearer {required('APP_MODEL_API_KEY')}"},
    )
    models = json.loads(payload).get("data", [])
    configured_model = required("APP_MODEL_NAME")
    if not any(item.get("id") == configured_model for item in models if isinstance(item, dict)):
        raise RuntimeError("Configured application model is not advertised by the endpoint")
    print("Application model identity: PASS")

    result = Pinecone(api_key=required("PINECONE_API_KEY")).Index(required("PINECONE_INDEX_NAME")).search(
        namespace=required("PINECONE_NAMESPACE"),
        query={"inputs": {"text": "Orbit Credit Card cashback"}, "top_k": 1},
        fields=[required("PINECONE_TEXT_FIELD")],
    )
    payload = result.to_dict() if hasattr(result, "to_dict") else result
    if not payload.get("result", {}).get("hits"):
        raise RuntimeError("Pinecone search returned no hits")
    print("Pinecone integrated text search: PASS")

    https_get("Splunk AO console", console_url)
    print("ACK outbound network validation: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
