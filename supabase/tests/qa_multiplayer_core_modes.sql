-- QA avant ouverture publique : Phrases à trou, Priorités, Baromètre.
-- Partie(s) simulées à 3 clients distincts avec vrais RPC de Supabase.
-- Une transaction + ROLLBACK : aucun état de test n'est conservé.
begin;
select pg_catalog.set_config('request.headers','{"x-forwarded-for":"192.0.2.181"}',true);

do $qa$
declare h json; a json; b json; room_code text; th uuid; ta uuid; tb uuid;
  rh uuid; ra uuid; rb uuid; rid uuid; reader_id uuid; reader_token uuid;
  r public.rooms; qid integer; nblanks integer; first_card integer; second_card integer;
  winner_submission uuid; winner_player uuid; n integer; player_row public.players;
  st json;
begin
  h:=public.create_room('QA Phrases Hôte',1,'phrases',1); room_code:=h->>'code';
  th:=(h->>'token')::uuid; rh:=(h->>'player_id')::uuid;
  a:=public.join_room(room_code,'QA Alice'); ta:=(a->>'token')::uuid; ra:=(a->>'player_id')::uuid;
  b:=public.join_room(room_code,'QA Bob'); tb:=(b->>'token')::uuid; rb:=(b->>'player_id')::uuid;
  select * into r from public.rooms where code=room_code;
  rid:=r.id;
  if room_code !~ '^[0-9]{8}$' then raise exception 'Phrases : invitation invalide'; end if;
  perform public.lancer_partie(room_code,th);
  select * into r from public.rooms where id=rid;
  if r.status<>'question_select' then raise exception 'Phrases : mauvais début %',r.status; end if;
  reader_id:=r.reader_id;
  reader_token:=case reader_id when rh then th when ra then ta when rb then tb end;
  qid:=r.question_choices[1];
  if qid is null then raise exception 'Phrases : aucune question'; end if;
  perform public.select_question(room_code,reader_token,qid);
  select * into r from public.rooms where id=rid;
  if r.status<>'answering' then raise exception 'Phrases : phase réponse non ouverte'; end if;
  select blanks into nblanks from public.questions where id=qid;
  for player_row in select * from public.players where room_id=rid and active and id<>reader_id loop
    select answer_id into first_card from public.hands where player_id=player_row.id order by answer_id limit 1;
    select answer_id into second_card from public.hands where player_id=player_row.id and answer_id<>first_card order by answer_id limit 1;
    if first_card is null or (nblanks=2 and second_card is null) then
      raise exception 'Phrases : cartes insuffisantes dans une main de test';
    end if;
    perform public.submit_answer(room_code,player_row.token,first_card,case when nblanks=2 then second_card end);
  end loop;
  select count(*) into n from public.submissions where room_id=rid and round=r.round;
  if n<>2 then raise exception 'Phrases : % soumissions au lieu de 2',n; end if;
  select * into r from public.rooms where id=rid;
  if r.status<>'judging' then raise exception 'Phrases : pas de vote du juge (%).',r.status; end if;
  select id,player_id into winner_submission,winner_player from public.submissions
    where room_id=rid and round=r.round order by sort_key limit 1;
  perform public.pick_winner(room_code,reader_token,winner_submission);
  select * into r from public.rooms where id=rid;
  if r.status<>'finished' or r.winner_id<>winner_player then
    raise exception 'Phrases : gagnant/fin erronés %',r.status;
  end if;
  if (select score from public.players where id=winner_player)<>1 then
    raise exception 'Phrases : mauvais score pour le gagnant';
  end if;
  begin
    perform public.pick_winner(room_code,reader_token,winner_submission);
    raise exception 'QA_ECHEC : double score accepté';
  exception when others then
    if sqlerrm like 'QA_ECHEC%' then raise; end if;
  end;
  if (select score from public.players where id=winner_player)<>1 then
    raise exception 'Phrases : score attribué deux fois';
  end if;
  raise notice 'QA PASS : Phrases à trou, 3 clients, soumissions, score, fin, double vote';
