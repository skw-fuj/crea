"""CREA's memory — a plain-text Obsidian vault.

Per the build plan, memory is an Obsidian vault rather than a database so every
job, client note and shoot log stays searchable, portable and readable by the
principal directly, instead of being locked inside CREA.

Layout follows the TRIS OS v2 control-document convention as design inspiration:
dashboards carry `type: ctrl-doc` frontmatter and clean filenames, entities live
in facet folders, and everything is wiki-linked so the graph stays connected.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field, asdict
from datetime import datetime, date
from .clock import now as _now
from pathlib import Path

# The job lifecycle from the build plan, in order. Index position is the
# progression, so a status can never silently move backwards unnoticed.
STATUSES = ["Booked", "Shot", "Editing", "Invoiced", "Paid"]

FOLDERS = ["Jobs", "Clients", "Leads", "Bookings", "Logs"]


def slugify(s: str) -> str:
    s = re.sub(r"[^\w\s-]", "", s).strip()
    return re.sub(r"[-\s]+", "-", s)


@dataclass
class Job:
    title: str
    client: str
    address: str
    shoot_at: str                 # ISO8601
    status: str = "Booked"
    job_type: str = "Photography"
    fee: float | None = None
    source: str = "manual"        # acuity | call | whatsapp | manual
    notes: str = ""
    tags: list[str] = field(default_factory=list)

    def validate(self) -> None:
        if self.status not in STATUSES:
            raise ValueError(f"unknown status {self.status!r}; expected one of {STATUSES}")
        datetime.fromisoformat(self.shoot_at)   # raises if malformed


class Vault:
    def __init__(self, root: Path):
        self.root = Path(root)

    def init(self) -> None:
        """Create the vault skeleton. Idempotent — never clobbers existing notes."""
        self.root.mkdir(parents=True, exist_ok=True)
        for f in FOLDERS:
            (self.root / f).mkdir(exist_ok=True)

    # ---------------------------------------------------------------- write

    def write_job(self, job: Job, external_id: str | None = None) -> Path:
        job.validate()
        d = datetime.fromisoformat(job.shoot_at)
        name = f"{d:%Y-%m-%d} {job.title}"
        p = self.root / "Jobs" / f"{slugify(name)}.md"

        fm = {
            "type": "job",
            "client": job.client,
            "address": job.address,
            "shoot_at": job.shoot_at,
            "status": job.status,
            "job_type": job.job_type,
            "fee": job.fee,
            "source": job.source,
            "tags": job.tags or ["cfilms/job"],
        }
        if external_id:
            fm["external_id"] = external_id
        body = [
            _frontmatter(fm),
            f"# {job.title}",
            "",
            f"**Client** [[{job.client}]] · **When** {d:%a %d %b %Y, %-I:%M%p} · **Status** `{job.status}`",
            f"**Where** {job.address}",
            "",
            "## Progress",
            _checklist(job.status),
            "",
            "## Notes",
            job.notes or "_none yet_",
            "",
            "---",
            "Part of [[CREA]] · client [[" + job.client + "]]",
        ]
        p.write_text("\n".join(body))
        return p

    def write_client(self, name: str, agency: str = "", phone: str = "",
                     email: str = "") -> Path:
        p = self.root / "Clients" / f"{slugify(name)}.md"
        if p.exists():
            return p                       # never overwrite an edited client note
        fm = {"type": "client", "agency": agency, "phone": phone,
              "email": email, "tags": ["cfilms/client"]}
        p.write_text("\n".join([
            _frontmatter(fm), f"# {name}", "",
            f"**Agency** {agency or '—'} · **Phone** {phone or '—'} · **Email** {email or '—'}",
            "", "## Jobs", "```dataview",
            'TABLE shoot_at, status FROM "Jobs" WHERE client = this.file.name SORT shoot_at DESC',
            "```", "", "## Notes", "_none yet_", "",
            "---", "Part of [[CREA]]",
        ]))
        return p

    def log(self, kind: str, message: str) -> None:
        p = self.root / "Logs" / f"{date.today():%Y-%m}.md"
        p.parent.mkdir(parents=True, exist_ok=True)
        stamp = _now().strftime("%Y-%m-%d %H:%M")
        with p.open("a") as fh:
            fh.write(f"- `{stamp}` **{kind}** — {message}\n")

    # ---------------------------------------------------------------- read

    def jobs(self) -> list[dict]:
        out = []
        for p in sorted((self.root / "Jobs").glob("*.md")):
            fm = _read_frontmatter(p)
            if fm:
                fm["_path"] = str(p)
                fm["_title"] = p.stem
                out.append(fm)
        return out

    def leads(self) -> list[dict]:
        """Enquiries the WhatsApp assistant captured but that aren't booked yet.

        Written by the automations pack into Leads/ in CREA's own frontmatter.
        """
        out = []
        d = self.root / "Leads"
        if not d.exists():
            return out
        for p in sorted(d.glob("*.md")):
            fm = _read_frontmatter(p)
            if fm:
                fm["_path"] = str(p)
                fm["_title"] = p.stem
                out.append(fm)
        return out

    def client(self, name: str) -> dict | None:
        p = self.root / "Clients" / f"{slugify(name)}.md"
        return _read_frontmatter(p) if p.exists() else None

    def clients(self) -> list[dict]:
        out = []
        for p in sorted((self.root / "Clients").glob("*.md")):
            fm = _read_frontmatter(p)
            if fm:
                fm["_path"] = str(p)
                fm["_name"] = p.stem.replace("-", " ")
                out.append(fm)
        return out

    # ---------------------------------------------------------------- edit

    def set_field(self, path, key: str, value) -> None:
        """Change one frontmatter field, leaving the body untouched.

        Job notes are the principal's documents as much as CREA's — rewriting a
        whole file to flip one field would clobber anything he typed into it.
        """
        p = Path(path)
        txt = p.read_text()
        if not txt.startswith("---"):
            return
        _, fm, body = txt.split("---", 2)
        lines, seen = [], False
        for line in fm.strip().splitlines():
            if line.split(":", 1)[0].strip() == key:
                lines.append(f"{key}: {json.dumps(value) if isinstance(value,(list,dict)) else value}")
                seen = True
            else:
                lines.append(line)
        if not seen:
            lines.append(f"{key}: {json.dumps(value) if isinstance(value,(list,dict)) else value}")
        p.write_text("---\n" + "\n".join(lines) + "\n---" + body)

    def set_status(self, path, status: str) -> None:
        if status not in STATUSES:
            raise ValueError(f"unknown status {status!r}")
        self.set_field(path, "status", status)
        # keep the visible checklist in step with the frontmatter
        p = Path(path)
        txt = p.read_text()
        i = STATUSES.index(status)
        new = "\n".join(f"- [{'x' if n <= i else ' '}] {s}"
                         for n, s in enumerate(STATUSES))
        txt = re.sub(r"(## Progress\n)(?:- \[.\] \w+\n?)+", r"\1" + new + "\n", txt)
        p.write_text(txt)

    # ------------------------------------------------------------ dashboard

    def render_dashboard(self) -> Path:
        """The home ctrl-doc — what Connell sees when the vault opens.

        Regenerated rather than hand-edited, so it can never drift from the jobs
        it describes.
        """
        jobs = self.jobs()
        by_status = {s: [j for j in jobs if j.get("status") == s] for s in STATUSES}
        owed = sum(j.get("fee") or 0 for j in jobs
                   if j.get("status") in ("Invoiced", "Shot", "Editing"))

        lines = [
            _frontmatter({"type": "ctrl-doc", "subtype": "dashboard",
                          "domain": "cfilms", "tags": ["crea/dashboard"]}),
            "# CREA", "",
            "> Cfilms Real Estate Adviser. Everything below is generated from the",
            "> vault — edit the job notes, not this page.", "",
            "## Pipeline", "",
            "| Stage | Jobs |", "|---|---|",
        ]
        lines += [f"| {s} | {len(by_status[s])} |" for s in STATUSES]
        lines += [
            "", f"**Outstanding** ${owed:,.0f} across "
                f"{sum(len(by_status[s]) for s in ('Shot','Editing','Invoiced'))} unpaid jobs.",
            "", "## Upcoming", "",
        ]
        upcoming = sorted(
            [j for j in jobs if j.get("status") == "Booked"],
            key=lambda j: j.get("shoot_at", ""),
        )[:8]
        if upcoming:
            for j in upcoming:
                d = parse_dt(j.get("shoot_at"))
                when = f"{d:%a %d %b %-I:%M%p}" if d else (j.get("shoot_at") or "time TBC")
                lines.append(f"- `{when}` [[{j['_title']}]] — "
                             f"[[{j['client']}]], {j['address']}")
        else:
            lines.append("_nothing booked_")

        lines += ["", "## Needs attention", ""]
        stale = [j for j in jobs if j.get("status") in ("Shot", "Editing")]
        if stale:
            lines += [f"- [[{j['_title']}]] — sitting in `{j['status']}`" for j in stale]
        else:
            lines.append("_nothing stalled_")

        lines += ["", "## Index", "",
                  "- [[Jobs]] · [[Clients]] · [[Bookings]] · [[Logs]]", ""]

        p = self.root / "CREA.md"
        p.write_text("\n".join(lines))
        return p


# ---------------------------------------------------------------- helpers

def _frontmatter(d: dict) -> str:
    out = ["---"]
    for k, v in d.items():
        if v is None:
            continue
        out.append(f"{k}: {json.dumps(v) if isinstance(v, (list, dict)) else v}")
    out += ["---", ""]
    return "\n".join(out)


def _read_frontmatter(p: Path) -> dict | None:
    txt = p.read_text()
    if not txt.startswith("---"):
        return None
    _, fm, *_ = txt.split("---", 2)
    d: dict = {}
    for line in fm.strip().splitlines():
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        v = v.strip()
        try:
            d[k.strip()] = json.loads(v)
        except Exception:
            d[k.strip()] = v
    return d


def parse_dt(value) -> datetime | None:
    """ISO8601 -> datetime, or None. Job notes written by the automations pack
    may carry a non-ISO time the customer typed ("Saturday 10am"); the voice
    side must degrade, not crash, on those."""
    try:
        return datetime.fromisoformat(str(value))
    except (TypeError, ValueError):
        return None


def _checklist(status: str) -> str:
    i = STATUSES.index(status)
    return "\n".join(f"- [{'x' if n <= i else ' '}] {s}"
                     for n, s in enumerate(STATUSES))
