-- Punitions facultatives : un joueur peut valider l'écran de saisie sans rien
-- écrire. « A validé » ne se déduit donc plus de la présence de punitions :
-- players.punish_sent le garde. Le jeu démarre quand tous les humains ont validé,
-- avec ou sans punitions. Sans aucune punition proposée, pas de roue à la fin.

alter table public.players
  add column if not exists punish_sent boolean not null default false;

-- ---------- Trigger : même rôle, contrôle sur punish_sent ----------
create or replace function public._punish_room_guard()
 returns trigger language plpgsql set search_path to '' as $function$
begin
  if old.status = 'lobby' and new.status <> 'lobby' then
    if new.punish and exists (
      select 1 from public.players p where p.room_id = new.id and p.active and not p.is_bot and not p.punish_sent
    ) then
      raise exception 'Chaque joueur doit valider l’écran des punitions.';
    end if;
    new.punish_phase := false;
    new.punish_loser := null; new.punish_pick := null; new.punish_spun_at := null;
  elsif old.status = 'finished' and new.status = 'lobby' then
    delete from public.punishments where room_id = new.id;
    update public.players set punish_sent = false where room_id = new.id and punish_sent;
    new.punish_phase := false;
    new.punish_loser := null; new.punish_pick := null; new.punish_spun_at := null;
  end if;
  return new;
end $function$;

-- ---------- Lancement : remet les validations à zéro ----------
create or replace function public.punish_start(p_code text, p_token uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; nb integer; mn integer;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception 'Seul l’hôte peut lancer la partie.'; end if;
  if r.status <> 'lobby' or r.punish_phase then raise exception 'La partie est déjà lancée.'; end if;
  if not r.punish then raise exception 'Les punitions ne sont pas activées.'; end if;
  mn := public._min_players(r.mode);
  select count(*) into nb from public.players where room_id = r.id and active;
  if nb < mn then raise exception 'Il faut au moins % joueurs.', mn; end if;
  if nb > public._max_players(r.mode) then raise exception 'Le Petit bac se joue à deux.'; end if;
  if exists (select 1 from public.players where room_id = r.id and active and not ready) then
    raise exception 'Tous les joueurs doivent être prêts.';
  end if;
  delete from public.punishments where room_id = r.id;
  update public.players set punish_sent = false where room_id = r.id and punish_sent;
  update public.rooms set punish_phase = true, punish_loser = null, punish_pick = null, punish_spun_at = null,
    phase_at = now(), updated_at = now() where id = r.id;
end $function$;

-- ---------- Démarrage automatique : tous les humains ont validé ----------
create or replace function public._punish_maybe_start(p_room uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare r public.rooms; tk uuid;
begin
  select * into r from public.rooms where id = p_room for update;
  if r.status <> 'lobby' or not r.punish_phase then return; end if;
  if (select count(*) from public.players where room_id = r.id and active) < public._min_players(r.mode) then
    delete from public.punishments where room_id = r.id;
    update public.players set punish_sent = false where room_id = r.id and punish_sent;
    update public.rooms set punish_phase = false, updated_at = now() where id = r.id;
    return;
  end if;
  if exists (
    select 1 from public.players p where p.room_id = r.id and p.active and not p.is_bot and not p.punish_sent
  ) then return; end if;
  update public.players set ready = true where room_id = r.id and active;
  select token into tk from public.players where id = r.host_id;
  perform public.start_game(r.code, tk);
end $function$;

-- ---------- Saisie : zéro à punish_count punitions ----------
create or replace function public.punish_submit(p_code text, p_token uuid, p_texts text[])
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; t text[];
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.status <> 'lobby' or not r.punish_phase then raise exception 'Ce n’est plus le moment de proposer des punitions.'; end if;
  if me.punish_sent then raise exception 'Tes punitions sont déjà envoyées.'; end if;
  select coalesce(array_agg(x order by i), '{}') into t
    from (select btrim(regexp_replace(coalesce(v, ''), '\s+', ' ', 'g')) x, i
          from unnest(coalesce(p_texts, '{}')) with ordinality as u(v, i)) s
    where x <> '';
  if cardinality(t) > r.punish_count then raise exception '% punition(s) au maximum.', r.punish_count; end if;
  if exists (select 1 from unnest(t) x where char_length(x) > 100) then
    raise exception 'Une punition fait 100 caractères au maximum.';
  end if;
  insert into public.punishments (room_id, player_id, text) select r.id, me.id, x from unnest(t) x;
  update public.players set punish_sent = true where id = me.id;
  update public.rooms set updated_at = now() where id = r.id;
  begin
    perform public._punish_maybe_start(r.id);
  exception when others then null;
  end;
end $function$;

-- ---------- Lecture : ajoute 'sent' (ids des joueurs ayant validé) ----------
create or replace function public.punish_state(p_code text, p_token uuid)
 returns json language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; l uuid;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id;
  if r.status = 'lobby' and r.punish_phase then
    begin perform public._punish_maybe_start(r.id); exception when others then null; end;
    select * into r from public.rooms where id = r.id;
  end if;
  if r.status = 'finished' and r.punish then l := public._punish_loser(r.id); select * into r from public.rooms where id = r.id; end if;
  return json_build_object(
    'on', r.punish,
    'count', r.punish_count,
    'phase', r.punish_phase,
    'mine', (select coalesce(json_agg(json_build_object('id', x.id, 'text', x.text) order by x.id), '[]'::json)
             from public.punishments x where x.player_id = me.id),
    'counts', (select coalesce(json_object_agg(c.player_id, c.n), '{}'::json)
               from (select player_id, count(*) n from public.punishments where room_id = r.id group by player_id) c),
    'sent', (select coalesce(json_agg(p.id), '[]'::json)
             from public.players p where p.room_id = r.id and p.punish_sent),
    'loser_id', r.punish_loser,
    'items', case when r.status = 'finished' then
      (select coalesce(json_agg(json_build_object('id', x.id, 'text', x.text) order by x.id), '[]'::json)
       from public.punishments x where x.room_id = r.id) else '[]'::json end,
    'pick', case when r.punish_pick is not null then
      (select json_build_object('id', x.id, 'text', x.text, 'author', p.name)
       from public.punishments x join public.players p on p.id = x.player_id where x.id = r.punish_pick) end
  );
end $function$;

revoke all on function public._punish_maybe_start(uuid) from public, anon, authenticated;
revoke all on function public.punish_start(text, uuid) from public, anon, authenticated;
revoke all on function public.punish_submit(text, uuid, text[]) from public, anon, authenticated;
revoke all on function public.punish_state(text, uuid) from public, anon, authenticated;
grant execute on function public.punish_start(text, uuid) to anon;
grant execute on function public.punish_submit(text, uuid, text[]) to anon;
grant execute on function public.punish_state(text, uuid) to anon;
