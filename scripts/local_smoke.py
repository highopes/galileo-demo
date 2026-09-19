#!/usr/bin/env python3
"""Validate tools, then record the intentionally imperfect baseline in Splunk AO."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import sys
import uuid
from pathlib import Path
from typing import Any


class SmokeStop(RuntimeError):
    pass


def load_env_file(path: Path) -> None:
    if not path.exists():
        raise SmokeStop(f"Required environment file does not exist: {path}")
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise SmokeStop(f"Invalid dotenv entry in {path}:{number}")
        key, raw_value = line.split("=", 1)
        parsed = shlex.split(raw_value, comments=True, posix=True)
        os.environ[key.strip()] = parsed[0] if parsed else ""


def configure(root: Path) -> None:
    load_env_file(Path(os.getenv("KUP_CONFIG", root / "kup.conf")))
    mappings = {
        "SPLUNK_AO_API_KEY": "GALILEO_SPLUNK_AO_API_KEY",
        "SPLUNK_AO_PROJECT": "GALILEO_SPLUNK_AO_PROJECT",
        "SPLUNK_AO_AGENT_STREAM": "GALILEO_SPLUNK_AO_AGENT_STREAM",
        "SPLUNK_AO_CONSOLE_URL": "GALILEO_SPLUNK_AO_CONSOLE_URL",
        "APP_MODEL_PROVIDER": "GALILEO_APP_MODEL_PROVIDER",
        "APP_MODEL_NAME": "GALILEO_APP_MODEL_NAME",
        "APP_MODEL_BASE_URL": "GALILEO_APP_MODEL_BASE_URL",
        "APP_MODEL_API_KEY": "GALILEO_APP_MODEL_API_KEY",
        "MODEL_REQUEST_TIMEOUT": "GALILEO_MODEL_REQUEST_TIMEOUT",
        "MODEL_MAX_RETRIES": "GALILEO_MODEL_MAX_RETRIES",
        "PINECONE_API_KEY": "GALILEO_PINECONE_API_KEY",
        "PINECONE_INDEX_NAME": "GALILEO_PINECONE_INDEX_NAME",
        "PINECONE_NAMESPACE": "GALILEO_PINECONE_NAMESPACE",
        "PINECONE_TEXT_FIELD": "GALILEO_PINECONE_TEXT_FIELD",
        "SPLUNK_AO_EXPERIMENT_EVALUATORS": "GALILEO_SPLUNK_AO_EXPERIMENT_EVALUATORS",
        "SPLUNK_AO_EXPERIMENT_DATASET": "GALILEO_SPLUNK_AO_EXPERIMENT_DATASET",
    }
    for runtime_name, config_name in mappings.items():
        value = os.getenv(config_name, "")
        if runtime_name != "SPLUNK_AO_EXPERIMENT_DATASET" and (
            not value or value == "ReplaceMe"
        ):
            raise SmokeStop(f"Required setting is empty or still a placeholder: {config_name}")
        os.environ[runtime_name] = value

    profile = os.getenv("GALILEO_SUPERVISOR_PROMPT_PROFILE", "baseline")
    baseline_variant = os.getenv("GALILEO_BASELINE_PROMPT_VARIANT", "qwen")
    if profile == "baseline" and baseline_variant == "qwen":
        os.environ["SUPERVISOR_PROMPT_PROFILE"] = "custom"
        os.environ["SUPERVISOR_PROMPT_CUSTOM_FILE"] = str(
            root / "app" / "prompts" / "supervisor-baseline-qwen.txt"
        )
    elif profile == "baseline" and baseline_variant == "official":
        os.environ["SUPERVISOR_PROMPT_PROFILE"] = "baseline"
        os.environ.pop("SUPERVISOR_PROMPT_CUSTOM_FILE", None)
    elif profile == "improved":
        os.environ["SUPERVISOR_PROMPT_PROFILE"] = "improved"
        os.environ.pop("SUPERVISOR_PROMPT_CUSTOM_FILE", None)
    else:
        raise SmokeStop("Unsupported GALILEO prompt selection")
    os.environ.setdefault("OTEL_SERVICE_NAME", "splunk-ao-banking-qwen-demo-local")


def summarize_messages(messages: list[Any]) -> list[dict[str, Any]]:
    summary: list[dict[str, Any]] = []
    for message in messages:
        tool_calls = getattr(message, "tool_calls", None) or []
        summary.append(
            {
                "type": type(message).__name__,
                "name": getattr(message, "name", None),
                "tool_calls": [call.get("name") for call in tool_calls if isinstance(call, dict)],
            }
        )
    return summary


def invoke(supervisor: Any, prompt: str, callback: Any) -> tuple[str, list[dict[str, Any]]]:
    from langchain.schema.runnable.config import RunnableConfig
    from langchain_core.messages import HumanMessage

    response = supervisor.invoke(
        input={"messages": [HumanMessage(content=prompt)]},
        config=RunnableConfig(
            callbacks=[callback],
            configurable={"thread_id": str(uuid.uuid4())},
            recursion_limit=30,
        ),
    )
    messages = response["messages"]
    return str(messages[-1].content), summarize_messages(messages)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        configure(root)
        sys.path.insert(0, str(root / "app"))
        from splunk_ao import splunk_ao_context
        from splunk_ao.handlers.langchain import SplunkAOCallback
        from src.splunk_ao_langgraph_fsi_agent.agents.supervisor_agent import create_supervisor_agent
        from src.splunk_ao_langgraph_fsi_agent.config import get_settings
        from src.splunk_ao_langgraph_fsi_agent.tools.credit_score_tool import CreditScoreTool
        from src.splunk_ao_langgraph_fsi_agent.tools.pinecone_retrieval_tool import PineconeRetrievalTool

        settings = get_settings()
        print(f"Application model: {settings.app_model_provider}/{settings.app_model_name}")
        print(f"Pinecone target: {settings.pinecone_index_name}/{settings.pinecone_namespace}")

        score_result = CreditScoreTool().invoke({})
        if "550" not in str(score_result):
            raise SmokeStop("Credit-score tool did not return its fixture value")
        print("credit-score tool: PASS")

        retrieval_result = PineconeRetrievalTool(
            index_name=settings.pinecone_index_name,
            namespace=settings.pinecone_namespace,
            text_field=settings.pinecone_text_field,
            api_key=settings.pinecone_api_key,
        ).invoke({"query": "What cashback rewards does the Orbit Credit Card offer?", "k": 3})
        if "cashback" not in str(retrieval_result).lower():
            raise SmokeStop("Pinecone tool did not retrieve cashback-related source material")
        print("pinecone retrieval tool: PASS")

        session_id = splunk_ao_context.start_session(
            name="FSI Agent - intentionally imperfect baseline",
            external_id=f"baseline-observation-{uuid.uuid4()}",
        )
        print(f"Splunk AO session started: {session_id}")
        callback = SplunkAOCallback()
        supervisor = create_supervisor_agent()

        cases = [
            ("credit-score", "What is my credit score?"),
            ("credit-card-rag", "What are the cashback rewards offered by the Orbit Credit Card?"),
            ("out-of-scope", "Recommend me a good book."),
        ]
        for case_name, prompt in cases:
            answer, message_summary = invoke(supervisor, prompt, callback)
            observed_tools = {
                tool_name
                for message in message_summary
                for tool_name in message["tool_calls"]
                if tool_name
            }
            print(f"{case_name}: BASELINE OBSERVED (not pass/fail graded)")
            print(f"  tools: {sorted(observed_tools)}")
            print(f"  route: {json.dumps(message_summary, ensure_ascii=False)}")
            print(f"  answer: {answer[:500]}")

        splunk_ao_context.flush()
        print("Splunk AO flush completed; inspect the intentional baseline behavior in the UI checkpoint.")
        return 0
    except SmokeStop as exc:
        print(f"LOCAL SMOKE STOP: {exc}", file=sys.stderr)
        return 2
    except Exception as exc:
        print(f"LOCAL SMOKE STOP: {type(exc).__name__}: {str(exc)[:1000]}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
