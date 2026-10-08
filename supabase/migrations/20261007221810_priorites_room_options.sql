-- Priorités : choix du jeu à la création et depuis le salon.

-- ---------- Choix du jeu : à la création, puis par l'hôte depuis le salon ----------
drop function if exists public.create_room(text, integer);
create or replace function public.create_room(p_name text, p_target integer default 5,
                                              p_mode text default 'phrases', p_turns integer default 2)
 returns json language plpgsql security definer set search_path to '' as $function$
declare
  r public.rooms;
  p public.players;
  n text := left(trim(coalesce(p_name, '')), 20);
  client_hash text;
  attempt integer;
begin
  if n = '' then
    raise exception 'Choisis un pseudo.';
  end if;
  if p_target is null or p_target not in (3, 5, 7, 10) then
    raise exception 'Le score cible doit être 3, 5, 7 ou 10.';
  end if;
  if p_mode is null or p_mode not in ('phrases', 'priorites') then
    raise exception 'Jeu inconnu.';
  end if;
  if p_turns is null or p_turns not in (1, 2, 3) then
    raise exception 'Le nombre de tours doit être 1, 2 ou 3.';
  end if;

  client_hash := public._client_hash();

  if client_hash is not null then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('bmp-create:' || client_hash, 0)
    );
    if (
      select count(*)
      from public.rooms x
      where x.created_by_hash = client_hash
        and x.created_at > now() - interval '10 minutes'
    ) >= 10 then
      raise exception 'Trop de parties créées récemment. Réessaie dans quelques minutes.';
    end if;
  end if;

  delete from public.rooms
  where updated_at < now() - interval '1 day';

  for attempt in 1..5 loop
    begin
      insert into public.rooms(code, target_score, mode, judge_turns, created_by_hash)
      values (public._new_code(), p_target, p_mode, p_turns, client_hash)
      returning * into r;
      exit;
    exception when unique_violation then
      if attempt = 5 then
        raise exception 'Impossible de générer un code de partie. Réessaie.';
      end if;
    end;
  end loop;

  insert into public.players(room_id, name, seat, joined_by_hash)
  values (r.id, n, 0, client_hash)
  returning * into p;

  update public.rooms
  set host_id = p.id
  where id = r.id;

  return json_build_object('code', r.code, 'player_id', p.id, 'token', p.token);
end
$function$;

create or replace function public.set_room_options(p_code text, p_token uuid, p_mode text, p_target integer, p_turns integer)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception 'Seul l’hôte choisit le jeu.'; end if;
  if r.status <> 'lobby' then raise exception 'Le jeu se choisit depuis le salon.'; end if;
  if p_mode is null or p_mode not in ('phrases', 'priorites') then raise exception 'Jeu inconnu.'; end if;
  if p_target is null or p_target not in (3, 5, 7, 10) then raise exception 'Le score cible doit être 3, 5, 7 ou 10.'; end if;
  if p_turns is null or p_turns not in (1, 2, 3) then raise exception 'Le nombre de tours doit être 1, 2 ou 3.'; end if;
  update public.rooms set mode = p_mode, target_score = p_target, judge_turns = p_turns, updated_at = now()
    where id = r.id;
end $function$;

create or replace function public.start_game(p_code text, p_token uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; rd uuid;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.host_id<>me.id then raise exception 'Seul l’hôte peut lancer la partie.'; end if;
 if r.status<>'lobby' then raise exception 'La partie est déjà en cours.'; end if;
 if (select count(*) from public.players where room_id=r.id and active)<3 then raise exception 'Il faut au moins 3 joueurs.'; end if;
 if exists(select 1 from public.players where room_id=r.id and active and not ready) then raise exception 'Tous les joueurs doivent être prêts.'; end if;
 update public.players set score=0,discard_round=0,next_ack_round=0,continue_requested=false,judge_count=0 where room_id=r.id and active;
 delete from public.hands where room_id=r.id; delete from public.used_answers where room_id=r.id; delete from public.submissions where room_id=r.id;
 delete from public.rankings where room_id=r.id;
 update public.rooms set used_questions='{}',round=0,previous_reader_id=null,reader_id=null,rank_cards='{}' where id=r.id;
 rd:=public._random_reader(r.id,null);
 perform public._begin_round(r.id,rd,1);
end $function$;

revoke all on function public.create_room(text, integer, text, integer) from public, anon, authenticated;
grant execute on function public.create_room(text, integer, text, integer) to anon;
revoke all on function public.set_room_options(text, uuid, text, integer, integer) from public, anon, authenticated;
grant execute on function public.set_room_options(text, uuid, text, integer, integer) to anon;
revoke all on function public.start_game(text, uuid) from public, anon, authenticated;
grant execute on function public.start_game(text, uuid) to anon;
