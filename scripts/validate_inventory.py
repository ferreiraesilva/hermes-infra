#!/usr/bin/env python3
from __future__ import annotations
import sys
from inventory import ID_RE, clients, derived, environment, products

def main() -> int:
    errors, catalog, seen, resources = [], products(), set(), set()
    for product_id, product in catalog.items():
        if not ID_RE.fullmatch(product_id): errors.append(f"produto inválido: {product_id}")
        if not product.get("plugin_name") or not product.get("repository"): errors.append(f"produto incompleto: {product_id}")
    for client in clients():
        client_id = client.get("client", {}).get("id", "")
        subscriptions, deployed = set(client.get("subscriptions", [])), set()
        if not ID_RE.fullmatch(client_id): errors.append(f"cliente inválido: {client_id!r}")
        if subscriptions - catalog.keys(): errors.append(f"{client_id}: produtos desconhecidos: {sorted(subscriptions-catalog.keys())}")
        for deployment in client.get("deployments", []):
            deployment_id, env_id = deployment.get("id", ""), deployment.get("environment", "")
            if not ID_RE.fullmatch(deployment_id): errors.append(f"{client_id}: deployment inválido: {deployment_id!r}")
            if (env_id, deployment_id) in seen: errors.append(f"deployment duplicado: {env_id}/{deployment_id}")
            seen.add((env_id, deployment_id))
            try: environment(env_id)
            except FileNotFoundError: errors.append(f"{deployment_id}: ambiente inexistente: {env_id}")
            selected = set(deployment.get("products", [])); deployed |= selected
            if not selected: errors.append(f"{deployment_id}: nenhum produto")
            if not selected <= subscriptions: errors.append(f"{deployment_id}: produto não contratado: {sorted(selected-subscriptions)}")
            if not deployment.get("telegram_secret"): errors.append(f"{deployment_id}: secret Telegram ausente")
            for field in ("container_name", "database_name", "database_role"):
                value = derived(client, deployment)[field]
                resource_key = (field, value)
                if resource_key in resources: errors.append(f"recurso duplicado: {field}={value}")
                resources.add(resource_key)
        if subscriptions != deployed: errors.append(f"{client_id}: produto contratado sem deployment: {sorted(subscriptions-deployed)}")
    if errors:
        print("Inventário inválido:", file=sys.stderr)
        for error in errors: print(f"- {error}", file=sys.stderr)
        return 1
    print(f"Inventário válido: {len(catalog)} produtos, {len(seen)} deployments")
    return 0

if __name__ == "__main__": raise SystemExit(main())
