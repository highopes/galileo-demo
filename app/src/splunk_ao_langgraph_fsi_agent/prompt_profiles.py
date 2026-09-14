"""Runtime-selectable supervisor prompts for the two-stage demo."""

from __future__ import annotations

import os
from pathlib import Path
from textwrap import dedent


BASELINE_PROFILE = "baseline"
IMPROVED_PROFILE = "improved"
CUSTOM_PROFILE = "custom"

# Adapt the official omission for a stronger tool-using model: an unlisted agent may
# investigate, while the prompt still fails to define how its result is delivered.
BASELINE_PROMPT = dedent(
    """
    You are a supervisor managing the following agents:
    - a credit card information agent. Assign any tasks related to information about credit cards to this agent
    For a credit-score request, make exactly one handoff to the most relevant available agent, even if that agent is not documented above. After that agent transfers back, do not make another handoff for the same request.
    Because credit-score handling is not documented in the supported agent list above, after that handoff returns do not include its result and respond only with 'I cannot answer that question'.
    Otherwise, only respond with 'I don't know' or 'I cannot answer that question'.
    If you need to ask the user for more information, do so in a concise manner.
    """
).strip()

# The improved profile explicitly documents the official credit-score capability
# and removes the baseline's deliberately broken final-answer scope.
IMPROVED_PROMPT = dedent(
    """
    You are a supervisor managing the following agents:
    - a credit card information agent. Assign any tasks related to information about credit cards to this agent
    - a credit score agent. Use this to get the users credit score.
    Otherwise, only respond with 'I don't know' or 'I cannot answer that question'.
    If you need to ask the user for more information, do so in a concise manner.
    """
).strip()

BUILTIN_PROMPTS = {
    BASELINE_PROFILE: BASELINE_PROMPT,
    IMPROVED_PROFILE: IMPROVED_PROMPT,
}


def _read_profile_file() -> str | None:
    path_value = os.getenv("SUPERVISOR_PROMPT_PROFILE_FILE", "").strip()
    if not path_value:
        return None
    path = Path(path_value)
    if not path.is_file():
        raise ValueError(f"SUPERVISOR_PROMPT_PROFILE_FILE does not exist: {path}")
    value = path.read_text(encoding="utf-8").strip()
    if not value:
        raise ValueError("SUPERVISOR_PROMPT_PROFILE_FILE is empty")
    return value


def resolve_supervisor_prompt(requested_profile: str | None = None) -> tuple[str, str]:
    """Return the selected profile name and prompt without changing source code."""
    profile = (
        requested_profile
        or _read_profile_file()
        or os.getenv("SUPERVISOR_PROMPT_PROFILE", BASELINE_PROFILE)
    ).strip().lower()

    if profile in BUILTIN_PROMPTS:
        return profile, BUILTIN_PROMPTS[profile]
    if profile != CUSTOM_PROFILE:
        supported = ", ".join((*BUILTIN_PROMPTS, CUSTOM_PROFILE))
        raise ValueError(f"Unsupported SUPERVISOR_PROMPT_PROFILE {profile!r}; choose {supported}")

    custom_file_value = os.getenv("SUPERVISOR_PROMPT_CUSTOM_FILE", "").strip()
    if custom_file_value:
        custom_path = Path(custom_file_value)
        if not custom_path.is_file():
            raise ValueError(f"SUPERVISOR_PROMPT_CUSTOM_FILE does not exist: {custom_path}")
        custom_prompt = custom_path.read_text(encoding="utf-8").strip()
    else:
        custom_prompt = os.getenv("SUPERVISOR_PROMPT_CUSTOM", "").strip()
    if not custom_prompt:
        raise ValueError("custom prompt profile requires SUPERVISOR_PROMPT_CUSTOM or SUPERVISOR_PROMPT_CUSTOM_FILE")
    return profile, custom_prompt
