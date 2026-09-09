# CREA — Build Manual

**Cfilms Real Estate Adviser** · Version 1.1 · 25 August 2026
Prepared for Connell Saputra. Supersedes the plan of 17 August 2026.

An always-on AI adviser that answers out loud, runs your booking pipeline, sorts
your cards, and keeps the admin off your plate.

> ### Every number in this document is a placeholder
>
> The jobs, clients, addresses, dollar figures and dates throughout — Aisha
> Rahman, $7,170 outstanding, the Baulkham Hills shoot — are **invented test
> data**, so the system has something realistic to run against before your real
> accounts are connected. None of it refers to a real client, shoot, or amount.
>
> The only figures that are **measured rather than invented** are the performance
> numbers in §1 and the costs in §10. Those were timed on real hardware.

**Presentation copy:** <https://skw-fuj.github.io/crea/>
**Interface mockup:** <https://skw-fuj.github.io/crea/shell/>
**Code:** <https://github.com/skw-fuj/crea>

*This file is the source of truth — it sits beside `install.sh` and cannot drift
from what the installer actually does.*

---

## 1. What changed since the first plan

The August plan estimated $25–100/month. Two decisions removed almost all of it.

The first plan assumed CREA would pay a per-word voice service and a per-token AI
service. Neither is necessary. The voice runs **entirely on your own machine** —
no account, no API key, no per-word cost — and the thinking is routed through a
**free model router**. Both were benchmarked on real hardware, not estimated.

Measured on a 2020 M1 MacBook with 8 GB of memory — deliberately the *worst*
machine this will ever run on. Your Mac Mini will be faster.

| | |
|---|---|
| **Voice generation** | **2.4× faster than real time** |
| **Thinking response** | **8.6s** on the free tier |
| **Voice cost** | **$0** — runs offline on the machine |
| **Running cost** | **$0–15/month**, vs the $25–100 originally quoted |

### What is already working

Not a mockup. This runs today:

- CREA speaks aloud in a natural voice, generated on-device — and says its own
  name properly. 26 voices to choose from, all free.
- It wakes when you say "Hey CREA", heard through a real microphone, with nothing
  transmitted until you do. It can learn your voice and answer only you.
- It holds your whole job pipeline in an Obsidian vault and answers questions
  about it — *"what have I got on this week, and how much am I owed?"* returns
  the right shoot, the right client and the right dollar figure, spoken back.
- The job dashboard builds itself: pipeline counts, upcoming shoots, outstanding
  money, anything stalled in editing.

It runs against realistic *test* data because none of your accounts are connected
yet. Connecting them happens during setup.

---

## 2. How it fits together

Four layers, one machine.

| Layer | What it does |
|---|---|
| **The voice** | Listens for "Hey CREA", turns your speech into text and its reply into audio. All on-device — nothing transmitted until the wake phrase fires |
| **The brain** | Hermes decides what you meant and which skill to run. It also owns the schedule, so the daily briefing and overnight jobs use the same brain |
| **The hands** | n8n does the plumbing to outside services — Acuity, Google, WhatsApp, Drive — as visual workflows rather than code you'd have to maintain |
| **The memory** | An Obsidian vault of plain text files. Every job, client and shoot log is readable and editable by you directly, and portable if you ever drop CREA |

**Why n8n carries the integrations.** The original plan had every connection
written as custom code — a maintenance burden nobody wants on someone else's
machine. n8n replaces most of it with visual workflows, and ships a **native
Acuity Scheduling trigger**, so bookings arrive as an event the moment they're
made with nothing custom to build.

**Why the model router matters.** It sits between Hermes and the AI models.
Hermes asks for "the fastest good model" and the router picks one, preferring
free providers and falling back automatically when one is rate-limited. You get
resilience and a $0 bill. Wanting a paid model later is a one-line change, not a
rebuild.

---

## 3. The stack

Every capability and the specific mechanism behind it.

