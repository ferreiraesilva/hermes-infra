from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import inventory


def test_minhaincorporadora_declara_defaults_sem_regra_na_ebm():
    plan = inventory.plan("hml", "ebm", "corretores")
    product_env = next(
        database["env"]
        for database in plan["databases"]
        if database["product"] == "minhaincorporadora"
    )
    _, raw_profile = inventory.find_profile("hml", "ebm", "corretores")

    assert product_env["MINHAINCORP_TELEGRAM_NATIVE_MEDIA"] == "true"
    assert plan["display"]["platforms"]["telegram"]["streaming"] is False
    assert "streaming" not in raw_profile["display"]["platforms"]["telegram"]


def test_profile_pode_sobrescrever_default_de_display_do_produto():
    catalog = {
        "minhaincorporadora": {
            "display": {"platforms": {"telegram": {"streaming": False}}}
        }
    }
    profile = {
        "products": ["minhaincorporadora"],
        "display": {"platforms": {"telegram": {"streaming": True}}},
    }

    assert inventory.display_for(profile, catalog) == {
        "platforms": {"telegram": {"streaming": True}}
    }
