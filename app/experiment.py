"""Run the banking agent against an existing Splunk AO dataset.

This program never creates, deletes, or edits datasets or evaluators. The
experiment itself is created through the supported Splunk AO experiment runner.
"""

from __future__ import annotations

import os
import sys
import time
from datetime import UTC, datetime
from typing import Any

from dotenv import load_dotenv

load_dotenv()

from langchain.schema.runnable.config import RunnableConfig  # noqa: E402
from langchain_core.messages import HumanMessage  # noqa: E402
from splunk_ao import splunk_ao_context  # noqa: E402
from splunk_ao.datasets import get_dataset  # noqa: E402
from splunk_ao.experiments import get_experiment, run_experiment  # noqa: E402
from splunk_ao.handlers.langchain import SplunkAOCallback  # noqa: E402

from src.splunk_ao_langgraph_fsi_agent.agents.supervisor_agent import create_supervisor_agent  # noqa: E402
from src.splunk_ao_langgraph_fsi_agent.config import get_settings  # noqa: E402
from src.splunk_ao_langgraph_fsi_agent.prompt_profiles import resolve_supervisor_prompt  # noqa: E402


POLL_INTERVAL_SECONDS = 10
POLL_DEADLINE_SECONDS = 600


def require_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value or value == "ReplaceMe":
        raise ValueError(f"{name} is required")
    return value


def serialize(value: Any) -> Any:
    if hasattr(value, "to_dict"):
        return value.to_dict()
    return value


def main() -> int:
    get_settings()
    project = require_env("SPLUNK_AO_PROJECT")
    dataset_name = require_env("SPLUNK_AO_EXPERIMENT_DATASET")
    evaluator_names = [
        item.strip()
        for item in require_env("SPLUNK_AO_EXPERIMENT_EVALUATORS").split(",")
        if item.strip()
    ]

    dataset = get_dataset(name=dataset_name, project_name=project)
    if dataset is None:
        print(
            f"STOP: Dataset {dataset_name!r} does not exist in project {project!r}. "
            "Create or attach it in the Splunk AO UI, then rerun.",
            file=sys.stderr,
        )
        return 2

    prompt_profile, _ = resolve_supervisor_prompt()
    supervisor = create_supervisor_agent(prompt_profile)

    def run_agent(dataset_input: Any) -> str:
        if isinstance(dataset_input, dict):
            user_input = dataset_input.get("input") or dataset_input.get("question")
        else:
            user_input = dataset_input
        if not isinstance(user_input, str) or not user_input.strip():
            raise ValueError("Dataset row must contain a non-empty input/question string")
        callback = SplunkAOCallback(
            splunk_ao_logger=splunk_ao_context.get_logger_instance(),
            start_new_trace=False,
            flush_on_chain_end=False,
        )
        response = supervisor.invoke(
            input={"messages": [HumanMessage(content=user_input)]},
            config=RunnableConfig(callbacks=[callback], configurable={"thread_id": user_input}),
        )
        return str(response["messages"][-1].content)

    experiment_name = f"banking-qwen-demo-{prompt_profile}-{datetime.now(UTC).strftime('%Y%m%d-%H%M%S')}"
    response = run_experiment(
        experiment_name,
        project=project,
        dataset=dataset,
        function=run_agent,
        metrics=evaluator_names,
    )
    experiment_obj = response["experiment"]
    print(f"Experiment id: {experiment_obj.id}")
    print(f"Experiment name: {experiment_obj.name}")
    print(f"Experiment link: {response.get('link', 'unavailable')}")

    deadline = time.monotonic() + POLL_DEADLINE_SECONDS
    current = experiment_obj
    while time.monotonic() < deadline:
        current = get_experiment(project_id=str(experiment_obj.project_id), experiment_name=experiment_obj.name)
        if current is None:
            print("Experiment is temporarily unavailable; polling again.")
            time.sleep(POLL_INTERVAL_SECONDS)
            continue
        metrics = serialize(current.aggregate_metrics)
        if isinstance(metrics, dict) and metrics:
            print(f"Experiment status: {serialize(current.status)}")
            print(f"Available aggregate metrics: {', '.join(sorted(metrics))}")
            return 0
        time.sleep(POLL_INTERVAL_SECONDS)

    available = serialize(current.aggregate_metrics) if current is not None else None
    available_names = sorted(available) if isinstance(available, dict) else []
    print(f"Experiment id: {experiment_obj.id}", file=sys.stderr)
    print(f"Experiment name: {experiment_obj.name}", file=sys.stderr)
    print(f"Current status: {serialize(current.status) if current is not None else 'unavailable'}", file=sys.stderr)
    print(f"Available metrics: {available_names}", file=sys.stderr)
    print(f"Configured evaluator names awaiting results: {evaluator_names}", file=sys.stderr)
    return 3


if __name__ == "__main__":
    raise SystemExit(main())
