"""Offline tests for configuration and import-time behavior."""

from __future__ import annotations

import importlib
import os
import sys
import unittest
from unittest.mock import patch

from src.splunk_ao_langgraph_fsi_agent.config import Settings, get_settings


VALID_ENV = {
    "APP_MODEL_PROVIDER": "bailian",
    "APP_MODEL_NAME": "qwen3.7-flash",
    "APP_MODEL_BASE_URL": "https://example.invalid/compatible-mode/v1",
    "APP_MODEL_API_KEY": "test-only-key",
    "MODEL_REQUEST_TIMEOUT": "120",
    "MODEL_MAX_RETRIES": "2",
    "PINECONE_API_KEY": "test-only-pinecone-key",
    "PINECONE_INDEX_NAME": "credit-card-information-qwen-demo",
    "PINECONE_NAMESPACE": "bank-docs",
    "PINECONE_TEXT_FIELD": "chunk_text",
}


class SettingsTests(unittest.TestCase):
    def tearDown(self) -> None:
        get_settings.cache_clear()

    def test_valid_settings(self) -> None:
        with patch.dict(os.environ, VALID_ENV, clear=True):
            settings = Settings.from_env()
        self.assertEqual(settings.app_model_provider, "bailian")
        self.assertEqual(settings.app_model_name, "qwen3.7-flash")
        self.assertEqual(settings.pinecone_namespace, "bank-docs")

    def test_unknown_provider_is_rejected(self) -> None:
        invalid = {**VALID_ENV, "APP_MODEL_PROVIDER": "automatic"}
        with patch.dict(os.environ, invalid, clear=True):
            with self.assertRaisesRegex(ValueError, "APP_MODEL_PROVIDER"):
                Settings.from_env()


class ImportSideEffectTests(unittest.TestCase):
    def test_agent_modules_do_not_open_network_connections(self) -> None:
        module_names = [
            "src.splunk_ao_langgraph_fsi_agent.agents.credit_score_agent",
            "src.splunk_ao_langgraph_fsi_agent.agents.credit_card_information_agent",
            "src.splunk_ao_langgraph_fsi_agent.agents.supervisor_agent",
        ]
        for name in module_names:
            sys.modules.pop(name, None)
        with patch("socket.create_connection", side_effect=AssertionError("network attempted during import")):
            for name in module_names:
                importlib.import_module(name)


if __name__ == "__main__":
    unittest.main()
