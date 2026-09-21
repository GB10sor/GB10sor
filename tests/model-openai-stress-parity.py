#!/usr/bin/env python3
"""Offline request parity checks; do not weaken long-context correctness gates."""
import importlib.util
import io
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("stress", Path(__file__).with_name("model-openai-stress.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ParityTests(unittest.TestCase):
    def request_payload(self, env):
        observed = []

        def response(request, **kwargs):
            observed.append(json.loads(request.data))
            return io.BytesIO(json.dumps({"choices": [{"message": {"content": "OK"}}], "usage": {"prompt_tokens": 20}}).encode())

        with patch.dict(os.environ, env, clear=True), patch.object(module.urllib.request, "urlopen", side_effect=response):
            module.completion("test-model", "test prompt")
        return observed[0]

    def test_disabled_mode_matches_profile(self):
        payload = self.request_payload({"GB10_CHAT_TEMPLATE_THINKING_MODE": "disabled"})
        self.assertEqual(payload["chat_template_kwargs"], {"thinking_mode": "disabled"})
        self.assertEqual(payload["temperature"], 0)
        self.assertEqual(payload["max_tokens"], 1024)

    def test_default_is_unchanged(self):
        self.assertNotIn("chat_template_kwargs", self.request_payload({}))

    def test_deepseek_thinking_boolean_matches_recipe(self):
        payload = self.request_payload({"GB10_CHAT_TEMPLATE_THINKING": "false"})
        self.assertEqual(payload["chat_template_kwargs"], {"thinking": False})

    def test_invalid_deepseek_thinking_fails_before_request(self):
        with patch.dict(os.environ, {"GB10_CHAT_TEMPLATE_THINKING": "disabled"}, clear=True), patch.object(module.urllib.request, "urlopen") as request:
            with self.assertRaises(RuntimeError):
                module.completion("test", "prompt")
            request.assert_not_called()

    def test_deepseek_probe_family_is_explicit(self):
        with patch.dict(os.environ, {"GB10_MODEL_PROBE_FAMILY": "deepseek-v41"}, clear=True):
            self.assertEqual(module.probe_family(), "deepseek-v41")

    def test_unknown_probe_family_fails_closed(self):
        with patch.dict(os.environ, {"GB10_MODEL_PROBE_FAMILY": "unknown"}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "must be generic or deepseek-v41"):
                module.probe_family()

    def test_reasoning_effort_matches_profile(self):
        payload = self.request_payload({"GB10_CHAT_TEMPLATE_THINKING_MODE": "adaptive", "GB10_CHAT_TEMPLATE_REASONING_EFFORT": "high"})
        self.assertEqual(payload["chat_template_kwargs"], {"thinking_mode": "adaptive", "reasoning_effort": "high"})

    def test_enabled_mode(self):
        self.assertEqual(self.request_payload({"GB10_CHAT_TEMPLATE_THINKING_MODE": "enabled"})["chat_template_kwargs"], {"thinking_mode": "enabled"})

    def test_effort_without_mode(self):
        self.assertEqual(self.request_payload({"GB10_CHAT_TEMPLATE_REASONING_EFFORT": "none"})["chat_template_kwargs"], {"reasoning_effort": "none"})

    def test_invalid_mode_fails_before_request(self):
        with patch.dict(os.environ, {"GB10_CHAT_TEMPLATE_THINKING_MODE": "unsafe"}, clear=True), patch.object(module.urllib.request, "urlopen") as request:
            with self.assertRaises(RuntimeError):
                module.completion("test", "prompt")
            request.assert_not_called()

    def test_invalid_effort_fails_before_request(self):
        with patch.dict(os.environ, {"GB10_CHAT_TEMPLATE_REASONING_EFFORT": "unsafe"}, clear=True), patch.object(module.urllib.request, "urlopen") as request:
            with self.assertRaises(RuntimeError):
                module.completion("test", "prompt")
            request.assert_not_called()

    def test_wrong_long_answer_still_fails(self):
        def response(model, prompt):
            text = "GB10_UNICODE_OK|한글|日本語|é|🙂" if "preserving every character" in prompt else "alpha alpha alpha"
            return {"choices": [{"message": {"content": text}}], "usage": {"prompt_tokens": 61230}}

        with patch.object(module, "completion", side_effect=response), patch.object(module.sys, "argv", ["stress", "all", "model", "60000", "1"]):
            with self.assertRaisesRegex(RuntimeError, "long-context gate failed"):
                module.main()

    def test_completion_match_defaults_to_exact(self):
        body = {"choices": [{"message": {"content": "work\n536"}}]}
        with patch.dict(os.environ, {}, clear=True):
            self.assertFalse(module.content_matches(body, "536"))

    def test_reasoning_profile_accepts_only_exact_final_nonempty_line(self):
        body = {"choices": [{"message": {"content": "work\n\n536\n"}}]}
        with patch.dict(
            os.environ, {"GB10_COMPLETION_MATCH": "final-nonempty-line"}, clear=True
        ):
            self.assertTrue(module.content_matches(body, "536"))
            body["choices"][0]["message"]["content"] = "work\n536 trailing"
            self.assertFalse(module.content_matches(body, "536"))

    def test_unknown_completion_match_fails_closed(self):
        body = {"choices": [{"message": {"content": "536"}}]}
        with patch.dict(os.environ, {"GB10_COMPLETION_MATCH": "substring"}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "must be exact or final-nonempty-line"):
                module.content_matches(body, "536")

    def test_empty_answer_reports_budget_without_reasoning_text(self):
        def response(model, prompt):
            text = "GB10_UNICODE_OK|한글|日本語|é|🙂" if "preserving every character" in prompt else ""
            return {"choices": [{"finish_reason": "length", "message": {"content": text, "reasoning_content": "PRIVATE_DIAGNOSTIC_TEXT"}}], "usage": {"prompt_tokens": 17450, "completion_tokens": 1024, "reasoning_tokens": 1024}}

        with patch.object(module, "completion", side_effect=response), patch.object(module.sys, "argv", ["stress", "all", "model", "16384", "8"]):
            with self.assertRaises(RuntimeError) as caught:
                module.main()
        detail = str(caught.exception)
        self.assertIn("finish_reason='length'", detail)
        self.assertIn("'completion_tokens': 1024", detail)
        self.assertNotIn("PRIVATE_DIAGNOSTIC_TEXT", detail)

    def test_missing_content_reports_only_termination_metadata(self):
        body = {
            "choices": [{"finish_reason": "length", "message": {
                "content": None, "reasoning_content": "PRIVATE_DIAGNOSTIC_TEXT"}}],
            "usage": {"prompt_tokens": 23, "completion_tokens": 1024,
                      "completion_tokens_details": {"reasoning_tokens": 1024}},
        }
        with self.assertRaisesRegex(RuntimeError, "completion did not contain assistant text") as caught:
            module.content(body)
        detail = str(caught.exception)
        self.assertIn("'finish_reason': 'length'", detail)
        self.assertIn("'completion_tokens': 1024", detail)
        self.assertIn("'reasoning_tokens': 1024", detail)
        self.assertNotIn("PRIVATE_DIAGNOSTIC_TEXT", detail)


if __name__ == "__main__":
    unittest.main()
