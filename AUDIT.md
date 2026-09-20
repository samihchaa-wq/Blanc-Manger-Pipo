# Audit complet — Le Soulièteur

État audité : `bcdd5f4` (= `origin/main`). Périmètre : `index.html` (client), `supabase/migrations/*`
(schéma + RPC), `supabase/seed.sql`, `sw.js`, `tests/sanity.mjs`, `.github/workflows/*`.

Méthode : lecture intégrale du client et reconstitution de l'état effectif des fonctions SQL après
application des 30 migrations dans l'ordre (chaque `create or replace` écrase la précédente — plusieurs
régressions viennent de là). La logique de composition des phrases a été extraite et exécutée sur un jeu
de cas réels.

Les constats sont classés par gravité. Aucun correctif n'est appliqué dans ce document.

---

## P0 — Bloquants

### 1. Une partie terminée peut rester bloquée définitivement si un joueur part

`finished` est le seul statut sans filet de sécurité.

- `continue_game` ne relance le salon que si **aucun joueur actif** n'a `continue_requested = false`.
- Si 3 joueurs sur 4 ont cliqué « Refaire une partie » et que le 4e quitte, `_remove_player` ne fait
  rien : son bloc de rattrapage couvre `question_select`, `answering`, `judging`, `reveal` — pas
  `finished` (`20260920120000_phase_timeouts_cleanup_admin_hardening.sql:126`).
- Le quorum n'est donc jamais réévalué.
- Il le serait si quelqu'un recliquait, mais le client désactive le bouton dès que
  `state.me.continue_requested` est vrai (`index.html:1023`).
- `reap_idle` n'a pas de branche `finished`, et `TIMED` (`index.html:546`) l'exclut : aucun minuteur ne
  débloque.

**Résultat : écran de fin figé, aucune sortie possible hors « Quitter ».** Le même trou existe en
`reveal` (`next_round` a le même quorum, `_remove_player` ne le réévalue pas non plus), mais là
`reap_idle` rattrape au bout de 2 min.

Correctif : ajouter la réévaluation des quorums `next_ack_round` / `continue_requested` en fin de
`_remove_player`, et traiter `finished` dans `reap_idle`.

### 2. Les bots deviennent impossibles à relancer après une partie

`add_bot` insère le bot avec `ready = true`, et rien ne peut le repasser à `true` ensuite
(`set_ready` n'agit que sur l'appelant, aucun RPC ne cible un autre joueur).

Or les deux chemins de retour au salon remettent **tout le monde** à `ready = false` :

- `continue_game` — `20260918190000_remove_bots.sql:47`
- `bot_step` (branche `finished`) — `20260920150000_bot_step_advance_after_ack.sql:66`

Et `start_game` refuse de démarrer tant qu'un joueur actif n'est pas prêt.

**Résultat : après « Refaire une partie » avec des bots, l'hôte ne peut plus jamais lancer la partie.**
Seule issue : retirer chaque bot et en recréer.

Cause racine : la version d'origine écrivait `ready = is_bot`
(`20260917135012_full_game_flow_ready_four_questions_bots.sql`). `20260918190000_remove_bots` l'a
simplifiée en `ready = false` puisqu'il n'y avait plus de bots, et `20260920140000_reintroduce_bots` a
réintroduit les bots **sans restaurer `continue_game`**.

Correctif : `ready = is_bot` dans les deux endroits.

### 3. Un environnement neuf est injouable : `seed.sql` ne contient aucune réponse

