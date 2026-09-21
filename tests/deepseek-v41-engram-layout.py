#!/usr/bin/env python3
"""Lock the reviewed DeepSeek V4.1 Engram TP4 and TP8 row boundaries."""

import importlib.util
from pathlib import Path

script = Path(__file__).resolve().parents[1] / "scripts" / "prepare-deepseek-v41-engram-local.py"
spec = importlib.util.spec_from_file_location("deepseek_engram_local", script)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

config = {
    "architectures": ["DeepseekV41ForCausalLM"],
    "text_config": {
        "engram_layer_ids": [1, 14],
        "engram_num_embeddings": [384006168, 384016682],
        "engram_max_ngram_size": 4,
        "engram_vocab_size": 16000000,
        "engram_n_heads": 8,
    },
}

assert module.layout(config, 4) == {
    1: [(0, 96000564), (96000564, 192001740), (192001740, 288003654), (288003654, 384006168)],
    14: [(0, 96003054), (96003054, 192007016), (192007016, 288011564), (288011564, 384016682)],
}
assert module.layout(config, 8) == {
    1: [
        (0, 48000217), (48000217, 96000564), (96000564, 144001069),
        (144001069, 192001740), (192001740, 240002613), (240002613, 288003654),
        (288003654, 336004849), (336004849, 384006168),
    ],
    14: [
        (0, 48001463), (48001463, 96003054), (96003054, 144004957),
        (144004957, 192007016), (192007016, 240009215), (240009215, 288011564),
        (288011564, 336014037), (336014037, 384016682),
    ],
}

print("PASS: DeepSeek V4.1 Engram TP4 and TP8 row boundaries are sealed")
