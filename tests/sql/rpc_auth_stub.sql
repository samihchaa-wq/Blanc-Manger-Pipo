-- Extension au PostgreSQL jetable de CI : tables minimales pour exécuter
-- les vraies fonctions SQL de production, sans connexion Supabase.
alter table public.rooms
  add column host_id uuid,
  add column round integer not null default 1,
  add column reader_id uuid;
alter table public.players
  add column is_bot boolean not null default false;

create or replace function public._player(p_code text, p_token uuid)
returns public.players
language sql stable security definer
set search_path to ''
as $$
  select p.* from public.players p join public.rooms r on r.id=p.room_id
  where r.code=upper(trim(p_code)) and p.token=p_token and p.active
$$;

create table public.dico_defs(
  id uuid primary key default pg_catalog.gen_random_uuid(),
  room_id uuid not null references public.rooms(id),
  round integer not null,
  player_id uuid,
  text text
);
create table public.dico_votes(
  room_id uuid not null references public.rooms(id),
  round integer not null,
  voter_id uuid not null references public.players(id),
  def_id uuid not null references public.dico_defs(id),
  primary key(room_id,round,voter_id)
);
create table public.dilemme_buts(
  id uuid primary key default pg_catalog.gen_random_uuid(),
  room_id uuid not null references public.rooms(id),
  round integer not null,
  player_id uuid not null references public.players(id),
  text text
);
create table public.dilemme_votes(
  room_id uuid not null references public.rooms(id),
  round integer not null,
  voter_id uuid not null references public.players(id),
  but_id uuid not null references public.dilemme_buts(id),
  yes boolean not null,
  primary key(room_id,round,voter_id,but_id)
);

create function public._dico_advance(p_room uuid) returns void
language plpgsql as $$begin null; end$$;
create function public._dilemme_advance(p_room uuid) returns void
language plpgsql as $$begin null; end$$;
