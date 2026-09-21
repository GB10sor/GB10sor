#!/usr/bin/env python3
"""Check DeepSeek V4.1 request-level reasoning and parsed OpenAI fields."""

import json
import sys
import urllib.request


def main():
    model = sys.argv[1]
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": "What is 19 plus 23? Give the final number."}],
        "reasoning_effort": "max",
        "chat_template_kwargs": {"thinking": True},
        "temperature": 0,
        "max_tokens": 1024,
        "stream": False,
    }
    request = urllib.request.Request(
        "http://127.0.0.1:8000/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer local"},
    )
    with urllib.request.urlopen(request, timeout=900) as response:
        body = json.load(response)
    choices = body.get("choices")
    assert isinstance(choices, list) and len(choices) == 1
    message = choices[0]["message"]
    # This pinned vLLM response schema emits `reasoning`; older runtimes use
    # `reasoning_content` for the same parsed field.
    reasoning = message.get("reasoning")
    if reasoning is None:
        reasoning = message.get("reasoning_content")
    content = message.get("content")
    assert isinstance(reasoning, str) and reasoning.strip(), (
        "reasoning was not parsed; response fields=" + ",".join(sorted(message))
        + "; reasoning type=" + type(message.get("reasoning")).__name__
    )
    assert isinstance(content, str) and content.strip(), "final answer was not parsed"
    assert choices[0].get("finish_reason") == "stop", "reasoning request did not complete"
    print(json.dumps({
        "status": "pass", "model": model,
        "reasoningCharacters": len(reasoning), "answerCharacters": len(content),
        "finishReason": choices[0]["finish_reason"],
    }, sort_keys=True))


if __name__ == "__main__":
    main()
