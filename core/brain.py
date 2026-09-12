"""CREA's brain — the thing that understands a request and decides what to do.

The build plan puts Hermes at the orchestration layer: it runs the skills, owns
the cron daemon, and holds the model connection. CREA therefore shells out to
Hermes rather than talking to a model directly, so scheduled/autonomous work and
interactive voice work go through one brain with one config.

Free by default: Hermes is pointed at a local Ollama model, so the demo costs
nothing and needs no API key. A paid model is a Hermes-level swap, not a CREA
change.
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

SYSTEM_PREAMBLE = """You are CREA, the AI adviser for Cfilms, a real estate
photography and video business in north-west Sydney. You are speaking aloud, so
answer in short spoken sentences — no markdown, no lists, no headings. Be
concrete and brief. If you do not know something, say so plainly.

Answer only from what you are given below. If the answer is not there, say you
do not have it — never guess a reason why, and never claim a service is
disconnected or unavailable, because you cannot see connection state from
here."""


class BrainError(RuntimeError):
    pass


class HermesBrain:
    def __init__(self, model: str | None = None, provider: str | None = None,
                 timeout: int = 300):
        self.binary = shutil.which("hermes") or str(Path.home() / ".local/bin/hermes")
        self.model, self.provider, self.timeout = model, provider, timeout

    def health(self) -> dict:
        """Real check: is the binary there and does Hermes have a provider?"""
        if not Path(self.binary).exists():
            return {"provider": "hermes", "reachable": False,
                    "error": "hermes binary not found"}
        try:
            out = subprocess.run([self.binary, "status"], capture_output=True,
                                 text=True, timeout=60).stdout
        except Exception as e:
            return {"provider": "hermes", "reachable": False, "error": str(e)}
        configured = "(not set)" not in out.split("Model:")[1][:40] if "Model:" in out else False
        return {"provider": "hermes", "reachable": True, "model_configured": configured}

    def ask(self, prompt: str, context: str = "") -> str:
        full = SYSTEM_PREAMBLE
        if context:
            full += f"\n\nWhat you know right now:\n{context}"
        full += f"\n\nThe principal said: {prompt}"

        cmd = [self.binary, "-z", full, "--cli"]
        if self.model:
            cmd += ["-m", self.model]
        if self.provider:
            cmd += ["--provider", self.provider]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=self.timeout)
        except subprocess.TimeoutExpired as e:
            raise BrainError(f"Hermes timed out after {self.timeout}s") from e
        if proc.returncode != 0:
            raise BrainError(f"Hermes failed: {(proc.stderr or proc.stdout)[-400:]}")
        return proc.stdout.strip()


def make_brain(cfg, timeout: int = 300) -> HermesBrain:
    if cfg.get("brain.provider") != "hermes":
        raise BrainError(f"unknown brain provider: {cfg.get('brain.provider')}")
    return HermesBrain(model=cfg.get("brain.model", None),
                       provider=cfg.get("brain.hermes_provider", None),
                       timeout=timeout)
