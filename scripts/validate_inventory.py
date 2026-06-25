#!/usr/bin/env python3
from __future__ import annotations
import sys
from inventory import ID_RE, SLUG_RE, clients, db_for, environment, products

ENV_CODE = {"hml": "Hml", "prd": "Prd"}

def main() -> int:
    errors: list[str] = []
    catalog = products()
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

        seen_env: set[str] = set()
        for deployment in client.get("deployments", []):
            env_id = deployment.get("environment", "")
            if env_id in seen_env:
                errors.append(f"{client_id}: ambiente duplicado: {env_id}")
            seen_env.add(env_id)
            try:
                environment(env_id)
            except FileNotFoundError:
                errors.append(f"{client_id}: ambiente inexistente: {env_id}")

            profile_ids: set[str] = set()
            product_owner: dict[str, str] = {}   # produto -> profile (1 só por cliente/ambiente)
            for profile in deployment.get("profiles", []):
                profile_id = profile.get("id", "")
                if not ID_RE.fullmatch(profile_id):
                    errors.append(f"{client_id}/{env_id}: profile inválido: {profile_id!r}")
                if profile_id in profile_ids:
                    errors.append(f"{client_id}/{env_id}: profile duplicado: {profile_id}")
                profile_ids.add(profile_id)

                selected = profile.get("products", [])
                deployed |= set(selected)
                if not selected:
                    errors.append(f"{client_id}/{env_id}/{profile_id}: nenhum produto")
                if not set(selected) <= subscriptions:
                    errors.append(f"{client_id}/{env_id}/{profile_id}: produto não contratado: {sorted(set(selected) - subscriptions)}")
                for pid in selected:
                    if pid in product_owner:
                        errors.append(f"{client_id}/{env_id}: produto {pid} em 2 profiles ({product_owner[pid]} e {profile_id}); um produto = um container")
                    product_owner[pid] = profile_id

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

                dashboard = profile.get("dashboard", {})
                if dashboard:
                    if not isinstance(dashboard, dict):
                        errors.append(f"{client_id}/{env_id}/{profile_id}: dashboard deve ser objeto")
                    else:
                        enabled = dashboard.get("enabled", False)
                        insecure = dashboard.get("insecure", False)
                        host = dashboard.get("host", "0.0.0.0")
                        basic_auth_username = dashboard.get("basic_auth_username", "")
                        basic_auth_password_secret = dashboard.get("basic_auth_password_secret", "")
                        if not isinstance(enabled, bool):
                            errors.append(f"{client_id}/{env_id}/{profile_id}: dashboard.enabled deve ser booleano")
                        if not isinstance(insecure, bool):
                            errors.append(f"{client_id}/{env_id}/{profile_id}: dashboard.insecure deve ser booleano")
                        if not isinstance(host, str) or not host:
                            errors.append(f"{client_id}/{env_id}/{profile_id}: dashboard.host deve ser string não vazia")
                        if basic_auth_username and not isinstance(basic_auth_username, str):
                            errors.append(f"{client_id}/{env_id}/{profile_id}: dashboard.basic_auth_username deve ser string")
                        if basic_auth_password_secret and not isinstance(basic_auth_password_secret, str):
                            errors.append(f"{client_id}/{env_id}/{profile_id}: dashboard.basic_auth_password_secret deve ser string")

                whatsapp = profile.get("whatsapp", {})
                if whatsapp:
                    if not isinstance(whatsapp, dict):
                        errors.append(f"{client_id}/{env_id}/{profile_id}: whatsapp deve ser objeto")
                    else:
                        enabled = whatsapp.get("enabled", False)
                        mode = whatsapp.get("mode", "bot")
                        bridge_port = whatsapp.get("bridge_port", 3000)
                        bridge_script = whatsapp.get("bridge_script", "/opt/hermes/scripts/whatsapp-bridge/bridge.js")
                        session_path = whatsapp.get("session_path", "/opt/data/whatsapp/session")
                        allowed_users_secret = whatsapp.get("allowed_users_secret", "")
                        if not isinstance(enabled, bool):
                            errors.append(f"{client_id}/{env_id}/{profile_id}: whatsapp.enabled deve ser booleano")
                        if mode not in {"bot", "self-chat"}:
                            errors.append(f"{client_id}/{env_id}/{profile_id}: whatsapp.mode deve ser bot ou self-chat")
                        if not isinstance(bridge_port, int) or not (1024 <= bridge_port <= 65535):
                            errors.append(f"{client_id}/{env_id}/{profile_id}: whatsapp.bridge_port deve ser porta TCP válida")
                        if not isinstance(bridge_script, str) or not bridge_script.startswith("/"):
                            errors.append(f"{client_id}/{env_id}/{profile_id}: whatsapp.bridge_script deve ser caminho absoluto")
                        if not isinstance(session_path, str) or not session_path.startswith("/"):
                            errors.append(f"{client_id}/{env_id}/{profile_id}: whatsapp.session_path deve ser caminho absoluto")
                        if enabled and (not isinstance(allowed_users_secret, str) or not allowed_users_secret):
                            errors.append(f"{client_id}/{env_id}/{profile_id}: whatsapp.allowed_users_secret é obrigatório quando habilitado")

                display = profile.get("display", {})
                if display:
                    if not isinstance(display, dict):
                        errors.append(f"{client_id}/{env_id}/{profile_id}: display deve ser objeto")
                    else:
                        platforms = display.get("platforms", {})
                        if platforms and not isinstance(platforms, dict):
                            errors.append(f"{client_id}/{env_id}/{profile_id}: display.platforms deve ser objeto")
                        elif isinstance(platforms, dict):
                            for platform_id, platform_display in platforms.items():
                                if not ID_RE.fullmatch(platform_id):
                                    errors.append(f"{client_id}/{env_id}/{profile_id}: display.platforms tem plataforma invalida: {platform_id!r}")
                                    continue
                                if not isinstance(platform_display, dict):
                                    errors.append(f"{client_id}/{env_id}/{profile_id}: display.platforms.{platform_id} deve ser objeto")
                                    continue
                                unknown = set(platform_display) - {"tool_progress"}
                                if unknown:
                                    errors.append(f"{client_id}/{env_id}/{profile_id}: display.platforms.{platform_id} tem chaves nao suportadas: {sorted(unknown)}")
                                tool_progress = platform_display.get("tool_progress")
                                if tool_progress is not None and tool_progress not in {"off", "new", "all", "verbose"}:
                                    errors.append(f"{client_id}/{env_id}/{profile_id}: display.platforms.{platform_id}.tool_progress deve ser off, new, all ou verbose")

                # Container único por profile; bancos/roles por produto x cliente.
                container = f"hermes-{client_id}-{profile_id}-{env_id}"
                if ("container", container) in resources:
                    errors.append(f"container duplicado: {container}")
                resources.add(("container", container))
                for pid in selected:
                    if pid not in catalog:
                        continue
                    db = db_for(catalog[pid], client_id)
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
    profiles = sum(len(d.get("profiles", [])) for c in clients() for d in c.get("deployments", []))
    print(f"Inventário válido: {len(catalog)} produtos, {len(bot_usernames)} profiles/containers ({profiles} no total)")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