| Capability | Mechanism | What you need | Cost | Status |
|---|---|---|---|---|
| Orchestration & scheduling | CLI — `hermes` | Nothing | Free | Running |
| AI thinking | Free model router | Nothing | $0 | Running |
| Speech out | CLI — Pocket TTS | Nothing | $0 | Running |
| Speech in | CLI — whisper.cpp | Nothing | $0 | Running |
| Memory / job records | Files — Obsidian vault | Obsidian (free) | Free | Running |
| Wake word "Hey CREA" | On-device listener | Microphone + permission | $0 | Running |
| Answers only your voice *(optional)* | On-device voice print | A minute to enrol | $0 | Built |
| Choice of 26 voices | Built in, on-device | Nothing | $0 | Running |
| WhatsApp booking assistant | n8n pack (`~/crea/n8n`) | Docker + a WhatsApp number + Groq key | Free | Built · `./go-live.sh` |
| Booking sync into the vault | the n8n pack writes job/lead notes directly | as above | Free | Built |
| Confirm / message a client by voice | CREA → n8n webhooks | the pack running | Free | Built |
| Calendar | n8n Google Calendar | Google authorisation | Free | Built · needs login |
| Call transcription | CLI — whisper.cpp | Recording app + consent flow | $0 | Built · needs login |
| WhatsApp messages | CLI — `hermes whatsapp` | QR scan from your phone | Free | Built · needs login |
| Drive upload | n8n Google Drive | Google authorisation | Existing plan | Built · needs login |
| Photo/video editing | Higgsfield API | Your Higgsfield account | Existing plan | Built · needs login |
| Editor notification | n8n → WhatsApp | Narendra's number | Free | Built · needs login |
| Invoicing | Your accounting tool | Xero/QuickBooks credentials | Existing plan | Built |
| Booking agent — confirms & chases | n8n → WhatsApp | Nothing beyond WhatsApp | Free | Built |
| Client check-in alerts | Reads your job vault | Nothing | Free | Built |
| Lead tracking | Your existing Apify scraping | Apify account | Existing plan | Built |
| Content repurposing → Reels | CLI — ffmpeg + Higgsfield | Nothing new | $0 | Built |
| Higher-quality voice *(optional)* | ElevenLabs | Account, if you want it | $5–22/mo | Optional |

**Read the status column literally.** *Running* means it was executed and
verified. *Built · needs login* means the skill is written and working, and
starts doing its job the moment that account is connected. Nothing here is a
stub, and nothing is described as connected unless it genuinely is.

---

## 4. What it can do

Nineteen skills. **Fourteen run the moment it's installed, with no accounts
connected at all.**

| Say this | And it |
|---|---|
| *"what's in the pipeline?"* | Reads out every job by stage, and what you're owed |
| *"mark Castle Hill as shot"* | Moves a job along Booked → Shot → Editing → Invoiced → Paid |
| *"the card's in"* | Copies it, splits it into shoots on the time gaps, verifies every file |
| *"is the card safe?"* | Only says yes once Drive has confirmed every file |
| *"who owes me?"* | Drafts the invoices and names what's overdue |
| *"I spent ninety-two on fuel"* | Logs it, works out the category itself |
| *"remind me about Mum's birthday on the 3rd"* | Files it and brings it up on the day |
| *"who haven't I spoken to?"* | Flags clients going quiet, most valuable first |
| *"what should I focus on?"* | The morning board — three things, most urgent first |
| *"when's my next booking?"* · *"any bookings today?"* | Reads it straight out of the vault the WhatsApp assistant fills |
| *"confirm booking 4A2"* | Books a held WhatsApp booking in — creates the Acuity appointment, tells the customer |
| *"message the Smith client I'm running late"* | One WhatsApp to that customer, through the automations |
| *"cut me some Reels"* | Vertical drafts out of the footage, with captions |
| *"take notes on this lecture"* | Slides in, revision notes out |
| — happens on its own | The WhatsApp assistant takes bookings, asks about the property, and writes them into the vault |
| — happens on its own | Pulls new Acuity bookings into your calendar and tracker |
| — happens on its own | Confirms tomorrow's shoots and chases replies |
| — happens on its own | Uploads shoots to Drive, hands to Higgsfield, tells your editor |
| — happens on its own | Flags agents worth approaching from your listing scrapes |

**Ten run on a schedule** without being asked: the briefing at 6:30, bookings
checked every fifteen minutes, WhatsApp every ten, confirmations at 5pm,
invoicing on Monday mornings, the board at 6.

`crea skills` lists them all and what each is waiting on. A skill that needs
an account you haven't connected says exactly that, and exactly how to connect
it. It never half-runs and never reports success for doing nothing.

