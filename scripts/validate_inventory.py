#!/usr/bin/env python3
from __future__ import annotations
import sys
from inventory import ID_RE, SLUG_RE, clients, db_for, environment, products

ENV_CODE = {"hml": "Hml", "prd": "Prd"}

def main() -> int:
    errors: list[str] = []
    catalog = products()
    seen_client_env: set[tuple[str, str]] = set()
    bot_usernames: set[str] = set()
    resources: set[tuple[str, str]] = set()
    slugs: dict[str, str] = {}

    for product_id, product in catalog.items():
        if not ID_RE.fullmatch(product_id):
            errors.append(f"produto inválido: {product_id}")
        if not product.get("plugin_name") or not product.get("repository"):
            errors.append(f"produto incompleto: {product_id}")
        slug = product.get("db_slug", "")
        if not SLUG_RE.fullmatch(slug):
            errors.append(f"{product_id}: db_slug inválido: {slug!r}")
        elif slug in slugs:
            errors.append(f"db_slug duplicado: {slug} ({slugs[slug]} e {product_id})")
        else:
            slugs[slug] = product_id

    for client in clients():
        client_meta = client.get("client", {})
        client_id, client_code = client_meta.get("id", ""), client_meta.get("code", "")
        subscriptions = set(client.get("subscriptions", []))
        deployed: set[str] = set()
        if not ID_RE.fullmatch(client_id):
            errors.append(f"cliente inválido: {client_id!r}")
        if subscriptions - catalog.keys():
            errors.append(f"{client_id}: produtos desconhecidos: {sorted(subscriptions - catalog.keys())}")

        for deployment in client.get("deployments", []):
            env_id = deployment.get("environment", "")
            if (client_id, env_id) in seen_client_env:
                errors.append(f"deployment duplicado: {client_id}/{env_id}")
            seen_client_env.add((client_id, env_id))
            try:
                environment(env_id)
            except FileNotFoundError:
                errors.append(f"{client_id}: ambiente inexistente: {env_id}")

            profile_ids: set[str] = set()
            for profile in deployment.get("profiles", []):
                profile_id = profile.get("id", "")
                if not ID_RE.fullmatch(profile_id):
                    errors.append(f"{client_id}/{env_id}: profile inválido: {profile_id!r}")
                if profile_id in profile_ids:
                    errors.append(f"{client_id}/{env_id}: profile duplicado: {profile_id}")
                profile_ids.add(profile_id)

                selected = set(profile.get("products", []))
                deployed |= selected
                if not selected:
                    errors.append(f"{client_id}/{env_id}/{profile_id}: nenhum produto")
                if not selected <= subscriptions:
                    errors.append(f"{client_id}/{env_id}/{profile_id}: produto não contratado: {sorted(selected - subscriptions)}")

                if not profile.get("telegram_secret"):
                    errors.append(f"{client_id}/{env_id}/{profile_id}: secret Telegram ausente")
                telegram_code = profile.get("telegram_code", "")
                env_code = ENV_CODE.get(env_id, env_id.title())
                expected_bot = f"TMHA_{client_code}_{telegram_code}_{env_code}_bot"
                actual_bot = profile.get("telegram_bot_username", "")
                if actual_bot != expected_bot:
                    errors.append(f"{client_id}/{env_id}/{profile_id}: bot fora do padrão; esperado {expected_bot}, recebido {actual_bot!r}")
                if actual_bot in bot_usernames:
                    errors.append(f"bot Telegram duplicado: {actual_bot}")
                bot_usernames.add(actual_bot)

            # Container único por cliente x ambiente; bancos/roles por produto x cliente.
            container = f"hermes-{client_id}-{env_id}"
            if ("container", container) in resources:
                errors.append(f"container duplicado: {container}")
            resources.add(("container", container))
            for product_id in deployment_products(deployment):
                if product_id not in catalog:
                    continue
                db = db_for(catalog[product_id], client_id)
                for field in ("database", "role"):
                    key = (field, db[field])
                    if key in resources:
                        errors.append(f"recurso duplicado: {field}={db[field]}")
                    resources.add(key)

        if subscriptions != deployed:
            errors.append(f"{client_id}: produto contratado sem deployment: {sorted(subscriptions - deployed)}")

    if errors:
        print("Inventário inválido:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"Inventário válido: {len(catalog)} produtos, {len(seen_client_env)} deployments")
    return 0

def deployment_products(deployment: dict) -> list[str]:
    out: list[str] = []
    for profile in deployment.get("profiles", []):
        for pid in profile.get("products", []):
            if pid not in out:
                out.append(pid)
    return out

if __name__ == "__main__":
    raise SystemExit(main())
