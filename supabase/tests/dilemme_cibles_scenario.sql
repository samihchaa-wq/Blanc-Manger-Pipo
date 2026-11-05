-- Scénario de test des cibles secrètes du Dilemme parfait. Il se termine par une
-- exception volontaire (« ANNULE | … ») : tout est annulé. Journal dans le message d'erreur.
do $t$
declare h json; a json; b json; z json; c text; th uuid; ta uuid; tb uuid; tz uuid; s json; log text := '';
  rid uuid; bh uuid; ba uuid; bb uuid; bz uuid; c2 text; h2 json; t2 uuid;
begin
  h := public.create_room('Hote', 5, 'dilemme', 1); c := h->>'code'; th := (h->>'token')::uuid;
  a := public.join_room(c, 'Alice'); ta := (a->>'token')::uuid;
  b := public.join_room(c, 'Bob'); tb := (b->>'token')::uuid;
  z := public.join_room(c, 'Zoe'); tz := (z->>'token')::uuid;
  select id into rid from public.rooms where code = c;
  perform public.set_ready(c, th, true); perform public.set_ready(c, ta, true); perform public.set_ready(c, tb, true); perform public.set_ready(c, tz, true);
  perform public.start_game(c, th);
  perform public.dilemme_pick(c, th, 'Tu gagnes un million d’euros');
  log := log || '1) cibles tirées=' || (select count(*) from public.dilemme_cibles where room_id = rid)
    || ' toutes-dans-10..90:' || (select bool_and(target between 10 and 90 and target % 10 = 0) from public.dilemme_cibles where room_id = rid);
  -- cibles fixées pour que les points soient prévisibles
  update public.dilemme_cibles set target = case player_id
    when (h->>'player_id')::uuid then 50 when (a->>'player_id')::uuid then 10
    when (b->>'player_id')::uuid then 90 else 30 end where room_id = rid;
  s := public.get_state(c, ta);
  log := log || ' | 2) ma-cible(Alice)=' || coalesce(s->'dilemme'->>'my_target', 'null');
  perform public.dilemme_write(c, th, 'tu perds tous tes amis');
  perform public.dilemme_write(c, ta, 'tu dois vivre en Antarctique');
  perform public.dilemme_write(c, tb, 'tu ne peux plus manger de fromage');
  perform public.dilemme_write(c, tz, 'tu sens le poisson pour toujours');
  s := public.get_state(c, ta);
  log := log || ' | 3) ' || (s->'room'->>'status') || ' cibles-des-autres-cachées:'
    || (select bool_and(e->>'target' is null) from json_array_elements(s->'dilemme'->'buts') e);
  select id into bh from public.dilemme_buts where room_id = rid and player_id = (h->>'player_id')::uuid;
  select id into ba from public.dilemme_buts where room_id = rid and player_id = (a->>'player_id')::uuid;
  select id into bb from public.dilemme_buts where room_id = rid and player_id = (b->>'player_id')::uuid;
  select id into bz from public.dilemme_buts where room_id = rid and player_id = (z->>'player_id')::uuid;
  -- Hôte (50 %) : 2 oui sur 3 -> 67 %, le plus proche possible -> 3
  -- Alice (10 %) : 0 oui sur 3 -> 0 %, le plus proche possible -> 3
  -- Bob (90 %) : 2 oui sur 3 -> 67 %, 100 % était possible (écart 13 en trop) -> 2
  -- Zoe (30 %) : 1 oui sur 3 -> 33 %, le plus proche possible -> 3
  perform public.dilemme_vote(c, th, array[ba, bb, bz], array[false, true, false]);
  perform public.dilemme_vote(c, ta, array[bh, bb, bz], array[true, false, true]);
  perform public.dilemme_vote(c, tb, array[bh, ba, bz], array[false, false, false]);
  perform public.dilemme_vote(c, tz, array[bh, ba, bb], array[true, false, true]);
  s := public.get_state(c, tz);
  log := log || ' | 4) ' || (s->'room'->>'status') || ' scores=' || (select string_agg(name || ':' || score, ',' order by seat) from public.players where room_id = rid)
    || ' (attendu Hote:3,Alice:3,Bob:2,Zoe:3) cibles-révélées:'
    || (select bool_and(e->>'target' is not null) from json_array_elements(s->'dilemme'->'buts') e);
  -- barème seul
  log := log || ' | 5) barème : 2 votants 50%/0 oui=' || public._dilemme_points(2, 0, 50)
    || ' 4 votants 50%/1 oui=' || public._dilemme_points(4, 1, 50)
    || ' 6 votants 50%/2 oui=' || public._dilemme_points(6, 2, 50)
    || ' 5 votants 80%/4 oui=' || public._dilemme_points(5, 4, 80)
    || ' 5 votants 80%/0 oui=' || public._dilemme_points(5, 0, 80)
    || ' 0 votant=' || public._dilemme_points(0, 0, 50)
    || ' (attendu 0, 1, 2, 3, 0, 0)';

  -- les bots reçoivent aussi une cible et la partie avance
  h2 := public.create_room('Solo', 5, 'dilemme', 1); c2 := h2->>'code'; t2 := (h2->>'token')::uuid;
  perform public.add_bot(c2, t2); perform public.add_bot(c2, t2);
  update public.players set ready = true where room_id = (select id from public.rooms where code = c2);
  perform public.start_game(c2, t2);
  perform public.dilemme_pick(c2, t2, 'Tu deviens célèbre');
  perform public.dilemme_bot_step(c2, t2, array['x'], array['tout le monde te déteste', 'tu bégaies']);
  perform public.dilemme_write(c2, t2, 'pour une vidéo gênante');
  perform public.dilemme_bot_step(c2, t2, array['x'], array['y']);
  s := public.get_state(c2, t2);
  perform public.dilemme_vote(c2, t2,
    array(select (e->>'id')::uuid from json_array_elements(s->'dilemme'->'buts') e where not (e->>'mine')::boolean),
    array[true, false]);
  s := public.get_state(c2, t2);
  log := log || ' | 6) bots : ' || (s->'room'->>'status') || ' cibles=' || (select count(*) from public.dilemme_cibles where room_id = (select id from public.rooms where code = c2));

  raise exception 'ANNULE | %', log;
end $t$;
