# BOOKING.md — how CREA takes a booking (and the two calls that are yours)

Everything in this file is **already built and working**. When you install, you decide
two things. Change nothing and CREA behaves like v3 did — it just qualifies the enquiry
and hands it to you.

---

## The conversation

A customer messages your WhatsApp. CREA:

1. **Asks about the property, one question at a time** — service (photos / video / both /
   drone / twilight / floor plan), house or apartment etc., bedrooms, bathrooms, car
   spaces, levels, rough floor area in m², pool (and size), and anything else that
   changes the shoot (verandas, backyards, storage, extra kitchens, granny flat, views,
   acreage…). Then the address and what day/time suits.
2. **Reads it back** — "So that's a listing video, 4-bed 2-bath house at 40 Awaba St,
   Saturday 10am — all correct?" — and waits for a clear **yes**.
3. On yes, it does whatever you picked in **decision 3** below.

It never says a booking is confirmed, never invents a price or a policy, and hands you
anything it can't answer.

---

## Decision 1 — does CREA quote a price?  `CREA_PRICING_MODE`

| value | what the customer hears | you set up |
|---|---|---|
| `defer` *(default)* | "I'll get you an exact quote" — never a number | nothing |
| `packages` | a rough range, e.g. "roughly $550–$780, Connell confirms" | prices in `knowledge/crea-knowledge.md` |
| `calculator` | one estimate figure, e.g. "about $980, Connell confirms" | `knowledge/pricing.json` (copy `pricing.example.json`) |

`defer` is the safe default and exactly what v3 does. Use `packages` if you're happy with
a ballpark going out. Use `calculator` only if your pricing is a clean formula (base +
per-bedroom + size + add-ons) — see the file below.

## Decision 2 — what the read-back includes  `CREA_CONFIRM_MODE`

| value | the read-back | |
|---|---|---|
| `booking_only` *(default)* | booking details only, no price | you send the quote afterwards |
| `with_price` | includes the estimate from decision 1 | needs `packages` or `calculator` |

## Decision 3 — what happens when the customer says yes  `CREA_AUTO_BOOK`

| value | what happens |
|---|---|
| `hold` *(default)* | CREA **holds** the booking and WhatsApps you the brief + estimate + a one-tap **`CONFIRM <ref>`** / **`DECLINE <ref>`**. You reply `CONFIRM 4A2`; CREA creates the real Acuity appointment (if Acuity is connected), tells the customer they're confirmed, and writes the job note. |
| `off` | CREA just hands you a "quote-ready enquiry" with the full brief — you book it yourself. This is v3 behaviour. |

**Nothing is ever booked without your `CONFIRM`.** The customer confirms the details; you
confirm the booking. Two humans in the loop before anything hits your calendar.

### Confirming when CREA is on your own number

If CREA runs on a **separate** WhatsApp number, just reply `CONFIRM 4A2` in the chat CREA
messages you from. If CREA runs on **your own** number (shared), your own messages don't
reach it — instead:

```bash
./go-live.sh --confirm 4A2      # or --decline 4A2
```

or say it to the CREA voice assistant: *"CREA, confirm booking 4A2."*

---

## `knowledge/pricing.json` (calculator mode only)

Copy `knowledge/pricing.example.json` to `knowledge/pricing.json` and put your numbers in.
CREA computes: **package base + per-bedroom + per-bathroom + per-extra-level + size (per m²
or a band) + pool + feature add-ons + service add-ons**, applies your minimum, rounds.

```jsonc
{
  "currency": "AUD", "minimum": 250, "round_to": 5,
  "packages": [
    { "name": "Photos", "match": "photo", "base": 295 },
    { "name": "Video",  "match": "video", "base": 450 },
    { "name": "Photos + Video", "match": "combo", "base": 650 }
  ],
  "per_bedroom": 15, "per_bathroom": 10, "per_extra_level": 60,
  "size_tiers": [ { "max_sqm": 200, "add": 0 }, { "max_sqm": 350, "add": 80 },
                  { "max_sqm": 600, "add": 180 }, { "add": 320 } ],
  "pool_addon": 60,
  "service_addons": { "drone": 150, "twilight": 180, "floor plan": 90, "3d tour": 280 }
}
```

Delete any line you don't use. It's a plain file — edit it any time, no restart needed
(`./go-live.sh` re-reads it; the running vault-api picks it up on the next estimate).

The estimate is **always** framed as "an estimate, Connell confirms the final quote" —
CREA never commits you to a number.

---

## Your setup interview

When you run the install, CREA's setup asks you these, in your words, and writes the
config for you:

1. Should CREA quote a price? (never / rough range / real estimate)
2. Your package prices, and — if a real estimate — your per-bedroom / size / add-on rules.
3. Read-back with the price, or details only?
4. When a customer confirms — hold it for your one-tap OK, or just hand you the lead?
5. Your Acuity appointment-type ID (Acuity → the type's page → the number in the URL).
6. The WhatsApp number CREA runs on (its own, or yours).

You can change any of these later in `config.env` and re-run `./go-live.sh`.
