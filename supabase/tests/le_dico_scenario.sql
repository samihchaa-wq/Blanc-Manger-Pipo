-- Scénario de test du Dico. Il se termine par une exception volontaire (« ANNULE | … »),
-- donc tout est annulé : aucune salle ni aucun joueur ne reste en base. Le journal
-- de chaque étape s'affiche dans le message d'erreur.
do $t$
declare h json; a json; b json; z json; c text; th uuid; ta uuid; tb uuid; tz uuid; s json; log text := '';
  d_a uuid; d_b uuid; d_t uuid; rid uuid; c2 text; h2 json; t2 uuid; c3 text; h3 json;
begin
  -- Partie à 4, un tour de meneur chacun
  h := public.create_room('Hote', 5, 'dico', 1); c := h->>'code'; th := (h->>'token')::uuid;
  a := public.join_room(c, 'Alice'); ta := (a->>'token')::uuid;
  b := public.join_room(c, 'Bob'); tb := (b->>'token')::uuid;
  z := public.join_room(c, 'Zoe'); tz := (z->>'token')::uuid;
  select id into rid from public.rooms where code = c;
  log := log || '0) mode=' || (select mode from public.rooms where id = rid) || ' temps=' || (select time_mode from public.rooms where id = rid);
  perform public.set_ready(c, th, true); perform public.set_ready(c, ta, true); perform public.set_ready(c, tb, true); perform public.set_ready(c, tz, true);
  perform public.start_game(c, th);
  s := public.get_state(c, th);
  log := log || ' | 1) ' || (s->'room'->>'status') || ' meneur=hôte:' || ((s->'room'->>'reader_id') = (h->>'player_id'));
  begin perform public.dico_pick(c, ta, 'x', 'n.', 'yyyyy'); log := log || ' ERREUR:pick-non-meneur-accepté';
  exception when others then log := log || ' pick-non-meneur-refusé'; end;
  perform public.dico_pick(c, th, 'maison', 'n. f.', 'Bâtiment servant d’habitation.');
  s := public.get_state(c, ta);
  log := log || ' | 2) ' || (s->'room'->>'status') || ' mot=' || (s->'dico'->>'word') || ' déf-cachée-joueur:' || ((s->'dico'->>'definition') is null);
  s := public.get_state(c, th);
  log := log || ' déf-meneur:' || coalesce(s->'dico'->>'definition', 'null') || ' minuteur:' || coalesce(s->'room'->>'phase_seconds', 'null');
  perform public.dico_write(c, ta, 'Petit animal à poils.');
  perform public.dico_write(c, tb, 'Instrument de musique ancien.');
  s := public.get_state(c, ta);
  log := log || ' | 3) après 2/3 : ' || (s->'room'->>'status') || ' écrits=' || json_array_length(s->'dico'->'written');
  perform public.dico_write(c, tz, 'Ville du Pérou.');
  s := public.get_state(c, ta);
  log := log || ' | 4) ' || (s->'room'->>'status') || ' défs=' || json_array_length(s->'dico'->'defs')
    || ' auteurs-cachés:' || ((s->'dico'->'defs'->0->>'author_id') is null) || ' vraie-cachée:' || ((s->'dico'->'defs'->0->>'is_true') is null)
    || ' mienne-marquée:' || (select count(*) from json_array_elements(s->'dico'->'defs') e where (e->>'mine')::boolean);
  select id into d_a from public.dico_defs where room_id = rid and text like 'Petit animal%';
  select id into d_b from public.dico_defs where room_id = rid and text like 'Instrument%';
  select id into d_t from public.dico_defs where room_id = rid and is_true;
  begin perform public.dico_vote(c, ta, d_a); log := log || ' ERREUR:vote-pour-soi-accepté';
  exception when others then log := log || ' vote-pour-soi-refusé'; end;
  begin perform public.dico_vote(c, th, d_a); log := log || ' ERREUR:vote-meneur-accepté';
  exception when others then log := log || ' vote-meneur-refusé'; end;
  perform public.dico_vote(c, ta, d_b);   -- Alice se fait avoir par Bob : Bob +1
  perform public.dico_vote(c, tb, d_t);   -- Bob trouve : +2
  perform public.dico_vote(c, tz, d_b);   -- Zoe se fait avoir par Bob : Bob +1
  s := public.get_state(c, tz);
  log := log || ' | 5) ' || (s->'room'->>'status') || ' scores=' || (select string_agg(name || ':' || score, ',' order by seat) from public.players where room_id = rid)
    || ' vraie-révélée:' || (select count(*) from json_array_elements(s->'dico'->'defs') e where (e->>'is_true')::boolean)
    || ' déf-révélée:' || coalesce(s->'dico'->>'definition', 'null');
  perform public.next_round(c, th); perform public.next_round(c, ta); perform public.next_round(c, tb); perform public.next_round(c, tz);
  s := public.get_state(c, th);
  log := log || ' | 6) ' || (s->'room'->>'status') || ' meneur=Alice:' || ((s->'room'->>'reader_id') = (a->>'player_id'));
  -- le meneur s'en va pendant la rédaction : manche suivante, sans lui
  perform public.dico_pick(c, ta, 'chat', 'n. m.', 'Petit félin domestique.');
  perform public.leave_room(c, ta);
  s := public.get_state(c, th);
  log := log || ' | 7) départ du meneur : ' || (s->'room'->>'status') || ' manche=' || (s->'room'->>'round') || ' meneur=Bob:' || ((s->'room'->>'reader_id') = (b->>'player_id'));
  -- minuteur expiré sans aucune définition : la manche est sautée
  perform public.dico_pick(c, tb, 'lune', 'n. f.', 'Satellite naturel de la Terre.');
  update public.rooms set phase_at = now() - interval '1 hour' where id = rid;
  perform public.reap_idle(c, th);
  s := public.get_state(c, th);
  log := log || ' | 8) expiré sans déf : ' || (s->'room'->>'status') || ' manche=' || (s->'room'->>'round') || ' meneur=Zoe:' || ((s->'room'->>'reader_id') = (z->>'player_id'));
  -- minuteur expiré en vote : on compte les voix données
  perform public.dico_pick(c, tz, 'pomme', 'n. f.', 'Fruit du pommier.');
  perform public.dico_write(c, th, 'Partie du genou.');
  update public.rooms set phase_at = now() - interval '1 hour' where id = rid;
  perform public.reap_idle(c, th);
  s := public.get_state(c, th);
  log := log || ' | 9) rédaction expirée avec 1 déf : ' || (s->'room'->>'status');
  update public.rooms set phase_at = now() - interval '1 hour' where id = rid;
  perform public.reap_idle(c, th);
  s := public.get_state(c, th);
  log := log || ' -> vote expiré : ' || (s->'room'->>'status');
  perform public.next_round(c, th); perform public.next_round(c, tb); perform public.next_round(c, tz);
  s := public.get_state(c, th);
  log := log || ' | 10) chacun a mené : ' || (s->'room'->>'status');

  -- Partie avec 2 bots : l'hôte mène, les bots écrivent et votent
  h2 := public.create_room('Solo', 5, 'dico', 1); c2 := h2->>'code'; t2 := (h2->>'token')::uuid;
  perform public.add_bot(c2, t2); perform public.add_bot(c2, t2);
  perform public.set_ready(c2, t2, true);
  perform public.start_game(c2, t2);
  perform public.dico_pick(c2, t2, 'arbre', 'n. m.', 'Grande plante ligneuse.');
  perform public.dico_bot_step(c2, t2, array['abaque','abbé'], array['n. m.','n. m.'], array['Table à calcul.','Supérieur d’une abbaye.']);
  s := public.get_state(c2, t2);
  log := log || ' | 11) bots ont écrit : ' || (s->'room'->>'status');
  perform public.dico_bot_step(c2, t2, '{}', '{}', '{}');
  s := public.get_state(c2, t2);
  log := log || ' -> bots ont voté : ' || (s->'room'->>'status') || ' points=' || coalesce((s->'dico'->'points')::text, 'null');
  perform public.next_round(c2, t2); perform public.bot_step(c2, t2);
  s := public.get_state(c2, t2);
  log := log || ' | 12) manche 2 meneur bot : ' || (s->'room'->>'status');
  perform public.dico_bot_step(c2, t2, array['abeille'], array['n. f.'], array['Insecte qui produit le miel.']);
  s := public.get_state(c2, t2);
  log := log || ' -> ' || (s->'room'->>'status') || ' mot=' || coalesce(s->'dico'->>'word', 'null');

  -- Les autres jeux ne bougent pas
  h3 := public.create_room('Autre', 5, 'mimes', 2); c3 := h3->>'code';
  log := log || ' | 13) mimes=' || (select mode from public.rooms where code = c3);
  perform public.set_room_options(c3, (h3->>'token')::uuid, 'dico', 5, 2);
  log := log || ' -> réglé en ' || (select mode from public.rooms where code = c3);
  perform public.set_room_options(c3, (h3->>'token')::uuid, 'phrases', 5, 2);
  log := log || ' -> ' || (select mode from public.rooms where code = c3);
  s := public.get_state(c3, (h3->>'token')::uuid);
  log := log || ' état=' || (s->'room'->>'status');
  raise exception 'ANNULE | %', log;
end $t$;
