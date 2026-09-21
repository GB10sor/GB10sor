#!/usr/bin/env python3
"""Offline parity checks for profile-selected Hermes request controls."""

import importlib.util
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "hermes_smoke", Path(__file__).with_name("hermes-openai-smoke.py")
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

model_spec = importlib.util.spec_from_file_location(
    "model_smoke", Path(__file__).with_name("model-openai-smoke.py")
)
model_module = importlib.util.module_from_spec(model_spec)
model_spec.loader.exec_module(model_module)


class ParityTests(unittest.TestCase):
    def payload(self, env):
        with patch.dict(os.environ, env, clear=True):
            return module.add_chat_template_kwargs({"model": "test"})

    def test_default_is_unchanged(self):
        self.assertEqual(self.payload({}), {"model": "test"})

    def test_deepseek_thinking_boolean_matches_recipe(self):
        self.assertEqual(
            self.payload({"GB10_CHAT_TEMPLATE_THINKING": "false"}),
            {"model": "test", "chat_template_kwargs": {"thinking": False}},
        )

    def test_invalid_deepseek_thinking_fails_closed(self):
        with self.assertRaisesRegex(SystemExit, "must be true or false"):
            self.payload({"GB10_CHAT_TEMPLATE_THINKING": "disabled"})

    def test_reasoning_effort_without_thinking_mode(self):
        self.assertEqual(
            self.payload({"GB10_CHAT_TEMPLATE_REASONING_EFFORT": "none"}),
            {"model": "test", "chat_template_kwargs": {"reasoning_effort": "none"}},
        )

    def test_both_controls_are_preserved(self):
        self.assertEqual(
            self.payload(
                {
                    "GB10_CHAT_TEMPLATE_THINKING_MODE": "adaptive",
                    "GB10_CHAT_TEMPLATE_REASONING_EFFORT": "high",
                }
            ),
            {
                "model": "test",
                "chat_template_kwargs": {
                    "thinking_mode": "adaptive",
                    "reasoning_effort": "high",
                },
            },
        )

    def test_openai_reasoning_effort_is_top_level(self):
        self.assertEqual(
            self.payload({"GB10_OPENAI_REASONING_EFFORT": "none"}),
            {"model": "test", "reasoning_effort": "none"},
        )

    def test_invalid_openai_effort_fails_closed(self):
        with self.assertRaisesRegex(SystemExit, "must be none"):
            self.payload({"GB10_OPENAI_REASONING_EFFORT": "unsafe"})

    def test_invalid_effort_fails_closed(self):
        with self.assertRaisesRegex(SystemExit, "must be none"):
            self.payload({"GB10_CHAT_TEMPLATE_REASONING_EFFORT": "unsafe"})

    def test_profile_output_budget(self):
        with patch.dict(os.environ, {"GB10_MODEL_SMOKE_MAX_TOKENS": "2048"}, clear=True):
            self.assertEqual(module.completion_token_budget(), 2048)

    def test_invalid_output_budget_fails_closed(self):
        with patch.dict(os.environ, {"GB10_MODEL_SMOKE_MAX_TOKENS": "4097"}, clear=True):
            with self.assertRaisesRegex(SystemExit, "must be 64..4096"):
                module.completion_token_budget()

    def test_model_smoke_openai_reasoning_effort_is_top_level(self):
        payload = {"model": "test"}
        with patch.dict(os.environ, {"GB10_OPENAI_REASONING_EFFORT": "none"}, clear=True):
            model_module.add_chat_template_kwargs(payload)
        self.assertEqual(payload, {"model": "test", "reasoning_effort": "none"})

    def test_failed_completion_diagnostic_never_contains_generated_text(self):
        body = {
            "choices": [{
                "finish_reason": "length",
                "message": {
                    "content": "private answer",
                    "reasoning_content": "private reasoning",
                },
            }],
            "usage": {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30},
        }
        diagnostic = model_module.safe_completion_diagnostic(body, 1)
        serialized = json.dumps(diagnostic)
        self.assertNotIn("private answer", serialized)
        self.assertNotIn("private reasoning", serialized)
        self.assertEqual(diagnostic["content_characters"], 14)
        self.assertEqual(diagnostic["reasoning_content_characters"], 17)

    def test_completion_match_defaults_to_exact(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertTrue(model_module.completion_matches("536\n", "536"))
            self.assertFalse(model_module.completion_matches("work\n536", "536"))

    def test_reasoning_profile_can_require_exact_final_nonempty_line(self):
        with patch.dict(
            os.environ, {"GB10_COMPLETION_MATCH": "final-nonempty-line"}, clear=True
        ):
            self.assertTrue(model_module.completion_matches("work\n\n536\n", "536"))
            self.assertFalse(model_module.completion_matches("work\n535\n", "536"))
            self.assertFalse(model_module.completion_matches("work\n536 trailing", "536"))

    def test_unknown_completion_match_fails_closed(self):
        with patch.dict(os.environ, {"GB10_COMPLETION_MATCH": "substring"}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "must be exact or final-nonempty-line"):
                model_module.completion_matches("536", "536")


if __name__ == "__main__":
    unittest.main()
