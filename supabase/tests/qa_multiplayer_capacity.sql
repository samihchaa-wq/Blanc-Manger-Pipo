-- Limites de capacité : sept jeux à 12 personnes et Petit Bac à 2.
-- Contrat RPC réel, 12 identités distinctes, rollback en fin de transaction.
begin;

do $capacity$
declare
  g text; host json; newcomer json; c text; i integer;
  last_token uuid; h_token uuid; rid uuid; st json; r public.rooms;
  n integer; n_intruders integer; expected_intruders integer; hashed_ip text;
begin
  foreach g in array array['phrases','priorites','ondes','white','mimes','dico','dilemme'] loop
    hashed_ip:='{"x-forwarded-for":"192.0.2.' || (200 + array_position(array['phrases','priorites','ondes','white','mimes','dico','dilemme'],g))::text || '"}';
    perform pg_catalog.set_config('request.headers',hashed_ip,true);
    host:=public.create_room('QA Capacité Hôte',1,g,1);c:=host->>'code';
    h_token:=(host->>'token')::uuid;
    for i in 2..12 loop
      newcomer:=public.join_room(c,'QA J'||i);
      if newcomer->>'error' is not null or newcomer->>'token' is null then
        raise exception 'Capacité % : joueur % refusé (%)',g,i,newcomer;
      end if;
      last_token:=(newcomer->>'token')::uuid;
    end loop;
    select * into r from public.rooms where code=c;rid:=r.id;
    if (select count(*) from public.players where room_id=rid and active)<>12 then
      raise exception 'Capacité % : 12 joueurs non enregistrés',g;
    end if;
    newcomer:=public.join_room(c,'QA Trop');
    if newcomer->>'error_code' <> 'JOIN_REJECTED' then
      raise exception 'Capacité % : 13e joueur accepté (%)',g,newcomer;
    end if;
    perform public.lancer_partie(c,h_token);
    st:=public.get_full_state(c,last_token);
    if json_array_length(st->'state'->'players')<>12 or st->'state'->'room'->>'status'='lobby' then
      raise exception 'Capacité % : 12 clients ne voient pas la bonne partie',g;
    end if;
    if g='white' then
      select count(*) into n_intruders from public.white_roles
        where room_id=rid and round=1 and role in ('undercover','white');
      if n_intruders<>2 then
        raise exception 'Capacité Mr White : 2 intrus nécessaires à 12 joueurs';
      end if;
    elsif g='mimes' then
      select count(*) into n from public.mime_parts where room_id=rid and round=1 and intensity is not null;
      if n<>11 then raise exception 'Capacité Mimes : 11 prestations requises, reçu %',n; end if;
    end if;
    raise notice 'QA PASS capacité : %, 12 joueurs, refus 13e et partie lancée',g;
  end loop;

  perform pg_catalog.set_config('request.headers','{"x-forwarded-for":"192.0.2.210"}',true);
  host:=public.create_room('QA Capacité Petit Bac',1,'bac',1);c:=host->>'code';
  newcomer:=public.join_room(c,'QA Second');
  if newcomer->>'token' is null then raise exception 'Petit Bac : second joueur refusé'; end if;
  newcomer:=public.join_room(c,'QA Troisième');
  if newcomer->>'error_code'<>'JOIN_REJECTED' then raise exception 'Petit Bac : troisième joueur accepté'; end if;
  perform public.lancer_partie(c,(host->>'token')::uuid);
  select * into r from public.rooms where code=c;
  if r.status<>'naming' then raise exception 'Petit Bac : 2 joueurs ne démarrent pas'; end if;
  raise notice 'QA PASS : capacité Petit Bac 2 joueurs et refus du troisième';
end $capacity$;

rollback;
