-- Scénario de test du Dilemme parfait. Il se termine par une exception volontaire
-- (« ANNULE | … »), donc tout est annulé : aucune salle ni aucun joueur ne reste
-- en base. Le journal de chaque étape s'affiche dans le message d'erreur.
do $t$
declare h json; a json; b json; z json; c text; th uuid; ta uuid; tb uuid; tz uuid; s json; log text := '';
  rid uuid; bh uuid; ba uuid; bb uuid; bz uuid; c2 text; h2 json; t2 uuid;
begin
  -- Partie à 4, un tour de meneur chacun
  h := public.create_room('Hote', 5, 'dilemme', 1); c := h->>'code'; th := (h->>'token')::uuid;
  a := public.join_room(c, 'Alice'); ta := (a->>'token')::uuid;
  b := public.join_room(c, 'Bob'); tb := (b->>'token')::uuid;
  z := public.join_room(c, 'Zoe'); tz := (z->>'token')::uuid;
  select id into rid from public.rooms where code = c;
  log := log || '0) mode=' || (select mode from public.rooms where id = rid) || ' temps=' || (select time_mode from public.rooms where id = rid);
  perform public.set_ready(c, th, true); perform public.set_ready(c, ta, true); perform public.set_ready(c, tb, true); perform public.set_ready(c, tz, true);
  perform public.start_game(c, th);
  s := public.get_state(c, th);
  log := log || ' | 1) ' || (s->'room'->>'status') || ' meneur=hôte:' || ((s->'room'->>'reader_id') = (h->>'player_id'));
  begin perform public.dilemme_pick(c, ta, 'Tu voles'); log := log || ' ERREUR:pick-non-meneur-accepté';
  exception when others then log := log || ' pick-non-meneur-refusé'; end;
  perform public.dilemme_pick(c, th, 'Tu gagnes un million d’euros, mais…');
  s := public.get_state(c, ta);
  log := log || ' | 2) ' || (s->'room'->>'status') || ' début=' || (s->'dilemme'->>'start') || ' minuteur:' || coalesce(s->'room'->>'phase_seconds', 'null');
  perform public.dilemme_write(c, th, 'Mais tu perds tous tes amis');
  perform public.dilemme_write(c, ta, 'tu dois vivre en Antarctique');
  perform public.dilemme_write(c, tb, 'tu ne peux plus manger de fromage');
  s := public.get_state(c, ta);
  log := log || ' | 3) après 3/4 : ' || (s->'room'->>'status') || ' écrits=' || json_array_length(s->'dilemme'->'written');
  perform public.dilemme_write(c, tz, 'tu sens le poisson pour toujours');
  s := public.get_state(c, ta);
  log := log || ' | 4) ' || (s->'room'->>'status') || ' props=' || json_array_length(s->'dilemme'->'buts')
    || ' auteurs-cachés:' || ((s->'dilemme'->'buts'->0->>'author_id') is null)
    || ' mienne:' || (select count(*) from json_array_elements(s->'dilemme'->'buts') e where (e->>'mine')::boolean)
    || ' mais-retiré:' || (select text from public.dilemme_buts where room_id = rid and player_id = (h->>'player_id')::uuid);
  select id into bh from public.dilemme_buts where room_id = rid and player_id = (h->>'player_id')::uuid;
  select id into ba from public.dilemme_buts where room_id = rid and player_id = (a->>'player_id')::uuid;
  select id into bb from public.dilemme_buts where room_id = rid and player_id = (b->>'player_id')::uuid;
  select id into bz from public.dilemme_buts where room_id = rid and player_id = (z->>'player_id')::uuid;
  begin perform public.dilemme_vote(c, ta, array[ba, bb, bh, bz], array[true, true, true, true]); log := log || ' ERREUR:vote-pour-soi-accepté';
  exception when others then log := log || ' vote-pour-soi-refusé'; end;
  begin perform public.dilemme_vote(c, ta, array[bb, bh], array[true, true]); log := log || ' ERREUR:vote-incomplet-accepté';
  exception when others then log := log || ' vote-incomplet-refusé'; end;
  -- Hôte : 3 votants, 2 oui 1 non -> 2 pts ; Alice : 3 non -> 0 ; Bob : 2/1 -> 2 ; Zoe : 1/2 -> 2
  perform public.dilemme_vote(c, th, array[ba, bb, bz], array[false, true, false]);
  perform public.dilemme_vote(c, ta, array[bh, bb, bz], array[true, false, true]);
  perform public.dilemme_vote(c, tb, array[bh, ba, bz], array[false, false, false]);
  s := public.get_state(c, tb);
  log := log || ' | 5) après 3/4 : ' || (s->'room'->>'status') || ' votés=' || json_array_length(s->'dilemme'->'voted');
  perform public.dilemme_vote(c, tz, array[bh, ba, bb], array[true, false, true]);
  s := public.get_state(c, tz);
  log := log || ' | 6) ' || (s->'room'->>'status') || ' scores=' || (select string_agg(name || ':' || score, ',' order by seat) from public.players where room_id = rid)
    || ' auteur-révélé:' || ((s->'dilemme'->'buts'->0->>'author_id') is not null)
    || ' oui-hôte=' || (select json_array_length(e->'yes') from json_array_elements(s->'dilemme'->'buts') e where (e->>'id')::uuid = bh);
  perform public.next_round(c, th); perform public.next_round(c, ta); perform public.next_round(c, tb); perform public.next_round(c, tz);
  s := public.get_state(c, th);
  log := log || ' | 7) ' || (s->'room'->>'status') || ' meneur=Alice:' || ((s->'room'->>'reader_id') = (a->>'player_id'));
  -- départ du meneur pendant la rédaction : la manche continue sans lui
  perform public.dilemme_pick(c, ta, 'Tu peux voler');
  perform public.dilemme_write(c, ta, 'seulement à 10 cm du sol');
  perform public.leave_room(c, ta);
  s := public.get_state(c, th);
  log := log || ' | 8) départ du meneur en rédaction : ' || (s->'room'->>'status') || ' manche=' || (s->'room'->>'round');
  -- minuteur expiré avec une seule proposition : manche sautée
  perform public.dilemme_write(c, th, 'tu es aveugle en vol');
  update public.rooms set phase_at = now() - interval '1 hour' where id = rid;
  perform public.reap_idle(c, th);
  s := public.get_state(c, th);
  log := log || ' | 9) expiré avec 1 prop : ' || (s->'room'->>'status') || ' manche=' || (s->'room'->>'round') || ' meneur=Bob:' || ((s->'room'->>'reader_id') = (b->>'player_id'));
  -- minuteur expiré en vote : on compte les voix données
  perform public.dilemme_pick(c, tb, 'Tu es invisible');
  perform public.dilemme_write(c, th, 'tout nu');
  perform public.dilemme_write(c, tz, 'quand personne ne te regarde');
  update public.rooms set phase_at = now() - interval '1 hour' where id = rid;
  perform public.reap_idle(c, th);
  s := public.get_state(c, th);
  log := log || ' | 10) rédaction expirée avec 2 props : ' || (s->'room'->>'status');
  update public.rooms set phase_at = now() - interval '1 hour' where id = rid;
  perform public.reap_idle(c, th);
  s := public.get_state(c, th);
  log := log || ' -> vote expiré : ' || (s->'room'->>'status');
  perform public.next_round(c, th); perform public.next_round(c, tb); perform public.next_round(c, tz);
  s := public.get_state(c, th);
  log := log || ' | 11) ' || (s->'room'->>'status') || ' meneur=Zoe:' || ((s->'room'->>'reader_id') = (z->>'player_id'));
  -- le meneur part pendant le choix : il ne reste que 2 joueurs, retour au salon
  perform public.leave_room(c, tz);
  s := public.get_state(c, th);
  log := log || ' | 12) départ en choix, 2 joueurs restants : ' || (s->'room'->>'status');

  -- Partie avec 2 bots : le bot mène quand c'est son tour, les bots écrivent et votent
  h2 := public.create_room('Solo', 5, 'dilemme', 1); c2 := h2->>'code'; t2 := (h2->>'token')::uuid;
  perform public.add_bot(c2, t2); perform public.add_bot(c2, t2);
  update public.players set ready = true where room_id = (select id from public.rooms where code = c2);
  perform public.start_game(c2, t2);
  perform public.dilemme_pick(c2, t2, 'Tu deviens célèbre');
  perform public.dilemme_bot_step(c2, t2, array['x'], array['tout le monde te déteste', 'tu bégaies']);
  perform public.dilemme_write(c2, t2, 'pour une vidéo gênante');
  s := public.get_state(c2, t2);
  log := log || ' | 13) bots : ' || (s->'room'->>'status') || ' props=' || json_array_length(s->'dilemme'->'buts');
  perform public.dilemme_bot_step(c2, t2, array['x'], array['y']);
  perform public.dilemme_vote(c2, t2,
    array(select (e->>'id')::uuid from json_array_elements(s->'dilemme'->'buts') e where not (e->>'mine')::boolean),
    array[true, false]);
  s := public.get_state(c2, t2);
  log := log || ' -> ' || (s->'room'->>'status');
  perform public.dilemme_bot_step(c2, t2, array['Tu peux lire dans les pensées'], array['y']);   -- reveal : rien
  perform public.bot_step(c2, t2);   -- les bots valident la manche
  perform public.next_round(c2, t2);
  perform public.dilemme_bot_step(c2, t2, array['Tu peux lire dans les pensées'], array['y']);
  s := public.get_state(c2, t2);
  log := log || ' | 14) meneur bot : ' || (s->'room'->>'status') || ' début=' || coalesce(s->'dilemme'->>'start', 'null');

  raise exception 'ANNULE | %', log;
end $t$;
