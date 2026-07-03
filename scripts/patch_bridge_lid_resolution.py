#!/usr/bin/env python3
"""
Patch bridge.js to resolve a WhatsApp LID sender to the real phone number.

WhatsApp addresses non-contacts by LID (``<digits>@lid``), which hides the phone
number. The stock bridge emits the LID digits as the sender identity, so any
downstream logic keyed on the phone number (TaskMe, allowlists, etc.) fails to
match the person.

Baileys 7.x already carries the phone: the decoded message key exposes
``participantAlt`` / ``remoteJidAlt`` (a ``@s.whatsapp.net`` phone JID when the
addressing mode is ``lid``), and ``sock.signalRepository.lidMapping.getPNForLID``
returns the phone JID from the LID<->PN store Baileys maintains.

This patch rewrites the sender derivation so that, when the sender is a ``@lid``,
the bridge resolves it to the phone JID (alt field first, LID store as fallback).
If it cannot be resolved, the ``@lid`` is kept unchanged (no worse than before;
plugins may onboard it).

Cross-product: identity is a Hermes-core concern, so this lives in hermes-infra
and is applied by deploy-instance.sh to every WhatsApp-enabled profile.

Idempotent. Run:
    python3 scripts/patch_bridge_lid_resolution.py --bridge /path/to/bridge.js
"""
import argparse
import os
import subprocess
import sys

MARKER = 'signalRepository?.lidMapping?.getPNForLID'

ANCHOR = (
    "      const senderId = msg.key.participant || chatId;\n"
    "      const isGroup = chatId.endsWith('@g.us');\n"
    "      const senderNumber = senderId.replace(/@.*/, '');"
)

REPLACEMENT = (
    "      let senderId = msg.key.participant || chatId;\n"
    "      const isGroup = chatId.endsWith('@g.us');\n"
    "      // LID -> phone: non-contacts are addressed by @lid (phone hidden).\n"
    "      // Recover the real phone JID so downstream identity (keyed by phone)\n"
    "      // matches. Prefer the alt address on the key; fall back to Baileys'\n"
    "      // LID<->PN store. If unresolved, keep the @lid (plugins may onboard).\n"
    "      if (typeof senderId === 'string' && senderId.endsWith('@lid')) {\n"
    "        const altJid = msg.key.participantAlt || msg.key.remoteJidAlt || '';\n"
    "        if (altJid && altJid.endsWith('@s.whatsapp.net')) {\n"
    "          senderId = altJid;\n"
    "        } else {\n"
    "          try {\n"
    "            const pn = await sock.signalRepository?.lidMapping?.getPNForLID?.(senderId);\n"
    "            if (pn && String(pn).endsWith('@s.whatsapp.net')) senderId = String(pn);\n"
    "          } catch {}\n"
    "        }\n"
    "      }\n"
    "      const senderNumber = senderId.replace(/@.*/, '');"
)


def patch(bridge_path):
    with open(bridge_path, 'r', encoding='utf-8') as f:
        src = f.read()

    if MARKER in src:
        print(f'[patch_bridge_lid_resolution] Already patched: {bridge_path}')
        return False

    if ANCHOR not in src:
        print('[patch_bridge_lid_resolution] ERROR: sender-derivation anchor not found')
        print('  (Hermes may have updated bridge.js — review the patch manually)')
        sys.exit(1)

    src = src.replace(ANCHOR, REPLACEMENT, 1)

    with open(bridge_path, 'w', encoding='utf-8') as f:
        f.write(src)

    print(f'[patch_bridge_lid_resolution] Successfully patched {bridge_path}')
    return True


def verify_syntax(bridge_path):
    node = None
    for candidate in (os.path.expanduser('~/.hermes/node/bin/node'), 'node'):
        if candidate == 'node' or os.path.exists(candidate):
            node = candidate
            break
    try:
        result = subprocess.run([node, '--check', bridge_path],
                                capture_output=True, text=True)
    except FileNotFoundError:
        print('[patch_bridge_lid_resolution] node not found, skipping syntax check.')
        return
    if result.returncode != 0:
        print('[patch_bridge_lid_resolution] SYNTAX ERROR after patch:')
        print(result.stderr)
        sys.exit(1)
    print('[patch_bridge_lid_resolution] Syntax OK')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bridge', required=True, help='Path to bridge.js')
    args = parser.parse_args()
    patch(args.bridge)
    verify_syntax(args.bridge)
