#!/usr/bin/env python3
"""Validate the final application model configured in the shared kup.conf.

The ACK runtime contract has one explicit model provider. This preflight proves
that its endpoint supports DNS/TLS, the exact model id, ordinary chat, raw
OpenAI-compatible tool calling, and the LangChain tool round-trip required by
the banking graph. It never rewrites kup.conf or prints credentials.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import socket
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class PreflightError(RuntimeError):
    """A sanitized preflight failure."""


class ConfigurationFailure(PreflightError):
    """Connectivity, auth, model, or ordinary-chat failure; never fallback."""


class ToolCapabilityFailure(PreflightError):
    """Ordinary chat worked, but required tool behavior did not."""


@dataclass(frozen=True)
class Provider:
    name: str
    model: str
    base_url: str
    api_key: str


def load_env_file(path: Path) -> None:
    """Load the assignment subset used by kup.conf."""
    if not path.exists():
        return
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise ConfigurationFailure(f"Invalid dotenv entry in {path}:{number}")
        key, raw_value = line.split("=", 1)
        key = key.strip()
        try:
            parsed = shlex.split(raw_value, comments=True, posix=True)
        except ValueError as exc:
            raise ConfigurationFailure(f"Invalid dotenv quoting in {path}:{number}") from exc
        value = parsed[0] if parsed else ""
        os.environ[key] = value


def require_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value or value == "ReplaceMe" or "在这里" in value or value == "<SECRET>":
        raise ConfigurationFailure(f"Required setting {name} is missing or still a placeholder")
    return value


def normalized_base_url(value: str) -> str:
    base_url = value.rstrip("/")
    parsed = urllib.parse.urlparse(base_url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ConfigurationFailure("Model base URL must be a valid HTTPS URL")
    return base_url


def sanitize(message: str, secrets: list[str]) -> str:
    result = message
    for secret in secrets:
        if secret:
            result = result.replace(secret, "<redacted>")
    return result[:1200]


def tls_dns_check(provider: Provider, timeout: float) -> None:
    parsed = urllib.parse.urlparse(provider.base_url)
    assert parsed.hostname
    port = parsed.port or 443
    try:
        addresses = socket.getaddrinfo(parsed.hostname, port, type=socket.SOCK_STREAM)
        if not addresses:
            raise OSError("DNS returned no addresses")
        context = ssl.create_default_context()
        with socket.create_connection((parsed.hostname, port), timeout=timeout) as sock:
            with context.wrap_socket(sock, server_hostname=parsed.hostname):
                pass
    except (OSError, ssl.SSLError) as exc:
        raise ConfigurationFailure(
            f"{provider.name} DNS/TLS/connectivity check failed: {type(exc).__name__}: {exc}"
        ) from exc


def request_json(
    provider: Provider,
    method: str,
    path: str,
    timeout: float,
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    url = f"{provider.base_url}/{path.lstrip('/')}"
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {provider.api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        try:
            detail = exc.read().decode("utf-8", errors="replace")
        except Exception:
            detail = ""
        detail = sanitize(detail, [provider.api_key])
        raise ConfigurationFailure(
            f"{provider.name} {method} {path} returned HTTP {exc.code}: {detail}"
        ) from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise ConfigurationFailure(
            f"{provider.name} {method} {path} failed: {type(exc).__name__}: {exc}"
        ) from exc
    try:
        decoded = json.loads(body)
    except json.JSONDecodeError as exc:
        raise ConfigurationFailure(
            f"{provider.name} {method} {path} returned non-JSON content"
        ) from exc
    if not isinstance(decoded, dict):
        raise ConfigurationFailure(f"{provider.name} {method} {path} returned an unexpected JSON shape")
    return decoded


def verify_models(provider: Provider, timeout: float) -> None:
    result = request_json(provider, "GET", "models", timeout)
    model_ids = {
        item.get("id")
        for item in result.get("data", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    if provider.model not in model_ids:
        available = ", ".join(sorted(model_ids)[:8]) or "none returned"
        raise ConfigurationFailure(
            f"{provider.name} model {provider.model!r} was not listed by GET /models; available: {available}"
        )


def verify_chat(provider: Provider, timeout: float) -> None:
    result = request_json(
        provider,
        "POST",
        "chat/completions",
        timeout,
        {
            "model": provider.model,
            "messages": [{"role": "user", "content": "Reply with exactly: CHAT_OK"}],
            "temperature": 0,
            "max_tokens": 32,
        },
    )
    try:
        content = result["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise ConfigurationFailure(f"{provider.name} ordinary chat response has no assistant content") from exc
    if not isinstance(content, str) or not content.strip():
        raise ConfigurationFailure(f"{provider.name} ordinary chat returned empty content")


TOOL_SCHEMA: dict[str, Any] = {
    "type": "function",
    "function": {
        "name": "get_demo_value",
        "description": "Return a deterministic demo value for a supplied name.",
        "parameters": {
            "type": "object",
            "properties": {"name": {"type": "string", "description": "Name to look up"}},
            "required": ["name"],
            "additionalProperties": False,
        },
    },
}


def extract_tool_call(provider: Provider, result: dict[str, Any]) -> tuple[dict[str, Any], str]:
    try:
        message = result["choices"][0]["message"]
        tool_call = message["tool_calls"][0]
        function = tool_call["function"]
        call_id = tool_call["id"]
        name = function["name"]
        arguments = json.loads(function["arguments"])
    except (KeyError, IndexError, TypeError, json.JSONDecodeError) as exc:
        raise ToolCapabilityFailure(
            f"{provider.name} did not return a standard, parseable tool_calls structure"
        ) from exc
    if name != "get_demo_value" or not isinstance(arguments, dict) or not arguments.get("name"):
        raise ToolCapabilityFailure(f"{provider.name} returned the wrong tool or invalid arguments")
    if not isinstance(call_id, str) or not call_id:
        raise ToolCapabilityFailure(f"{provider.name} returned a tool call without an id")
    return message, call_id


def verify_raw_tool_round_trip(provider: Provider, timeout: float) -> None:
    first = request_json(
        provider,
        "POST",
        "chat/completions",
        timeout,
        {
            "model": provider.model,
            "messages": [
                {
                    "role": "user",
                    "content": (
                        "You must call get_demo_value with name='banking-demo'. "
                        "Do not answer from memory."
                    ),
                }
            ],
            "tools": [TOOL_SCHEMA],
            "tool_choice": "auto",
            "temperature": 0,
            "max_tokens": 256,
        },
    )
    assistant_message, call_id = extract_tool_call(provider, first)
    second = request_json(
        provider,
        "POST",
        "chat/completions",
        timeout,
        {
            "model": provider.model,
            "messages": [
                {
                    "role": "user",
                    "content": (
                        "You must call get_demo_value with name='banking-demo'. "
                        "Do not answer from memory."
                    ),
                },
                assistant_message,
                {
                    "role": "tool",
                    "tool_call_id": call_id,
                    "content": json.dumps({"value": "DEMO_VALUE_OK"}),
                },
            ],
            "tools": [TOOL_SCHEMA],
            "temperature": 0,
            "max_tokens": 256,
        },
    )
    try:
        final_content = second["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise ToolCapabilityFailure(f"{provider.name} raw tool round-trip returned no final answer") from exc
    if not isinstance(final_content, str) or not final_content.strip():
        raise ToolCapabilityFailure(f"{provider.name} raw tool round-trip returned empty final content")


def verify_langchain_tool_round_trip(provider: Provider, timeout: float, max_retries: int) -> None:
    try:
        from langchain_core.messages import HumanMessage, ToolMessage
        from langchain_core.tools import tool
        from langchain_openai import ChatOpenAI
    except ImportError as exc:
        raise ConfigurationFailure(
            "LangChain preflight dependencies are missing; install langchain-openai"
        ) from exc

    @tool
    def get_demo_value(name: str) -> str:
        """Return a deterministic demo value for a supplied name."""
        return json.dumps({"name": name, "value": "DEMO_VALUE_OK"})

    try:
        model = ChatOpenAI(
            model=provider.model,
            base_url=provider.base_url,
            api_key=provider.api_key,
            timeout=timeout,
            max_retries=max_retries,
            temperature=0,
        )
        bound = model.bind_tools([get_demo_value])
        prompt = HumanMessage(
            content="You must call get_demo_value with name='banking-demo'. Do not answer from memory."
        )
        first = bound.invoke([prompt])
        if not first.tool_calls:
            raise ToolCapabilityFailure(f"{provider.name} LangChain returned no tool_calls")
        call = first.tool_calls[0]
        if call.get("name") != "get_demo_value" or not isinstance(call.get("args"), dict):
            raise ToolCapabilityFailure(f"{provider.name} LangChain returned an invalid tool call")
        tool_result = get_demo_value.invoke(call["args"])
        final = bound.invoke(
            [prompt, first, ToolMessage(content=tool_result, tool_call_id=call["id"])]
        )
        if not isinstance(final.content, str) or not final.content.strip():
            raise ToolCapabilityFailure(f"{provider.name} LangChain tool round-trip returned no final text")
    except ToolCapabilityFailure:
        raise
    except Exception as exc:
        message = sanitize(str(exc), [provider.api_key])
        raise ToolCapabilityFailure(
            f"{provider.name} LangChain tool round-trip failed: {type(exc).__name__}: {message}"
        ) from exc


def run_provider(provider: Provider, timeout: float, max_retries: int) -> None:
    print(f"[{provider.name}] DNS/TLS/connectivity: running", flush=True)
    tls_dns_check(provider, timeout)
    print(f"[{provider.name}] DNS/TLS/connectivity: PASS", flush=True)
    verify_models(provider, timeout)
    print(f"[{provider.name}] GET /models and model id: PASS", flush=True)
    verify_chat(provider, timeout)
    print(f"[{provider.name}] ordinary chat: PASS", flush=True)
    try:
        verify_raw_tool_round_trip(provider, timeout)
        print(f"[{provider.name}] raw tool round-trip: PASS", flush=True)
        verify_langchain_tool_round_trip(provider, timeout, max_retries)
        print(f"[{provider.name}] LangChain tool round-trip: PASS", flush=True)
    except ConfigurationFailure as exc:
        # HTTP errors after ordinary chat commonly indicate unsupported tool parameters.
        raise ToolCapabilityFailure(str(exc)) from exc


def provider_from_env() -> Provider:
    name = require_env("GALILEO_APP_MODEL_PROVIDER")
    if name not in {"vllm", "bailian"}:
        raise ConfigurationFailure("GALILEO_APP_MODEL_PROVIDER must be vllm or bailian")
    return Provider(
        name=name,
        model=require_env("GALILEO_APP_MODEL_NAME"),
        base_url=normalized_base_url(require_env("GALILEO_APP_MODEL_BASE_URL")),
        api_key=require_env("GALILEO_APP_MODEL_API_KEY"),
    )


def parse_args() -> argparse.Namespace:
    root_default = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=root_default)
    parser.add_argument("--config", type=Path, help="private kup.conf; defaults to ROOT/kup.conf")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.root.resolve()
    try:
        load_env_file(args.config or root / "kup.conf")
        timeout = float(os.getenv("GALILEO_MODEL_REQUEST_TIMEOUT", "120"))
        max_retries = int(os.getenv("GALILEO_MODEL_MAX_RETRIES", "2"))
        provider = provider_from_env()
        run_provider(provider, timeout, max_retries)
        print(f"Configured application model: {provider.name}/{provider.model}")
        print("Model capability preflight: PASS")
        return 0
    except PreflightError as exc:
        secrets = [os.getenv("GALILEO_APP_MODEL_API_KEY", "")]
        print(f"PRECHECK STOP: {sanitize(str(exc), secrets)}", file=sys.stderr)
        return 2
    except (OSError, ValueError) as exc:
        secrets = [os.getenv("GALILEO_APP_MODEL_API_KEY", "")]
        print(f"PRECHECK STOP: {sanitize(str(exc), secrets)}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
