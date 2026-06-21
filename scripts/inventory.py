#!/usr/bin/env python3
"""Inventário do hermes-infra.

Unidade de instalação = cliente x ambiente = 1 container Hermes.
Cada cliente tem 1 deployment por ambiente, com 1+ profiles dentro.
Cada profile agrupa produtos; cada produto tem seu próprio banco/role.
"""
from __future__ import annotations
import json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ID_RE = re.compile(r"^[a-z][a-z0-9-]{1,62}$")
SLUG_RE = re.compile(r"^[a-z][a-z0-9_]{1,40}$")

def load_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)

def products() -> dict[str, dict]:
    return {p["id"]: p for path in sorted((ROOT / "catalog/products").glob("*.json")) for p in [load_json(path)]}

def clients() -> list[dict]:
    return [load_json(path) for path in sorted((ROOT / "clients").glob("*.json"))]

def environment(env_id: str) -> dict:
    return load_json(ROOT / "environments" / env_id / "environment.json")

def find_deployment(env_id: str, client_id: str) -> tuple[dict, dict]:
    for client in clients():
        if client["client"]["id"] != client_id:
            continue
        for deployment in client["deployments"]:
            if deployment["environment"] == env_id:
                return client, deployment
    raise KeyError(f"deployment não encontrado: {env_id}/{client_id}")

def db_for(product: dict, client_id: str) -> dict:
    """Nome de banco/role/var por (produto x cliente). Sem ambiente no nome:
    o ambiente já é a separação física (postgres-hml vs postgres-prd)."""
    slug = product["db_slug"]
    return {
        "product": product["id"],
        "db_slug": slug,
        "database": f"db_{slug}_{client_id}",
        "role": f"role_{slug}_{client_id}",
        "env_var": f"DB_{slug.upper()}_URL",
        "plugin_name": product["plugin_name"],
        "local_source_hml": product.get("local_source_hml", ""),
        "ref_hml": product.get("ref_hml", ""),
        "migrations": product.get("migrations", ""),
        "seed_hml": product.get("seed_hml", ""),
        "env": product.get("env", {}),
    }

def plan(env_id: str, client_id: str) -> dict:
    client, deployment = find_deployment(env_id, client_id)
    env = environment(env_id)
    catalog = products()

    # Produtos únicos do cliente neste ambiente (união dos profiles).
    product_ids: list[str] = []
    for profile in deployment["profiles"]:
        for pid in profile["products"]:
            if pid not in product_ids:
                product_ids.append(pid)

    databases = [db_for(catalog[pid], client_id) for pid in product_ids]

    profiles = [
        {
            "id": profile["id"],
            "products": profile["products"],
            "plugins": [catalog[pid]["plugin_name"] for pid in profile["products"]],
            # Pares plugin->fonte (db_slug) para symlink do código dentro do profile.
            "plugin_sources": [
                {"plugin": catalog[pid]["plugin_name"], "db_slug": catalog[pid]["db_slug"]}
                for pid in profile["products"]
            ],
            "telegram_bot_username": profile["telegram_bot_username"],
            "telegram_secret": profile["telegram_secret"],
        }
        for profile in deployment["profiles"]
    ]

    return {
        "client_id": client_id,
        "environment": env_id,
        "container_name": f"hermes-{client_id}-{env_id}",
        "compose_project": f"hermes-{client_id}-{env_id}",
        "data_dir": f"{env['data_root']}/{client_id}",
        "postgres_container": env["postgres_container"],
        "postgres_host": env["postgres_host"],
        "postgres_port": env["postgres_port"],
        "databases": databases,
        "profiles": profiles,
    }

if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "plan":
        json.dump(plan(sys.argv[2], sys.argv[3]), sys.stdout, ensure_ascii=False)
        print()
    else:
        raise SystemExit("uso: inventory.py plan <ambiente> <cliente>")
