-- Protection des codes de salon : journaliser également les tentatives refusées.
-- IMPORTANT : une exception PostgreSQL annulerait le compteur en même temps
-- que la tentative. Les refus attendus sont donc renvoyés sous forme JSON.
begin;

create table if not exists public.room_join_limits (
  client_hash text primary key,
  window_started_at timestamptz not null default now(),
  requests integer not null default 0 check (requests >= 0),
  failures integer not null default 0 check (failures >= 0),
  last_attempt_at timestamptz not null default now()
);

create index if not exists room_join_limits_last_attempt_idx
  on public.room_join_limits(last_attempt_at);

alter table public.room_join_limits enable row level security;
-- Les visiteurs ne lisent ni les empreintes de réseau ni les compteurs.
revoke all on table public.room_join_limits from PUBLIC, anon, authenticated;

create or replace function public.join_room(p_code text, p_name text)
returns json
language plpgsql
security definer
set search_path to ''
as $function$
declare
  r public.rooms;
  p public.players;
  n text := left(trim(coalesce(p_name, '')), 20);
  client_hash text;
  rl public.room_join_limits;
  err text;
begin
  if n = '' then
    return json_build_object('error', 'Choisis un pseudo.', 'error_code', 'INVALID_NAME');
  end if;

  client_hash := public._client_hash();
  if client_hash is not null then
    -- Série d'appels simultanés : un seul compteur par source, sans interleaving.
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('bmp-join:' || client_hash, 0)
    );

    insert into public.room_join_limits(client_hash, window_started_at, requests, failures, last_attempt_at)
      values (client_hash, now(), 1, 0, now())
    on conflict (client_hash) do update set
      window_started_at = case
        when public.room_join_limits.window_started_at < now() - interval '10 minutes'
          then now() else public.room_join_limits.window_started_at end,
      requests = case
        when public.room_join_limits.window_started_at < now() - interval '10 minutes'
          then 1 else public.room_join_limits.requests + 1 end,
      failures = case
        when public.room_join_limits.window_started_at < now() - interval '10 minutes'
          then 0 else public.room_join_limits.failures end,
      last_attempt_at = now()
    returning * into rl;

    -- Une source peut réunir plusieurs amis derrière un même Wi-Fi.
    -- 48 essais au total ou 8 refus sur 10 minutes : blocage temporaire.
    if rl.requests > 48 or rl.failures >= 8 then
      return json_build_object('error',
        'Trop de tentatives. Réessaie dans quelques minutes.',
        'error_code', 'RATE_LIMITED');
    end if;

    -- Nettoyage opportuniste sans tâche programmée ni stockage d'IP en clair.
    if random() < 0.02 then
      delete from public.room_join_limits
      where last_attempt_at < now() - interval '1 day';
    end if;
  end if;

  select * into r from public.rooms
  where code = upper(trim(p_code)) for update;

  if r.id is null then
    err := 'Aucune partie avec ce code.';
  elsif r.status not in ('lobby', 'finished') then
    err := 'La partie a déjà commencé. Attends qu''elle se termine.';
  elsif (select count(*) from public.players
         where room_id = r.id and active) >= public._max_players(r.mode) then
    err := case when r.mode = 'bac'
      then 'La partie est pleine : le Petit bac se joue à deux.'
      else 'La partie est pleine (12 joueurs max).' end;
  elsif exists(select 1 from public.players
               where room_id = r.id and active and lower(name) = lower(n)) then
    err := 'Ce pseudo est déjà pris dans cette partie.';
  end if;

  if err is not null then
    -- Pas de RAISE EXCEPTION : les compteurs doivent survivre aux mauvais codes.
    if client_hash is not null then
      update public.room_join_limits
      set failures = failures + 1, last_attempt_at = now()
      where room_join_limits.client_hash = rl.client_hash;
    end if;
    if r.id is null then perform pg_catalog.pg_sleep(0.15); end if;
    return json_build_object('error', err, 'error_code', 'JOIN_REJECTED');
  end if;

  insert into public.players(room_id, name, seat, joined_by_hash)
  values(r.id, n, (select coalesce(max(seat), -1) + 1
                   from public.players where room_id = r.id), client_hash)
  returning * into p;
  update public.rooms set updated_at = now() where id = r.id;
  return json_build_object('code', r.code, 'player_id', p.id, 'token', p.token);
end
$function$;

commit;
