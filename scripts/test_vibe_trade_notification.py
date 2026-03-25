#!/usr/bin/env python3
"""
Simple Vibe trade notification smoke test.

This sends a trade-style event to:
  POST /api/agents/:identifier/events

It uses only the Python standard library so it can run anywhere.
"""

from __future__ import annotations

import argparse
import json
import os
import runpy
import sys
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone


DEFAULT_TRADE_SETTINGS_PATH = "/Users/mohammadshayani/tradeai/trading_robot/config/settings.py"


def load_trade_settings(path: str | None) -> dict:
    if not path:
        return {}

    trimmed = path.strip()
    if not trimmed or not os.path.exists(trimmed):
        return {}

    try:
        namespace = runpy.run_path(trimmed)
    except Exception:
        return {}

    settings = namespace.get("SETTINGS")
    return settings if isinstance(settings, dict) else {}


def normalize_api_base_url(value: str | None) -> str | None:
    if not value:
        return None

    trimmed = value.strip().rstrip("/")
    marker = "/api/agents/"
    if marker in trimmed:
      return trimmed.split(marker, 1)[0]
    return trimmed


def resolve_string(*values: object) -> str | None:
    for value in values:
        if value is None:
            continue
        text = str(value).strip()
        if text:
            return text
    return None


def parse_args() -> argparse.Namespace:
    default_settings = load_trade_settings(
        os.getenv("TRADE_SETTINGS_PATH") or DEFAULT_TRADE_SETTINGS_PATH
    )
    vibe_settings = default_settings.get("vibe_settings") if isinstance(default_settings, dict) else {}
    vibe_settings = vibe_settings if isinstance(vibe_settings, dict) else {}

    parser = argparse.ArgumentParser(description="Send a test trade notification to Vibe.")
    parser.add_argument(
        "--settings-path",
        default=os.getenv("TRADE_SETTINGS_PATH") or DEFAULT_TRADE_SETTINGS_PATH,
        help="Path to the trade settings.py file",
    )
    parser.add_argument(
        "--api-base-url",
        default=resolve_string(
            os.getenv("VIBE_API_BASE_URL"),
            normalize_api_base_url(vibe_settings.get("api_base_url")),
        ),
    )
    parser.add_argument(
        "--agent-identifier",
        default=resolve_string(
            os.getenv("VIBE_AGENT_IDENTIFIER"),
            vibe_settings.get("agent_identifier"),
        ),
    )
    parser.add_argument(
        "--agent-secret",
        default=resolve_string(
            os.getenv("VIBE_AGENT_SECRET"),
            vibe_settings.get("agent_secret"),
        ),
    )
    parser.add_argument(
        "--destination-chat-id",
        default=resolve_string(
            os.getenv("VIBE_DESTINATION_CHAT_ID"),
            vibe_settings.get("destination_chat_id"),
        ),
    )
    parser.add_argument(
        "--source",
        default=resolve_string(
            os.getenv("VIBE_SOURCE"),
            vibe_settings.get("source"),
            "desktop_trade",
        ),
    )
    parser.add_argument("--symbol", default="EURUSD")
    parser.add_argument("--action", choices=["open", "close", "update"], default="open")
    parser.add_argument("--ticket-id", default="999001")
    parser.add_argument("--price", type=float, default=1.0825)
    parser.add_argument("--sl", type=float, default=1.0795)
    parser.add_argument("--tp", type=float, default=1.0885)
    parser.add_argument("--volume", type=float, default=0.10)
    parser.add_argument("--confidence", type=float, default=78.0)
    parser.add_argument(
        "--timeout",
        type=float,
        default=float(
            resolve_string(
                os.getenv("VIBE_TIMEOUT_SECONDS"),
                vibe_settings.get("timeout_seconds"),
                "15",
            )
        ),
    )
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def require(value: str | None, flag: str) -> str:
    if value and str(value).strip():
        return str(value).strip()
    raise SystemExit(f"Missing required value: {flag}")


def build_payload(args: argparse.Namespace) -> dict:
    event_type = {
        "open": "trade.opened",
        "close": "trade.closed",
        "update": "trade.updated",
    }[args.action]

    title = f"{args.action.upper()} {args.symbol}"
    text = (
        f"{args.symbol} {args.action.upper()} at {args.price:.5f} "
        f"(SL {args.sl:.5f}, TP {args.tp:.5f}, volume {args.volume:.2f})"
    )

    payload = {
        "eventId": f"trade_test_{uuid.uuid4()}",
        "eventType": event_type,
        "threadKey": f"trade_{args.ticket_id}",
        "source": args.source,
        "title": title,
        "text": text,
        "data": {
            "action": args.action,
            "symbol": args.symbol,
            "ticket_id": args.ticket_id,
            "trade_id": args.ticket_id,
            "price": args.price,
            "sl": args.sl,
            "tp": args.tp,
            "volume": args.volume,
            "confidence": args.confidence,
        },
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }

    if args.destination_chat_id:
        payload["destinationChatId"] = args.destination_chat_id

    return payload


def send_event(args: argparse.Namespace, payload: dict) -> int:
    base_url = require(args.api_base_url, "--api-base-url or VIBE_API_BASE_URL")
    agent_identifier = require(args.agent_identifier, "--agent-identifier or VIBE_AGENT_IDENTIFIER")
    agent_secret = require(args.agent_secret, "--agent-secret or VIBE_AGENT_SECRET")

    url = f"{base_url.rstrip('/')}/api/agents/{agent_identifier}/events"
    body = json.dumps(payload).encode("utf-8")

    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "X-Vibe-Agent-Secret": agent_secret,
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=args.timeout) as response:
            text = response.read().decode("utf-8", errors="replace")
            print(f"HTTP {response.status}")
            print(text)
            return 0 if 200 <= response.status < 300 else 1
    except urllib.error.HTTPError as exc:
        text = exc.read().decode("utf-8", errors="replace")
        print(f"HTTP {exc.code}")
        print(text)
        return 1
    except Exception as exc:  # noqa: BLE001
        print(f"Request failed: {exc}")
        return 1


def main() -> int:
    args = parse_args()
    payload = build_payload(args)

    if args.dry_run:
        print(json.dumps(payload, indent=2))
        return 0

    return send_event(args, payload)


if __name__ == "__main__":
    sys.exit(main())
