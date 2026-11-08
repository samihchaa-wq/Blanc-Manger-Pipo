-- QA résilience : les huit jeux, départs sous le minimum, session reconnectée,
-- hôte transféré et invitations bloquées pendant une manche.
-- Zéro persistance (ROLLBACK).
begin;
select pg_catalog.set_config('request.headers','{"x-forwarded-for":"192.0.2.185"}',true);

do $qa_depart$
declare
  mode_game text; min_count integer; h json; guest json; c text; token_h uuid;
  last_token uuid; rid uuid; r public.rooms; check_state json; i integer;
begin
  foreach mode_game in array array['phrases','priorites','ondes','bac','white','mimes','dico','dilemme'] loop
    min_count:=public._min_players(mode_game);
    h:=public.create_room('QA Départ Hôte',1,mode_game,1);
    c:=h->>'code';token_h:=(h->>'token')::uuid;
    for i in 2..min_count loop
      guest:=public.join_room(c,'QA P' || i);
      last_token:=(guest->>'token')::uuid;
    end loop;
    select id into rid from public.rooms where code=c;
    -- Reconnexion : même jeton, même identité, accès à l'état avant/après lancement.
    check_state:=public.get_full_state(c,token_h);
    if check_state->'state'->'me'->>'id' is distinct from h->>'player_id' then
      raise exception '% : reconnexion hôte invalide',mode_game;
    end if;
    perform public.lancer_partie(c,token_h);
    check_state:=public.get_full_state(c,token_h);
    if check_state->'state'->'room'->>'status' = 'lobby' or check_state->'state'->'room'->>'status' is null then
      raise exception '% : partie non commencée',mode_game;
    end if;
    perform public.leave_room(c,last_token);
    select * into r from public.rooms where id=rid;
    if r.status<>'lobby' then
      raise exception '% : retour au salon impossible après un départ (% joueurs, phase %)',
         mode_game,min_count,r.status;
    end if;
    if (select count(*) from public.players where room_id=rid and active)<>min_count-1 then
      raise exception '% : joueur quitté encore actif',mode_game;
    end if;
    begin
      perform public.get_full_state(c,last_token);
      raise exception 'QA_ECHEC : le jeton du joueur parti marche encore (%).',mode_game;
    exception when others then
      if sqlerrm like 'QA_ECHEC%' then raise; end if;
      if sqlerrm not like '%Session expirée%' then
        raise exception '% : mauvais échec après départ : %',mode_game,sqlerrm;
      end if;
    end;
    -- L'hôte n'a pas perdu sa connexion en raison du départ.
    check_state:=public.get_full_state(c,token_h);
    if check_state->'state'->'room'->>'status'<>'lobby' then
      raise exception '% : hôte incapable de revoir le salon',mode_game;
    end if;
  end loop;
  raise notice 'QA PASS : 8 jeux, départ sous minimum, retour au salon, jeton invalidé, reconnexion';
end $qa_depart$;

do $qa_host$
declare
  h json; a json; b json; c text; t_host uuid; t_new uuid; id_new uuid;
  rid uuid; r public.rooms; state_new json;
begin
  h:=public.create_room('QA Ancien hôte',1,'priorites',1);c:=h->>'code';t_host:=(h->>'token')::uuid;
  a:=public.join_room(c,'QA Nouveau hôte');t_new:=(a->>'token')::uuid;id_new:=(a->>'player_id')::uuid;
  b:=public.join_room(c,'QA Invité');
  select id into rid from public.rooms where code=c;
  perform public.leave_room(c,t_host);
  select * into r from public.rooms where id=rid;
  if r.host_id<>id_new then raise exception 'Transfert hôte : mauvais successeur'; end if;
  state_new:=public.get_full_state(c,t_new);
  if state_new->'state'->'me'->>'id' <> id_new::text then
    raise exception 'Transfert hôte : nouvelle session invalide';
  end if;
  perform public.lancer_partie(c,t_new);
  select * into r from public.rooms where id=rid;
  if r.status='lobby' then raise exception 'Transfert hôte : impossible de démarrer à deux'; end if;
  begin
    perform public.get_state(c,t_host);
    raise exception 'QA_ECHEC : l’ancien hôte conserve l’accès';
  exception when others then if sqlerrm like 'QA_ECHEC%' then raise; end if; end;
  state_new:=public.join_room(c,'QA Intrus');
  if state_new->>'error_code' <> 'JOIN_REJECTED' then
    raise exception 'QA_ECHEC : arrivée permise après le début : %',state_new;
  end if;
  raise notice 'QA PASS : transfert d’hôte, démarrage et session invalidée';
end $qa_host$;

rollback;
