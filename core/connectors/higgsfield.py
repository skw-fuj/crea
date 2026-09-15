"""Higgsfield — AI-assisted generation for a delivered shoot.

Connell already pays for this. CREA's job is to hand a finished, verified shoot
folder over and record what came back, not to do the editing itself.

Higgsfield retired the bearer-token REST API this connector used to speak. There
is no API key to paste any more: the product authenticates through its own CLI
using OAuth 2.0 PKCE, and the token lives in the CLI's own credential store. So
this talks to the CLI rather than to api.higgsfield.ai, and "connected" now means
"the CLI is installed and holds a live token", which is something we can actually
check rather than infer from a string being present.
"""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

from .base import Connector, ConnectorError

CLI = "higgsfield"

SETUP = (
    "Higgsfield uses a CLI and OAuth now — there is no API key to paste.\n"
    "    1. npm i -g @higgsfield/cli\n"
    "    2. higgsfield auth login        (opens your browser)\n"
    "    3. higgsfield workspace list    then: higgsfield workspace set <id>\n"
    "  Optional companion skills:  npx skills add higgsfield-ai/skills"
)


class Higgsfield(Connector):
    name = "higgsfield"
    how_to_connect = ("Higgsfield authenticates through its own CLI, not an API key. "
                      "Run: higgsfield auth login  (see `crea connect higgsfield` "
                      "for the full three steps)")
    console_url = "https://higgsfield.ai/"
    docs_url = "https://higgsfield.ai/"

    # ------------------------------------------------------------------ cli

    def _bin(self) -> str | None:
        """Locate the CLI.

        launchd gives background services a PATH without ~/.local/bin, where npm
        puts global binaries, so fall back to the known install location rather
        than reporting a missing CLI that is sitting right there.
        """
        found = shutil.which(CLI)
        if found:
            return found
        candidate = Path.home() / ".local/bin" / CLI
        return str(candidate) if candidate.exists() else None

    def _run(self, *args: str, timeout: int = 120) -> str:
        exe = self._bin()
        if not exe:
            raise ConnectorError(f"the Higgsfield CLI is not installed.\n{SETUP}")
        proc = subprocess.run([exe, *args], capture_output=True, text=True,
                              timeout=timeout)
        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout or "").strip()
            raise ConnectorError(f"higgsfield {' '.join(args)}: {err[:300]}")
        return proc.stdout.strip()

    # --------------------------------------------------------------- status

    def ready(self) -> bool:
        """Installed, authenticated, and pointed at a workspace.

        Every one of those is a real check. A token with no workspace selected
        looks connected and then fails on the first command with "No workspace
        selected", which is exactly the kind of false green this file used to
        report when it only checked that an env var existed.
        """
        if not self._bin():
            return False
        try:
            if not self._run("auth", "token", timeout=30):
                return False
            self._run("account", "status", timeout=60)
            return True
        except Exception:
            return False

    def verify(self) -> dict:
        """Prove the connection by asking who we are and what credits remain."""
        if not self._bin():
            raise ConnectorError(f"the Higgsfield CLI is not installed.\n{SETUP}")
        if not self._run("auth", "token", timeout=30):
            raise ConnectorError(f"not signed in.\n{SETUP}")
        status = self._run("account", "status", timeout=60)
        return {"ok": True, "account": status}

    def workspaces(self) -> str:
        return self._run("workspace", "list", timeout=60)

    # ------------------------------------------------------------ delivery

    def submit_shoot(self, name: str, drive_folder_url: str,
                     preset: str | None = None) -> dict:
        """Record a shoot as ready for Higgsfield work.

        The old REST endpoint accepted a Drive URL and created a project. The
        CLI has no equivalent "import this folder" command — it generates from
        prompts and uploaded media — so there is nothing to call here that would
        genuinely hand a folder over.

        Rather than pretend, this raises. `deliver` already treats a Higgsfield
        failure as non-fatal: the shoot still reaches Drive and the editor is
        still told. Claiming success for doing nothing would be worse than
        saying plainly that this step is manual for now.
        """
        raise ConnectorError(
            "Higgsfield's CLI has no folder hand-off, so CREA cannot submit a "
            f"shoot automatically. {name} is uploaded and verified in Drive: "
            f"{drive_folder_url}\n"
            "  Generate from it with the CLI, e.g.:  higgsfield generate create "
            "--help")

    def generate(self, prompt: str, model: str | None = None,
                 extra: list[str] | None = None) -> dict:
        """Run a generation through the CLI and return whatever it reports."""
        args = ["generate", "create", "--prompt", prompt, "--json"]
        if model:
            args += ["--model", model]
        args += list(extra or [])
        out = self._run(*args, timeout=900)
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            return {"ok": True, "output": out}
