import json, glob, sys
# for the offline test both OmniRoute slots point at the one existing credential
OMNI = {"id": "creaomniroutecred", "name": "CREA OmniRoute"}
ACU  = {"id": "creaacuitycred",   "name": "CREA Acuity"}
HIGG = {"id": "creahiggscred",    "name": "CREA Higgsfield"}
d = sys.argv[1]
for fn in glob.glob(d + "/*.json"):
    o = json.load(open(fn)); ch = False
    for nd in o["nodes"]:
        p = nd.get("parameters", {})
        if p.get("authentication") != "genericCredentialType":
            continue
        gt = p.get("genericAuthType"); nm = (p.get("url", "") + " " + nd["name"]).lower()
        if "higgsfield" in nm:
            nd["credentials"] = {"httpHeaderAuth": HIGG}
        elif gt == "httpHeaderAuth":
            nd["credentials"] = {"httpHeaderAuth": OMNI}
        elif gt == "httpBasicAuth":
            nd["credentials"] = {"httpBasicAuth": ACU}
        ch = True
    if ch:
        json.dump(o, open(fn, "w"), indent=2, ensure_ascii=False)
print("test creds attached in", d)
