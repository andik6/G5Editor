"""Builds effects.json (names, parameters, ranges) from the legacy Edit&Share
G5 resource folder. Only parameter data is extracted; no artwork."""
import sys, re, os, json, glob
R, out = sys.argv[1], sys.argv[2]
manual = open(sys.argv[3]).read().replace("\n", " ") if len(sys.argv) > 3 else ""
norm = lambda n: re.sub(r"[^a-z0-9]", "", n.lower())
desc = {}
for _, n, d in re.findall(r"\b(\d{3}) ([A-Za-z0-9.+&\-' ]{2,12}?) ((?:This|These|An?|The|Simulation|Modeled|Model|Combin)[^.]{10,200}\.)", manual):
    desc.setdefault(norm(n), d.strip())
AMPS = {}
for line in re.findall(r"([A-Z0-9\- ]+?) (\d[xX]\d{2}) ((?:Fender|British|Early|Mesa|Matchless|Carr|Two Rock|Cabinet|Hiwatt|Orange|Marshall|Bogner|Diezel|Engl|Krank)[^.]*?speakers?)", manual):
    AMPS.setdefault(norm(line[0]), line[1].lower() + " · " + line[2])
mod = open(os.path.join(R, "Module.xml"), encoding="utf-8-sig").read()
unit1 = re.search(r"<UNIT1>(.*?)</UNIT1>", mod, re.S).group(1)

def unesc(s): return s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"')

def ctrls(fname):
    p = os.path.join(R, fname + ".zrc")
    if not os.path.exists(p): return None, []
    b = open(p, "rb").read()
    m = re.search(rb"<TypeInfo>.*?</TypeInfo>", b, re.S)
    if not m: return None, []
    x = m.group(0).decode("utf-8", "replace")
    cat = re.search(r"<EfxCategory>([^<]*)<", x)
    params = {}
    for attrs, body in re.findall(r"<Ctrl ([^>]*)>(.*?)</Ctrl>", x, re.S):
        if 'type="dsp"' not in attrs: continue
        prm = int(re.search(r'prm="(\d+)"', attrs).group(1))
        name = re.search(r"<PrmName>([^<]*)<", body)
        mx = re.search(r"<DspMax>(\d+)<", body)
        if prm < 2 or not name or not mx or prm in params: continue
        g = lambda t: (re.search(rf"<{t}>(-?\d+)<", body) or [None, None])[1]
        table = [unesc(s) for s in re.findall(r"<String>([^<]*)</String>", re.search(r"<PrmTable>(.*?)</PrmTable>", body, re.S).group(1))] if "<PrmTable>" in body else None
        sync = re.search(r"<ImgPrmOffset>(\d+)<", body)
        nsync = len(re.findall(r"<String>Common:Sync", body))
        params[prm] = dict(syncFrom=int(sync.group(1)) if sync and nsync else None, syncCount=nsync,prm=prm, name=unesc(name.group(1)), max=int(mx.group(1)),
                           initial=int(g("InitDspVal") or 0), offset=int(g("PrmOffset") or 0),
                           pedal=bool(g("PrmRTM")), control=re.search(r"<Type>(\w+)<", body).group(1),
                           choices=table)
    return (unesc(cat.group(1)) if cat else None), [params[k] for k in sorted(params)]

types = []
for attrs, fname in re.findall(r"<Type([^>]*)>([^<]*)</Type>", unit1):
    a = dict(re.findall(r'(\w+)="([^"]*)"', attrs))
    if "EfxNoOnMachine" not in a: continue
    cat, prms = ctrls(unesc(fname))
    types.append(dict(id=int(a["EfxNoOnMachine"]), name=unesc(a["name"]), category=cat,
                      amp=a.get("modeling") == "1" and any(p["name"] == "CAB" for p in prms),
                      zpedal=a.get("IsZPedalEfx") == "1", thru=a.get("IsTHRU") == "1",
                      hidden=a.get("NotVisibleToTypeChg") == "1", params=prms,
                      description=desc.get(norm(a["name"])), cabinet=AMPS.get(norm(a["name"]))))
json.dump(types, open(out, "w"), indent=1, ensure_ascii=False)
print(len(types), "types;", sum(t["amp"] for t in types), "amps;", sum(t["zpedal"] for t in types), "Z-pedal;",
      [t["name"] for t in types if t["hidden"] or not t["params"]])
