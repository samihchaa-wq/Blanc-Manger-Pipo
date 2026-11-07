-- Scénario de test de la migration 20261112120000_salon_admin_refonte, à lancer
-- sur une copie de la base (jamais en production) :
--   psql … -v admin='<code admin>' -v plus='<code admin +>' -f supabase/tests/salon_admin_scenario.sql
-- Chaque vérification lève une exception « ÉCHEC … » au premier écart. Tout se
-- termine par une exception volontaire « OK | … » : rien ne reste en base.
select set_config('test.admin', :'admin', false), set_config('test.plus', :'plus', false);

do $t$
declare
  adm text := current_setting('test.admin'); plus text := current_setting('test.plus');
  h json; a json; b json; c text; th uuid; ta uuid; tb uuid; rid uuid; s json; res json; n integer; id1 integer;
  log text := '';
begin
  ---------------------------------------------------------------- salon sans « prêt »
  h := public.create_room('Hote', 5, 'phrases', 2); c := h->>'code'; th := (h->>'token')::uuid;
  a := public.join_room(c, 'Alice'); ta := (a->>'token')::uuid;
  b := public.join_room(c, 'Bob'); tb := (b->>'token')::uuid;
  select id into rid from public.rooms where code = c;
  if exists (select 1 from public.players where room_id = rid and ready) then
    raise exception 'ÉCHEC préalable : un joueur est déjà prêt';
  end if;

  ---------------------------------------------------------------- Private Joke
  begin perform public.set_phrases_variant(c, ta, 'normal', null); raise exception 'ÉCHEC : un invité change le mode';
  exception when others then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  begin perform public.set_phrases_variant(c, th, 'private'); raise exception 'ÉCHEC : 3 arguments acceptent Private Joke';
  exception when others then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  begin perform public.set_phrases_variant(c, th, 'private', ''); raise exception 'ÉCHEC : code vide accepté';
  exception when others then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  begin perform public.set_phrases_variant(c, th, 'private', 'mauvais'); raise exception 'ÉCHEC : mauvais code accepté';
  exception when others then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  if (select phrases_variant from public.rooms where id = rid) <> 'normal' then raise exception 'ÉCHEC : mode changé malgré le refus'; end if;
  perform public.set_phrases_variant(c, th, 'private', adm);
  if (select phrases_variant from public.rooms where id = rid) <> 'private' then raise exception 'ÉCHEC : code admin refusé'; end if;
  perform public.set_phrases_variant(c, th, 'normal');
  perform public.set_phrases_variant(c, th, 'private', plus);
  begin perform public.admin_set_private_code(adm, 'grinta'); raise exception 'ÉCHEC : admin simple définit le code de groupe';
  exception when others then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  begin perform public.admin_set_private_code(plus, 'abc'); raise exception 'ÉCHEC : code de 3 caractères accepté';
  exception when others then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  perform public.admin_set_private_code(plus, 'grinta');
  perform public.set_phrases_variant(c, th, 'normal', null);
  perform public.set_phrases_variant(c, th, 'private', 'grinta');
  log := log || 'private-joke ok';

  ---------------------------------------------------------------- lancement sans « prêt », paquet Private
  perform public.start_game(c, th);
  if (select status from public.rooms where id = rid) = 'lobby' then raise exception 'ÉCHEC : partie non lancée'; end if;
  select count(*) into n from public.hands h2 join public.answers x on x.id = h2.answer_id where h2.room_id = rid and x.pack <> 'private';
  if n > 0 then raise exception 'ÉCHEC : % cartes Normal distribuées en Private Joke', n; end if;
  if not exists (select 1 from public.hands where room_id = rid) then raise exception 'ÉCHEC : aucune carte distribuée'; end if;
  begin perform public.set_phrases_variant(c, th, 'normal', null); raise exception 'ÉCHEC : mode changé en pleine partie';
  exception when others then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  log := log || ' | lancement sans prêt ok';

  ---------------------------------------------------------------- punitions sans « prêt »
  h := public.create_room('Hote2', 5, 'phrases', 2); c := h->>'code'; th := (h->>'token')::uuid;
  perform public.join_room(c, 'Alice'); perform public.join_room(c, 'Bob');
  select id into rid from public.rooms where code = c;
  perform public.punish_options(c, th, true, 2);
  perform public.punish_start(c, th);
  if not (select punish_phase from public.rooms where id = rid) then raise exception 'ÉCHEC : saisie des punitions non ouverte'; end if;
  log := log || ' | punitions sans prêt ok';

  ---------------------------------------------------------------- admin générique
  begin perform public.admin_cards_list(adm, 'j', '', 0); raise exception 'ÉCHEC : admin simple consulte le catalogue';
  exception when others then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  begin perform public.admin_cards_list(plus, 'z', '', 0); raise exception 'ÉCHEC : catalogue inconnu accepté';
  exception when others then if sqlerrm like 'ÉCHEC%' then raise; end if; end;

  -- Private jokes : ajout (admin simple), modification, type, suppression
  res := public.admin_card_add(adm, 'j', '  Une raclette chez Guibon.  ');
  id1 := (res->>'id')::integer;
  if (select pack from public.answers where id = id1) <> 'private' then raise exception 'ÉCHEC : réponse ajoutée hors Private'; end if;
  if (select text from public.answers where id = id1) <> 'Une raclette chez Guibon' then raise exception 'ÉCHEC : texte non nettoyé'; end if;
  res := public.admin_cards_list(plus, 'j', 'raclette', 0);
  if (res->>'total')::integer <> 1 then raise exception 'ÉCHEC : recherche Private'; end if;
  if (public.admin_cards_list(plus, 'a', 'raclette', 0)->>'total')::integer <> 0 then raise exception 'ÉCHEC : Private visible en Normal'; end if;
  res := public.admin_card_update(plus, 'j', id1, 'Une fondue chez Guibon');
  if (select text from public.answers where id = id1) <> 'Une fondue chez Guibon' then raise exception 'ÉCHEC : modification'; end if;
  perform public.admin_card_update(plus, 'j', id1, null, null, null, 'v');
  if (select form from public.answers where id = id1) <> 'v' then raise exception 'ÉCHEC : changement de type'; end if;
  begin perform public.admin_card_update(plus, 'a', id1, 'Autre'); raise exception 'ÉCHEC : réponse Private modifiée via Normal';
  exception when others then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  begin perform public.admin_card_add(adm, 'j', 'une fondue chez guibon'); raise exception 'ÉCHEC : doublon accepté';
  exception when others then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  perform public.admin_card_delete(plus, 'j', id1);
  if (select deleted_at from public.answers where id = id1) is null then raise exception 'ÉCHEC : suppression'; end if;
  log := log || ' | réponses ok';

  -- Questions : un trou obligatoire
  begin perform public.admin_card_add(adm, 'q', 'Sans trou du tout'); raise exception 'ÉCHEC : question sans trou acceptée';
  exception when others then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  res := public.admin_card_add(adm, 'q', 'Mon plus grand secret : ___.');
  id1 := (res->>'id')::integer;
  perform public.admin_card_update(plus, 'q', id1, 'Mon plus grand secret : ____ et ____.');
  if (select blanks from public.questions where id = id1) <> 2 then raise exception 'ÉCHEC : nombre de trous'; end if;
  perform public.admin_card_delete(plus, 'q', id1);
  log := log || ' | questions ok';

  -- Priorités
  res := public.admin_card_add(adm, 'p', 'Un apéro au soleil'); id1 := (res->>'id')::integer;
  perform public.admin_card_update(plus, 'p', id1, 'Un apéro à l’ombre');
  if (select text from public.priority_cards where id = id1) <> 'Un apéro à l’ombre' then raise exception 'ÉCHEC : Priorités modif'; end if;
  perform public.admin_card_delete(plus, 'p', id1);
  log := log || ' | priorités ok';

  -- Baromètre : le doublon inversé est refusé
  res := public.admin_card_add(adm, 'w', null, 'Glacial', 'Brûlant'); id1 := (res->>'id')::integer;
  begin perform public.admin_card_add(adm, 'w', null, 'brûlant', 'glacial'); raise exception 'ÉCHEC : doublon inversé accepté';
  exception when others then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  res := public.admin_cards_list(plus, 'w', 'glacial', 0);
  if res->'items'->0->>'left' <> 'Glacial' or res->'items'->0->>'right' <> 'Brûlant' then raise exception 'ÉCHEC : forme Baromètre %', res; end if;
  perform public.admin_card_update(plus, 'w', id1, null, 'Gelé', 'Bouillant');
  perform public.admin_card_delete(plus, 'w', id1);
  log := log || ' | baromètre ok';

  -- Mr White
  res := public.admin_card_add(adm, 'm', null, 'Plage', 'Piscine'); id1 := (res->>'id')::integer;
  begin perform public.admin_card_add(adm, 'm', null, 'Plage', 'Piscine'); raise exception 'ÉCHEC : paire en double acceptée';
  exception when others then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  res := public.admin_cards_list(plus, 'm', 'plage', 0);
  if res->'items'->0->>'left' <> 'Plage' then raise exception 'ÉCHEC : forme Mr White %', res; end if;
  perform public.admin_card_update(plus, 'm', id1, null, 'Mer', 'Lac');
  if (select civil || '/' || undercover from public.white_words where id = id1) <> 'Mer/Lac' then raise exception 'ÉCHEC : Mr White modif'; end if;
  perform public.admin_card_delete(plus, 'm', id1);
  log := log || ' | mr white ok';

  -- Mimes
  res := public.admin_card_add(adm, 'x', 'soulève un sac', 'il est vide', 'il pèse une tonne'); id1 := (res->>'id')::integer;
  if (select action from public.mime_cards where id = id1) <> 'Soulève un sac' then raise exception 'ÉCHEC : majuscule Mimes'; end if;
  res := public.admin_cards_list(plus, 'x', 'sac', 0);
  if res->'items'->0->>'right' <> 'il pèse une tonne' then raise exception 'ÉCHEC : forme Mimes %', res; end if;
  perform public.admin_card_update(plus, 'x', id1, 'Porte un sac', 'léger', 'très lourd');
  perform public.admin_card_delete(plus, 'x', id1);
  begin perform public.admin_card_delete(plus, 'x', id1); raise exception 'ÉCHEC : double suppression acceptée';
  exception when others then if sqlerrm like 'ÉCHEC%' then raise; end if; end;
  log := log || ' | mimes ok';

  raise exception 'OK | %', log;
end $t$;
