-- Schéma minimal pour tester le SQL de production dans un Postgres jetable.
-- Ce fichier est réservé à la CI : il ne doit jamais être appliqué à Supabase.
create role anon nologin;
create role authenticated nologin;

create table public.rooms (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  code text not null unique,
  status text not null default 'lobby',
  mode text not null default 'phrases',
  updated_at timestamptz not null default now()
);
create table public.players (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  room_id uuid not null references public.rooms(id),
  name text not null,
  token uuid not null default pg_catalog.gen_random_uuid(),
  seat integer not null,
  active boolean not null default true,
  joined_by_hash text,
  created_at timestamptz not null default now()
);
create function public._client_hash() returns text
language sql stable
set search_path to ''
as $$
  select nullif(pg_catalog.current_setting('request.headers', true)::jsonb->>'x-forwarded-for','')
$$;
create function public._max_players(p_mode text) returns integer
language sql immutable
as $$select case when p_mode='bac' then 2 else 12 end$$;
create function public.create_room(
  p_name text, p_target integer default 5,
  p_mode text default 'phrases', p_turns integer default 2
) returns json language plpgsql set search_path to ''
as $$
declare rid uuid; pid uuid; tok uuid;
begin
  insert into public.rooms(code, mode) values ('1234',p_mode) returning id into rid;
  insert into public.players(room_id,name,seat) values (rid,p_name,0)
    returning id,token into pid,tok;
  return pg_catalog.json_build_object('code','1234','player_id',pid,'token',tok);
end
$$;
