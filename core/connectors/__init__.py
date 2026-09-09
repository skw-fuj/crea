"""External services CREA talks to.

Every connector answers the same two questions honestly:

    ready()   — can I actually call this right now?
    status()  — what exactly is missing if not?

There is no "configured" state that isn't backed by a real credential. A
connector that has not been authenticated says so, and the skills that depend on
it decline to run rather than pretending. This is the difference between a
system that reports green and a system that works.
"""
from __future__ import annotations

from .acuity import Acuity
from .google import Google
from .whatsapp import WhatsApp
from .higgsfield import Higgsfield
from .apify import Apify
from .n8n import N8N

REGISTRY = {
    "acuity": Acuity,
    "google": Google,
    "whatsapp": WhatsApp,
    "higgsfield": Higgsfield,
    "apify": Apify,
    "n8n": N8N,
}


def load_all(cfg) -> dict:
    return {name: klass(cfg) for name, klass in REGISTRY.items()}


def status_all(cfg) -> dict:
    out = {}
    for name, conn in load_all(cfg).items():
        try:
            out[name] = conn.status()
        except Exception as e:
            out[name] = {"ready": False, "error": f"{type(e).__name__}: {e}"}
    return out
