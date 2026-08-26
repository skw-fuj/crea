"""Booking and client management — group one of Connell's plan.

Acuity sync, the job tracking dashboard, and the booking agent that confirms,
reschedules and chases on his behalf.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from ..vault import Job, STATUSES, slugify
from .base import Skill, SkillResult
from ..clock import now as _now


class CalendarSync(Skill):
    """Every event on the Shoots calendar becomes a job.

    Acuity's API is a paid add-on, but Acuity syncs bookings into Google
    Calendar on any plan — so the calendar, not the Acuity API, is the honest
    source of truth for what has been booked. This reads one named calendar
    ("Shoots" by default) and mirrors it into the vault.
    """

    name = "calendar-sync"
    title = "Pull shoots from the Shoots calendar"
    needs = ("google",)
    schedule = "*/15 * * * *"
    phrases = ("sync my calendar", "check for new shoots")

    CAL_NAME = "Shoots"

    @staticmethod
    def _plain(html: str) -> str:
        """Google lets descriptions carry HTML; the vault is plain text."""
        import re
        txt = re.sub(r"<br\s*/?>|</p>", "\n", html or "", flags=re.I)
        txt = re.sub(r"<[^>]+>", "", txt)
        for a, b in (("&amp;", "&"), ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">")):
            txt = txt.replace(a, b)
        return "\n".join(l.strip() for l in txt.splitlines() if l.strip())

    @classmethod
    def _client_from(cls, desc: str, summary: str) -> str:
        """Pull a client name out of the description, else fall back.

        These events are written by a person, so the only reliable convention
        is a "Contact:" line. Guessing harder than that invents clients.
        """
        import re
        m = re.search(r"contact\s*:\s*([^\n+0-9]{2,40})", desc, re.I)
        if m:
            name = m.group(1).strip(" -–—·,")
            if name:
                return name
        return "Unknown"

    def run(self, **kw) -> SkillResult:
        blocked = self.guard()
        if blocked:
            return blocked

        google = self.conn["google"]
        cal_name = self.cfg.get("integrations.google.shoots_calendar", self.CAL_NAME)
        cal_id = (self.cfg.get("integrations.google.shoots_calendar_id", None)
                  or google.calendar_id_by_name(cal_name))
        if not cal_id:
            return SkillResult(ok=False,
                               message=f"No calendar named {cal_name!r}. "
                                       f"Rename it, or set "
                                       f"integrations.google.shoots_calendar in "
                                       f"crea.config.json.")

        existing = {j.get("external_id") for j in self.vault.jobs()}
        added = []
        for e in google.events(days=180, calendar_id=cal_id, days_back=60):
            eid = e.get("id")
            if not eid or eid in existing:
                continue          # idempotent: the event id is the key

            st = e.get("start", {})
            raw = st.get("dateTime") or st.get("date")
            if not raw:
                continue
            shoot_at = raw[:16] if "T" in raw else f"{raw}T09:00"

            desc = self._plain(e.get("description", ""))
            summary = (e.get("summary") or "Shoot").strip()
            job = Job(
                title=summary,
                client=self._client_from(desc, summary),
                address=(e.get("location") or "").strip(),
                shoot_at=shoot_at,
                status="Booked",
                job_type=summary,
                fee=None,          # the calendar does not carry a price
                source="calendar",
                notes=desc,
            )
            self.vault.write_job(job, external_id=eid)
            added.append(job)

        if added:
            self.vault.render_dashboard()
            self.vault.log("calendar", f"{len(added)} shoot(s) from {cal_name}")

        return SkillResult(
            ok=True,
            message=(f"{len(added)} new shoot(s) from {cal_name}."
                     if added else f"No new shoots on {cal_name}."),
            data={"added": len(added)})


class AcuitySync(Skill):
    """Every Acuity booking becomes a job and a calendar entry, automatically."""

    name = "acuity-sync"
    title = "Pull bookings from Acuity"
    needs = ("acuity",)
    schedule = "*/15 * * * *"
    phrases = ("sync acuity", "check for new bookings")

    def run(self, **kw) -> SkillResult:
        blocked = self.guard()
        if blocked:
            return blocked

        existing = {j.get("external_id") for j in self.vault.jobs()}
        added, calendared = [], 0
        google = self.conn.get("google")

        for a in self.conn["acuity"].appointments():
            if a["external_id"] in existing:
                continue          # idempotent: never duplicate a booking
            job = Job(
                title=f"{a['address'].split(',')[0] or a['title']} — {a['title']}",
                client=a["client"], address=a["address"], shoot_at=a["shoot_at"],
                status="Booked", job_type=a["title"], fee=a["fee"],
                source="acuity", notes=a["notes"],
            )
            self.vault.write_job(job, external_id=a["external_id"])
            self.vault.write_client(a["client"], phone=a["phone"], email=a["email"])
            added.append(job)

            if google and google.ready():
                try:
                    google.create_event(
                        f"{a['title']} — {a['client']}", a["shoot_at"],
                        location=a["address"],
                        description=f"Booked via Acuity. {a['notes']}".strip())
                    calendared += 1
                except Exception:
                    pass          # the job note is the source of truth, not the calendar

        if added:
            self.vault.render_dashboard()
            self.vault.log("acuity", f"{len(added)} new booking(s)")

        return SkillResult(
            ok=True, changed=bool(added),
            summary=(f"{len(added)} new booking(s), {calendared} added to your calendar."
                     if added else "No new bookings since last check."),
            added=[a.title for a in added])


class JobBoard(Skill):
    """The job tracking dashboard — Booked -> Shot -> Editing -> Invoiced -> Paid."""

    name = "jobs"
    title = "Job tracking dashboard"
    schedule = "0 * * * *"
    phrases = ("what's in the pipeline", "show me the jobs", "what's outstanding")

    def run(self, status: str | None = None, **kw) -> SkillResult:
        jobs = self.vault.jobs()
        self.vault.render_dashboard()
        if not jobs:
            return SkillResult(ok=True, changed=False, summary="No jobs yet.")

        counts = {s: len([j for j in jobs if j.get("status") == s]) for s in STATUSES}
        unpaid = [j for j in jobs if j.get("status") in ("Shot", "Editing", "Invoiced")]
        owed = sum(j.get("fee") or 0 for j in unpaid)

        if status:
            rows = [j for j in jobs if j.get("status", "").lower() == status.lower()]
            listing = "; ".join(f"{j['_title']} (${j.get('fee') or 0:,.0f})" for j in rows)
            return SkillResult(ok=True, changed=False,
                               summary=f"{len(rows)} in {status}: {listing}" if rows
                               else f"Nothing in {status}.")

        return SkillResult(
            ok=True, changed=False,
            summary=(", ".join(f"{v} {k.lower()}" for k, v in counts.items() if v)
                     + f". ${owed:,.0f} outstanding across {len(unpaid)} unpaid jobs."),
            counts=counts, outstanding=owed)


class AdvanceJob(Skill):
    """Move a job along the pipeline by voice: 'mark Castle Hill as shot'."""

    name = "advance"
    title = "Move a job to the next stage"
    phrases = ("mark as", "move to", "that one's done")

    def run(self, job: str = "", status: str = "", **kw) -> SkillResult:
        if not job:
            return SkillResult(ok=False, changed=False,
                               summary="Which job? Say the suburb or the client.")
        matches = [j for j in self.vault.jobs()
                   if job.lower() in j["_title"].lower()
                   or job.lower() in str(j.get("client", "")).lower()]
        if not matches:
            return SkillResult(ok=False, changed=False, summary=f"No job matching '{job}'.")
        if len(matches) > 1 and not status:
            return SkillResult(ok=False, changed=False,
                               summary=f"{len(matches)} jobs match '{job}'. Be more specific.")

        target = matches[0]
        cur = target.get("status", "Booked")
        if status:
            new = next((s for s in STATUSES if s.lower() == status.lower()), None)
            if not new:
                return SkillResult(ok=False, changed=False,
                                   summary=f"'{status}' isn't a stage. Try: {', '.join(STATUSES)}.")
        else:
            i = STATUSES.index(cur)
            if i >= len(STATUSES) - 1:
                return SkillResult(ok=True, changed=False,
                                   summary=f"{target['_title']} is already paid.")
            new = STATUSES[i + 1]

        self.vault.set_status(target["_path"], new)
        self.vault.render_dashboard()
        self.vault.log("advance", f"{target['_title']}: {cur} -> {new}")
        return SkillResult(ok=True, changed=True,
                           summary=f"{target['_title']} moved from {cur} to {new}.")


class BookingAgent(Skill):
    """Confirms, reschedules and chases replies on his behalf.

    The plan describes this as 'the same pattern as booking a restaurant table'.
    In practice a photographer's version is: confirm the day before, chase an
    unanswered booking request, and offer a new time when something moves.
    Every outbound message is gated — CREA drafts, the principal approves.
    """

    name = "booking-agent"
    title = "Confirm and chase bookings"
    needs = ("whatsapp",)
    schedule = "0 17 * * *"
    phrases = ("confirm tomorrow", "chase that booking")

    def run(self, dry_run: bool = False, **kw) -> SkillResult:
        blocked = self.guard()
        if blocked:
            return blocked

        tomorrow = (_now(self.cfg) + timedelta(days=1)).date()
        due = [j for j in self.vault.jobs()
               if j.get("status") == "Booked"
               and datetime.fromisoformat(j["shoot_at"]).date() == tomorrow
               and not j.get("confirmed")]
        if not due:
            return SkillResult(ok=True, changed=False,
                               summary="Nothing needs confirming for tomorrow.")

        sent = []
        for j in due:
            client = self.vault.client(j.get("client", ""))
            phone = (client or {}).get("phone")
            when = datetime.fromisoformat(j["shoot_at"])
            msg = (f"Hi {j.get('client','').split()[0] if j.get('client') else 'there'}, "
                   f"just confirming the shoot at {j.get('address','')} tomorrow at "
                   f"{when:%-I:%M%p}. Let me know if anything's changed. — Cfilms")
            if dry_run or not phone:
                sent.append({"job": j["_title"], "to": phone, "draft": msg, "sent": False})
                continue
            if self.cfg.get("safety.confirm_before_send", True):
                if not self.confirm(f'Send to {phone}: "{msg}"?'):
                    sent.append({"job": j["_title"], "sent": False})
                    continue
            self.conn["whatsapp"].send(phone, msg)
            self.vault.set_field(j["_path"], "confirmed", True)
            sent.append({"job": j["_title"], "to": phone, "sent": True})

        n = sum(1 for s in sent if s.get("sent"))
        return SkillResult(
            ok=True, changed=bool(n),
            summary=(f"Confirmed {n} of {len(due)} shoot(s) for tomorrow."
                     if n else f"{len(due)} confirmation(s) drafted, waiting on you."),
            messages=sent)
