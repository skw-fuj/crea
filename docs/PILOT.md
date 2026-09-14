# CREA — the pilot, before you trust it with everything

Everything up to now has been verified by running it against test data, fixtures, and
mock accounts — thoroughly, but never against a real customer. This is the one step
nothing can substitute for: a bounded stretch of **real** enquiries, calls, and bookings,
that you watch, before CREA runs unsupervised.

This isn't a formality. It's the difference between "the code is correct" and "I trust
this with my business" — and once this is handed over, that trust is yours to build,
not something carried over from testing. Nobody is monitoring this in the background
after handover. You are.

## Before you start

- [ ] `./go-live.sh --test` prints green (WhatsApp path)
- [ ] If you're taking phone bookings: `./go-live.sh --test-voice` prints green
- [ ] `crea status` shows every account you're using as `ready`
- [ ] Your real prices are in `knowledge/crea-knowledge.md` (not the placeholder ones)
- [ ] You've read [`BOOKING.md`](../n8n/BOOKING.md) and know which of the two booking modes you chose —
      **hold for your CONFIRM** or **hand you the lead** — because that decision is
      what determines how much room for error the pilot actually has

If any of those aren't true yet, stop here and finish [`HANDOVER.md`](../n8n/HANDOVER.md) / [`VOICE.md`](../n8n/VOICE.md) first.
Piloting on top of an unverified install just tests the install, not CREA.

## The pilot itself

**Two weeks, real traffic, low stakes first.**

- **Days 1–3 — you only.** Message the WhatsApp number yourself, a few different ways
  (a real enquiry, a vague one, a price question, an awkward one). If you take calls,
  ring the number yourself too. Nothing here touches an actual client yet — this is
  where the sharp edges show up cheaply.
- **Days 4–14 — real enquiries, watched daily.** Let it run on real incoming traffic.
  Keep doing a once-a-day check (below) rather than trusting it silently — that's the
  entire point of a pilot.

Recommended minimum before you call it enough: **10 real WhatsApp enquiries** and, if
voice is on, **3 real calls**, spanning at least one Monday (so the weekly jobs —
invoicing, lead sweep — fire for real at least once). Adjust up if your volume is low;
don't cut it short because the first few looked fine — the point is the range of real
customers, not the count.

## The daily check (2 minutes, every day of the pilot)

1. `./go-live.sh --status` — everything green? WhatsApp session `WORKING`?
2. Open your vault's `alerts/` folder. **Empty is what you want.** Each file in there is
   one thing CREA caught failing on its own — read it, it names the workflow and why.
3. Open `leads/` and `inbox/` in Obsidian. Read what CREA actually said today. Does it
   match what you'd have said? Any price it shouldn't have quoted, any detail it got
   wrong, any tone that's off?
4. If you're using the hold-for-CONFIRM booking mode: check nothing's sitting held and
   forgotten — a customer waiting on you, not on CREA, is the one failure mode CREA
   can't catch for you.

Takes two minutes once you know the four spots. Skipping this for "it's probably fine"
defeats the pilot — the two weeks only mean something if someone's actually reading
what happened each day.

## Go / no-go — write the answer down, don't just eyeball it

At the end of the two weeks (or your real minimum from above), these should all be true:

- [ ] **Zero** files in `alerts/` you didn't understand or that repeated
- [ ] Every real booking a customer thought they made is actually a job in the vault
      with the right details — check this against your own memory of what came in,
      not just that the system says so
- [ ] No price quoted that wasn't in `knowledge/crea-knowledge.md`
- [ ] No held booking sat un-actioned past a day you'd have wanted to know sooner
- [ ] You'd be comfortable if it had answered *every* enquiry that came in this window,
      not just the ones you happened to check

If any of those is a no, that's not a failed pilot — it's the pilot doing its job.
Fix the specific thing ([`OPERATIONS.md`](../n8n/OPERATIONS.md) §1–2 covers most of it — wording, prices,
schedules), then run another week rather than extending trust past what you've verified.

## If something goes wrong mid-pilot

CREA already has a safe degraded mode built in — use it rather than turning the whole
thing off:

- **Wrong price / bad wording:** fix `knowledge/crea-knowledge.md`, no restart needed —
  CREA only ever says what's in that file.
- **A booking you don't trust:** if you're in hold-for-CONFIRM mode, just don't confirm
  it — decline it and message the customer yourself. Nothing books without your tap.
- **Something's actually broken:** `./go-live.sh --logs n8n`, then [`OPERATIONS.md`](../n8n/OPERATIONS.md) §9.
  If it's a real fault, WhatsApp/calls both fail closed — CREA hands the enquiry to a
  human rather than guessing (see [`COUNTERMEASURES.md`](../n8n/COUNTERMEASURES.md)). You won't lose an enquiry
  silently; worst case, you're doing what you did before CREA existed.

None of these require anyone but you. That's the design — CREA is built to fail toward
"ask a human" rather than "guess and hope," so a mid-pilot problem is visible, not silent.

## When you're done

Two weeks of real traffic, a clean daily-check record, and every go/no-go box checked
means CREA has actually earned the trust, not just passed a build check. From here it's
yours — run it the same way any other piece of your business runs: [`OPERATIONS.md`](../n8n/OPERATIONS.md) for
changes, `crea status` when in doubt, and the daily-check habit is worth keeping even
after the pilot ends, just less formally.
