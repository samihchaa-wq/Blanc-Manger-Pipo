# Supabase — Blanc Manger Pipo

Production project: `cartes-soiree` (`yqfewxadpyulgxehhpcu`).

## Security model

- The browser uses only the Supabase publishable key.
- Public tables have RLS enabled and no direct `anon`/`authenticated` table grants.
- The game is exposed through explicitly granted RPC functions.
- Internal helper functions are not executable by `anon` or `authenticated`.
- `SECURITY DEFINER` functions use an empty `search_path` and schema-qualified object references.
- The application is intentionally anonymous; gameplay/admin RPCs are not granted to the `authenticated` role.
- Creation/join abuse controls store only a salted/peppered one-way client fingerprint, never the raw client IP.

## Secrets

Never commit `app_settings.admin_hash`, the anti-abuse `rate_pepper`, a service-role/secret key, database password, or any Supabase access token.

For a fresh environment, create the admin password directly in that environment after applying the schema, for example from a trusted SQL session:

```sql
insert into public.app_settings(key, value)
values ('admin_hash', extensions.crypt('<ADMIN_PASSWORD>', extensions.gen_salt('bf', 10)))
on conflict (key) do update set value = excluded.value;
```

Do not replace `<ADMIN_PASSWORD>` inside a committed file.

## Migration history strategy

The production database was created before migrations were committed to this public repository. At least one historical migration contained environment-specific admin credential material, so the raw historical migration stream must not be copied here.

`supabase/migrations/20260917111656_game_schema_and_rpcs.sql` is therefore a **sanitized squashed baseline** of the current schema and RPC surface. It contains no admin hash and generates a fresh anti-abuse pepper at install time.

Historical production versions whose original SQL is unnecessary or sensitive are represented by deliberate no-op markers. This keeps local and remote migration version numbers aligned while avoiding publication of sensitive values or replaying changes already folded into the baseline. The independently committed `20260917133009_winner_integrity_and_privileged_path_hardening.sql` is intentionally retained with its real, non-secret forward SQL. New migrations created after this baseline must also contain their real forward SQL normally.

`supabase/seed.sql` contains only the active card catalogue (135 questions and 352 answers as of 2026-09-17). It intentionally excludes rooms, players, submissions, tokens and all `app_settings` values.

Current production migration tail:

