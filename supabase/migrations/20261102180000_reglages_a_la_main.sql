-- Réglages tapés à la main, pour tous les jeux :
--   manches à gagner (Phrases à trou) et manches à jouer (Petit bac) : 1 à 20 ;
--   tours de juge / de médium par joueur (Priorités, Baromètre) : 1 à 5.
-- Remplace aussi 20261031150000_petit_bac_manches_reglables, jamais appliquée
-- en production (d'où le refus de « 1 manche » au Petit bac).
-- Petit bac : 20 manches au plus, autant que de lettres dans la roue.

alter table public.rooms drop constraint if exists rooms_target_score_check;
alter table public.rooms add constraint rooms_target_score_check check (target_score between 1 and 20);
alter table public.rooms drop constraint if exists rooms_judge_turns_check;
alter table public.rooms add constraint rooms_judge_turns_check check (judge_turns between 1 and 5);

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
  if p_target is null or p_target not between 1 and 20 then
    raise exception 'Le nombre de manches doit être entre 1 et 20.';
  end if;
  if p_mode is null or p_mode not in ('phrases', 'priorites', 'ondes', 'bac') then
    raise exception 'Jeu inconnu.';
  end if;
  if p_turns is null or p_turns not between 1 and 5 then
    raise exception 'Le nombre de tours doit être entre 1 et 5.';
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
  if p_mode is null or p_mode not in ('phrases', 'priorites', 'ondes', 'bac') then raise exception 'Jeu inconnu.'; end if;
  if p_target is null or p_target not between 1 and 20 then raise exception 'Le nombre de manches doit être entre 1 et 20.'; end if;
  if p_turns is null or p_turns not between 1 and 5 then raise exception 'Le nombre de tours doit être entre 1 et 5.'; end if;
  if (select count(*) from public.players where room_id = r.id and active) > public._max_players(p_mode) then
    raise exception 'Le Petit bac se joue à deux.';
  end if;
  update public.rooms set mode = p_mode, target_score = p_target, judge_turns = p_turns, updated_at = now()
    where id = r.id;
end $function$;

create or replace function public._begin_bac_round(p_room uuid, p_next_round integer)
 returns void language plpgsql security definer set search_path to '' as $function$
declare r public.rooms; w uuid; l text;
  lettres text[] := string_to_array('A,B,C,D,E,F,G,H,I,J,L,M,N,O,P,R,S,T,U,V', ',');
begin
  select * into r from public.rooms where id = p_room;
  -- nombre de manches choisi au salon (target_score), 20 au plus : une lettre par manche
  if p_next_round > least(r.target_score, 20) then
    select id into w from public.players where room_id = p_room and active order by score desc, seat limit 1;
    update public.rooms set status = 'finished', winner_id = w, winning_submission_id = null,
      phase_at = now(), updated_at = now() where id = p_room;
    return;
  end if;

  update public.players set next_ack_round = 0 where room_id = p_room and active;
  delete from public.bac_answers where room_id = p_room and round = p_next_round;

  if cardinality(r.bac_categories) < 6 then
    update public.rooms set
      status = 'naming', round = p_next_round,
      previous_reader_id = reader_id, reader_id = public._next_reader(p_room, null),
      bac_letter = null, bac_step = 0,
      question_id = null, question_choices = '{}',
      winner_id = null, winning_submission_id = null,
      phase_at = now(), updated_at = now()
    where id = p_room;
    return;
  end if;

  -- K, Q, W, X, Y et Z sont écartées : trop peu de mots pour six catégories.
  select x into l from unnest(lettres) x where not (x = any(r.used_bac_letters)) order by random() limit 1;
  update public.rooms set
    status = 'writing', round = p_next_round,
    previous_reader_id = reader_id,
    bac_letter = l, used_bac_letters = r.used_bac_letters || l, bac_step = 0,
    question_id = null, question_choices = '{}',
    winner_id = null, winning_submission_id = null,
    phase_at = now() + interval '5 seconds', updated_at = now()
  where id = p_room;
end $function$;

revoke all on function public.create_room(text, integer, text, integer) from public, anon, authenticated;
grant execute on function public.create_room(text, integer, text, integer) to anon;
revoke all on function public.set_room_options(text, uuid, text, integer, integer) from public, anon, authenticated;
grant execute on function public.set_room_options(text, uuid, text, integer, integer) to anon;
revoke all on function public._begin_bac_round(uuid, integer) from public, anon, authenticated;