end $qa$;

do $qa$
declare h json; a json; b json; code_salon text; rid uuid; r public.rooms;
  cards integer[]; p public.players; n integer; stored integer; st json;
begin
  h:=public.create_room('QA Priorités Hôte',5,'priorites',1); code_salon:=h->>'code';
  a:=public.join_room(code_salon,'QA Alice'); b:=public.join_room(code_salon,'QA Bob');
  perform public.lancer_partie(code_salon,(h->>'token')::uuid);
  select * into r from public.rooms where code=code_salon; rid:=r.id;
  if r.status<>'ranking' or cardinality(r.rank_cards)<>5 then
    raise exception 'Priorités : données de classement initiales incorrectes (%)',r.status;
  end if;
  cards:=r.rank_cards;
  begin
    perform public.submit_ranking(code_salon,(a->>'token')::uuid,array[cards[1],cards[1],cards[3],cards[4],cards[5]]);
    raise exception 'QA_ECHEC : classement avec doublon accepté';
  exception when others then
    if sqlerrm like 'QA_ECHEC%' then raise; end if;
  end;
  for p in select * from public.players where room_id=rid and active order by seat loop
    perform public.submit_ranking(code_salon,p.token,cards);
  end loop;
  select * into r from public.rooms where id=rid;
  if r.status<>'reveal' then raise exception 'Priorités : résultats non dévoilés'; end if;
  select count(*) into n from public.rankings where room_id=rid and round=1;
  if n<>3 then raise exception 'Priorités : nombre de votes incorrect'; end if;
  if exists(select 1 from public.players p join public.rankings k on k.player_id=p.id and k.room_id=rid and k.round=1
     where p.score is distinct from k.points) then
    raise exception 'Priorités : incohérence points/classements';
  end if;
  begin
    perform public.submit_ranking(code_salon,(a->>'token')::uuid,cards);
    raise exception 'QA_ECHEC : classement après révélation accepté';
  exception when others then
    if sqlerrm like 'QA_ECHEC%' then raise; end if;
  end;
  raise notice 'QA PASS : Priorités, 3 classements, validation doublons, points, révélation';
end $qa$;

do $qa$
declare h json; a json; b json; code_salon text; th uuid; ta uuid; tb uuid;
  rid uuid; r public.rooms; st json; p public.players;
begin
  h:=public.create_room('QA Ondes Hôte',5,'ondes',1); code_salon:=h->>'code';
  th:=(h->>'token')::uuid;
  a:=public.join_room(code_salon,'QA Alice'); ta:=(a->>'token')::uuid;
  b:=public.join_room(code_salon,'QA Bob'); tb:=(b->>'token')::uuid;
  perform public.lancer_partie(code_salon,th);
  select * into r from public.rooms where code=code_salon; rid:=r.id;
  if r.status<>'clue' or r.wave_target not between 0 and 100 then
    raise exception 'Baromètre : création d’énigme incorrecte';
  end if;
  st:=public.get_state(code_salon,case when r.reader_id=(h->>'player_id')::uuid then ta else th end);
  if st->'wave'->>'target' is not null then
    raise exception 'Baromètre : cible secrète divulguée avant le vote';
  end if;
  select p.token into th from public.players p where p.id=r.reader_id;
  perform public.submit_clue(code_salon,th,'Indice de contrôle');
  for p in select * from public.players where room_id=rid and active and id<>r.reader_id loop
    perform public.submit_guess(code_salon,p.token,r.wave_target);
  end loop;
  select * into r from public.rooms where id=rid;
  if r.status<>'reveal' then raise exception 'Baromètre : révélation absente'; end if;
  if exists(select 1 from public.players where room_id=rid and active and score<>4) then
    raise exception 'Baromètre : estimation parfaite ne donne pas quatre points à chacun';
  end if;
  raise notice 'QA PASS : Baromètre, secret, 2 prédictions, points, révélation';
end $qa$;

rollback;
