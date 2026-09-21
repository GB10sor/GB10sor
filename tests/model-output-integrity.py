#!/usr/bin/env python3
"""Unit checks for the quiet-output-corruption acceptance gate."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch


MODULE_PATH = Path(__file__).with_name("model-openai-smoke.py")
SPEC = importlib.util.spec_from_file_location("model_openai_smoke", MODULE_PATH)
assert SPEC and SPEC.loader
SMOKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMOKE)


class OutputIntegrityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.original_request = SMOKE.request

    def tearDown(self) -> None:
        SMOKE.request = self.original_request

    @staticmethod
    def answer_for(prompt: str) -> str:
        if "37 * 4" in prompt:
            return "148"
        for answer in ("GLM53_COPY_729", "[GB10:TRIPS:OK]", "A1-B2-C3-D4"):
            if answer in prompt:
                return answer
        raise AssertionError(f"unknown probe: {prompt}")

    def install_fake(self, mutate=None) -> None:
        def fake_request(_path, payload):
            prompt = payload["messages"][0]["content"]
            answer = self.answer_for(prompt)
            if mutate is not None:
                answer = mutate(answer)
            return {
                "choices": [
                    {"finish_reason": "stop", "message": {"content": answer}}
                ]
            }

        SMOKE.request = fake_request

    def test_two_pass_exact_receipt(self) -> None:
        self.install_fake()
        receipt = SMOKE.output_integrity("example/model")
        self.assertEqual(receipt["status"], "pass")
        self.assertEqual(receipt["passes"], 2)
        self.assertEqual(len(receipt["receipts"]), 8)

    def test_replacement_character_fails(self) -> None:
        self.install_fake(lambda answer: answer + "\ufffd")
        with self.assertRaisesRegex(RuntimeError, "replacement or control"):
            SMOKE.output_integrity("example/model")

    def test_wrong_ascii_is_hashed_but_not_exposed(self) -> None:
        self.install_fake(lambda _answer: "WRONG")
        with self.assertRaisesRegex(RuntimeError, r"length=5, sha256=[0-9a-f]{64}") as raised:
            SMOKE.output_integrity("example/model")
        self.assertNotIn("WRONG", str(raised.exception))

    def test_deepseek_v41_uses_source_backed_math_probe_family(self) -> None:
        expected_by_prompt = {
            "What is 17 * 23 + 145? Reply with only the number.": "536",
            "What is 37 * 4? Reply with only the number.": "148",
            "What is 1000 - 357? Reply with only the number.": "643",
            "What is 144 / 12 + 7? Reply with only the number.": "19",
        }

        def fake_request(_path, payload):
            prompt = payload["messages"][0]["content"]
            return {
                "choices": [
                    {
                        "finish_reason": "stop",
                        "message": {"content": expected_by_prompt[prompt]},
                    }
                ]
            }

        SMOKE.request = fake_request
        with patch.dict(os.environ, {"GB10_MODEL_PROBE_FAMILY": "deepseek-v41"}, clear=True):
            self.assertEqual(SMOKE.exact_completion_probe()[1], "536")
            receipt = SMOKE.output_integrity("deepseek-ai/DeepSeek-V4.1-Flash")
        self.assertEqual(receipt["status"], "pass")
        self.assertEqual(len(receipt["receipts"]), 8)

    def test_unknown_probe_family_fails_closed(self) -> None:
        with patch.dict(os.environ, {"GB10_MODEL_PROBE_FAMILY": "unknown"}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "must be generic or deepseek-v41"):
                SMOKE.exact_completion_probe()


if __name__ == "__main__":
    unittest.main()
