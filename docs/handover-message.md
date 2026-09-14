# Handover message to Connell — v3.2.1

Email version below; short version after. Rewritten for v3.2.1 — the original v1.1 draft only
covered the voice assistant; the WhatsApp/voice booking automations and the pilot step below
didn't exist yet.

---

## Email

**Subject:** CREA is ready — here's everything to run it, and one thing before you rely on it

Hey Connell,

CREA's built and verified. Everything from the August plan, plus the WhatsApp booking
assistant and the shoot-ops automations we added after, plus phone bookings if you want them.
Here's everything you need — and one honest ask before you hand it your whole enquiry inbox.

---

**THE THREE LINKS**

Manual — what it does, what it costs, how to set it up
https://skw-fuj.github.io/crea/

Interface — click the orange circle and it talks to you
https://skw-fuj.github.io/crea/shell/

Code — all of it, open, yours
https://github.com/skw-fuj/crea

---

**TO INSTALL — two parts, the second one optional**

**Part 1 — the voice assistant.** Plug the Mac Mini in, finish Apple's normal setup, open
**Terminal** (press ⌘ Space, type "terminal", hit Enter), and paste this:

```
curl -fsSL https://raw.githubusercontent.com/skw-fuj/crea/main/install.sh | bash
```

Walk away for about twenty minutes. Safe to run again any time — it leaves alone whatever's
already there.

**Part 2 — the WhatsApp booking assistant and shoot-ops automations.** Optional; the voice
assistant works fine without it. If you want a customer's WhatsApp message to be turned into a
held booking automatically, this is that piece — see `n8n/HANDOVER.md` in the code. About an
hour, mostly creating a couple of free accounts.

---

**THE ACCOUNTS — two WhatsApp numbers, not one**

Part 1 asks about five accounts near the end. It opens each page in your browser for you, you
paste the key, and it checks the key actually works before saving it. Skip any and add them
later with `crea connect`.

| Account | Where exactly | What you copy |
|---|---|---|
| Acuity | Left sidebar → Business Settings → Integrations → API → view credentials | User ID (the numeric one) and API Key |
| Google | console.cloud.google.com → APIs & Services → Credentials → Create credentials → OAuth client ID → Desktop app | Client ID + secret, then click Allow |
| WhatsApp (**your own number**) | Your phone: WhatsApp → Settings → Linked Devices → Link a Device | Nothing — you scan a QR code |
| Higgsfield | Your account settings | API key |
| Apify | console.apify.com → Settings → Integrations | Personal API token |

That WhatsApp pairing is **your own personal number** — it's what CREA uses to confirm
tomorrow's shoots on your behalf, chase an unanswered booking, and message your editor. It's
not the number customers book through.

If you install Part 2, it asks for a **second, separate WhatsApp number** — the one customers
actually message to book (a cheap spare SIM works well, so your own number never touches it),
plus a free Groq API key. `n8n/HANDOVER.md` walks through both.

Your keys go into locked files on your own Mac. Not in the settings file, never uploaded, and
I never see them.

---

**PHONE BOOKINGS — entirely optional, on top of Part 2**

