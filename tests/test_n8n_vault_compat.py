#!/usr/bin/env python3
"""The automations pack (n8n + vault-api) writes Job/Client/Lead notes straight
into this vault in CREA's own frontmatter. This test proves the voice side can
read every one of them back.

It runs the REAL vault-api/server.js against a throwaway vault, POSTs the same
payloads crea-11 / crea-02b send, then parses the resulting Markdown with the
same core.vault code the voice assistant uses.

    python3 tests/test_n8n_vault_compat.py
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SERVER = REPO / "n8n" / "vault-api" / "server.js"
sys.path.insert(0, str(REPO))
from core.vault import Vault, parse_dt  # noqa: E402

PORT = 5793


def _post(path: str, body: dict) -> dict:
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}{path}", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())


def main() -> int:
    assert SERVER.exists(), f"vault-api not found at {SERVER}"
    tmp = Path(tempfile.mkdtemp(prefix="crea-compat-"))
    kb = tmp / "knowledge"
    kb.mkdir()
    (kb / "crea-knowledge.md").write_text("# Cfilms\nPhotos $295. Video $450.\n")
    (kb / "pricing.json").write_text(json.dumps({
        "currency": "AUD", "minimum": 250, "round_to": 5,
        "packages": [{"name": "Video", "match": "video", "base": 450}],
        "per_bedroom": 15, "per_bathroom": 10, "per_extra_level": 60,
        "size_tiers": [{"max_sqm": 350, "add": 80}, {"max_sqm": 600, "add": 180}],
        "pool_addon": 60, "service_addons": {"drone": 150},
    }))

    env = {**os.environ, "VAULT_API_PORT": str(PORT), "VAULT_DIR": str(tmp / "vault"),
           "KNOWLEDGE_FILE": str(kb / "crea-knowledge.md"),
           "PRICING_FILE": str(kb / "pricing.json"),
           "PRICING_MODE": "calculator", "VAULT_PROFILE": "crea"}
    proc = subprocess.Popen(["node", str(SERVER)], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    failures = []
    try:
        for _ in range(50):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{PORT}/ping", timeout=1)
                break
            except Exception:
                time.sleep(0.1)
        else:
            print("vault-api did not start:", proc.stderr.read().decode()[:500])
            return 1

        # 1) a job note, the way crea-11 writes one after the owner confirms
        _post("/job", {
            "jobId": "WA-4A2", "client": "Jane Smith",
            "address": "40 Awaba St, Mosman, NSW",
            "datetime": "2026-09-19T10:00:00", "type": "Listing Video",
            "price": "$980", "phone": "61400111222", "email": "jane@example.com",
            "source": "whatsapp", "notes": "Side gate open. Pool + deck.",
            "status": "Booked"})

        # 2) a lead note, the way crea-02b writes one on a hand-off
        _post("/lead", {
            "from": "61400333444",
            "brief": {"service": "photos", "address": "9 Hill Rd", "bedrooms": 3,
                      "preferred_datetime": "next Thursday"},
            "status": "needs-human", "capturedAt": "2026-09-10T09:00:00Z"})

        # 3) the pricing calculator the assistant quotes from
        est = _post("/estimate", {"brief": {"service": "video and drone",
                    "bedrooms": 4, "bathrooms": 2, "levels": 2, "floor_sqm": 380,
                    "pool": True}})

        time.sleep(0.3)
        v = Vault(tmp / "vault")

        jobs = v.jobs()
        if not jobs:
            failures.append("core.vault.jobs() read nothing from the n8n-written Jobs/ folder")
        else:
            j = jobs[0]
            checks = {
                "type == job": j.get("type") == "job",
                "client parsed": j.get("client") == "Jane Smith",
                "fee is a number": isinstance(j.get("fee"), (int, float)) and j["fee"] == 980,
                "status in lifecycle": j.get("status") == "Booked",
                "shoot_at is ISO": parse_dt(j.get("shoot_at")) is not None,
                "tags is a list": isinstance(j.get("tags"), list),
            }
            for label, ok in checks.items():
                if not ok:
                    failures.append(f"job note: {label}  (got {j!r})")

        clients = v.clients()
        if not any(c.get("type") == "client" for c in clients):
            failures.append("core.vault.clients() did not read the n8n-written client note")

        leads = v.leads()
        if not leads:
            failures.append("core.vault.leads() read nothing from the n8n-written Leads/ folder")
        elif leads[0].get("type") != "lead":
            failures.append(f"lead note: type != lead  (got {leads[0]!r})")

        if est.get("mode") != "calculator" or not isinstance(est.get("price"), (int, float)):
            failures.append(f"/estimate calculator did not return a price: {est!r}")

        # the dashboard render must not choke on n8n-written notes
        try:
            v.init()
            v.render_dashboard()
        except Exception as e:
            failures.append(f"render_dashboard() crashed on n8n notes: {e!r}")

    finally:
        proc.terminate()
        proc.wait(timeout=5)

    if failures:
        print("FAIL — n8n/voice vault compatibility:")
        for f in failures:
            print("  -", f)
        return 1
    print("OK — every n8n-written note (job, client, lead) reads back through core.vault; "
          f"estimate ${est['price']} {est.get('currency')}; dashboard renders.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
