-- Grand Quiz AS Grinta 2026: create once with Admin+, join with a normal 8-digit room code.
-- The event's two halves remain server-side, no question bank and no host control panel.

alter table asgq_private.event
  add column if not exists created boolean not null default false;
alter table asgq_private.event
  add column if not exists room_code text;
alter table asgq_private.event
  add constraint asgq_room_code_8_digits check (room_code is null or room_code ~ '^[0-9]{8}$');

-- Cryptographically random 8 digit room code (same representation as the other games).
create or replace function asgq_private.new_room_code()
returns text
language plpgsql volatile security definer set search_path = '' as $fn$
declare
  raw_random bigint;
begin
  for attempt in 1..64 loop
    raw_random := ('x' || substr(replace(pg_catalog.gen_random_uuid()::text, '-', ''), 1, 8))::bit(32)::bigint;
    if raw_random >= 4200000000 then continue; end if;
    return pg_catalog.lpad((raw_random % 100000000)::text, 8, '0');
  end loop;
  raise exception 'Code de salon indisponible. Réessaie.';
end $fn$;

-- Allow anonymous clients to create only after server-side Admin+ verification.
create or replace function public.asgq_create(p_password text, p_name text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_private.event%rowtype;
  private_code text;
  public_code text;
  joined jsonb;
begin
  if not public._is_admin_plus(p_password) then
    raise exception 'Mot de passe Admin+ incorrect.';
  end if;
  select * into ev from asgq_private.event where id=1 for update;
  if ev.id is null then raise exception 'Événement indisponible.'; end if;
  if ev.created or ev.phase <> 'lobby' then
    raise exception 'La partie AS Grinta existe déjà : rejoins-la avec son code.';
  end if;
  public_code := asgq_private.new_room_code();
  select plaintext_code into private_code from asgq_private.invitation where event_id=1;
  if private_code is null then raise exception 'Événement non configuré.'; end if;
  update asgq_private.event set created=true, room_code=public_code where id=1;
  joined := public.asgq_join(private_code, p_name, null);
  return joined || pg_catalog.jsonb_build_object('code',public_code);
end $fn$;

-- Guessing attempts use the same per-client hashing as normal Soulieteur rooms.
create table if not exists asgq_private.join_attempts(
  client_hash text primary key,
  window_started_at timestamptz not null default now(),
  attempts integer not null default 0
);
alter table asgq_private.join_attempts enable row level security;
revoke all on asgq_private.join_attempts from public, anon, authenticated;

create or replace function public.asgq_join_room(p_code text, p_name text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_private.event%rowtype;
  normalized_code text;
  private_code text;
  client_hash text;
  attempt_count integer;
  joined jsonb;
begin
  normalized_code := regexp_replace(coalesce(p_code,''),'[^0-9]','','g');
  client_hash := public._client_hash();
  if client_hash is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('asgq-join:'||client_hash,0));
    insert into asgq_private.join_attempts(client_hash,window_started_at,attempts)
      values(client_hash,clock_timestamp(),1)
      on conflict (client_hash) do update
        set attempts=case when asgq_private.join_attempts.window_started_at < clock_timestamp() - interval '10 minutes'
                          then 1 else asgq_private.join_attempts.attempts+1 end,
            window_started_at=case when asgq_private.join_attempts.window_started_at < clock_timestamp() - interval '10 minutes'
                          then clock_timestamp() else asgq_private.join_attempts.window_started_at end
      returning attempts into attempt_count;
    if attempt_count > 10 then
      return pg_catalog.jsonb_build_object('error','Trop de tentatives. Réessaie dans quelques minutes.');
    end if;
  end if;
  select * into ev from asgq_private.event where id=1;
  if ev.id is null or not ev.created then
    return pg_catalog.jsonb_build_object('error','La partie AS Grinta n’a pas encore été créée.');
  end if;
  if length(normalized_code) <> 8 or normalized_code <> ev.room_code then
    return pg_catalog.jsonb_build_object('error','Code de partie incorrect.');
  end if;
  select plaintext_code into private_code from asgq_private.invitation where event_id=1;
  if private_code is null then raise exception 'Événement non configuré.'; end if;
  joined := public.asgq_join(private_code,p_name,null);
  return joined || pg_catalog.jsonb_build_object('code',ev.room_code);
end $fn$;

create or replace function asgq_private.tick()
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_private.event%rowtype;
  question_row asgq_private.questions%rowtype;
  next_row asgq_private.questions%rowtype;
  player_total integer;
  boundary timestamptz;
begin
  select * into ev from asgq_private.event where id = 1 for update;
  if not found then raise exception 'Événement non configuré.'; end if;

  -- Disarm/correct the event without a countdown accidentally surviving.
  if ev.phase = 'lobby' and ev.starts_at is not null
     and (not ev.armed or not asgq_private.ready_for_kickoff()) then
    update asgq_private.event set starts_at=null, phase_started_at=null where id=1;
    select * into ev from asgq_private.event where id=1;
  end if;

  if ev.phase = 'lobby' and ev.starts_at is null then
    select count(*) into player_total from asgq_private.players;
    if player_total >= ev.min_players and ev.created and ev.armed and asgq_private.ready_for_kickoff() then
      update asgq_private.event
        set phase_started_at = clock_timestamp(),
            starts_at = clock_timestamp() + make_interval(secs => ev.lobby_seconds)
      where id = ev.id;
      select * into ev from asgq_private.event where id = 1;
    end if;
  end if;

  for i in 1..100 loop
    exit when ev.phase = 'finished';
    exit when ev.phase = 'lobby' and (ev.starts_at is null or clock_timestamp() < ev.starts_at);
    exit when ev.phase <> 'lobby' and (ev.phase_until is null or clock_timestamp() < ev.phase_until);

    boundary := case when ev.phase = 'lobby' then ev.starts_at else ev.phase_until end;

    if ev.phase = 'lobby' then
      update asgq_private.event set phase='intro', phase_started_at=boundary,
        phase_until=boundary + make_interval(secs=>ev.intro_seconds) where id=1;
    elsif ev.phase = 'intro' then
      select * into question_row from asgq_private.questions order by position limit 1;
      if not found then raise exception 'Aucune question configurée.'; end if;
      update asgq_private.event set phase='question', current_position=question_row.position,
        phase_started_at=boundary, phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
    elsif ev.phase = 'question' then
      select * into question_row from asgq_private.questions where position=ev.current_position;
      -- Snapshot / idempotence: only the question -> reveal transition awards points.
      update asgq_private.answers a
        set points_awarded = case when a.choice = question_row.correct_index then question_row.points else 0 end
      where a.question_id = question_row.id;
      update asgq_private.players p set score = p.score + t.earned
      from (select player_id, sum(points_awarded)::integer as earned
            from asgq_private.answers where question_id=question_row.id
            group by player_id) t
      where p.id=t.player_id;
      update asgq_private.event set phase='reveal',phase_started_at=boundary,
        phase_until=boundary + make_interval(secs=>ev.reveal_seconds) where id=1;
    elsif ev.phase = 'reveal' then
      select * into question_row from asgq_private.questions where position=ev.current_position;
      select * into next_row from asgq_private.questions where position>ev.current_position order by position limit 1;
      if not found then
        update asgq_private.event set phase='finished', phase_started_at=boundary,
          phase_until=null where id=1;
      elsif question_row.half=1 and next_row.half=2 then
        update asgq_private.event set phase='halftime',phase_started_at=boundary,
          phase_until=boundary + make_interval(secs=>ev.halftime_seconds) where id=1;
      else
        update asgq_private.event set phase='question', current_position=next_row.position,
          phase_started_at=boundary,phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
      end if;
    elsif ev.phase = 'halftime' then
      select * into next_row from asgq_private.questions where half=2 order by position limit 1;
      if not found then raise exception 'La seconde mi-temps est vide.'; end if;
      update asgq_private.event set phase='question', current_position=next_row.position,
        phase_started_at=boundary,phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
    end if;

    select * into ev from asgq_private.event where id=1;
  end loop;
end $fn$;

create or replace function public.asgq_state(p_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  player_row asgq_private.players%rowtype;
  ev asgq_private.event%rowtype;
  q asgq_private.questions%rowtype;
  my_answer asgq_private.answers%rowtype;
  show_result boolean;
  n integer;
  first_half integer;
  second_half integer;
  ordinal integer;
  people jsonb;
  ranking jsonb;
begin
  player_row := asgq_private.player_for(p_token);
  if player_row.id is null then raise exception 'Session expirée. Rejoins la partie.'; end if;
  perform asgq_private.tick();
  select * into ev from asgq_private.event where id=1;
  select count(*) into n from asgq_private.questions;
  select count(*) into first_half from asgq_private.questions where half=1;
  select count(*) into second_half from asgq_private.questions where half=2;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.joined_at), '[]'::jsonb)
    into people from asgq_private.players p;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'score',p.score) order by p.score desc,p.joined_at), '[]'::jsonb)
    into ranking from asgq_private.players p;
  select * into q from asgq_private.questions where position=ev.current_position;
  if q.id is not null then
    select * into my_answer from asgq_private.answers
    where question_id=q.id and player_id=player_row.id;
  end if;
  select count(*) into ordinal from asgq_private.questions where position <= ev.current_position;
  show_result := ev.phase='reveal';
  return jsonb_build_object(
    'phase', ev.phase, 'ready', (ev.armed and asgq_private.ready_for_kickoff()), 'room_code', ev.room_code, 'title', ev.title, 'now',clock_timestamp(),
    'starts_at',ev.starts_at,'phase_started_at',ev.phase_started_at,'phase_until',ev.phase_until,
    'position',ordinal, 'total',n, 'first_half_count',first_half, 'second_half_count',second_half,
    'half',case when ev.phase='halftime' then 2 when q.id is not null then q.half else 1 end,
    'players',people, 'standings',case when ev.phase in ('reveal','halftime','finished') then ranking else null end,
    'me',jsonb_build_object('id',player_row.id,'name',player_row.name,
      'score',(select score from asgq_private.players where id=player_row.id)),
    'question', case when ev.phase in ('question','reveal') and q.id is not null then
      jsonb_build_object('text',q.prompt,'choices',q.choices,'points',q.points,
        'correct',case when show_result then q.correct_index else null end,
        'explanation',case when show_result then q.explanation else null end,
        'my_choice',my_answer.choice,'earned',case when show_result then my_answer.points_awarded else null end,
        'answered_count',(select count(*) from asgq_private.answers where question_id=q.id))
      else null end
  );
end $fn$;

-- Deactivate the previous Admin+ *joining* shortcut and the technical invitation RPC.
revoke execute on function public.asgq_join_admin_plus(text,text) from public, anon, authenticated;
revoke execute on function public.asgq_join(text,text,uuid) from public, anon, authenticated;
revoke execute on function public.asgq_create(text,text) from public, anon, authenticated;
revoke execute on function public.asgq_join_room(text,text) from public, anon, authenticated;
grant execute on function public.asgq_create(text,text) to anon, authenticated;
grant execute on function public.asgq_join_room(text,text) to anon, authenticated;
revoke all on all functions in schema asgq_private from public, anon, authenticated;
