# Lit le flux JSONL du Wiktionnaire (wiktextract) sur l'entrée standard et garde
# une entrée par mot français : nature, première définition propre.
import sys, json, re
POS = {'noun':'nom','verb':'verbe','adj':'adjectif','adv':'adverbe'}
MOT = re.compile(r"^[a-zàâäçéèêëîïôöùûüÿœæ][a-zàâäçéèêëîïôöùûüÿœæ'’-]{1,22}$")
MAUVAIS_TAGS = {'form-of','alt-of','vulgar','offensive','abbreviation','obsolete-form','misspelling'}
RENVOI = re.compile(r"^(pluriel|féminin|masculin|participe|première|deuxième|troisième|forme|variante|synonyme|abréviation|graphie|ancienne orthographe|orthographe|diminutif de|augmentatif de|ellipse de|apocope|aphérèse|sigle|acronyme|relatif à|qui concerne|celui qui|action de)\b", re.I)
vus, n_fr, sortie = set(), 0, open(sys.argv[1], 'w', encoding='utf-8')
for line in sys.stdin:
    if '"lang_code": "fr"' not in line[:400] and '"lang_code":"fr"' not in line[:400]: continue
    try: d = json.loads(line)
    except Exception: continue
    if d.get('lang_code') != 'fr': continue
    n_fr += 1
    w, pos = d.get('word',''), d.get('pos')
    if pos not in POS or w in vus or not MOT.match(w): continue
    if set(d.get('tags') or []) & MAUVAIS_TAGS: continue
    df = None
    for s in d.get('senses') or []:
        tags = set(s.get('tags') or [])
        if tags & MAUVAIS_TAGS or s.get('form_of') or s.get('alt_of'): continue
        g = ' '.join(s.get('glosses') or []).strip()
        g = re.sub(r'\s+', ' ', g)
        if not g or RENVOI.match(g) or w.lower() in g.lower().split()[:3]: continue
        if not (18 <= len(g) <= 190): continue
        df = g if g.endswith(('.', '!', '?', '…')) else g + '.'
        break
    if not df: continue
    t = set(d.get('tags') or [])
    nature = POS[pos]
    if pos == 'noun': nature += ' féminin' if 'feminine' in t else ' masculin' if 'masculine' in t else ''
    vus.add(w)
    sortie.write(json.dumps({'m': w, 'n': nature, 'd': df}, ensure_ascii=False) + '\n')
sortie.close()
print('entrées françaises lues :', n_fr, '| gardées :', len(vus), file=sys.stderr)
