# A new assistant for another facet — in ~15 minutes

`facet-template/` is the CREA AI assistant with every domain specific stripped to a
`{{FACET_*}}` placeholder. Copy it, set ~12 values, register — you get the same shape:
context → knowledge → generate → parse JSON → reply → persist → escalate, with a safe
degrade when the model is down.

## The three files

| File | |
|---|---|
| `facet-assistant.macro.json` | inbound message → answer from knowledge → capture structured details → reply → escalate if it can't help. 11 nodes. |
| `channel-send.atomic.json` | the one outbound node — switches on `{{FACET_CHANNEL}}` (`waha` / `meta` / `telegram` / `webhook`), so the channel is a config choice. |
| `facet-scheduled-digest.macro.json` | cron → pull a source → optional LLM phrasing → deliver. For "send me a summary every morning". |

For anything more (multi-step qualification, scrape→enrich, a full pipeline) start from the
matching macro in the TRIS OS families at `~/.claude/n8n/workflows/` — see `../../COMPOSITION.md`.

## Stand one up

```bash
mkdir -p /tmp/myfacet && cp facet-template/*.json /tmp/myfacet/
cp facet-template/facet.config.example.env /tmp/myfacet/facet.config.env
#   edit facet.config.env — mainly:
#     FACET_CHANNEL + that channel's creds
#     FACET_OMNIROUTE_URL / FACET_LLM_MODEL
#     FACET_SYSTEM_PROMPT      (who the assistant is, its rules)
#     FACET_KNOWLEDGE_URL      (a GET ?q= endpoint returning {chunks:[...]} — the vault API does this)
#     FACET_INBOUND_PATH       (the webhook path)
#     FACET_ESCALATION_TO      (where "needs a human" goes)

../fill-config.sh facet.config.env /tmp/myfacet      # (run from a dir with fill-config.sh)
n8n import:workflow --separate --input=/tmp/myfacet/_filled/
```

Then in n8n: point the channel's inbound webhook at `…/webhook/<FACET_INBOUND_PATH>`, select
the `FACET OmniRoute` credential on the AI node, and activate.

## Knowledge

`facet-assistant` answers **only** from whatever `FACET_KNOWLEDGE_URL?q=` returns. The
`vault-api/server.js` in this pack is a ready implementation — point it at a markdown file
(`KNOWLEDGE_FILE=...`) and it does section retrieval. Anything the file doesn't cover, the
assistant says a human will follow up. It never invents.

## The rule

Reference, don't copy. One `channel-send` serves every facet. One `facet-assistant` shape,
N configs. Improve the shape once → every facet benefits.
