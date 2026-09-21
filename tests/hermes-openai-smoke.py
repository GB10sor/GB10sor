#!/usr/bin/env python3
"""Fail-closed OpenAI API contract used by the Hermes compatibility gate."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request


BASE_URL = "http://127.0.0.1:8000/v1"


def request_timeout() -> float:
    raw = os.environ.get("GB10SOR_OPENAI_TIMEOUT_SECONDS", "120")
    try:
        timeout = float(raw)
    except ValueError as error:
        fail("GB10SOR_OPENAI_TIMEOUT_SECONDS is not numeric")
        raise AssertionError from error
    if not 1 <= timeout <= 900:
        fail("GB10SOR_OPENAI_TIMEOUT_SECONDS must be 1..900")
    return timeout


def completion_token_budget() -> int:
    raw = os.environ.get("GB10_MODEL_SMOKE_MAX_TOKENS", "512")
    try:
        budget = int(raw)
    except ValueError:
        fail("GB10_MODEL_SMOKE_MAX_TOKENS is not an integer")
    if not 64 <= budget <= 4096:
        fail("GB10_MODEL_SMOKE_MAX_TOKENS must be 64..4096")
    return budget


def fail(message: str) -> None:
    raise SystemExit(f"Hermes compatibility failed: {message}")


def add_chat_template_kwargs(payload: dict) -> dict:
    """Apply profile-selected, model-native reasoning controls to a request."""

    kwargs: dict[str, object] = {}
    thinking = os.environ.get("GB10_CHAT_TEMPLATE_THINKING")
    if thinking is not None:
        if thinking not in {"true", "false"}:
            fail("GB10_CHAT_TEMPLATE_THINKING must be true or false")
        kwargs["thinking"] = thinking == "true"

    mode = os.environ.get("GB10_CHAT_TEMPLATE_THINKING_MODE")
    if mode is not None:
        if mode not in {"disabled", "adaptive", "enabled"}:
            fail("GB10_CHAT_TEMPLATE_THINKING_MODE must be disabled, adaptive, or enabled")
        kwargs["thinking_mode"] = mode

    effort = os.environ.get("GB10_CHAT_TEMPLATE_REASONING_EFFORT")
    if effort is not None:
        if effort not in {"none", "low", "medium", "high", "max"}:
            fail(
                "GB10_CHAT_TEMPLATE_REASONING_EFFORT must be none, low, medium, high, or max"
            )
        kwargs["reasoning_effort"] = effort

    if kwargs:
        payload["chat_template_kwargs"] = kwargs

    openai_effort = os.environ.get("GB10_OPENAI_REASONING_EFFORT")
    if openai_effort is not None:
        if openai_effort not in {
            "none", "minimal", "low", "medium", "high", "xhigh", "max"
        }:
            fail(
                "GB10_OPENAI_REASONING_EFFORT must be none, minimal, low, medium, high, xhigh, or max"
            )
        payload["reasoning_effort"] = openai_effort
    return payload


def selected_tool_choice(name: str) -> str | dict:
    """Use auto tool choice only for profiles whose native recipe requires it."""

    mode = os.environ.get("GB10_TOOL_CHOICE_MODE", "forced")
    if mode == "forced":
        return {"type": "function", "function": {"name": name}}
    if mode == "auto":
        return "auto"
    fail("GB10_TOOL_CHOICE_MODE must be forced or auto")


def request_json(path: str, payload: dict | None = None) -> dict:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        f"{BASE_URL}{path}",
        data=body,
        headers={
            "Authorization": "Bearer local",
            "Content-Type": "application/json",
        },
        method="GET" if body is None else "POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=request_timeout()) as response:
            return json.load(response)
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
        fail(f"{path} request failed: {error}")


def assistant_message(response: dict) -> dict:
    try:
        choices = response["choices"]
        message = choices[0]["message"]
    except (KeyError, IndexError, TypeError) as error:
        fail(f"invalid chat response structure: {error}")
    if len(choices) != 1 or not isinstance(message, dict):
        fail("expected exactly one assistant message")
    return message


def exact_content(message: dict, expected: str, gate: str) -> None:
    content = message.get("content")
    if not isinstance(content, str) or content.strip() != expected:
        fail(f"{gate} expected exact content {expected!r}, observed {content!r}")


def exact_tool_result_content(message: dict, expected: str) -> None:
    """Accept the two semantically exact tool-result renderings used by tested runtimes."""

    content = message.get("content")
    if isinstance(content, str) and content.strip() == expected:
        return
    if isinstance(content, str):
        try:
            decoded = json.loads(content)
        except json.JSONDecodeError:
            decoded = None
        if decoded == {"value": expected}:
            return
    fail(
        "tool result expected exact scalar or single-value JSON content "
        f"for {expected!r}, observed {content!r}"
    )


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: hermes-openai-smoke.py MODEL_ID")
    model_id = sys.argv[1]

    models = request_json("/models")
    advertised = {
        item.get("id")
        for item in models.get("data", [])
        if isinstance(item, dict)
    }
    if model_id not in advertised:
        fail(f"model is not advertised by /models: {model_id}")

    chat = request_json(
        "/chat/completions",
        add_chat_template_kwargs({
            "model": model_id,
            "messages": [
                {
                    "role": "user",
                    "content": "Reply with exactly GB10_OK and nothing else.",
                }
            ],
            "temperature": 0,
            "max_tokens": completion_token_budget(),
        }),
    )
    exact_content(assistant_message(chat), "GB10_OK", "plain chat")

    tool = {
        "type": "function",
        "function": {
            "name": "lookup_catalog_entry",
            "description": (
                "Return the exact stored value for a catalog item. Use this tool whenever "
                "the user asks for a catalog value because the value is not otherwise known."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "item_id": {"type": "string", "enum": ["sample-17"]}
                },
                "required": ["item_id"],
                "additionalProperties": False,
            },
        },
    }
    tool_response = request_json(
        "/chat/completions",
        add_chat_template_kwargs({
            "model": model_id,
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "You are a tool-use agent. When the user names an available function "
                        "and supplies every required argument, call that function before replying."
                    ),
                },
                {
                    "role": "user",
                    "content": (
                        "Call the function lookup_catalog_entry now with the JSON arguments "
                        '{"item_id":"sample-17"}. Do not write prose before the tool call. '
                        "After receiving the tool result, reply with exactly the returned value "
                        "and nothing else."
                    ),
                }
            ],
            "tools": [tool],
            "tool_choice": selected_tool_choice("lookup_catalog_entry"),
            "temperature": 0,
            "max_tokens": completion_token_budget(),
        }),
    )
    tool_message = assistant_message(tool_response)
    calls = tool_message.get("tool_calls")
    if not isinstance(calls, list) or len(calls) != 1:
        fail(
            "expected exactly one tool call; observed response="
            + json.dumps(tool_response, sort_keys=True)
        )
    call = calls[0]
    try:
        call_id = call["id"]
        function = call["function"]
        name = function["name"]
        arguments = json.loads(function["arguments"])
    except (KeyError, TypeError, json.JSONDecodeError) as error:
        fail(f"invalid tool call structure: {error}")
    if name != "lookup_catalog_entry" or arguments != {"item_id": "sample-17"}:
        fail(f"unexpected tool call: {name} {arguments!r}")
    if not isinstance(call_id, str) or not call_id:
        fail("tool call id is absent")

    final_response = request_json(
        "/chat/completions",
        add_chat_template_kwargs({
            "model": model_id,
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "You are a tool-use agent. When the user names an available function "
                        "and supplies every required argument, call that function before replying."
                    ),
                },
                {
                    "role": "user",
                    "content": (
                        "Call the function lookup_catalog_entry now with the JSON arguments "
                        '{"item_id":"sample-17"}. Do not write prose before the tool call. '
                        "After receiving the tool result, reply with exactly the returned value "
                        "and nothing else."
                    ),
                },
                tool_message,
                {
                    "role": "tool",
                    "tool_call_id": call_id,
                    "content": json.dumps({"value": "GB10_TOOL_OK"}),
                },
            ],
            "tools": [tool],
            "tool_choice": "none",
            "temperature": 0,
            "max_tokens": completion_token_budget(),
        }),
    )
    exact_tool_result_content(assistant_message(final_response), "GB10_TOOL_OK")

    print(
        json.dumps(
            {
                "status": "pass",
                "model": model_id,
                "models_gate": "pass",
                "chat_gate": "pass",
                "tool_call_gate": "pass",
                "tool_result_gate": "pass",
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
