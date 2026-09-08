import json,glob,sys
CRED={"httpBasicAuth":{"id":"creaacuitycred","name":"CREA Acuity"},
      "httpHeaderAuth":{"id":"creaomniroutecred","name":"CREA OmniRoute"}}
HIGGS={"id":"creahiggscred","name":"CREA Higgsfield"}
d=sys.argv[1]
for fn in glob.glob(d+"/*.json"):
    o=json.load(open(fn)); ch=False
    for nd in o["nodes"]:
        p=nd.get("parameters",{})
        if p.get("authentication")=="genericCredentialType":
            gt=p.get("genericAuthType")
            if "higgsfield" in (p.get("url","")+nd["name"]).lower(): nd["credentials"]={"httpHeaderAuth":HIGGS}
            elif gt in CRED: nd["credentials"]={gt:CRED[gt]}
            ch=True
    if ch: json.dump(o,open(fn,"w"),indent=2,ensure_ascii=False)
print("test creds attached in",d)
