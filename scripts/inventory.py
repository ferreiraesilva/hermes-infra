#!/usr/bin/env python3
from __future__ import annotations
import json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ID_RE = re.compile(r"^[a-z][a-z0-9-]{1,62}$")

def load_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)

def products() -> dict[str, dict]:
    return {p["id"]: p for path in sorted((ROOT / "catalog/products").glob("*.json")) for p in [load_json(path)]}

def clients() -> list[dict]:
    return [load_json(path) for path in sorted((ROOT / "clients").glob("*.json"))]

def environment(env_id: str) -> dict:
    return load_json(ROOT / "environments" / env_id / "environment.json")

def find_deployment(env_id: str, deployment_id: str) -> tuple[dict, dict]:
    for client in clients():
        for deployment in client["deployments"]:
            if deployment["environment"] == env_id and deployment["id"] == deployment_id:
                return client, deployment
    raise KeyError(f"deployment não encontrado: {env_id}/{deployment_id}")

def derived(client: dict, deployment: dict) -> dict:
    env_id, deployment_id = deployment["environment"], deployment["id"]
    db_id = f"{deployment_id.replace('-', '_')}_{env_id}"
    return {
        "client_id": client["client"]["id"], "deployment_id": deployment_id,
        "environment": env_id, "container_name": f"hermes-{deployment_id}-{env_id}",
        "compose_project": f"hermes-{deployment_id}-{env_id}",
        "database_name": f"hermes_{db_id}", "database_role": f"hermes_{db_id}"
    }

def shell(env_id: str, deployment_id: str) -> None:
    client, deployment = find_deployment(env_id, deployment_id)
    env = environment(env_id)
    data = derived(client, deployment) | {
        "data_root": env["data_root"], "runtime_root": env["runtime_root"],
        "postgres_container": env["postgres_container"], "postgres_host": env["postgres_host"],
        "postgres_port": str(env["postgres_port"]), "products": ",".join(deployment["products"])
    }
    for key, value in data.items():
        if not re.fullmatch(r"[A-Za-z0-9_./,:-]+", value):
            raise ValueError(f"valor inseguro para shell: {key}")
        print(f"{key.upper()}={value}")

if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "shell": shell(sys.argv[2], sys.argv[3])
    else: raise SystemExit("uso: inventory.py shell <ambiente> <deployment>")
