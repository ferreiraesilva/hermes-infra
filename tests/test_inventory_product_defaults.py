import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "scripts"))
import inventory


def test_minhaincorporadora_define_minimax_openrouter():
    result = inventory.plan("hml", "city", "corretores")
    assert result["inference"] == {
        "provider": "openrouter",
        "model": "minimax/minimax-m3",
        "base_url": "https://openrouter.ai/api/v1",
    }