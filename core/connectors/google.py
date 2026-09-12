"""Google Calendar, Drive and Docs.

Authentication is an OAuth flow, which needs a browser and a human. CREA does
not attempt to fake that: `crea connect google` opens the consent screen once
and stores the refresh token; everything afterwards is a token exchange.
"""
from __future__ import annotations

import json
import time
import urllib.parse
import urllib.request
from pathlib import Path

from .base import Connector, ConnectorError

TOKEN_URL = "https://oauth2.googleapis.com/token"
SCOPES = [
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/drive.file",
    "https://www.googleapis.com/auth/documents",
]


class Google(Connector):
    name = "google"
    how_to_connect = ("Run: crea connect google  —  opens a browser to approve access once. "
                      "Needs an OAuth client from console.cloud.google.com > APIs & Services "
                      "> Credentials > Create credentials > OAuth client ID > Desktop app")
    console_url = "https://console.cloud.google.com/apis/credentials"
    docs_url = "https://developers.google.com/identity/protocols/oauth2/native-app"

    @property
    def token_path(self) -> Path:
        return Path(self.cfg.get("paths.root")) / "var/google-token.json"

    def _token(self) -> dict | None:
        p = self.token_path
        if not p.exists():
            return None
        try:
            return json.loads(p.read_text())
        except Exception:
            return None

    def ready(self) -> bool:
        t = self._token()
        return bool(t and t.get("refresh_token"))

    def access_token(self) -> str:
        """Refresh and return a usable access token."""
        self.require()
        t = self._token()
        if t.get("expires_at", 0) > time.time() + 60:
            return t["access_token"]
        data = urllib.parse.urlencode({
            "client_id": t["client_id"],
            "client_secret": t["client_secret"],
            "refresh_token": t["refresh_token"],
            "grant_type": "refresh_token",
        }).encode()
        req = urllib.request.Request(TOKEN_URL, data=data)
        fresh = self._json(req)
        if "access_token" not in fresh:
            raise ConnectorError(f"token refresh failed: {fresh}")
        t["access_token"] = fresh["access_token"]
        t["expires_at"] = time.time() + int(fresh.get("expires_in", 3600))
        self.token_path.write_text(json.dumps(t, indent=2))
        self.token_path.chmod(0o600)
        return t["access_token"]

    def _req(self, url: str, method="GET", body=None) -> urllib.request.Request:
        r = urllib.request.Request(url, method=method)
        r.add_header("Authorization", f"Bearer {self.access_token()}")
        if body is not None:
            r.add_header("Content-Type", "application/json")
            r.data = json.dumps(body).encode()
        return r

    # ------------------------------------------------------------ calendar

    def create_event(self, summary: str, start_iso: str, minutes: int = 90,
                     location: str = "", description: str = "") -> dict:
        from datetime import datetime, timedelta
        cal = self.conf.get("calendar_id") or "primary"
        start = datetime.fromisoformat(start_iso)
        tz = self.cfg.get("identity.timezone", "Australia/Sydney")
        body = {
            "summary": summary, "location": location, "description": description,
            "start": {"dateTime": start.isoformat(), "timeZone": tz},
            "end": {"dateTime": (start + timedelta(minutes=minutes)).isoformat(),
                    "timeZone": tz},
        }
        url = f"https://www.googleapis.com/calendar/v3/calendars/{urllib.parse.quote(cal)}/events"
        return self._json(self._req(url, "POST", body))

    def calendars(self) -> list[str]:
        """Every calendar this account can read, primary first.

        Most people keep work in a shared calendar rather than their personal
        one, so defaulting to "primary" quietly hides the very shoots CREA is
        supposed to know about. Read them all unless told otherwise.
        """
        url = "https://www.googleapis.com/calendar/v3/users/me/calendarList"
        items = self._json(self._req(url)).get("items", [])
        # Google subscribes most accounts to a public-holidays calendar. It is
        # read-only noise for a work assistant and would pad every briefing.
        items = [c for c in items if "#holiday@" not in (c.get("id") or "")]
        ids = [c["id"] for c in items if c.get("primary")]
        ids += [c["id"] for c in items if not c.get("primary") and c.get("id")]
        return ids or ["primary"]

    def calendar_id_by_name(self, name: str) -> str | None:
        """Find a calendar by its display name, case-insensitively."""
        url = "https://www.googleapis.com/calendar/v3/users/me/calendarList"
        for c in self._json(self._req(url)).get("items", []):
            if (c.get("summary") or "").strip().lower() == name.strip().lower():
                return c.get("id")
        return None

    def events(self, days: int = 14, calendar_id: str | None = None,
               days_back: int = 0) -> list[dict]:
        from datetime import datetime, timedelta, timezone

        # calendar_id may be a single id, a list of ids, or null. Null now means
        # "every calendar I can see" rather than "primary only".
        cal = calendar_id or self.conf.get("calendar_id")
        if not cal:
            try:
                cals = self.calendars()
            except Exception:
                cals = ["primary"]        # a listing failure must not kill the brief
        elif isinstance(cal, str):
            cals = [cal]
        else:
            cals = list(cal)

        now = datetime.now(timezone.utc)
        q = urllib.parse.urlencode({
            "timeMin": (now - timedelta(days=days_back)).isoformat(),
            "timeMax": (now + timedelta(days=days)).isoformat(),
            "singleEvents": "true", "orderBy": "startTime", "maxResults": 100,
        })
        out: list[dict] = []
        for c in cals:
            url = (f"https://www.googleapis.com/calendar/v3/calendars/"
                   f"{urllib.parse.quote(c)}/events?{q}")
            try:
                out += self._json(self._req(url)).get("items", [])
            except Exception:
                continue                  # one unreadable calendar shouldn't lose the rest

        def _start(e):
            s = e.get("start", {})
            return s.get("dateTime") or s.get("date") or ""
        return sorted(out, key=_start)

    # --------------------------------------------------------------- drive

    def ensure_folder(self, name: str, parent: str | None = None) -> str:
        parent = parent or self.conf.get("drive_root_folder_id") or "root"
        q = (f"name='{name}' and '{parent}' in parents and "
             "mimeType='application/vnd.google-apps.folder' and trashed=false")
        url = "https://www.googleapis.com/drive/v3/files?" + urllib.parse.urlencode(
            {"q": q, "fields": "files(id,name)"})
        found = self._json(self._req(url)).get("files", [])
        if found:
            return found[0]["id"]
        made = self._json(self._req(
            "https://www.googleapis.com/drive/v3/files", "POST",
            {"name": name, "mimeType": "application/vnd.google-apps.folder",
             "parents": [parent]}))
        return made["id"]

    def upload(self, path, folder_id: str) -> dict:
        """Resumable-free simple upload. Fine for stills; large video is chunked."""
        from pathlib import Path as P
        import mimetypes
        p = P(path)
        meta = json.dumps({"name": p.name, "parents": [folder_id]}).encode()
        mime = mimetypes.guess_type(p.name)[0] or "application/octet-stream"
        boundary = "creaboundary7f3a"
        body = (
            f"--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".encode()
            + meta + f"\r\n--{boundary}\r\nContent-Type: {mime}\r\n\r\n".encode()
            + p.read_bytes() + f"\r\n--{boundary}--".encode()
        )
        req = urllib.request.Request(
            "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart",
            data=body, method="POST")
        req.add_header("Authorization", f"Bearer {self.access_token()}")
        req.add_header("Content-Type", f"multipart/related; boundary={boundary}")
        return self._json(req, timeout=300)

    # ---------------------------------------------------------------- docs

    def create_doc(self, title: str, text: str) -> dict:
        doc = self._json(self._req("https://docs.googleapis.com/v1/documents",
                                   "POST", {"title": title}))
        did = doc["documentId"]
        self._json(self._req(
            f"https://docs.googleapis.com/v1/documents/{did}:batchUpdate", "POST",
            {"requests": [{"insertText": {"location": {"index": 1}, "text": text}}]}))
        return {"id": did, "url": f"https://docs.google.com/document/d/{did}/edit"}
