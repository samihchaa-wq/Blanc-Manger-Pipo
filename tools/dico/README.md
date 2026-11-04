# Générer le livre du Dico

```sh
curl -sS https://kaikki.org/frwiktionary/raw-wiktextract-data.jsonl.gz \
  | gunzip | python3 -I tools/dico/extraire.py /tmp/mots.jsonl   # ~740 Mo lus en flux
python3 -I tools/dico/livre.py /tmp/mots.jsonl dico              # pages de 8 mots, 200 pages par fichier
```

`extraire.py` garde une entrée par mot français (nom, verbe, adjectif, adverbe),
sans noms propres, formes fléchies, renvois ni termes vulgaires, avec la première
définition propre. `livre.py` retire encore quelques familles peu jouables
(« … à nouveau », gentilés, communes, définitions manquantes), trie dans l'ordre
d'un dictionnaire et découpe en pages. Licence des données : voir `dico/LICENCE.md`.