Same assistant answers a phone call instead of a WhatsApp message. Needs a Twilio number
(small per-minute cost once it's live, no monthly fee) and a free Cloudflare account.
`n8n/VOICE.md` walks through it, and **`./go-live.sh --test-voice`** proves the whole thing
works — signature verification, the whole call flow — before you ever point a real number at
it. Skip this section entirely if you just want WhatsApp; nothing else changes.

---

**COMMANDS YOU'LL ACTUALLY USE**

```
crea skills                     everything it can do, and what each needs
crea status                     honest health of every part
crea connect                    add an account you skipped

crea ask "how much am I owed?"  ask by typing instead of talking
crea card                       import a plugged-in SD card
crea jobs                       the pipeline
crea board                      what deserves attention today
crea brief                      today's briefing, spoken

crea enrol                      teach it your voice
crea voice-check on             then it only answers you
```

Or just talk to it: **"Hey CREA, what have I got on today?"**

If you installed Part 2: `./go-live.sh --status` is the equivalent for the booking side.

---

**BEFORE YOU LET IT HANDLE EVERYTHING — the one thing I'm asking you to actually do**

Once installed, run the two-week pilot in `docs/PILOT.md`: real WhatsApp traffic (start with
messaging it yourself), watched daily with a two-minute check, a checklist to actually tick
off rather than eyeball. I'm not going to be monitoring this for you day to day once it's
handed over — that's the whole point of it being yours. The pilot is how *you* build the
confidence to trust it with every enquiry unsupervised, rather than just assuming it from the
fact that it was built carefully. It also tells you fast if something needs adjusting — a
wrong price, an awkward reply — while the stakes are still low.

---

**WHAT'S RUNNING UNDERNEATH**

All installed for you. Listed so nothing's a mystery.

- **hermes** — runs the skills and the schedule
- **n8n** — the visual automations for booking and shoot-ops (Part 2)
- **whisper.cpp** — turns your speech into text, on the machine
- **Pocket TTS** — CREA's voice, on the machine, 26 voices to pick from
- **ffmpeg / exiftool** — Reels, and reading shot times off your files
- **Obsidian** — where you read and edit your own job vault
- **crea** — the command that drives all of it

Acuity, Google, Higgsfield and Apify are reached over their normal web APIs. Both WhatsApp
numbers connect the way WhatsApp Web does. Nothing exotic, nothing you're locked into.

---

**A FEW THINGS THAT CAME OUT OF TESTING**

**It can learn your voice.** By default CREA answers anyone who says its name. `crea enrol`
takes about a minute and after that it only answers you. Off unless you turn it on — worth
leaving off if an assistant or your editor should be able to ask it things too.

**It keeps the Mac awake.** An always-on assistant that goes to sleep isn't always on. It
handles that itself without changing your own power settings.

**The clock follows daylight saving.** Everything runs on Sydney time properly, rather than
trusting whatever timezone got picked during first-time setup.

**Section 13 of the manual covers using it from your phone** — three ways, two of them free,
and an honest answer on whether the paid option is worth it.

**Section 14 covers what to do when something breaks** — read what `crea status` prints, it
names the specific thing rather than just "unhealthy."

---

**TWO THINGS BEFORE YOU LOOK**

The **voice is real** — that's CREA, generated on the machine, no subscription.

But **every job, client and dollar figure on those screens is made up**, until your own
accounts are connected. The layout is a proposal too — if a screen's missing something you'd
use, now's the cheap time to say so.

---

**WHAT IT COSTS**

$0–15 a month for the voice assistant and WhatsApp booking — the voice runs on the machine and
the thinking goes through free tiers. If you turn on phone bookings, add Twilio's per-minute
call cost on top (no monthly fee, only pay for what's actually used).

---

**WHAT I NEED FROM YOU**

1. **Order the Mac Mini — 16GB of memory**, if you haven't already. 8GB genuinely isn't
   enough. Refurbished M1 is fine if it's 16GB, otherwise the base M4.
2. **Run the pilot** in `docs/PILOT.md` before relying on it for real — see above.
3. **Listen to the voice** and tell me if it suits you.
4. **Look at the screens** and tell me what you'd change.
5. **Decide on WhatsApp** — your existing number for the automations, or a second SIM. The
   manual and `n8n/BOOKING.md` have what you need to choose.

One last thing: it's pronounced **kree-ah**, not "cray". Matters more than it sounds like,
because the speech recognition is tuned for it.

Tris

---

## WhatsApp / short version

> Hey mate, CREA's built and verified — the voice assistant, the WhatsApp booking automations,
> phone bookings if you want them.
>
> Manual: https://skw-fuj.github.io/crea/
> Interface (tap the orange circle, it talks): https://skw-fuj.github.io/crea/shell/
> Code: https://github.com/skw-fuj/crea
>
> To install: plug the Mini in, open Terminal, paste this one line, walk away for twenty
> minutes —
>
> `curl -fsSL https://raw.githubusercontent.com/skw-fuj/crea/main/install.sh | bash`
>
> It asks about five accounts (Acuity, Google, your own WhatsApp, Higgsfield, Apify), opens
> each page for you, checks the keys work. The WhatsApp booking automations are a separate
> optional step after — `n8n/HANDOVER.md` — that one uses a *second* WhatsApp number, the one
> customers actually message.
>
> Then just talk to it: "Hey CREA, what have I got on today?"
>
> **One real ask:** run the two-week pilot in `docs/PILOT.md` before you trust it with every
> enquiry — real traffic, a daily two-minute check, a checklist. I won't be watching it for
> you day to day once it's handed over, so that pilot is how you build the confidence yourself.
>
> About $0–15/month for WhatsApp, plus a small per-call cost only if you turn on phone
> bookings — no monthly fee for that part.
>
> (Pronounced kree-ah, not cray 😄)

---

## Before sending

- [x] Both artifact links set to anyone-with-the-link — reverified unauthenticated 2026-09-15
      (both return 200 + real content: "CREA Build Manual", the interface shell)
- [x] GitHub repo public — reverified unauthenticated 2026-09-15 (200 + real repo page)
- [x] Manual and this message both stamped v3.2.4
- [ ] Decide whether to raise pricing for the build. This draft deliberately does not.
- [ ] Confirm the Mac Mini has actually been ordered/arrived before sending — item 1 assumes
      it hasn't, delete if it has
