"""Validated runtime settings for the banking agent."""

from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache


def _required(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value or value == "ReplaceMe" or "在这里" in value or value == "<SECRET>":
        raise ValueError(f"Required environment variable {name} is missing or still a placeholder")
    return value


def _positive_float(name: str, default: str) -> float:
    value = float(os.getenv(name, default))
    if value <= 0:
        raise ValueError(f"{name} must be positive")
    return value


def _nonnegative_int(name: str, default: str) -> int:
    value = int(os.getenv(name, default))
    if value < 0:
        raise ValueError(f"{name} must be non-negative")
    return value


@dataclass(frozen=True)
class Settings:
    app_model_provider: str
    app_model_name: str
    app_model_base_url: str
    app_model_api_key: str
    model_request_timeout_seconds: float
    model_max_retries: int
    pinecone_api_key: str
    pinecone_index_name: str
    pinecone_namespace: str
    pinecone_text_field: str

    @classmethod
    def from_env(cls) -> "Settings":
        provider = _required("APP_MODEL_PROVIDER")
        if provider not in {"vllm", "bailian"}:
            raise ValueError("APP_MODEL_PROVIDER must be either 'vllm' or 'bailian'")
        base_url = _required("APP_MODEL_BASE_URL").rstrip("/")
        if not base_url.startswith("https://"):
            raise ValueError("APP_MODEL_BASE_URL must use HTTPS")
        return cls(
            app_model_provider=provider,
            app_model_name=_required("APP_MODEL_NAME"),
            app_model_base_url=base_url,
            app_model_api_key=_required("APP_MODEL_API_KEY"),
            model_request_timeout_seconds=_positive_float("MODEL_REQUEST_TIMEOUT", "120"),
            model_max_retries=_nonnegative_int("MODEL_MAX_RETRIES", "2"),
            pinecone_api_key=_required("PINECONE_API_KEY"),
            pinecone_index_name=_required("PINECONE_INDEX_NAME"),
            pinecone_namespace=os.getenv("PINECONE_NAMESPACE", "bank-docs").strip() or "bank-docs",
            pinecone_text_field=os.getenv("PINECONE_TEXT_FIELD", "chunk_text").strip() or "chunk_text",
        )


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Return one immutable runtime configuration for the process."""
    return Settings.from_env()