**The WhatsApp booking assistant is its own pack** (`~/crea/n8n`, in Docker). It
runs the customer conversation — property questions, a read-back, an optional
one-tap `CONFIRM` before anything hits your calendar — and writes every job,
client and lead into this same vault. CREA reads them. Set it up with
`cd ~/crea/n8n && ./go-live.sh`; the two behaviour choices are in `n8n/BOOKING.md`.
`bookings.source` in `crea.config.json` is `n8n` once it's running, which turns
off CREA's own Acuity poll so the two don't double up.

---

## 5. Where everything comes from

You don't need to find any of these. During setup CREA opens the right page for
you and checks the key works before saving it.

| Account | Exactly where | What you copy | Unlocks |
|---|---|---|---|
| **Acuity** | Left sidebar → Business Settings → Integrations → API → view credentials | User ID (numeric) + API Key | Bookings arriving on their own |
| **Google** | [console.cloud.google.com](https://console.cloud.google.com/apis/credentials) → APIs & Services → Credentials → Create credentials → OAuth client ID → Desktop app | Client ID + secret, then Allow | Calendar, Drive uploads, uni notes in Docs |
| **WhatsApp** | Phone → WhatsApp → Settings → Linked Devices → Link a Device | Nothing — scan a QR | Booking messages, confirmations, telling your editor |
| **Higgsfield** | Your account settings | API key | Shoots handed over for editing |
| **Apify** | [console.apify.com](https://console.apify.com/settings/integrations) → Settings → Integrations | Personal API token | Lead tracking |

### What runs underneath — all installed for you

| Piece | What it is |
|---|---|
| `hermes` | Runs the skills and the schedule |
| `n8n` | Visual connections to outside services |
| `whisper-cli` | Your speech to text, on the machine |
| Pocket TTS | CREA's voice, on the machine — 26 voices |
| `ffmpeg`, `exiftool` | Reels, and reading shot times off your files |
| Obsidian | Where you read and edit the job vault |
| `crea` | The command that drives it all |

Acuity, Google, Higgsfield and Apify are reached over their normal web APIs.
WhatsApp connects the way WhatsApp Web does. Nothing exotic, nothing you're
locked into.

**Your keys** go into one locked file on your Mac that only your account can
read. Never in the settings file, never uploaded, and I never see them.

---

## 6. The WhatsApp question — your number stays your number

The obvious way to read WhatsApp is Meta's official Business API. It's a trap for
you specifically: connecting a number to it means that number **can no longer use
the normal WhatsApp app**, local chat history is deleted, and incoming messages
can be held for up to a month while migration completes. For a business whose
bookings arrive by WhatsApp, that's not a risk worth taking.

CREA uses a second path. `hermes whatsapp` pairs by QR code, exactly like
WhatsApp Web on a laptop. Your number stays a normal WhatsApp number, your
history stays intact, and CREA reads incoming messages the way a second device
would.

**The honest caveat:** this uses an unofficial connection library. Meta's terms
don't formally permit non-official clients, and there is a small risk of a number
being restricted. It's widely used and rarely a problem in practice, but you
should know before we switch it on — and if you'd rather not take it, we use a
second SIM for CREA and leave your main number untouched.

---

## 7. Call recording — the one legal condition

NSW requires **all parties** to a private conversation to consent to being
recorded. The Surveillance Devices Act 2007 has a narrow exception for protecting
your own lawful interests — but *"so I get the booking details right"* is
convenience, not protection, so that exception isn't available. It also fails
outright where a recording is passed to people who weren't part of the
conversation, which is what any transcription pipeline does.

That leaves consent, and consent is workable. In NSW consent can be implied — if
a caller is clearly told at the start that the call is recorded and continues
talking, that's generally accepted. So CREA plays a spoken disclosure before it
retains a single second of audio:

```jsonc
"require_disclosure": true,
"disclosure_text": "Just so you know, I record calls so I get the booking details right.",
"retain_audio": false,          // transcribe, then discard the recording
"abort_if_disclosure_fails": true
```

`retain_audio: false` means the recording is transcribed for the booking details
and then deleted — CREA keeps the date, time and address, not a library of your
clients' voices. `abort_if_disclosure_fails` means that if the disclosure doesn't
play for any reason, nothing is recorded at all.

**Before this goes live:** I'm not a lawyer and this isn't legal advice. Every
other capability you can switch on at your own discretion; for this one, run the
wording past someone qualified first. It's a cheap conversation and it's the
difference between a feature and a liability.

---

## 8. The card pipeline — plug it in, go have a shower

The sequence is exactly as originally specified: detect the card, copy everything
off, split the files into separate shoots by looking for time gaps between shots,
upload each shoot to Drive in its own named folder, push it into Higgsfield, and
tell Narendra it's ready.

```jsonc
"shoot_gap_minutes": 90,     // a longer break = a new shoot
"verify_copies": true,
"format_card": "never"       // never | ask | auto
```

**One change from the original plan.** It had CREA format the card automatically
once everything was copied. It won't, and it ships with that disabled.

Until Drive confirms the upload, that card is the only copy of a paid shoot in
existence. Every other failure in this system costs you an inconvenience; this
one costs you a job, a client, and a reputation. CREA verifies every copy and
then *tells you* the card is safe to format. Once you've watched it get that
right a dozen times we can move it to `"ask"`, and eventually `"auto"` if you
want. That's your call to make later, not a default to inherit now.

---

## 9. Build order

| # | Phase | Time | Status |
|---|---|---|---|
| 1 | Core loop — voice, vault, brain | — | **Done** |
| 2 | "Hey CREA" wake word | — | **Done** — verified from a real mic |
| 3 | Acuity + calendar | ½ day | |
| 4 | Calls + WhatsApp | 2 days | |
| 5 | Card → Drive → Higgsfield | 2–4 days | |
| 6 | Job dashboard, invoicing, booking agent | 1–2 days | |
| 7 | Phone access (Shortcut + private network) | 2–3 days | |
| 8 | Personal layer — briefing, reminders, expenses | 1–2 days | |
| 9 | Uni note-taking from lecture slides | 1 day | |
| 10 | Lead tracking, client check-ins, content repurposing | 2–3 days | |
| 11 | The daily agent board | 2–3 days | |

Full system, built steadily: **3–6 weeks part-time.**

---

## 10. Money and time

| Item | First plan | This plan | Why it changed |
|---|---|---|---|
| Hardware, one-off | $550–1,300 | $550–1,300 | Unchanged. Get **16 GB**, not 8 |
| Voice | $5–22/mo | **$0** | Runs on the machine instead of a service |
| AI model | $20–60/mo | **$0** | Routed to free tiers automatically |
| Call transcription | $0–15/mo | **$0** | Runs on the machine |
| Everything else | — | **$0** | Obsidian, n8n and Hermes are free and open-source |
| **Monthly total** | **$25–100** | **$0–15** | The range only exists if you upgrade the voice |
| Build time | 4–8 weeks | 3–6 weeks | Phase 1 is done; n8n removes most custom work |

**One caveat on hardware.** The base Mac Mini is the right machine, but **memory
is the specification that decides whether this works**. The alpha was benchmarked
on an 8 GB machine, and 8 GB is genuinely not enough to hold the voice model and
everything else at once. 16 GB is the floor. It's usually a couple of hundred
dollars and it's the difference between CREA being instant and CREA being
frustrating.

---

## 11. Setup — one line

Take the Mac Mini out of the box, plug it in, and go through Apple's normal
first-time setup. Then open **Terminal** (press `⌘ Space`, type "terminal", press
Enter) and paste:

```bash
curl -fsSL https://raw.githubusercontent.com/skw-fuj/crea/main/install.sh | bash
```

Walk away for about twenty minutes. It installs:

| It installs | Which gives you |
|---|---|
| Homebrew, Node, uv, ffmpeg, ExifTool | The groundwork everything sits on |
| CREA itself, from GitHub | The assistant. Re-run the line to update it |
| whisper.cpp + speech model | CREA hearing you, on-device |
| Pocket TTS + voice model | CREA talking back, on-device |
| Hermes, routed to a free model tier | The thinking, at no cost |
| n8n | Connections to Acuity, Google and WhatsApp |
| Obsidian + your job vault | The memory, readable by you directly |
| Background services | CREA starting itself on boot, forever |
| The `crea` command | Everything controllable in one word |
| This manual | A copy lands at `~/crea/docs/MANUAL.md` |

Near the end it asks about the five accounts. Each is a yes/no and each is
optional; `crea connect` adds them later. Say no to all five and CREA still
installs and still talks to you.

**Safe to re-run.** Anything already installed is left alone, and your settings
file is never overwritten.

### If something goes wrong

It won't fail silently. Every step reports whether it actually did something, was
already done, or failed — and at the end it re-checks the core components rather
than assuming they came up. If anything is broken it says exactly what, writes a
log, and asks you to send it to me.

### The moment it finishes

CREA starts talking. It's already listening for its name and restarts itself
whenever the Mini reboots — you never start it manually.

```bash
# say this out loud
"Hey CREA — what have I got on this week?"

# or type it
crea ask "how much am I owed?"
crea skills                 # everything it can do
crea status                 # is everything healthy?
crea connect                # add an account you skipped
crea card                   # import a plugged-in SD card
crea enrol                  # teach it your voice
```

Open Obsidian and your job vault is there — every shoot, client and note as a
plain document you can read and edit. Change something and CREA knows immediately.

---

## 12. Talking to it

### It's pronounced *KREE-ah*

Not "cray". The speech recognition is tuned for that pronunciation, and CREA says
its own name that way too. Say it "cray" and it will usually still catch you, but
"kree-ah" is what it listens for.

### macOS will ask for the microphone

The first time CREA listens, macOS asks permission to use the microphone.
**Say yes.** If you miss it or hit Don't Allow, CREA sits there hearing nothing
forever — the most common reason a setup like this looks broken when it isn't.
Fix it later under **System Settings → Privacy & Security → Microphone**.

### Just talk

```
"Hey CREA, what have I got on today?"
"Hey CREA, how much am I owed?"
"Hey CREA, mark the Castle Hill job as shot."
```

Say the name, wait for the short "Yep?", then say what you want. It listens
continuously; nothing is transmitted until you've said its name, and the
recording is discarded once understood.

### If it doesn't hear you

| What's happening | What to do |
|---|---|
| No response at all | `crea status` — reports honestly which part is down |
| Never wakes up | Check mic permission. Then check the input device — a connected iPhone or headset can quietly steal it |
| Wakes at the wrong times | Tuned to accept near-misses rather than miss you. Say the word and I'll tighten it |
| Hears you but answers oddly | Expected early. It only knows the vault — connecting Acuity and Google makes answers real |

### Making it answer only you

Out of the box CREA answers anyone who says its name — the way a HomePod does.
If you'd rather it only answered you:

```bash
crea enrol              # say a few sentences
crea voice-check on     # now it only answers you
```

Enrolment takes about a minute. It asks you to speak five times and wants a bit
of variety — closer, further away, mid-sentence — because that's far more
reliable than five identical recordings. It tells you if one came out noticeably
different, so a bad enrolment doesn't quietly make it flaky.

Do it on the Mini, with the microphone you'll actually use. A voice measures
differently through a different mic.

Leave it off if you'd rather it answered anyone — handy if an assistant or your
editor ever needs to ask it something. Off is the default.

**It errs towards answering.** If the voice check can't run for any reason, CREA
answers anyway rather than going silent.

### 26 voices

CREA's own voice is one of 26 built in, all free and on-device. If the default
doesn't suit you, change `voice.tts.voice` in the settings file to any of:
cosette, marius, javert, alba, jean, anna, vera, fantine, charles, paul, eponine,
azelma, george, mary, jane, michael, eve, giovanni, lola, juergen, rafael,
estelle, and a few more. Cloning a specific person's voice needs the paid
ElevenLabs path.

### You never have to use your voice

Everything CREA does by voice it also does by typing, and the vault is plain
documents you can edit in Obsidian. Voice is the convenient path, not the only one.

---

## 13. CREA on your phone

Three ways, two of them free. Don't decide on day one — use it a fortnight first.

**1. Let CREA message you — free.** Once WhatsApp is connected it can message
you: the morning brief, tomorrow's shoots, a nudge when a job's been sitting in
editing. No app, no subscription. For *"what's my next job and where"*, this
covers most of it. Start here.

**2. Talk to it from the car — free.** An iPhone Shortcut reaching the Mini over
a private network (phase 7). Nothing is exposed publicly and there's no port
forwarding — an always-on machine with an open door on a home connection is how
people get compromised.

**3. The whole vault on your phone — $4–5/month.** Obsidian Sync puts the job
vault on your iPhone, readable and editable. $4/mo billed yearly, $5 monthly, on
a system otherwise running at $0–15. Students get 40% off.

### Why not free iCloud?

Because iCloud **removes files from your Mac** when it decides they're cold,
leaving a placeholder that downloads on demand. Invisible when a person opens a
note. Not invisible to CREA, which reads the vault automatically every fifteen
minutes — an emptied-out job note is a job CREA can't see.

Not theoretical: while building this, two files in an iCloud folder showed as
completely empty until manually pulled back down.

Obsidian Sync keeps a full copy on every device and never empties one out. For a
folder a background program reads on a schedule, that matters more than the
version history you're nominally paying for.

**What I'd do:** run two weeks on WhatsApp alone. If you find yourself wanting to
*read and edit* the vault on your phone rather than just get answers, that's when
Sync earns its money.

---

## 14. When things go wrong

None of these are exotic. They're the ones that catch every always-on setup, so
they're handled or flagged rather than left for you to discover.

| If this happens | What's going on | What to do |
|---|---|---|
| Stops answering overnight | The Mac slept. Handled — CREA keeps it awake itself, without changing your power settings | Nothing |
| Power cut / restart | Everything restarts on its own | Nothing. Give it a minute |
| Internet drops | Voice and the vault keep working (they're local). Bookings, Drive and WhatsApp catch up after | Nothing is lost |
| An account stops working | A key expired or was revoked. Skills needing it say exactly what's wrong rather than half-running | `crea status`, then `crea connect <name>` |
| WhatsApp unlinks itself | Linked devices drop off after long idle. Normal, not a fault | `crea connect whatsapp`, scan again |

**The one that would actually hurt** is losing a shoot. That's why CREA verifies
every file copied off a card and will **never** format one — it tells you the card
is safe and leaves the decision with you.

**If something's wrong and you can't tell what:** run `crea status`. It reports
what's actually working rather than what's supposed to be, including whether the
Mac's clock disagrees with CREA's. Send me what it prints.

---

## 15. What's new in 1.1

| New | What it means for you |
|---|---|
| **It can learn your voice** | CREA can answer only you rather than anyone who says its name. About a minute to set up, off by default — leave it off if an assistant or your editor should be able to ask it things too |
| **26 voices, not one** | If the default grates, there are 25 others. All free, all on the machine |
| **Setup opens each page for you** | No hunting through settings menus. It opens Acuity, Google and Apify at the right page and checks each key works before saving |
| **It keeps the Mac awake** | An always-on assistant that sleeps isn't always on. Handled, without changing your own power settings |
| **The clock is right year-round** | Sydney time, following daylight saving on its own, rather than trusting whatever the Mac was set to at first-time setup. A wrong clock would have fired the morning brief at the wrong hour and dated invoices a day out |
| **CREA on your phone** | §13 — three ways, two free, and an honest answer on the paid one |
| **When things go wrong** | §14 — the five that catch every setup like this |

**Also fixed:** the wake word didn't work in 1.0. It does now, and it was tested
with a real human voice rather than assumed — which is how the problem was found.
Speech recognition kept hearing "Hey CREA" as "Paycray", so the name is given to
it in advance now. Related: it's pronounced **kree-ah**.

**1.0 → 1.1.** 1.0 was the working core: voice in, voice out, the job vault, the
card pipeline. 1.1 is every remaining skill from your original plan, plus the
things you only discover by running something on a machine that has to stay up
for months.

---

## 16. Next

1. **Order the Mac Mini — 16 GB.** Everything waits on this, and it's the one
   spec that matters. Refurbished M1 is fine if it's 16 GB; a new base M4 is the
   safer buy.
2. **Look at the interface mockup and listen to the voice.** Tell me what you'd
   change — colour, layout, what's on the first screen, whether the voice suits
   you. Now is the cheap time to change any of it.
3. **Decide on WhatsApp** — your existing number by QR, or a second SIM for CREA.
   §6 has what you need to choose.

That's it. The Acuity key and the Google login happen during the install itself,
so there's nothing to gather in advance. If you want calls included in phase 4,
get the disclosure wording in §7 checked by someone qualified — WhatsApp
extraction can go ahead without it.

### Moving machines later

Every setting specific to you lives in `crea.config.json`. Moving CREA to a
different Mac is copying that one file across. Nothing gets reinstalled or
reconfigured by hand.

---

*Status labels reflect what was verified at time of writing, not what is
intended. Performance figures measured on Apple M1 / 8 GB.*
