-- Punitions : option du salon. Chaque joueur humain en propose 1 ou 2, cachées
-- jusqu'à la fin de la partie. Le dernier du classement tourne alors une roue
-- qui tire l'une d'elles (tirage côté serveur : tout le monde voit la même).
-- Migration additive : aucune fonction existante n'est réécrite, deux triggers
-- sur rooms gèrent le lancement et le retour au salon.

alter table public.rooms
  add column if not exists punish boolean not null default false,
  add column if not exists punish_loser uuid,
  add column if not exists punish_pick bigint,
  add column if not exists punish_spun_at timestamptz;

create table if not exists public.punishments (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.rooms(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  text text not null,
  created_at timestamptz not null default now()
);
create index if not exists punishments_room_idx on public.punishments(room_id);
create index if not exists punishments_player_idx on public.punishments(player_id);
alter table public.punishments enable row level security;
revoke all on table public.punishments from public, anon, authenticated;

-- ---------- Triggers ----------
-- Lancement : chaque joueur humain doit avoir proposé au moins une punition.
-- Fin de partie → salon : on repart de zéro (punitions et tirage effacés).
create or replace function public._punish_room_guard()
 returns trigger language plpgsql set search_path to '' as $function$
begin
  if old.status = 'lobby' and new.status <> 'lobby' then
    if new.punish and exists (
      select 1 from public.players p where p.room_id = new.id and p.active and not p.is_bot
        and not exists (select 1 from public.punishments x where x.player_id = p.id)
    ) then
      raise exception 'Chaque joueur doit proposer au moins une punition.';
    end if;
    new.punish_loser := null; new.punish_pick := null; new.punish_spun_at := null;
  elsif old.status = 'finished' and new.status = 'lobby' then
    delete from public.punishments where room_id = new.id;
    new.punish_loser := null; new.punish_pick := null; new.punish_spun_at := null;
  end if;
  return new;
end $function$;

drop trigger if exists punish_room_guard on public.rooms;
create trigger punish_room_guard before update of status on public.rooms
  for each row execute function public._punish_room_guard();

-- ---------- Perdant : le dernier du classement, tiré au sort en cas d'égalité ----------
-- Calculé à la première lecture de l'écran de fin, quand les scores sont figés.
create or replace function public._punish_loser(p_room uuid)
 returns uuid language plpgsql security definer set search_path to '' as $function$
declare r public.rooms; l uuid;
begin
  select * into r from public.rooms where id = p_room for update;
  if r.status <> 'finished' or not r.punish then return null; end if;
  if r.punish_loser is not null then return r.punish_loser; end if;
  select p.id into l from public.players p
    where p.room_id = p_room and p.active
    order by p.score asc, random() limit 1;
  update public.rooms set punish_loser = l where id = p_room;
  return l;
end $function$;

-- ---------- Option du salon ----------
create or replace function public.punish_set(p_code text, p_token uuid, p_on boolean)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception 'Seul l’hôte peut changer les options.'; end if;
  if r.status <> 'lobby' then raise exception 'La partie est déjà en cours.'; end if;
  update public.rooms set punish = coalesce(p_on, false), updated_at = now() where id = r.id;
end $function$;

-- ---------- Saisie (au salon) ----------
create or replace function public.punish_add(p_code text, p_token uuid, p_text text)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; t text := btrim(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g'));
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.status <> 'lobby' then raise exception 'Les punitions se proposent avant la partie.'; end if;
  if not r.punish then raise exception 'Les punitions ne sont pas activées.'; end if;
  if t = '' then raise exception 'Écris une punition.'; end if;
  if char_length(t) > 100 then raise exception 'Une punition fait 100 caractères au maximum.'; end if;
  if (select count(*) from public.punishments where player_id = me.id) >= 2 then
    raise exception 'Deux punitions au maximum.';
  end if;
  insert into public.punishments (room_id, player_id, text) values (r.id, me.id, t);
  update public.rooms set updated_at = now() where id = r.id;
end $function$;

create or replace function public.punish_remove(p_code text, p_token uuid, p_id bigint)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.status <> 'lobby' then raise exception 'La partie est déjà en cours.'; end if;
  delete from public.punishments where id = p_id and player_id = me.id;
  update public.rooms set updated_at = now() where id = r.id;
end $function$;

-- ---------- La roue : le perdant tourne (n'importe qui si c'est un bot ou s'il est parti) ----------
create or replace function public.punish_spin(p_code text, p_token uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; l uuid; pick bigint;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  l := public._punish_loser(me.room_id);
  select * into r from public.rooms where id = me.room_id for update;
  if r.status <> 'finished' or not r.punish then raise exception 'Pas de punition à tirer.'; end if;
  if r.punish_pick is not null then return; end if;
  if l is not null and l <> me.id and exists (
    select 1 from public.players p where p.id = l and p.active and not p.is_bot
  ) then
    raise exception 'C’est au perdant de tourner la roue.';
  end if;
  select id into pick from public.punishments where room_id = r.id order by random() limit 1;
  if pick is null then raise exception 'Aucune punition proposée.'; end if;
  update public.rooms set punish_pick = pick, punish_spun_at = now(), updated_at = now() where id = r.id;
end $function$;

-- ---------- Lecture : ses propres punitions, le nombre proposé par chacun ;
-- la liste complète seulement une fois la partie finie ----------
create or replace function public.punish_state(p_code text, p_token uuid)
 returns json language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; l uuid;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id;
  if r.status = 'finished' and r.punish then l := public._punish_loser(r.id); select * into r from public.rooms where id = r.id; end if;
  return json_build_object(
    'on', r.punish,
    'mine', (select coalesce(json_agg(json_build_object('id', x.id, 'text', x.text) order by x.id), '[]'::json)
             from public.punishments x where x.player_id = me.id),
    'counts', (select coalesce(json_object_agg(c.player_id, c.n), '{}'::json)
               from (select player_id, count(*) n from public.punishments where room_id = r.id group by player_id) c),
    'loser_id', r.punish_loser,
    'items', case when r.status = 'finished' then
      (select coalesce(json_agg(json_build_object('id', x.id, 'text', x.text) order by x.id), '[]'::json)
       from public.punishments x where x.room_id = r.id) else '[]'::json end,
    'pick', case when r.punish_pick is not null then
      (select json_build_object('id', x.id, 'text', x.text, 'author', p.name)
       from public.punishments x join public.players p on p.id = x.player_id where x.id = r.punish_pick) end
  );
end $function$;

revoke all on function public._punish_room_guard() from public, anon, authenticated;
revoke all on function public._punish_loser(uuid) from public, anon, authenticated;
revoke all on function public.punish_set(text, uuid, boolean) from public, anon, authenticated;
revoke all on function public.punish_add(text, uuid, text) from public, anon, authenticated;
revoke all on function public.punish_remove(text, uuid, bigint) from public, anon, authenticated;
revoke all on function public.punish_spin(text, uuid) from public, anon, authenticated;
revoke all on function public.punish_state(text, uuid) from public, anon, authenticated;
grant execute on function public.punish_set(text, uuid, boolean) to anon;
grant execute on function public.punish_add(text, uuid, text) to anon;
grant execute on function public.punish_remove(text, uuid, bigint) to anon;
grant execute on function public.punish_spin(text, uuid) to anon;
grant execute on function public.punish_state(text, uuid) to anon;