`supabase/seed.sql` contient 135 questions et **0 réponse** (la migration
`20260918020000_purge_answers_and_keep_author_casing.sql` a supprimé toutes les réponses de production
et le seed n'a jamais été regarni).

Conséquence d'un `supabase db reset` :

- `_deal` n'insère rien → toutes les mains sont vides ;
- l'écran de réponse s'affiche sans carte, aucun envoi possible ;
- `_maybe_judge` ne se déclenche jamais ; au bout de 2 min `reap_idle` exclut tous les joueurs hors
  lecteur et renvoie au salon — en boucle.

`supabase/README.md` affirme pourtant « 135 questions and 352 answers as of 2026-09-17 » : la
documentation est fausse et masque le problème.

Correctif : versionner le catalogue de réponses dans `seed.sql` (avec la colonne `form`, ou en laissant
le trigger `_answers_set_form` la calculer) et corriger le README.

---

## P1 — Importants

### 4. Un bot peut devenir hôte, et plus rien ne fonctionne

`_remove_player` réattribue l'hôte au joueur actif de plus petit siège, **sans exclure les bots** :

```sql
set host_id = (select id from public.players where room_id = r.id and active order by seat limit 1)
```
(`20260920120000_phase_timeouts_cleanup_admin_hardening.sql:121`)

Si le siège 0 (l'humain hôte) part et que le siège 1 est un bot, le bot devient hôte. Or :

- `start_game`, `add_bot` et `kick_player` exigent d'être l'hôte → plus aucun humain ne peut agir ;
- `scheduleBots` (`index.html`) ne pilote les bots que depuis le client de l'hôte
  (`isMe(state.room.host_id)`) → **plus personne ne fait avancer les bots**, la partie ne survit que
  par `reap_idle` toutes les 2 min.

Chemin d'accès sans départ volontaire : `reap_idle` exclut le lecteur inactif en `question_select` ou
`judging` — si ce lecteur est l'hôte, même résultat.

Correctif : `... and not is_bot ...` dans la réattribution, avec repli sur un bot seulement s'il ne
reste aucun humain (et dans ce cas, fermer la salle).

### 5. Décalage d'horloge client : boucle d'appels serveur à 500 ms

`phaseDeadline()` (`index.html:547`) compare `phase_at` du serveur à `Date.now()` du téléphone, sans
aucune correction de dérive.

Si l'horloge du client avance de plus de 2 min :

1. l'échéance paraît dépassée en permanence ;
2. `scheduleReap` appelle `reap_idle` ;
3. le serveur revérifie, ne fait rien, mais `refresh(true)` force un rendu → `scheduleAuto` →
   `scheduleReap` → `Math.max(0, dl - Date.now()) + 500` = **500 ms** ;
4. nouvel appel, indéfiniment.

Chaque client mal réglé martèle ainsi le serveur, avec l'anneau de minuteur affiché vide en permanence.

Correctif : renvoyer `now()` dans `get_state`, mémoriser `skew = Date.parse(now) - Date.now()` et
l'appliquer dans `phaseDeadline()` et dans le calcul d'âge de la roue. Ajouter un délai plancher
(ex. 10 s) entre deux `reap_idle`.

### 6. `admin_level` est un déni de service non authentifié

`admin_level`, `_is_admin` et `_is_admin_plus` prennent tous un **verrou consultatif global**
(`bmp-admin-global`) puis font `pg_sleep(1.5)` en cas d'échec
(`20260920120000_phase_timeouts_cleanup_admin_hardening.sql`, section 5b).

`admin_level` est `grant execute ... to anon`, sans limitation de débit ni compteur de tentatives.

N requêtes concurrentes avec un mot de passe faux se sérialisent sur le verrou global et immobilisent
chacune une connexion pendant ≥ 1,5 s. Avec un pool PostgREST de quelques dizaines de connexions,
quelques centaines de requêtes suffisent à **affamer tout le reste de l'API** — `get_state` compris,
donc le jeu entier.

Le verrou global a été introduit pour empêcher le parallélisme par usurpation d'IP ; il transforme une
protection anti-bruteforce en amplificateur de DoS.

Correctif : retirer le `pg_sleep` du chemin SQL (échec immédiat), remplacer par un compteur de
tentatives par empreinte client persisté en table avec fenêtre glissante, et conserver au plus un
verrou par client.

### 7. Les limites de débit par IP sont contournables si `cf-connecting-ip` est absent

`_client_hash` (même migration, section 5a) prend `cf-connecting-ip`, sinon **le premier élément** de
`x-forwarded-for`. Ce premier élément est celui envoyé par le client : `X-Forwarded-For: 1.2.3.4` le
fixe arbitrairement, le proxy ne fait qu'ajouter la vraie IP à droite.

Si `cf-connecting-ip` ne remonte pas jusqu'à `request.headers` (dépend de la chaîne de proxy Supabase,
non vérifiable depuis ce dépôt), toutes les protections reposant sur l'empreinte tombent : création de
parties (10 / 10 min), tentatives de connexion (30 / 10 min), verrou anti-bruteforce admin par client.

Correctif : ne jamais faire confiance au premier élément — prendre le dernier, ou le n-ième depuis la
droite selon le nombre de proxys connus, et refuser de limiter silencieusement plutôt que de limiter
sur une valeur falsifiable.

### 8. Joueurs fantômes : `last_seen` est écrit mais jamais lu

`players.last_seen` est mis à jour dans `get_state` (toutes les 5 min) et **n'est lu nulle part** :
aucune purge par inactivité n'existe.

Combiné à deux chemins qui abandonnent une session sans appeler `leave_room` :

- `index.html:1334` — ouvrir un lien d'invitation vers une autre partie fait `save(null)` ;
- `leaveLocal()` sur « Session expirée » ;
- fermeture d'onglet (aucun `pagehide` / `beforeunload`).

Un joueur qui ferme son navigateur dans le salon y reste **actif et non prêt pour toujours**
(jusqu'à la purge des salles à 24 h), ce qui empêche `start_game`. L'hôte doit le retirer à la main.

`reap_idle` ne couvre que les phases de jeu, pas le salon.

Correctif : exploiter `last_seen` (exclusion après N minutes d'absence, au moins dans le salon) et
appeler `leave_room` sur `pagehide`.

---

## P2 — Moyens

### 9. La roue du lecteur se rejoue à chaque petite mise à jour

`qselect()` (`index.html:906`) calcule l'âge de la phase à partir de `r.updated_at`, qui bouge à la
moindre action (départ d'un joueur, `bot_step`…). `phase_at` existe précisément pour ça et n'est pas
utilisé ici : un départ pendant `question_select` relance la roue 2 s pour tout le monde.

### 10. `pick_winner` a perdu sa garde d'intégrité

La version durcie de `20260917133009_winner_integrity_and_privileged_path_hardening.sql` vérifiait
`if sc is null then raise ...` après l'incrément de score. Les réécritures successives
(`20260917135012`, puis `20260920120000`) ont supprimé ce contrôle. Si `sc` était `NULL`,
`sc >= r.target_score` vaut `NULL` et le `case` retombe silencieusement sur `reveal` avec un
`winner_id` inactif.

Non exploitable aujourd'hui (le verrou `for update` sur la salle sérialise `_remove_player`), mais la
garde retirée était la seule protection explicite.

### 11. Aucun retour en cas de perte de réseau

`refresh()` (`index.html:495`) n'intercepte que « Session expirée » et **avale toutes les autres
erreurs**. Hors connexion ou en cas de panne Supabase :

- le premier chargement reste sur « Connexion à la partie… » indéfiniment ;
- en partie, l'écran se fige sans le moindre message.

Le service worker sert bien la page hors ligne, mais l'application est inutilisable sans réseau et ne
le dit pas. Il manque un état « hors connexion » et une reprise visible.

### 12. Les bots n'ont pas de garde-fou anti-boucle

`scheduleBots` réarme `bot_step` toutes les 900 ms tant qu'un bot a quelque chose à faire, sans
détecter l'absence de progrès. Si un bot ne peut pas jouer (catalogue de réponses quasi vide, phrase à
deux trous avec une main d'une carte), la boucle tourne indéfiniment. Elle retombe à 4 s si
`bot_step` lève une exception (le `catch` vide court-circuite `refresh`), mais ne s'arrête jamais.

Correctif : compter les appels sans changement d'état et suspendre après 2 ou 3 essais.

### 13. Rien ne garantit qu'une main contienne une carte jouable pour la phrase tirée

`_deal` garantit 3 verbes et 3 groupes nominaux, mais **les questions ne portent aucune forme
attendue**. La question 7 du catalogue, « Mon psy m'a conseillé d'arrêter ____ », n'accepte qu'un
groupe nominal : les 3 verbes de la main y produisent « d'arrêter aller chez le kiné ». À l'inverse,
« Ce soir, au lieu de dormir, je vais ____ » n'accepte qu'un verbe.

La moitié de chaque main est donc régulièrement inutilisable ou absurde. L'ajout de `form` sur
`answers` (`20260918120000`) n'a résolu que la moitié du problème : il manque la symétrique sur
`questions` (forme attendue par trou), et `submit_answer` ne la contrôle pas.

### 14. Les codes de partie sont énumérables

4 chiffres = 10 000 codes. `join_room` distingue clairement « Aucune partie avec ce code », « La partie
a déjà commencé » et « Ce pseudo est déjà pris » : l'existence d'une salle est directement observable.
La limite est de 30 tentatives / 10 min / empreinte — et cette empreinte est contournable (cf. §7).

Impact réel limité (jeu de soirée), mais rien n'empêche un intrus de rejoindre un salon au hasard.
Un verrou de salon côté hôte, ou un code à 6 chiffres, réduirait la surface.

### 15. Les canaux temps réel ne sont pas authentifiés

`connect()` s'abonne à `'room-' + session.code` avec la clé publiable. N'importe qui connaissant (ou
devinant) un code peut s'abonner et **émettre** des `bump`. La charge utile est vide, donc aucune fuite
de données, mais chaque `bump` force un `get_state` sur tous les clients de la salle (débounce 250 ms) :
amplification triviale. À traiter avec Realtime Authorization si la fonctionnalité est activable.

---

## P3 — Mineurs & hygiène

**Client**

- `index.html:976` — l'écran d'attente du jugement passe `subs.length` pour dimensionner la pile de
  cartes, mais `get_state` renvoie `submissions = []` aux non-lecteurs : la pile est toujours réduite
  à une carte. Le paramètre ne sert à rien.
- Le bouton « Afficher plus » du catalogue (`admin-more`) se désactive et **ne se réactive pas** en cas
  d'erreur, contrairement à `admin-del` et `admin-form`.
- `render()` n'a pas de branche par défaut : un statut inconnu renvoyé par le serveur produit un
  `TypeError` et une page blanche.
- Les messages d'erreur Postgres bruts sont affichés tels quels dans le toast (`act()`,
  `index.html:478`) — fuite de détails internes sur les erreurs non prévues.
- Élision : `ce` est traité comme élidable (`ELIDE`), ce qui donnerait « c'avion » au lieu de « cet
  avion ». `ma / ta / sa` ne sont pas traités (« ma amie »). Aucune phrase du catalogue actuel ne
  déclenche le cas, mais l'admin peut en ajouter une.
- Aucun `<noscript>` : sans JavaScript la page est entièrement vide.
- Pas de CSP (`<meta http-equiv>` possible même sur GitHub Pages) alors que tout le rendu passe par
  `innerHTML`. L'échappement est correct partout — vérifié point par point, aucune injection trouvée —
  mais une CSP serait une défense en profondeur utile.
- Google Fonts en CDN tiers : requête bloquante au rendu et IP des joueurs transmise à Google.
- Accessibilité : `role="tablist"` sans `role="tabpanel"` ni `aria-controls` ; roue sans équivalent
  textuel ; changements d'écran sans région live ; cibles tactiles sous 44 px (`.link` ≈ 35 px,
  `.catlist .del` 32 px, `.catlist .form` 30 px).
- `og:image` et `twitter:image` sont des chemins relatifs — les scrapeurs attendent des URL absolues.
- `manifest.webmanifest` : pas d'icône `purpose: "maskable"` (rognage en cercle blanc sur Android),
  pas de champ `id`. `theme_color` (`#120714`) ne correspond pas à `--bg-0` (`#110519`).

**Base de données**

- Colonnes mortes : `rooms.previous_reader_id` (écrite, jamais lue — `_random_reader` exclut le lecteur
  courant), `players.last_seen` (cf. §8).
- Champs morts dans `get_state` : `room.target`, `room.submission_count` — jamais consommés par le
  client.
- RPC exposés à `anon` sans aucun appelant : `card_counts`, `admin_check`, `admin_update_card`,
  `force_judging`. Surface d'attaque gratuite.
- `admin_add_card` accepte `_is_admin` (niveau `admin` **ou** `plus`) pour les deux types de carte,
  alors que `supabase/README.md` décrit `admin_hash` comme limité aux réponses.
- `reap_idle` en `answering` boucle sur un `select` figé et appelle `_remove_player` pour chaque joueur,
  sans revérifier l'état de la salle entre deux : les exclusions continuent même après le retour au
  salon.
- `admin_delete_card` boucle sur les salles concernées et appelle `_deal` sans poser de verrou : course
  possible avec une partie en cours.

**Dépôt / CI**

- `supabase/README.md` « Current production migration tail » n'énumère que 8 migrations et saute les
  11 intermédiaires (`135012` → `20260919120000`). Présenté comme la queue de migration, c'est
  trompeur.
- `README.md` mentionne un « transactional game-flow test » dans le processus de changement : aucun
  test SQL n'existe dans le dépôt.
- `tests/sanity.mjs` teste des **chaînes de caractères exactes** du source (`setInterval(()=>{if(!document.hidden)refresh()},4000)`,
  `id="c-target" value="5"`…). C'est délibéré, mais tout reformatage casse la CI sans qu'un
  comportement ait changé. Aucune couverture de la logique métier (`fill`, roue, quorums).
- `.github/workflows/pages.yml` accorde `contents: write` à tout le workflow, y compris au job `test`
  qui n'en a pas besoin. L'étape « Make branch deployment self-contained » est aujourd'hui un no-op
  (le dépôt pointe déjà sur `./vendor/supabase.js` et le fichier est versionné) mais peut encore
  pousser un commit sur `main` depuis un déploiement.
- `index.html` : 1 344 lignes, 77 Ko, CSS + HTML + JS dans un seul fichier, sans build. Cohérent avec
  le choix « une page, zéro dépendance », mais la limite de maintenabilité est atteinte.

---

## Ce qui est solide

Le relevé serait déséquilibré sans ça :

- **Aucune faille XSS.** Toutes les entrées utilisateur (pseudos, textes de carte, code d'URL,
  pseudo en `localStorage`) passent par `esc()` avant insertion, attributs compris. Vérifié sink par
  sink.
- **Modèle d'autorisation correct.** RLS activée, aucun `grant` direct sur les tables, surface
  exposée réduite à des RPC `security definer` avec `search_path` vide et références qualifiées.
  Chaque RPC revalide le jeton du joueur et l'autorisation métier — le client ne peut rien affirmer.
- **Aucun secret dans le dépôt.** Seule la clé publiable est présente ; `tests/sanity.mjs` vérifie
  explicitement l'absence de clé de service.
- **Verrouillage transactionnel cohérent.** `select ... for update` sur la salle avant toute mutation
  d'état : les jointures concurrentes, les envois simultanés et les appels `reap_idle` en rafale sont
  correctement sérialisés.
- **Le rendu est bien pensé.** Diff par comparaison de chaîne (`lastHtml`) avant écriture du DOM,
  animation d'entrée réservée aux changements d'écran, gel du rendu pendant un glissement,
  neutralisation du clic fantôme, mesure réelle de la barre d'action (`fitDock`) au lieu d'une
  hauteur devinée. Ces choix règlent de vrais problèmes mobiles.
- **La composition des phrases fonctionne.** Élisions, contractions (`à` + `les` → `aux`, `de` + `des`
  → `des`), majuscule en tête de phrase, préservation des noms propres : vérifié sur 20 cas, tous
  corrects.
- **La roue est mathématiquement juste.** L'angle d'arrêt place bien le lecteur sous la flèche et le
  retournement des étiquettes est calculé sur l'angle final, pas l'angle de départ.
- **Le CSS ne contient aucune classe morte** (vérifié par balayage croisé).
- **L'historique des migrations documente ses propres erreurs** (`drop_legacy_round_path`,
  `keep_reader_hand`, `drop_submit_answer_overload`). Les commentaires expliquent le *pourquoi*, pas le
  *quoi* — c'est rare et précieux.

---

## Ordre d'attaque suggéré

1. **§3** (seed sans réponses) — sans ça, aucun environnement neuf ne fonctionne, donc rien n'est
   testable.
2. **§1** et **§2** — les deux blocages définitifs rencontrés en partie réelle. Correctifs courts.
3. **§4** (bot hôte) — une ligne, empêche une salle de devenir ingouvernable.
4. **§5** (dérive d'horloge) et **§12** (boucle bots) — les deux sources de martèlement du serveur.
5. **§6** et **§7** — la surface d'abus la plus sérieuse ; à traiter ensemble, le verrou global et
   l'empreinte falsifiable étant deux faces du même compromis.
6. **§8** (fantômes), puis le reste par gravité.

Avant de corriger quoi que ce soit : ajouter au moins un test de flux de partie en transaction (créer →
prêt → lancer → choisir → répondre → juger → révéler → rejouer), sans quoi les régressions
§1/§2/§4 se reproduiront exactement comme elles se sont produites — par réécriture d'une fonction sans
relire ce que la précédente garantissait.
