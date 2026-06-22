#!/usr/bin/env python3
"""Inventário do hermes-infra.

Unidade de instalação = PROFILE = 1 container Hermes = 1 bot.
Um profile pertence a um cliente, num ambiente, e agrupa 1+ produtos que
compartilham o mesmo bot. Cada produto tem seu próprio banco/role.
Cada container roda o `gateway run` do seu profile default (image-native, s6).
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

def client_rows() -> list[tuple[str, str]]:
    return [(c["client"]["id"], c["client"]["name"]) for c in clients()]

def environment_ids(client_id: str) -> list[str]:
    for client in clients():
        if client["client"]["id"] == client_id:
            return [d["environment"] for d in client["deployments"]]
    raise KeyError(f"cliente não encontrado: {client_id}")

def environment(env_id: str) -> dict:
    return load_json(ROOT / "environments" / env_id / "environment.json")

def find_profile(env_id: str, client_id: str, profile_id: str) -> tuple[dict, dict]:
    for client in clients():
        if client["client"]["id"] != client_id:
            continue
        for deployment in client["deployments"]:
            if deployment["environment"] != env_id:
                continue
            for profile in deployment["profiles"]:
                if profile["id"] == profile_id:
                    return client, profile
    raise KeyError(f"profile não encontrado: {env_id}/{client_id}/{profile_id}")

def profile_ids(env_id: str, client_id: str) -> list[str]:
    for client in clients():
        if client["client"]["id"] != client_id:
            continue
        for deployment in client["deployments"]:
            if deployment["environment"] == env_id:
                return [p["id"] for p in deployment["profiles"]]
    raise KeyError(f"cliente/ambiente não encontrado: {env_id}/{client_id}")

def db_for(product: dict, client_id: str) -> dict:
    """Banco/role/var por (produto x cliente). Sem ambiente no nome: o ambiente
    já é a separação física (postgres-hml vs postgres-prd)."""
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

def plan(env_id: str, client_id: str, profile_id: str) -> dict:
    client, profile = find_profile(env_id, client_id, profile_id)
    env = environment(env_id)
    catalog = products()
    instance = f"{client_id}-{profile_id}"

    databases = [db_for(catalog[pid], client_id) for pid in profile["products"]]
    plugin_sources = [
        {"plugin": catalog[pid]["plugin_name"], "db_slug": catalog[pid]["db_slug"]}
        for pid in profile["products"]
    ]

    return {
        "client_id": client_id,
        "profile_id": profile_id,
        "environment": env_id,
        "container_name": f"hermes-{instance}-{env_id}",
        "compose_project": f"hermes-{instance}-{env_id}",
        "data_dir": f"{env['data_root']}/{instance}",
        "postgres_container": env["postgres_container"],
        "postgres_host": env["postgres_host"],
        "postgres_port": env["postgres_port"],
        "telegram_bot_username": profile["telegram_bot_username"],
        "telegram_secret": profile["telegram_secret"],
        "databases": databases,
        "plugins": [s["plugin"] for s in plugin_sources],
        "plugin_sources": plugin_sources,
    }

if __name__ == "__main__":
    try:
        if len(sys.argv) == 2 and sys.argv[1] == "clients":
            for client_id, name in client_rows():
                print(f"{client_id}\t{name}")
        elif len(sys.argv) == 3 and sys.argv[1] == "environments":
            print("\n".join(environment_ids(sys.argv[2])))
        elif len(sys.argv) == 5 and sys.argv[1] == "plan":
            json.dump(plan(sys.argv[2], sys.argv[3], sys.argv[4]), sys.stdout, ensure_ascii=False)
            print()
        elif len(sys.argv) == 4 and sys.argv[1] == "profiles":
            print("\n".join(profile_ids(sys.argv[2], sys.argv[3])))
        else:
            raise SystemExit(
                "uso: inventory.py clients | environments <cliente> | "
                "plan <ambiente> <cliente> <profile> | profiles <ambiente> <cliente>"
            )
    except (KeyError, FileNotFoundError) as exc:
        raise SystemExit(exc.args[0] if exc.args else str(exc)) from None
