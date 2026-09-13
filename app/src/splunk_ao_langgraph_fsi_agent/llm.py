"""OpenAI-compatible model factory shared by every agent."""

from __future__ import annotations

from langchain_openai import ChatOpenAI

from .config import Settings, get_settings


def create_chat_model(component_name: str, settings: Settings | None = None) -> ChatOpenAI:
    """Create a configured chat model without provider-specific credentials."""
    resolved = settings or get_settings()
    return ChatOpenAI(
        model=resolved.app_model_name,
        base_url=resolved.app_model_base_url,
        api_key=resolved.app_model_api_key,
        timeout=resolved.model_request_timeout_seconds,
        max_retries=resolved.model_max_retries,
        temperature=0,
        name=component_name,
    )
