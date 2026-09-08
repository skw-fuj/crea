# New facet in ~15 minutes

The CREA pack is one *vertical* of a repeatable shape. To stand up the same kind of
assistant for any other facet (a different business, a personal line, a project inbox):

## 1. Pick your pieces from the TRIS OS families
You rarely build from scratch — the shapes already exist in `~/.claude/n8n/workflows/`:

| Need | Use |
|---|---|
| Inbound message → canned/LLM reply | `facet-template/facet-assistant.macro.json` |
| Send on any channel | `facet-template/channel-send.atomic.json` |
| Multi-step qualification (stages) | `../workflows/crea-02-booking-agent.macro.json` as the pattern, or `../../workflows/conversation-state.macro.json` |
| Scheduled digest / reminder | `../../workflows/scheduled-report.macro.json` |
| Webhook → validate → act | `../../workflows/reliable-ingress.macro.json` |
| Branch on intent | `../../workflows/llm-decision-router.macro.json` |
| Scrape → enrich | `../../workflows/scrape-enrich.macro.json` |

## 2. Copy the two template files, set the vars
```
cp facet-template/*.json  /tmp/myfacet/
cp facet-template/facet.config.example.env  /tmp/myfacet/facet.config.env
# edit facet.config.env  — ~10 values, mostly which channel + which LLM + knowledge URL
../fill-config.sh  /tmp/myfacet/facet.config.env      # (run from a folder holding the copies)
n8n import:workflow --separate --input=/tmp/myfacet/_filled/
```

## 3. Wire it
- Point the channel's inbound webhook at `…/webhook/<FACET_INBOUND_PATH>`.
- Create an n8n **Data Table** `keyword | reply` and put its id in `FACET_CANNED_TABLE_ID` (leave blank for pure-LLM).
- Select credentials in any credential-typed node (OmniRoute header auth, etc.).
- Activate.

## 4. Register (optional, for orchestration)
Add it to a recipe (`../../workflows/orchestrator.recipe.json`) as an Execute-Workflow node
if other automations should call it. See `../../COMPOSITION.md`.

## The rule
Reference, don't copy. One `channel-send` serves every facet. One `facet-assistant`
shape, N configs. Improve the shape once → every facet benefits.