- `20260917132852_production_hardening_and_game_fixes`
- `20260917133009_winner_integrity_and_privileged_path_hardening`
- `20260917133016_restore_admin_function_resolution` (transient repair, superseded)
- `20260917133047_repair_admin_search_path_hardening`
- `20260917133523_harden_remaining_security_definers`
- `20260920120000_phase_timeouts_cleanup_admin_hardening` (minuteurs de phase via `rooms.phase_at` + `reap_idle`, retrait de `skip_question`/`add_reward_card`/`_draw_question` et des colonnes `skips_used`/`reward_*`, sérialisation globale de l'auth admin, `cf-connecting-ip` prioritaire dans `_client_hash`)
- `20260920140000_reintroduce_bots` (colonne `players.is_bot`, `add_bot`, `bot_step`, `is_bot` exposé par `get_state` — pour tester une partie en solo)
- `20260920150000_bot_step_advance_after_ack` (les bots relancent la manche / la partie quand ils sont les derniers à valider)
- `20261018153154_tour_de_role_et_jeu_auto` (lecteur à tour de rôle via `_next_reader`, l'hôte d'abord, et `_random_reader` qui y délègue pour ses appelants existants ; `reap_idle` joue à la place des absents après 2 min via les RPC de jeu au lieu de les exclure ; résultat de manche limité à 5 s ; migration additive : `next_round` reste pour les clients pas encore mis à jour)
- `20261026140000_petit_bac` (quatrième jeu, à deux : `bac_category` pour proposer les six catégories de la partie à tour de rôle — gardées dans `rooms.bac_categories`, aucun catalogue —, `bac_save` pour la grille enregistrée au fil de la frappe, `bac_vote` pour juger catégorie par catégorie ; table `bac_answers` ; `_max_players` borne la salle à 2 joueurs ; migration additive)
- `20261105120000_barometre_inverse_mimes_white_tour` (Mr White : premier joueur tiré au sort puis rotation, `starter_id` dans `white_state` ; Baromètre `wave_variant` normal/inversé avec `set_wave_variant`, `submit_theme`, `wave_bot_step` ; nouveau jeu Mimes : tables `mime_cards`/`mime_parts`, `mime_rate`, `mime_bot_step`, statut `mime_play` ; `get_state`, `white_state`, `white_resume`, `create_room`, `set_room_options`, `_remove_player`, `_begin_wave_round`, `_begin_white_round` enveloppent leur ancienne version renommée en `*_base`)

- `20261104175320_etat_complet` et `20261104175401_etat_complet_phase_false` (`get_full_state` : une seule RPC par relecture, qui enchaîne `get_state`, `white_state` et `punish_state` côté serveur et relit l'état si `punish_state` vient de lancer la partie ; migration additive, le client retombe sur les trois RPC si elle est absente ; la seconde migration relit aussi l'état quand `punish_state` renvoie `phase: false`, sa valeur réelle hors saisie)

- `20261104230000_le_dico` (septième jeu, Le Dico : phases `dico_pick` → `dico_write` → `dico_vote` → `reveal`, tables `dico_defs` / `dico_votes` / `dico_points`, RPC `dico_pick`, `dico_write`, `dico_vote`, `dico_bot_step` ; branches ajoutées à `_begin_round`, `get_state`, `reap_idle`, `_time_phase_seconds`, `_remove_player`, `create_room`, `set_room_options`. Appliquée à la main dans l'éditeur SQL, en une transaction qui s'inscrit elle-même dans l'historique ; testée sur une copie de la production puis en production dans une transaction annulée — `supabase/tests/le_dico_scenario.sql`)

- `20261107120000_dilemme_parfait` (huitième jeu, Dilemme parfait : phases `dilemme_pick` → `dilemme_write` → `dilemme_vote` → `reveal`, tables `dilemme_buts` / `dilemme_votes` / `dilemme_points`, RPC `dilemme_pick`, `dilemme_write`, `dilemme_vote`, `dilemme_bot_step` ; branches ajoutées à `_begin_round`, `get_state`, `reap_idle`, `_time_phase_seconds`, `_remove_player`, `create_room`, `set_room_options`. Scénario : `supabase/tests/dilemme_scenario.sql`)

- `20261108120000_dilemme_cibles` (Dilemme parfait : cible secrète par joueur, de 10 à 90 % de Oui, table `dilemme_cibles` ; barème `_dilemme_points` selon l'écart à la cible, une fois retiré l'écart minimal atteignable : 3, 2 à 20 points près, 1 à 40 près ; `_dilemme_set_start`, `_dilemme_score` et `get_state` remplacés. Scénario : `supabase/tests/dilemme_cibles_scenario.sql`)

- `20261109120000_dilemme_cibles_adaptees` (cible = nombre de Oui entre 1 et « votants − 1 », toujours atteignable ; colonnes `target_yes` et `voters` ; `_dilemme_set_start` et `get_state` remplacés)

- `20261110120000_dilemme_modes` (Dilemme : modes de partie `rooms.dilemme_variant` — `moitie` (50/50, cible 50 % pour tous) ou `aleatoire` (cible tirée, défaut) — avec `set_dilemme_variant` ; `_dilemme_set_start` et `get_state` remplacés)
- `20261111120000_phrases_private_jokes` (Phrases à trou : `answers.pack` — `normal` ou `private`, toutes les réponses existantes passent en `private` — et `rooms.phrases_variant` (défaut `normal`) avec `set_phrases_variant` ; `_deal` ne distribue que le paquet de la salle ; `_rank_pool` ne lit plus que `priority_cards` ; questions visant le groupe retirées ; admin : `admin_add_card`/`admin_list_cards`/`admin_delete_card` gèrent le type `j` (Private jokes), catalogue Mimes `admin_add_mime_card`/`admin_list_mime_cards`/`admin_delete_mime_card` ; `get_state` enveloppe `_get_state_v8` et ajoute `room.phrases_variant`)
- `20261111120100_phrases_reponses_normales` (paquet Normal de Phrases à trou : 480 réponses, 240 groupes nominaux et 240 verbes)
- `20261112120000_salon_admin_refonte` (salon : `lancer_partie` marque tout le monde prêt puis appelle `start_game` ou `punish_start`, inchangées : l'hôte lance quand il veut ; Private Joke réservé au groupe : `set_phrases_variant(p_code, p_token, p_variant, p_secret)` demande le code du groupe (`app_settings.private_joke_hash`, défini par l'admin + avec `admin_set_private_code`) ou un code admin, avec la même garde que l'admin (un essai à la fois, 1,5 s de pause après un échec) ; la version à trois arguments n'accepte plus que Normal ; admin générique : `admin_cards_list`, `admin_card_add`, `admin_card_update` (texte, champs courts, type nom/verbe), `admin_card_delete` pour les sept catalogues `q`, `a`, `j`, `p`, `w`, `m`, `x`. Uniquement des fonctions créées ou remplacées ; les anciennes fonctions admin par jeu restent, plus rien ne les appelle. Scénario : `supabase/tests/salon_admin_scenario.sql`, à lancer sur une copie avec `-v admin=… -v plus=…`)
- `20261121120000_qcm` (neuvième jeu, QCM : quiz personnalisé écrit à l'avance par l'animateur, hors des salons — tables `qcm_quizzes` (code secret de 12 caractères, seule son empreinte est stockée), `qcm_questions` (2 à 4 réponses, la bonne, 1 à 3 points, commentaire), `qcm_room_questions` (copie faite au lancement), `qcm_answers` ; RPC `qcm_quiz_create`, `qcm_quiz_get`, `qcm_quiz_save`, `qcm_quiz_delete`, `qcm_select`, `set_qcm_variant` (Classique / Rapidité : +1 à la première bonne réponse), `qcm_answer`, `qcm_reveal`, `qcm_next`, `qcm_bot_step`, `qcm_state` ; phase `qcm_question` puis `reveal` ; l'hôte anime, ne répond pas et n'est jamais classé ni désigné perdant ; 2 à 30 joueurs ; temps par question : 15, 30 ou 60 s, ou illimité. Fonctions partagées reprises de la production avec la seule branche du QCM : `_begin_round`, `get_full_state`, `create_room`, `set_room_options`, `_min_players`, `_max_players`, `_time_phase_seconds`, `reap_idle`, `_remove_player`, `lancer_partie`, `_punish_loser`. Scénario : `supabase/tests/qa_qcm_scenario.sql`, joué en CI par `tests/sql/qcm_schema.sh` sur toutes les migrations rejouées)

## Change workflow

For future database changes:

1. Create a new migration rather than editing the squashed baseline.
2. Apply it to the intended Supabase project.
3. Run transactional game-flow tests so test rooms/data are rolled back.
4. Run Supabase security and performance advisors.
5. Commit the migration in the same PR as any client change that depends on it.

The current advisor warning `RLS enabled with no policy` is expected for this architecture because direct table grants are removed. Anonymous `SECURITY DEFINER` warnings are also expected only for the explicitly exposed browser RPC surface; each such function must still validate its player token/admin credential and operation-specific authorization internally.
