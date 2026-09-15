"""`crea connect` — link the outside services, one at a time.

Everything here is designed for someone who is not a developer. Each service
asks the fewest questions it can, verifies the answer against the real API
before saving it, and says plainly what went wrong when it fails.

Secrets go to ~/crea/var/env with 0600 permissions and are loaded into the
environment by the CLI. They are never written into crea.config.json, so that
file stays safe to share, commit or paste.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.parse
from pathlib import Path

SERVICES = ("acuity", "google", "whatsapp", "higgsfield", "apify", "editor", "calls")


# ------------------------------------------------------------------ env file

def env_path(cfg) -> Path:
    return Path(cfg.get("paths.root")) / "var/env"


def load_env(cfg) -> None:
    p = env_path(cfg)
    if not p.exists():
        return
    for line in p.read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip())


def set_env(cfg, key: str, value: str) -> None:
    p = env_path(cfg)
    p.parent.mkdir(parents=True, exist_ok=True)
    lines = [l for l in (p.read_text().splitlines() if p.exists() else [])
             if not l.startswith(f"{key}=")]
    lines.append(f"{key}={value}")
    p.write_text("\n".join(lines) + "\n")
    p.chmod(0o600)
    os.environ[key] = value


def set_config(cfg, dotted: str, value) -> None:
    path = Path(cfg.get("paths.root")) / "crea.config.json"
    data = json.loads(path.read_text())
    node = data
    parts = dotted.split(".")
    for part in parts[:-1]:
        node = node.setdefault(part, {})
    node[parts[-1]] = value
    path.write_text(json.dumps(data, indent=2))


# ------------------------------------------------------------------- prompts

def ask(label: str, secret: bool = False) -> str:
    if secret:
        import getpass
        return getpass.getpass(f"  {label}: ").strip()
    return input(f"  {label}: ").strip()


def head(title: str, blurb: str = "") -> None:
    print(f"\n\033[1m{title}\033[0m")
    if blurb:
        print(f"  {blurb}")


def open_page(url: str, label: str = "") -> None:
    """Open the exact page the credential lives on.

    Nobody should have to go hunting through a settings menu they have never
    seen. CREA opens the right page and prints the address as a fallback.
    """
    if not url:
        return
    print(f"  Opening {label or url}")
    subprocess.run(["open", url], capture_output=True)
    print(f"  If it didn't open: {url}\n")


# ------------------------------------------------------------------ services

def connect_acuity(cfg) -> bool:
    head("Acuity Scheduling",
         "Left sidebar > Business Settings > Integrations > API > view credentials.")
    open_page("https://secure.acuityscheduling.com/", "Acuity")
    uid = ask("User ID (the numeric one)")
    key = ask("API Key", secret=True)
    if not (uid and key):
        print("  skipped.")
        return False
    set_env(cfg, "ACUITY_USER_ID", uid)
    set_env(cfg, "ACUITY_API_KEY", key)
    from .connectors.acuity import Acuity
    try:
        me = Acuity(cfg).verify()
        print(f"  connected to {me.get('business') or me.get('email')}.")
        return True
    except Exception as e:
        print(f"  that didn't work: {e}")
        print("  Double-check you copied the API Key and not the Client ID.")
        return False


def connect_google(cfg) -> bool:
    head("Google (Calendar, Drive, Docs)",
         "This opens a browser once so you can approve access.")
    print("  You need an OAuth client. In Google Cloud Console:")
    print("    APIs & Services > Credentials > Create credentials")
    print("    > OAuth client ID > Application type: Desktop app")
    print("  If Tris set one up for you already, just paste those two values.\n")
    open_page("https://console.cloud.google.com/apis/credentials", "Google Cloud Console")
    cid = ask("Client ID")
    csec = ask("Client secret", secret=True)
    if not (cid and csec):
        print("  skipped.")
        return False

    from .connectors.google import SCOPES, TOKEN_URL

    # Google blocked the out-of-band flow (urn:ietf:wg:oauth:2.0:oob) for every
    # remaining client on 31 January 2023 — it returns a user-facing "this app is
    # blocked" page, so there is no code to paste back and the connect can never
    # complete. The documented replacement for a desktop app is the loopback
    # flow: bind a throwaway local server, let Google redirect the browser to it
    # with the code, and read it off the request. Port 0 asks the OS for a free
    # port, so nothing collides with n8n, Ollama or the voice service.
    # https://developers.google.com/identity/protocols/oauth2/resources/oob-migration
    import http.server
    import socketserver
    import threading
    import urllib.request

    caught: dict[str, str] = {}

    class _Catch(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802 - name fixed by BaseHTTPRequestHandler
            parsed = urllib.parse.urlparse(self.path)
            params = urllib.parse.parse_qs(parsed.query)
            caught.update({k: v[0] for k, v in params.items()})
            body = (b"<html><body style='font:16px -apple-system;padding:3em'>"
                    b"<h2>CREA is connected.</h2>"
                    b"<p>You can close this tab and go back to the terminal.</p>"
                    b"</body></html>")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass  # the terminal is the user's; don't scribble request logs on it

    httpd = socketserver.TCPServer(("127.0.0.1", 0), _Catch)
    port = httpd.server_address[1]
    redirect_uri = f"http://127.0.0.1:{port}"

    print(f"\n  Add this to your OAuth client's Authorised redirect URIs:")
    print(f"    {redirect_uri}")
    print("  (Desktop-app clients usually accept any 127.0.0.1 port already.)")

    q = urllib.parse.urlencode({
        "client_id": cid, "redirect_uri": redirect_uri,
        "response_type": "code", "scope": " ".join(SCOPES),
        "access_type": "offline", "prompt": "consent"})
    url = f"https://accounts.google.com/o/oauth2/v2/auth?{q}"
    print("\n  Opening your browser. Approve access — the code comes back on its own.")
    subprocess.run(["open", url], capture_output=True)
    print(f"  If it didn't open: {url}\n")
    print("  Waiting for Google (Ctrl-C to give up)...")

    t = threading.Thread(target=httpd.handle_request, daemon=True)
    t.start()
    t.join(timeout=300)
    httpd.server_close()

    if "error" in caught:
        print(f"  Google refused: {caught['error']}")
        return False
    code = caught.get("code")
    if not code:
        print("  timed out waiting for the approval. Run this again when you're ready.")
        return False
    print("  got the approval.")

    data = urllib.parse.urlencode({
        "code": code, "client_id": cid, "client_secret": csec,
        "redirect_uri": redirect_uri,
        "grant_type": "authorization_code"}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(TOKEN_URL, data=data),
                                    timeout=30) as r:
            tok = json.loads(r.read())
    except Exception as e:
        print(f"  that didn't work: {e}")
        return False
    if "refresh_token" not in tok:
        print("  Google didn't return a refresh token. Try again and make sure you "
              "approve rather than reuse a previous approval.")
        return False

    import time
    tok.update({"client_id": cid, "client_secret": csec,
                "expires_at": time.time() + int(tok.get("expires_in", 3600))})
    p = Path(cfg.get("paths.root")) / "var/google-token.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(tok, indent=2))
    p.chmod(0o600)

    from .connectors.google import Google
    try:
        n = len(Google(cfg).events(days=7))
        print(f"  connected. {n} event(s) in your next week.")
        return True
    except Exception as e:
        print(f"  saved, but a test call failed: {e}")
        return False


def connect_whatsapp(cfg) -> bool:
    head("WhatsApp",
         "A QR code will appear. On your phone: WhatsApp -> Settings -> "
         "Linked Devices -> Link a Device, and scan it.")
    print("  Your number stays a normal WhatsApp number. Nothing is migrated.")
    from .connectors.whatsapp import WhatsApp
    w = WhatsApp(cfg)
    try:
        w.pair()
    except Exception as e:
        print(f"  couldn't start pairing: {e}")
        return False
    if w.ready():
        print("  paired.")
        return True
    print("  pairing didn't complete. Run this again when you're ready.")
    return False


def connect_higgsfield(cfg) -> bool:
    # Higgsfield retired its bearer-token API. There is no key to paste: the
    # product ships a CLI that authenticates over OAuth and stores the token
    # itself, so all CREA can do is check the CLI is installed, signed in and
    # pointed at a workspace — and say exactly which of those is missing.
    head("Higgsfield", "Higgsfield uses a CLI and a browser sign-in, not an API key.")
    from .connectors.higgsfield import Higgsfield, SETUP
    h = Higgsfield(cfg)

    if not h._bin():
        print("  The Higgsfield CLI isn't installed yet.\n")
        print(f"  {SETUP}\n")
        print("  Run those three, then: crea connect higgsfield")
        return False

    try:
        info = h.verify()
    except Exception as e:
        print(f"  the CLI is installed but not usable yet: {e}\n")
        print(f"  {SETUP}")
        return False

    print(f"  connected — {info['account']}")
    try:
        print("\n  Workspaces:")
        for line in h.workspaces().splitlines():
            print(f"    {line}")
    except Exception:
        pass
    return True


def connect_apify(cfg) -> bool:
    head("Apify", "Settings > Integrations > Personal API token.")
    open_page("https://console.apify.com/settings/integrations", "Apify Console")
    tok = ask("API token", secret=True)
    if not tok:
        print("  skipped.")
        return False
    set_env(cfg, "APIFY_TOKEN", tok)
    ds = ask("Dataset ID of your listings scraper (Enter to skip)")
    if ds:
        set_config(cfg, "integrations.apify.dataset_id", ds)
    from .connectors.apify import Apify
    try:
        me = Apify(cfg).verify()
        print(f"  connected as {me.get('username') or 'ok'}.")
        return True
    except Exception as e:
        print(f"  that didn't work: {e}")
        return False


def connect_editor(cfg) -> bool:
    head("Your editor", "The number CREA messages when a shoot is ready.")
    name = ask("Editor's name") or "Editor"
    num = ask("WhatsApp number, with country code (e.g. +61412345678)")
    if not num:
        print("  skipped.")
        return False
    set_config(cfg, "integrations.whatsapp.editor_handle", num)
    set_config(cfg, "integrations.whatsapp.editor_name", name)
    print(f"  {name} will be told when a shoot lands.")
    return True


def connect_calls(cfg) -> bool:
    head("Call recording",
         "NSW requires every party to a call to consent to being recorded.")
    print("  CREA plays a disclosure before it keeps any audio, and deletes the")
    print("  recording once it has read the booking out of it.\n")
    current = cfg.get("call_recording.disclosure_text", "")
    print(f"  Current wording: \"{current}\"\n")
    print("  Have this checked by someone qualified before switching it on.")
    ans = ask("Has the wording been checked, and do you want this on? (yes/no)")
    if ans.lower() not in ("y", "yes"):
        set_config(cfg, "call_recording.enabled", False)
        print("  left off. Nothing will be recorded.")
        return False
    new = ask("Disclosure wording (Enter to keep the current one)")
    if new:
        set_config(cfg, "call_recording.disclosure_text", new)
    set_config(cfg, "call_recording.enabled", True)
    print("  on. CREA will not record a call where the disclosure fails to play.")
    return True


HANDLERS = {
    "acuity": connect_acuity, "google": connect_google, "whatsapp": connect_whatsapp,
    "higgsfield": connect_higgsfield, "apify": connect_apify,
    "editor": connect_editor, "calls": connect_calls,
}


def run(cfg, which: str | None = None) -> int:
    load_env(cfg)
    if which:
        if which not in HANDLERS:
            print(f"unknown service '{which}'. Try: {', '.join(HANDLERS)}")
            return 1
        return 0 if HANDLERS[which](cfg) else 1

    from .connectors import status_all
    st = status_all(cfg)
    print("\nWhat's connected:\n")
    for name in ("acuity", "google", "whatsapp", "higgsfield", "apify"):
        row = st.get(name, {})
        mark = "yes" if row.get("ready") else "no "
        where = "" if row.get("ready") else f"   {row.get('where') or 'pair on your phone'}"
        print(f"  {mark:<4} {name:<11}{where}")
    print()

    if not sys.stdin.isatty():
        print("Run this from a Terminal window to connect anything.")
        return 0

    todo = [n for n in ("acuity", "google", "whatsapp", "higgsfield", "apify")
            if not st.get(n, {}).get("ready")]
    if not todo:
        print("Everything's connected.")
        return 0

    print("Let's connect what's missing. Press Enter to skip any of them.\n")
    for name in todo:
        HANDLERS[name](cfg)
    if not cfg.get("integrations.whatsapp.editor_handle", None):
        connect_editor(cfg)
    return 0
