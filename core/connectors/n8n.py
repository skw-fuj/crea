"""The n8n automations layer — CREA's hands for anything WhatsApp.

The `crea's automations` pack (n8n + WAHA + vault-api, in Docker on this Mac)
runs the customer-facing WhatsApp booking assistant. It writes job, client and
lead notes into this same vault in CREA's own frontmatter, so the voice
assistant already sees every booking it takes.

This connector is the small path the other way: the voice assistant asking the
automations to *do* something — confirm a held booking, or send a customer a
one-off WhatsApp. It only ever calls localhost webhooks the pack exposes; it
never talks to WhatsApp itself.
"""
from __future__ import annotations

import json
import urllib.request

from .base import Connector, ConnectorError


class N8N(Connector):
    name = "n8n"
    how_to_connect = ("Run the automations pack: cd ~/crea/n8n && ./go-live.sh  "
                      "(brings up n8n + WAHA + vault-api in Docker)")
    console_url = "http://localhost:5678"
    docs_url = "https://github.com/skw-fuj/crea/blob/main/n8n/README.md"

    def _base(self) -> str:
        return (self.conf.get("base_url") or "http://localhost:5678").rstrip("/")

    def ready(self) -> bool:
        if self.conf.get("enabled") is False:
            return False
        try:
            req = urllib.request.Request(self._base() + "/healthz")
            with urllib.request.urlopen(req, timeout=4) as r:
                return r.status == 200
        except Exception:
            return False

    # ---------------------------------------------------------------- calls

    def _post(self, path: str, body: dict) -> dict:
        data = json.dumps(body).encode()
        req = urllib.request.Request(
            self._base() + path, data=data,
            headers={"Content-Type": "application/json"}, method="POST")
        return self._json(req, timeout=20)

    def book_confirm(self, ref: str, action: str = "confirm") -> dict:
        """Owner's decision on a held booking. action = confirm | decline.

        The automations create the real Acuity appointment (if Acuity is set up),
        tell the customer, and write the job note.
        """
        ref = "".join(c for c in str(ref).upper() if c.isalnum())
        if not ref:
            raise ConnectorError("no booking ref")
        return self._post("/webhook/crea-book-confirm",
                          {"action": action, "ref": ref})

    def message_client(self, phone: str = "", text: str = "",
                       job_ref: str = "") -> dict:
        """Send one WhatsApp to a customer, through the pack's single sender."""
        if not text.strip():
            raise ConnectorError("empty message")
        body = {"text": text}
        if phone:
            body["phone"] = "".join(c for c in str(phone) if c.isdigit())
        if job_ref:
            body["jobRef"] = job_ref
        return self._post("/webhook/crea-message-client", body)
