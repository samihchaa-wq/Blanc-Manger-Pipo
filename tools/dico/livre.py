# Second filtre, tri alphabétique « à la française », découpage en pages.
# Usage : python3 -I livre.py mots.jsonl dossier_sortie
import sys, json, re, os, unicodedata
src, out = sys.argv[1], sys.argv[2]
PAR_PAGE, PAGES_PAR_FICHIER = 8, 200
JETER = [
  re.compile(r"\b(à nouveau|de nouveau|une (seconde|deuxième|troisième|nouvelle|autre) fois)\b", re.I),   # re-signer, re-témoigner…
  re.compile(r"^(relatif|relative|relatifs|relatives) (à|au|aux)\b", re.I),
  re.compile(r"^(habitant|habitante|natif|native|originaire)s? (de|du|des|d’|d')", re.I),
  re.compile(r"\bcommune (française|italienne|espagnole|belge|suisse|allemande|canadienne)\b|\bdépartement\b|\bcanton\b", re.I),
  re.compile(r"^(nom|prénom|patronyme|surnom) (de|du|d’|d')", re.I),
  re.compile(r"\b(variante|synonyme|abréviation|graphie|orthographe) (de|du|d’|d')", re.I),
  re.compile(r"\b(sexuel|sexuelle|pénis|vagin|sodom|coït|prostitu|nazi)\w*", re.I),
  re.compile(r"définition manquante|à compléter|\(ajouter\)|\bsens (à préciser|inconnu)\b", re.I),
]
NATURE = {'nom masculin':'n. m.', 'nom féminin':'n. f.', 'nom':'n.', 'verbe':'v.', 'adjectif':'adj.', 'adverbe':'adv.'}
def cle(m):
    base = ''.join(c for c in unicodedata.normalize('NFD', m.lower()) if unicodedata.category(c) != 'Mn')
    return (re.sub(r"[-'’]", '', base).replace('œ', 'oe').replace('æ', 'ae'), m)
mots = []
for l in open(src, encoding='utf-8'):
    e = json.loads(l); d = e['d']
    if len(d) > 170 or any(r.search(d) for r in JETER): continue
    mots.append([e['m'], NATURE.get(e['n'], e['n']), d])
mots.sort(key=lambda e: cle(e[0]))
pages = [mots[i:i + PAR_PAGE] for i in range(0, len(mots), PAR_PAGE)]
os.makedirs(out, exist_ok=True)
for f in range(0, len(pages), PAGES_PAR_FICHIER):
    with open(os.path.join(out, f'p{f // PAGES_PAR_FICHIER:03d}.json'), 'w', encoding='utf-8') as fh:
        json.dump(pages[f:f + PAGES_PAR_FICHIER], fh, ensure_ascii=False, separators=(',', ':'))
index = {'pages': len(pages), 'parFichier': PAGES_PAR_FICHIER, 'mots': len(mots),
         'source': 'Définitions : Wiktionnaire (https://fr.wiktionary.org), licence CC BY-SA 4.0, extraites via Wiktextract (kaikki.org).'}
json.dump(index, open(os.path.join(out, 'index.json'), 'w', encoding='utf-8'), ensure_ascii=False)
print(json.dumps(index, ensure_ascii=False))
