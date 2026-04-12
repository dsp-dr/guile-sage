#!/usr/bin/env python3
"""Generate synthetic PII test data for guardrail testing.

All data is faker-generated with seed=42 for reproducibility.
NONE of this is real personal data. The CC numbers are Luhn-valid
but from synthetic BIN ranges — not actual accounts.

Usage:
    python3 scripts/generate-test-pii.py > /tmp/test-pii.json
    python3 scripts/generate-test-pii.py --shell  # shell-friendly output
"""
import json
import sys
from faker import Faker

f = Faker()
Faker.seed(42)

data = {
    "emails": [f.email() for _ in range(3)],
    "credit_cards": [
        {"provider": f.credit_card_provider(), "number": f.credit_card_number()}
        for _ in range(4)
    ],
    "ssns": [f.ssn() for _ in range(3)],
    "names": [f.name() for _ in range(3)],
    "api_keys": {
        "aws": "AKIA" + f.pystr(min_chars=16, max_chars=16).upper(),
        "openai": "sk-proj-" + f.pystr(min_chars=40, max_chars=40),
        "github": "ghp_" + f.pystr(min_chars=36, max_chars=36),
    },
    "passwords": [
        f"POSTGRES_PASSWORD={f.password()}",
        f"REDIS_PASSWORD={f.password()}",
        f"JWT_SECRET=eyJhbGciOiJIUzI1NiJ9.{f.pystr(min_chars=20, max_chars=20)}.{f.pystr(min_chars=20, max_chars=20)}",
    ],
}

if "--shell" in sys.argv:
    print(f'TEST_EMAILS="{"; ".join(data["emails"])}"')
    print(f'TEST_CC="{data["credit_cards"][0]["number"]}"')
    print(f'TEST_SSN="{data["ssns"][0]}"')
    print(f'TEST_AWS_KEY="{data["api_keys"]["aws"]}"')
    print(f'TEST_OPENAI_KEY="{data["api_keys"]["openai"]}"')
    print(f'TEST_PASSWORD="{data["passwords"][0]}"')
else:
    print(json.dumps(data, indent=2))
