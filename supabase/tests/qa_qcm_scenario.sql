-- QCM de bout en bout, sur une copie du schéma de production avec la
-- migration 20261121120000_qcm appliquée. Tout se passe dans une transaction
-- annulée : aucun quiz ni salon de test ne reste.
--   psql -v ON_ERROR_STOP=1 -f supabase/tests/qa_qcm_scenario.sql
begin;

-- Un appel qui doit être refusé, avec le bon message.
create function pg_temp.refus(p_sql text, p_motif text) returns void language plpgsql as $f$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like 'QCM_QA%' then raise; end if;
    if sqlerrm not like p_motif then
      raise exception 'QCM_QA : refus inattendu pour « % » : %', p_sql, sqlerrm;
    end if;
    return;
  end;
  raise exception 'QCM_QA : accepté à tort : %', p_sql;
end $f$;

do $qa$
declare
  quiz json; k text; k2 text; saved json; s json; q json;
  room json; cd text; th uuid; h_id uuid;
  ja json; jb json; jc json; ta uuid; tb uuid; tc uuid; a_id uuid; b_id uuid; c_id uuid;
  r public.rooms; n integer; sc integer; loser uuid; i integer;
  vide json; code_vide text; t_vide uuid;
  questions jsonb := '[
    {"text":"Qui a marqué le plus de buts cette saison ?","choices":["Karim","Yanis","Théo","Malik"],"correct":2,"points":1,"note":"Théo : 14 buts !"},
    {"text":"On a gagné contre Saint-Denis ?","choices":["Vrai","Faux"],"correct":0,"points":2},
    {"text":"Combien de matchs joués ?","choices":["12","18","22"],"correct":1,"points":3,"note":""}
  ]';
