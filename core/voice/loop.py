"""The core loop: wake -> listen -> understand -> answer -> speak.

This is step 1 and 2 of the build plan proven end to end. Everything upstream
(Acuity, WhatsApp, calls, the media pipeline) eventually feeds the same loop by
writing into the vault that supplies `context` here.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
import time
from pathlib import Path

from ..brain import make_brain
from ..vault import Vault
from .providers import make_stt, make_tts
from .wake import make_wake
from ..clock import now as _now


def _when(d, today) -> str:
    """Label a date relative to today, in the words a person would use.

    The brain is good with facts and bad at arithmetic on dates: given raw
    dates it happily answered "what have I got on this week?" with jobs three
    weeks out. Labelling each row removes the calculation entirely.
    """
    delta = (d.date() - today).days
    if delta == 0:
        return "TODAY"
    if delta == 1:
        return "TOMORROW"
    # Weeks run Monday-Sunday, matching how people say "this week".
    start_of_week = today.fromordinal(today.toordinal() - today.weekday())
    week = (d.date() - start_of_week).days // 7
    if week == 0:
        return "this week"
    if week == 1:
        return "next week"
    if delta < 0:
        return "in the past"
    return "later"


def vault_context(vault: Vault, limit: int = 6, conn=None) -> str:
    """A compact snapshot of the pipeline, so the brain answers about real jobs."""
    from datetime import datetime
    today = _now().date()
    jobs = vault.jobs()
    if not jobs:
        lines = ["No jobs in the vault yet."]
        lines += _calendar_lines(conn, today)
        return "\n".join(lines)
    upcoming = sorted([j for j in jobs if j.get("status") == "Booked"],
                      key=lambda j: j.get("shoot_at", ""))[:limit]
    unpaid = [j for j in jobs if j.get("status") in ("Shot", "Editing", "Invoiced")]
    owed = sum(j.get("fee") or 0 for j in unpaid)

    lines = [f"Today is {_now():%A %d %B %Y}.",
             "Every dated row below is tagged with when it falls. Trust the tag "
             "and do not recompute it: only rows tagged [TODAY] are today, only "
             "rows tagged [this week] are this week.",
             f"{len(jobs)} jobs total. ${owed:,.0f} outstanding across {len(unpaid)} unpaid jobs."]
    if upcoming:
        lines.append("Upcoming shoots:")
        for j in upcoming:
            d = datetime.fromisoformat(j["shoot_at"])
            lines.append(f"- [{_when(d, today)}] {d:%a %d %b %-I:%M%p}: {j['_title']} "
                         f"for {j['client']} at {j['address']}, "
                         f"${j.get('fee') or 0:,.0f}")

    # Anything stalled mid-pipeline is the most common thing to be asked about
    # ("what's stuck?", "what haven't I invoiced?"). Without it the brain has to
    # answer "I don't know" about data that is sitting right there in the vault.
    for status in ("Shot", "Editing", "Invoiced"):
        rows = [j for j in jobs if j.get("status") == status]
        if not rows:
            continue
        total = sum(j.get("fee") or 0 for j in rows)
        lines.append(f"Jobs in {status} ({len(rows)}, ${total:,.0f}):")
        for j in sorted(rows, key=lambda r: r.get("shoot_at", "")):
            d = datetime.fromisoformat(j["shoot_at"])
            lines.append(f"- {j['_title']} for {j['client']}, shot {d:%d %b}, "
                         f"${j.get('fee') or 0:,.0f}")
    lines += _calendar_lines(conn, today)
    return "\n".join(lines)


def _calendar_lines(conn, today) -> list[str]:
    """Calendar entries, so "what's on today?" is answerable.

    Without this the brain has no calendar data at all and — rather than saying
    so — invents a reason, most memorably telling the principal that Google was
    "not connected" while the connector was live and authorised.
    """
    if conn is None:
        return []
    google = conn.get("google") if hasattr(conn, "get") else None
    if not google or not google.ready():
        return ["Calendar: not connected, so nothing here reflects the diary."]
    from datetime import datetime
    try:
        evs = google.events(days=14)
    except Exception as e:
        return [f"Calendar: could not be read ({str(e)[:60]}). Say so rather than guessing."]
    if not evs:
        return ["Calendar: connected, nothing in the next 14 days."]
    out = ["Calendar (all calendars, next 14 days):"]
    for e in evs[:12]:
        st = e.get("start", {})
        raw = st.get("dateTime") or st.get("date") or ""
        if not raw:
            continue
        try:
            d = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        except ValueError:
            continue
        when = _when(d, today)
        stamp = f"{d:%a %d %b}" + ("" if st.get("date") else f" {d:%-I:%M%p}")

        # The finish time matters for a shoot day — it is how long you are on
        # site — so include it when the event is not all-day.
        fin = e.get("end", {}).get("dateTime")
        if fin and not st.get("date"):
            try:
                stamp += f"-{datetime.fromisoformat(fin.replace('Z', '+00:00')):%-I:%M%p}"
            except ValueError:
                pass

        row = f"- [{when}] {stamp}: {e.get('summary') or '(untitled)'}"

        # What was actually booked usually lives in the description
        # ("Photos/floorplan/reel"), and the full street address in location.
        # Passing only the title threw both away, so CREA could say where it
        # was but never what the job involved.
        desc = " ".join((e.get("description") or "").split())
        if desc:
            row += f" — {desc[:200]}"
        loc = " ".join((e.get("location") or "").split())
        if loc and loc.lower() not in row.lower():
            row += f" (at {loc})"
        out.append(row)
    return out


def play(audio: bytes) -> None:
    # mkstemp returns (fd, path) and the fd is already open. Taking [1] and
    # dropping the fd leaks one descriptor per call — the always-on loop hits
    # the per-process limit after a few hundred wakes and then every reply
    # fails with "Too many open files".
    fd, name = tempfile.mkstemp(suffix=".wav")
    os.close(fd)
    p = Path(name)
    p.write_bytes(audio)
    try:
        subprocess.run(["afplay", str(p)], check=False)
    finally:
        p.unlink(missing_ok=True)


def answer(cfg, vault: Vault, question: str, speak: bool = True) -> str:
    """One turn, no microphone — the testable core of the loop."""
    brain = make_brain(cfg)
    from ..connectors import load_all
    reply = brain.ask(question, context=vault_context(vault, conn=load_all(cfg)))
    vault.log("ask", f"{question!r} -> {reply[:120]!r}")
    if speak:
        play(make_tts(cfg).speak(reply))
    return reply


def run(cfg, vault: Vault) -> None:
    """The always-on loop. Ctrl-C to stop."""
    from .wake import WakeError
    from .speaker import Speaker
    stt = make_stt(cfg)
    tts = make_tts(cfg)
    speaker = Speaker(cfg)
    wake = make_wake(cfg, stt, speaker=speaker if speaker.enabled else None)
    brain = make_brain(cfg)
    from ..connectors import load_all
    conns = load_all(cfg)
    phrase = cfg.get("identity.wake_phrase")

    print(f"[crea] listening for {phrase!r} — nothing leaves this machine until it fires")
    if speaker.enabled:
        st = speaker.status()
        print(f"[crea] voice check on — {'enrolled' if st['enrolled'] else 'NOT ENROLLED, '
              'answering anyone until you run: crea enrol'}", flush=True)
    while True:
        try:
            wake.wait()
            print("[crea] wake")
            play(tts.speak("Yep?"))

            cmd_wav = wake.capture_command()
            try:
                # Identity is checked on the command, not the wake phrase: this
                # is several seconds of speech rather than two, and it is also
                # the thing that actually matters — never ACT on a stranger.
                if speaker.enabled:
                    ok, score = speaker.verify(cmd_wav.read_bytes())
                    if not ok:
                        print(f"[crea] not your voice (match {score:.2f}) — ignoring",
                              flush=True)
                        play(tts.speak("Sorry, I only take instructions from you."))
                        continue
                    if score is not None:
                        print(f"[crea] voice matched ({score:.2f})", flush=True)
                said = stt.transcribe(cmd_wav)
            finally:
                cmd_wav.unlink(missing_ok=True)

            if not said.strip():
                # Never fail silently — the user is standing there waiting.
                print("[crea] didn't catch that", flush=True)
                play(tts.speak("Sorry, I didn't catch that."))
                continue
            print(f"[crea] heard: {said}")

            reply = brain.ask(said, context=vault_context(vault, conn=conns))
            print(f"[crea] reply: {reply}")
            vault.log("voice", f"{said!r} -> {reply[:120]!r}")
            play(tts.speak(reply))
        except KeyboardInterrupt:
            print("\n[crea] stopped")
            wake.close()
            return
        except WakeError as e:
            # A misconfigured or missing wake model will not fix itself. Spinning
            # on it just fills the log with the same line hundreds of times.
            print(f"[crea] cannot listen: {e}")
            return
        except Exception as e:
            print(f"[crea] error: {e}")
            time.sleep(2)          # never hot-loop on a repeating fault