begin
  -- ------------------------------------------------ Préparer le quiz
  quiz := public.qcm_quiz_create('  Fin   de saison  ');
  k := quiz->>'key';
  if k !~ '^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$' then
    raise exception 'QCM_QA : format du code inattendu : %', k;
  end if;
  if quiz->>'title' <> 'Fin de saison' then raise exception 'QCM_QA : titre non nettoyé : %', quiz->>'title'; end if;
  if json_array_length(quiz->'questions') <> 0 then raise exception 'QCM_QA : un nouveau quiz doit être vide'; end if;
  -- seule l'empreinte du code est stockée
  if exists (select 1 from public.qcm_quizzes where key_hash = k or key_hash = replace(k, '-', '')) then
    raise exception 'QCM_QA : le code est stocké en clair';
  end if;

  saved := public.qcm_quiz_save(k, 'Fin de saison 2026', questions);
  if json_array_length(saved->'questions') <> 3 then raise exception 'QCM_QA : 3 questions attendues'; end if;
  if (saved->'questions'->0->>'correct')::int <> 2 or (saved->'questions'->2->>'points')::int <> 3 then
    raise exception 'QCM_QA : bonne réponse ou points mal enregistrés : %', saved;
  end if;
  if saved->'questions'->2->>'note' is not null then raise exception 'QCM_QA : un commentaire vide doit valoir null'; end if;
  -- code saisi en minuscules, sans tirets : même quiz
  if public.qcm_quiz_get(lower(replace(k, '-', '')))->>'title' <> 'Fin de saison 2026' then
    raise exception 'QCM_QA : le code doit tolérer minuscules et tirets absents';
  end if;

  perform pg_temp.refus(format('select public.qcm_quiz_get(%L)', 'AAAA-BBBB-CCCC'), 'Code de quiz inconnu%');
  perform pg_temp.refus(format('select public.qcm_quiz_save(%L, %L, %L)', k, '', questions), '%titre%');
  perform pg_temp.refus(format('select public.qcm_quiz_save(%L, %L, %L)', k, 'T',
    '[{"text":" ? ","choices":["A","B"],"correct":0}]'), '%écris la question%');
  perform pg_temp.refus(format('select public.qcm_quiz_save(%L, %L, %L)', k, 'T',
    '[{"text":"Question ?","choices":["Seule"],"correct":0}]'), '%2 à 4 réponses%');
  perform pg_temp.refus(format('select public.qcm_quiz_save(%L, %L, %L)', k, 'T',
    '[{"text":"Question ?","choices":["A","B","C","D","E"],"correct":0}]'), '%2 à 4 réponses%');
  perform pg_temp.refus(format('select public.qcm_quiz_save(%L, %L, %L)', k, 'T',
    '[{"text":"Question ?","choices":["Oui","  "],"correct":0}]'), '%réponse est vide%');
  perform pg_temp.refus(format('select public.qcm_quiz_save(%L, %L, %L)', k, 'T',
    '[{"text":"Question ?","choices":["Paris","paris"],"correct":0}]'), '%identiques%');
  perform pg_temp.refus(format('select public.qcm_quiz_save(%L, %L, %L)', k, 'T',
    '[{"text":"Question ?","choices":["A","B"],"correct":2}]'), '%bonne réponse%');
  perform pg_temp.refus(format('select public.qcm_quiz_save(%L, %L, %L)', k, 'T',
    '[{"text":"Question ?","choices":["A","B"],"correct":0.5}]'), '%bonne réponse%');
  perform pg_temp.refus(format('select public.qcm_quiz_save(%L, %L, %L)', k, 'T',
    '[{"text":"Question ?","choices":["A","B"],"correct":0,"points":4}]'), '%1, 2 ou 3 points%');
  -- un enregistrement refusé ne doit rien avoir effacé
  if json_array_length(public.qcm_quiz_get(k)->'questions') <> 3 then
    raise exception 'QCM_QA : un enregistrement refusé a modifié le quiz';
  end if;

  -- ------------------------------------------------ Salon
  room := public.create_room('Animateur', 5, 'qcm', 2);
  cd := room->>'code'; th := (room->>'token')::uuid; h_id := (room->>'player_id')::uuid;
  select * into r from public.rooms where code = room->>'code';
  if r.mode <> 'qcm' or r.time_mode <> 'medium' or r.qcm_variant <> 'classique' then
    raise exception 'QCM_QA : salon QCM mal créé (%, %, %)', r.mode, r.time_mode, r.qcm_variant;
  end if;
  ja := public.join_room(cd, 'Alice'); ta := (ja->>'token')::uuid; a_id := (ja->>'player_id')::uuid;
  jb := public.join_room(cd, 'Bruno'); tb := (jb->>'token')::uuid; b_id := (jb->>'player_id')::uuid;
  jc := public.join_room(cd, 'Chloé'); tc := (jc->>'token')::uuid; c_id := (jc->>'player_id')::uuid;

  -- Sans quiz, pas de lancement.
  perform pg_temp.refus(format('select public.lancer_partie(%L, %L)', cd, th), '%Choisis un quiz%');
  perform pg_temp.refus(format('select public.qcm_select(%L, %L, %L)', cd, ta, k), 'Seul l%hôte%');
  perform pg_temp.refus(format('select public.qcm_select(%L, %L, %L)', cd, th, 'ZZZZ-ZZZZ-ZZZZ'), 'Code de quiz inconnu%');
  q := public.qcm_select(cd, th, k);
  if q->>'title' <> 'Fin de saison 2026' or (q->>'count')::int <> 3 then raise exception 'QCM_QA : résumé du quiz : %', q; end if;

  -- Au salon, les invités voient le titre et le nombre de questions, rien d'autre.
  s := public.get_full_state(cd, ta);
  if s->'qcm'->'quiz'->>'title' <> 'Fin de saison 2026' or (s->'qcm'->'quiz'->>'count')::int <> 3 then
    raise exception 'QCM_QA : résumé absent du salon : %', s->'qcm';
  end if;
  if (s->'qcm')::text ~ 'Karim|Théo' then raise exception 'QCM_QA : une question a fuité au salon'; end if;
  -- l'identifiant du quiz (qui sert à l'hôte à retrouver son code) ne va qu'à l'hôte
  if s->'qcm'->'quiz'->>'id' is not null then raise exception 'QCM_QA : identifiant du quiz donné à un invité'; end if;
  if public.get_full_state(cd, th)->'qcm'->'quiz'->>'id' is distinct from quiz->>'id' then
    raise exception 'QCM_QA : l’hôte doit recevoir l’identifiant de son quiz';
  end if;

  perform pg_temp.refus(format('select public.set_qcm_variant(%L, %L, %L)', cd, ta, 'rapidite'), 'Seul l%hôte%');
  perform pg_temp.refus(format('select public.set_qcm_variant(%L, %L, %L)', cd, th, 'turbo'), 'Mode inconnu%');
  perform public.set_qcm_variant(cd, th, 'rapidite');
  if public.get_full_state(cd, tb)->'qcm'->>'variant' <> 'rapidite' then raise exception 'QCM_QA : mode non transmis'; end if;

  -- ------------------------------------------------ Question 1 : tout le monde répond
  perform public.lancer_partie(cd, th);
  select * into r from public.rooms where code = room->>'code';
  if r.status <> 'qcm_question' or r.round <> 1 or r.reader_id <> h_id then
    raise exception 'QCM_QA : départ inattendu (%, %, %)', r.status, r.round, r.reader_id;
  end if;
  select count(*) into n from public.qcm_room_questions where room_id = r.id;
  if n <> 3 then raise exception 'QCM_QA : copie du quiz incomplète (%)', n; end if;
  -- Le minuteur du salon s'applique : 30 s en temps moyen.
  s := public.get_full_state(cd, ta);
  if (s->'state'->'room'->>'phase_seconds')::int <> 30 or s->'state'->'room'->>'phase_deadline' is null then
    raise exception 'QCM_QA : minuteur absent : %', s->'state'->'room';
  end if;
  if s->'qcm'->>'text' <> 'Qui a marqué le plus de buts cette saison ?' or json_array_length(s->'qcm'->'choices') <> 4 then
    raise exception 'QCM_QA : question mal transmise : %', s->'qcm';
  end if;
  if s->'qcm'->>'correct' is not null or s->'qcm'->>'note' is not null or s->'qcm'->>'answers' is not null then
    raise exception 'QCM_QA : la bonne réponse a fuité avant la révélation : %', s->'qcm';
  end if;
  s := public.get_full_state(cd, th);
  if (s->'qcm'->>'correct')::int <> 2 or s->'qcm'->>'note' <> 'Théo : 14 buts !' then
    raise exception 'QCM_QA : l’animateur doit voir la bonne réponse : %', s->'qcm';
  end if;

  perform pg_temp.refus(format('select public.qcm_answer(%L, %L, 0)', cd, th), '%Tu animes%');
  perform pg_temp.refus(format('select public.qcm_answer(%L, %L, 4)', cd, ta), 'Réponse invalide%');
  perform pg_temp.refus(format('select public.qcm_answer(%L, %L, -1)', cd, ta), 'Réponse invalide%');
  perform pg_temp.refus(format('select public.qcm_reveal(%L, %L)', cd, ta), 'Seul l%animateur%');

  perform public.qcm_answer(cd, ta, 0);     -- Alice se trompe…
  perform public.qcm_answer(cd, ta, 2);     -- …puis se corrige : c'est sa réponse finale
  perform public.qcm_answer(cd, tb, 1);     -- Bruno se trompe
  s := public.get_full_state(cd, tc);
  if json_array_length(s->'qcm'->'answered') <> 2 or s->'qcm'->>'my_choice' is not null then
    raise exception 'QCM_QA : suivi des réponses : %', s->'qcm';
  end if;
  if (public.get_full_state(cd, ta)->'qcm'->>'my_choice')::int <> 2 then raise exception 'QCM_QA : changement de réponse perdu'; end if;
  select status into r.status from public.rooms where id = r.id;
  if r.status <> 'qcm_question' then raise exception 'QCM_QA : question fermée trop tôt'; end if;
  perform public.qcm_answer(cd, tc, 2);     -- Chloé trouve, après Alice : tout le monde a répondu
  select status into r.status from public.rooms where id = r.id;
  if r.status <> 'reveal' then raise exception 'QCM_QA : la question devait se fermer (%)', r.status; end if;
  -- Mode Rapidité : Alice (première bonne réponse) 1 + 1, Chloé 1, Bruno 0.
  if (select score from public.players where id = a_id) <> 2 or (select score from public.players where id = c_id) <> 1
     or (select score from public.players where id = b_id) <> 0 or (select score from public.players where id = h_id) <> 0 then
    raise exception 'QCM_QA : points de la question 1 inattendus';
  end if;
  s := public.get_full_state(cd, tb);
  if (s->'qcm'->>'correct')::int <> 2 or s->'qcm'->>'note' <> 'Théo : 14 buts !' or json_array_length(s->'qcm'->'answers') <> 3 then
    raise exception 'QCM_QA : révélation incomplète : %', s->'qcm';
  end if;
  if not exists (select 1 from json_array_elements(s->'qcm'->'answers') x
                 where (x->>'player_id')::uuid = a_id and (x->>'bonus')::boolean and (x->>'points')::int = 2) then
    raise exception 'QCM_QA : bonus de rapidité absent : %', s->'qcm'->'answers';
  end if;
  perform pg_temp.refus(format('select public.qcm_answer(%L, %L, 1)', cd, tb), '%fermées%');

  -- ------------------------------------------------ Question 2 : l'animateur révèle tôt
  perform pg_temp.refus(format('select public.qcm_next(%L, %L)', cd, ta), 'Seul l%animateur%');
  perform public.qcm_next(cd, th);
  select * into r from public.rooms where id = r.id;
  if r.status <> 'qcm_question' or r.round <> 2 then raise exception 'QCM_QA : question 2 attendue'; end if;
  perform public.qcm_answer(cd, tb, 0);     -- Bruno trouve (2 points + 1 de rapidité)
  perform public.qcm_reveal(cd, th);
  select * into r from public.rooms where id = r.id;
  if r.status <> 'reveal' then raise exception 'QCM_QA : révélation anticipée refusée'; end if;
  if (select score from public.players where id = b_id) <> 3 then raise exception 'QCM_QA : points de la question 2'; end if;

  -- ------------------------------------------------ Question 3 : le temps s'écoule
  perform public.qcm_next(cd, th);
  perform public.qcm_answer(cd, ta, 1);     -- Alice répond à temps (3 points + 1)
  update public.rooms set phase_at = now() - interval '1 minute' where id = r.id;
  perform pg_temp.refus(format('select public.qcm_answer(%L, %L, 1)', cd, tc), 'Le temps est écoulé%');
  perform public.reap_idle(cd, tb);
  select * into r from public.rooms where id = r.id;
  if r.status <> 'reveal' or (select score from public.players where id = a_id) <> 6 then
    raise exception 'QCM_QA : fin du temps mal gérée (%)', r.status;
  end if;

  -- ------------------------------------------------ Fin : l'animateur n'est pas classé
  perform public.qcm_next(cd, th);
  select * into r from public.rooms where id = r.id;
  if r.status <> 'finished' or r.winner_id <> a_id or r.reader_id <> h_id then
    raise exception 'QCM_QA : fin de partie inattendue (%, %)', r.status, r.winner_id;
  end if;
  -- Punitions : le perdant est Chloé (1 point), jamais l'animateur (0 point).
  update public.rooms set punish = true where id = r.id;
  loser := public._punish_loser(r.id);
  if loser is distinct from c_id then raise exception 'QCM_QA : perdant inattendu : %', loser; end if;
  update public.rooms set punish = false, punish_loser = null where id = r.id;

  -- ------------------------------------------------ Départs en cours de question
  perform public.continue_game(cd, th);
  perform public.continue_game(cd, ta);
  perform public.continue_game(cd, tb);
  perform public.continue_game(cd, tc);
  perform public.lancer_partie(cd, th);
  select * into r from public.rooms where id = r.id;
  if r.status <> 'qcm_question' or r.round <> 1 or (select sum(score) from public.players where room_id = r.id) <> 0 then
    raise exception 'QCM_QA : la nouvelle partie doit repartir de zéro';
  end if;
  perform public.qcm_answer(cd, ta, 2);
  perform public.qcm_answer(cd, tb, 2);
  perform public.leave_room(cd, tc);         -- Chloé part : il ne reste que des joueurs qui ont répondu
  select * into r from public.rooms where id = r.id;
  if r.status <> 'reveal' then raise exception 'QCM_QA : un départ doit débloquer la question (%)', r.status; end if;
  perform public.qcm_next(cd, th);
  perform public.qcm_answer(cd, ta, 0);
  perform public.leave_room(cd, th);         -- l'animateur part : Alice, nouvelle hôte, prend la main
  select * into r from public.rooms where id = r.id;
  if r.host_id <> a_id or r.reader_id <> a_id or r.status <> 'qcm_question' then
    raise exception 'QCM_QA : relève de l’animateur (%, %, %)', r.host_id, r.reader_id, r.status;
  end if;
  if exists (select 1 from public.qcm_answers where room_id = r.id and round = r.round and player_id = a_id) then
    raise exception 'QCM_QA : la réponse du nouvel animateur doit disparaître';
  end if;
  perform public.qcm_answer(cd, tb, 0);      -- seul joueur restant : la question se ferme
  select * into r from public.rooms where id = r.id;
  if r.status <> 'reveal' then raise exception 'QCM_QA : question non fermée après la relève (%)', r.status; end if;
  perform public.qcm_next(cd, ta);
  perform public.leave_room(cd, tb);         -- plus assez de joueurs : retour au salon
  select * into r from public.rooms where id = r.id;
  if r.status <> 'lobby' then raise exception 'QCM_QA : retour au salon attendu (%)', r.status; end if;

  -- ------------------------------------------------ 30 joueurs, bots
  vide := public.create_room('Grand groupe', 5, 'qcm', 2);
  code_vide := vide->>'code'; t_vide := (vide->>'token')::uuid;
  for i in 1..14 loop perform public.join_room(code_vide, 'Joueur ' || i); end loop;
  select count(*) into n from public.players p join public.rooms x on x.id = p.room_id where x.code = code_vide and p.active;
  if n <> 15 then raise exception 'QCM_QA : le QCM doit accepter plus de 12 joueurs (%)', n; end if;
  perform pg_temp.refus(format('select public.set_room_options(%L, %L, %L, 5, 2)', code_vide, t_vide, 'phrases'),
    'Trop de joueurs pour ce jeu (12 au maximum)%');
  if public._max_players('qcm') <> 30 or public._min_players('qcm') <> 2 then raise exception 'QCM_QA : bornes de joueurs'; end if;

  room := public.create_room('Test solo', 5, 'qcm', 2);
  cd := room->>'code'; th := (room->>'token')::uuid;
  perform public.add_bot(cd, th);
  perform public.add_bot(cd, th);
  perform public.qcm_select(cd, th, k);
  perform public.lancer_partie(cd, th);
  perform public.qcm_bot_step(cd, th);
  select * into r from public.rooms where code = room->>'code';
  if r.status <> 'reveal' then raise exception 'QCM_QA : les bots doivent répondre (%)', r.status; end if;

  -- ------------------------------------------------ Suppression du quiz
  k2 := (public.qcm_quiz_create('À jeter'))->>'key';
  perform public.qcm_select(code_vide, t_vide, k2);
  perform public.qcm_quiz_delete(k2);
  if (select qcm_quiz_id from public.rooms where code = code_vide) is not null then
    raise exception 'QCM_QA : un quiz supprimé doit être retiré du salon';
  end if;
  perform pg_temp.refus(format('select public.qcm_quiz_get(%L)', k2), 'Code de quiz inconnu%');
  -- la partie en cours garde sa copie
  if (select count(*) from public.qcm_room_questions where room_id = r.id) <> 3 then
    raise exception 'QCM_QA : la copie de la partie doit survivre';
  end if;

  -- ------------------------------------------------ Les autres jeux ne voient rien
  vide := public.create_room('Autre jeu', 5, 'phrases', 2);
  if public.get_full_state(vide->>'code', (vide->>'token')::uuid)->>'qcm' is not null then
    raise exception 'QCM_QA : état QCM hors du QCM';
  end if;

  -- ------------------------------------------------ Droits
  if has_table_privilege('anon', 'public.qcm_quizzes', 'select')
     or has_table_privilege('anon', 'public.qcm_questions', 'select')
     or has_table_privilege('anon', 'public.qcm_room_questions', 'select')
     or has_table_privilege('anon', 'public.qcm_answers', 'select') then
    raise exception 'QCM_QA : tables QCM lisibles directement';
  end if;
  if has_function_privilege('anon', 'public._qcm_close(uuid)', 'execute')
     or has_function_privilege('anon', 'public._begin_qcm_round(uuid, integer)', 'execute')
     or has_function_privilege('anon', 'public._qcm_quiz_json(uuid, text)', 'execute')
     or has_function_privilege('anon', 'public._qcm_find(text)', 'execute') then
    raise exception 'QCM_QA : fonction interne exposée';
  end if;
  if not has_function_privilege('anon', 'public.qcm_answer(text, uuid, integer)', 'execute')
     or not has_function_privilege('anon', 'public.qcm_quiz_save(text, text, jsonb)', 'execute')
     or not has_function_privilege('anon', 'public.get_full_state(text, uuid)', 'execute') then
    raise exception 'QCM_QA : RPC du QCM non accessibles à l’appli';
  end if;

  raise notice 'QCM_QA : scénario complet réussi.';
end $qa$;

rollback;
