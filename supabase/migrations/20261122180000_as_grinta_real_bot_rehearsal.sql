-- Server-based practice room for the Grand Quiz AS Grinta 2026.
-- Mirrors the actual question/scoring/timer/answer engine in a separate private schema.
-- The 1-use official event (asgq_private) remains untouched.
-- AS Grinta 2026: standalone, one-night, mobile-first quiz.
-- Independent of the Soulieteur rooms/QCM tables and RPCs.
-- One 10-character secret invitation code; never bundle this code in client assets.
-- All quiz answers stay in a non-exposed schema until the reveal phase.

create schema if not exists asgq_rehearsal_private;
revoke all on schema asgq_rehearsal_private from public, anon, authenticated;

create table if not exists asgq_rehearsal_private.event (
  id integer primary key check (id = 1),
  title text not null default 'Le Grand Quiz AS Grinta 2026',
  code_hash text not null,
  phase text not null default 'lobby' check (phase in ('lobby','intro','question','reveal','halftime','finished')),
  phase_started_at timestamptz,
  phase_until timestamptz,
  starts_at timestamptz,
  current_position integer not null default 0,
  min_players integer not null default 2 check (min_players between 2 and 30),
  max_players integer not null default 30 check (max_players between 2 and 30),
  lobby_seconds integer not null default 120 check (lobby_seconds between 20 and 3600),
  intro_seconds integer not null default 7 check (intro_seconds between 3 and 30),
  question_seconds integer not null default 25 check (question_seconds between 10 and 120),
  reveal_seconds integer not null default 9 check (reveal_seconds between 3 and 90),
  halftime_seconds integer not null default 40 check (halftime_seconds between 10 and 600),
  created_at timestamptz not null default now()
);

-- Secret only visible in the SQL dashboard; intentionally NO public RPC for this table.
create table if not exists asgq_rehearsal_private.invitation (
  event_id integer primary key references asgq_rehearsal_private.event(id) on delete cascade,
  plaintext_code text not null
);

create table if not exists asgq_rehearsal_private.players (
  id uuid primary key default gen_random_uuid(),
  event_id integer not null default 1 references asgq_rehearsal_private.event(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 22),
  token_hash text not null unique,
  score integer not null default 0,
  joined_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create unique index if not exists asgq_rehearsal_player_unique_name on asgq_rehearsal_private.players(event_id, lower(name));

create table if not exists asgq_rehearsal_private.questions (
  id bigint generated always as identity primary key,
  position integer not null unique check (position between 1 and 40),
  half smallint not null check (half in (1, 2)),
  prompt text not null check (char_length(prompt) between 3 and 220),
  choices text[] not null check (cardinality(choices) between 2 and 4),
  correct_index smallint not null check (correct_index between 0 and 3 and correct_index < cardinality(choices)),
  points smallint not null default 1 check (points between 1 and 3),
  explanation text
);

create table if not exists asgq_rehearsal_private.answers (
  player_id uuid not null references asgq_rehearsal_private.players(id) on delete cascade,
  question_id bigint not null references asgq_rehearsal_private.questions(id) on delete cascade,
  choice smallint not null check (choice between 0 and 3),
  answered_at timestamptz not null default clock_timestamp(),
  points_awarded integer not null default 0,
  primary key (player_id, question_id)
);
create index if not exists asgq_rehearsal_answers_question on asgq_rehearsal_private.answers(question_id);

-- Defensive RLS on every table, even though this schema is not exposed by Data API.
alter table asgq_rehearsal_private.event enable row level security;
alter table asgq_rehearsal_private.invitation enable row level security;
alter table asgq_rehearsal_private.players enable row level security;
alter table asgq_rehearsal_private.questions enable row level security;
alter table asgq_rehearsal_private.answers enable row level security;
revoke all on all tables in schema asgq_rehearsal_private from public, anon, authenticated;

-- Generate the single event's invitation code once. DB-only; not committed in git.
with code as materialized (
  select upper(encode(extensions.gen_random_bytes(5), 'hex')) as plaintext_code
), seeded as (
  insert into asgq_rehearsal_private.event(id, code_hash)
  select 1, encode(extensions.digest('asgq:' || plaintext_code, 'sha256'), 'hex') from code
  on conflict (id) do nothing
  returning id
)
insert into asgq_rehearsal_private.invitation(event_id, plaintext_code)
select seeded.id, code.plaintext_code from seeded cross join code
on conflict (event_id) do nothing;

-- Four clearly marked placeholders, two per half, ONLY for the first technical test.
-- Replace all of them with the actual 10-20 questions per half before the event.
insert into asgq_rehearsal_private.questions(position, half, prompt, choices, correct_index, points)
select p, case when p <= 2 then 1 else 2 end,
  'QUESTION DE TEST ' || p || ' — à remplacer avant la soirée',
  array['Réponse A (test)', 'Réponse B (test)', 'Réponse C (test)', 'Réponse D (test)'],
  0, 1
from generate_series(1,4) as p
on conflict (position) do nothing;

-- Internal authenticated participant lookup; never executable over PostgREST.
create or replace function asgq_rehearsal_private.player_for(p_token uuid)
returns asgq_rehearsal_private.players
language sql stable security definer set search_path = '' as $fn$
  select p from asgq_rehearsal_private.players p
  where p_token is not null and p.token_hash = encode(extensions.digest('asgq-token:' || p_token::text, 'sha256'), 'hex')
$fn$;

-- State-machine transitions are executed transactionally on ANY state read.
-- The event row is locked so simultaneous polls cannot award points twice.
create or replace function asgq_rehearsal_private.tick()
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  question_row asgq_rehearsal_private.questions%rowtype;
  next_row asgq_rehearsal_private.questions%rowtype;
  player_total integer;
  boundary timestamptz;
begin
  select * into ev from asgq_rehearsal_private.event where id = 1 for update;
  if not found then raise exception 'Événement non configuré.'; end if;

  if ev.phase = 'lobby' and ev.starts_at is null then
    select count(*) into player_total from asgq_rehearsal_private.players;
    if player_total >= ev.min_players and exists (select 1 from asgq_rehearsal_private.questions) then
      update asgq_rehearsal_private.event
        set phase_started_at = clock_timestamp(),
            starts_at = clock_timestamp() + make_interval(secs => ev.lobby_seconds)
      where id = ev.id;
      select * into ev from asgq_rehearsal_private.event where id = 1;
    end if;
  end if;

  for i in 1..100 loop
    exit when ev.phase = 'finished';
    exit when ev.phase = 'lobby' and (ev.starts_at is null or clock_timestamp() < ev.starts_at);
    exit when ev.phase <> 'lobby' and (ev.phase_until is null or clock_timestamp() < ev.phase_until);

    boundary := case when ev.phase = 'lobby' then ev.starts_at else ev.phase_until end;

    if ev.phase = 'lobby' then
      update asgq_rehearsal_private.event set phase='intro', phase_started_at=boundary,
        phase_until=boundary + make_interval(secs=>ev.intro_seconds) where id=1;
    elsif ev.phase = 'intro' then
      select * into question_row from asgq_rehearsal_private.questions order by position limit 1;
      if not found then raise exception 'Aucune question configurée.'; end if;
      update asgq_rehearsal_private.event set phase='question', current_position=question_row.position,
        phase_started_at=boundary, phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
    elsif ev.phase = 'question' then
      select * into question_row from asgq_rehearsal_private.questions where position=ev.current_position;
      -- Snapshot / idempotence: only the question -> reveal transition awards points.
      update asgq_rehearsal_private.answers a
        set points_awarded = case when a.choice = question_row.correct_index then question_row.points else 0 end
      where a.question_id = question_row.id;
      update asgq_rehearsal_private.players p set score = p.score + t.earned
      from (select player_id, sum(points_awarded)::integer as earned
            from asgq_rehearsal_private.answers where question_id=question_row.id
            group by player_id) t
      where p.id=t.player_id;
      update asgq_rehearsal_private.event set phase='reveal',phase_started_at=boundary,
        phase_until=boundary + make_interval(secs=>ev.reveal_seconds) where id=1;
    elsif ev.phase = 'reveal' then
      select * into question_row from asgq_rehearsal_private.questions where position=ev.current_position;
      select * into next_row from asgq_rehearsal_private.questions where position>ev.current_position order by position limit 1;
      if not found then
        update asgq_rehearsal_private.event set phase='finished', phase_started_at=boundary,
          phase_until=null where id=1;
      elsif question_row.half=1 and next_row.half=2 then
        update asgq_rehearsal_private.event set phase='halftime',phase_started_at=boundary,
          phase_until=boundary + make_interval(secs=>ev.halftime_seconds) where id=1;
      else
        update asgq_rehearsal_private.event set phase='question', current_position=next_row.position,
          phase_started_at=boundary,phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
      end if;
    elsif ev.phase = 'halftime' then
      select * into next_row from asgq_rehearsal_private.questions where half=2 order by position limit 1;
      if not found then raise exception 'La seconde mi-temps est vide.'; end if;
      update asgq_rehearsal_private.event set phase='question', current_position=next_row.position,
        phase_started_at=boundary,phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
    end if;

    select * into ev from asgq_rehearsal_private.event where id=1;
  end loop;
end $fn$;

-- Entry is secret-code gated. Reconnection always uses the original token.
create or replace function public.asgq_rehearsal_join(p_code text, p_name text, p_token uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  player_row asgq_rehearsal_private.players%rowtype;
  clean_name text;
  generated_token uuid;
  normalized_code text;
begin
  select * into ev from asgq_rehearsal_private.event where id=1 for update;
  if not found then raise exception 'Événement indisponible.'; end if;

  if p_token is not null then
    player_row := asgq_rehearsal_private.player_for(p_token);
    if player_row.id is null then raise exception 'Session inconnue.'; end if;
    update asgq_rehearsal_private.players set last_seen_at=clock_timestamp() where id=player_row.id;
    perform asgq_rehearsal_private.tick();
    return jsonb_build_object('token',p_token,'name',player_row.name);
  end if;

  normalized_code := upper(regexp_replace(coalesce(p_code,''), '[^A-Za-z0-9]', '', 'g'));
  if encode(extensions.digest('asgq:' || normalized_code, 'sha256'),'hex') <> ev.code_hash then
    raise exception 'Code d’entrée incorrect.';
  end if;
  if ev.phase <> 'lobby' or (ev.starts_at is not null and clock_timestamp() >= ev.starts_at) then
    raise exception 'Le quiz a déjà commencé.';
  end if;
  if (select count(*) from asgq_rehearsal_private.players)>=ev.max_players then raise exception 'Le vestiaire est complet.'; end if;
  clean_name := btrim(regexp_replace(coalesce(p_name,''),'\s+',' ','g'));
  if char_length(clean_name) < 2 or char_length(clean_name) > 22 then raise exception 'Prénom : entre 2 et 22 caractères.'; end if;
  if exists(select 1 from asgq_rehearsal_private.players where lower(name)=lower(clean_name)) then
    raise exception 'Ce prénom est déjà pris dans le vestiaire.';
  end if;
  generated_token := gen_random_uuid();
  insert into asgq_rehearsal_private.players(event_id,name,token_hash)
    values (1,clean_name,encode(extensions.digest('asgq-token:' || generated_token::text,'sha256'),'hex'));
  perform asgq_rehearsal_private.tick();
  return jsonb_build_object('token', generated_token, 'name', clean_name);
end $fn$;

create or replace function public.asgq_rehearsal_state(p_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  player_row asgq_rehearsal_private.players%rowtype;
  ev asgq_rehearsal_private.event%rowtype;
  q asgq_rehearsal_private.questions%rowtype;
  my_answer asgq_rehearsal_private.answers%rowtype;
  show_result boolean;
  n integer;
  first_half integer;
  second_half integer;
  ordinal integer;
  people jsonb;
  ranking jsonb;
begin
  player_row := asgq_rehearsal_private.player_for(p_token);
  if player_row.id is null then raise exception 'Session expirée. Rejoins la partie.'; end if;
  perform asgq_rehearsal_private.tick();
  select * into ev from asgq_rehearsal_private.event where id=1;
  select count(*) into n from asgq_rehearsal_private.questions;
  select count(*) into first_half from asgq_rehearsal_private.questions where half=1;
  select count(*) into second_half from asgq_rehearsal_private.questions where half=2;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.joined_at), '[]'::jsonb)
    into people from asgq_rehearsal_private.players p;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'score',p.score) order by p.score desc,p.joined_at), '[]'::jsonb)
    into ranking from asgq_rehearsal_private.players p;
  select * into q from asgq_rehearsal_private.questions where position=ev.current_position;
  if q.id is not null then
    select * into my_answer from asgq_rehearsal_private.answers
    where question_id=q.id and player_id=player_row.id;
  end if;
  select count(*) into ordinal from asgq_rehearsal_private.questions where position <= ev.current_position;
  show_result := ev.phase='reveal';
  return jsonb_build_object(
    'phase', ev.phase, 'title', ev.title, 'now',clock_timestamp(),
    'starts_at',ev.starts_at,'phase_started_at',ev.phase_started_at,'phase_until',ev.phase_until,
    'position',ordinal, 'total',n, 'first_half_count',first_half, 'second_half_count',second_half,
    'half',case when ev.phase='halftime' then 2 when q.id is not null then q.half else 1 end,
    'players',people, 'standings',case when ev.phase in ('reveal','halftime','finished') then ranking else null end,
    'me',jsonb_build_object('id',player_row.id,'name',player_row.name,
      'score',(select score from asgq_rehearsal_private.players where id=player_row.id)),
    'question', case when ev.phase in ('question','reveal') and q.id is not null then
      jsonb_build_object('text',q.prompt,'choices',q.choices,'points',q.points,
        'correct',case when show_result then q.correct_index else null end,
        'explanation',case when show_result then q.explanation else null end,
        'my_choice',my_answer.choice,'earned',case when show_result then my_answer.points_awarded else null end,
        'answered_count',(select count(*) from asgq_rehearsal_private.answers where question_id=q.id))
      else null end
  );
end $fn$;

create or replace function public.asgq_rehearsal_answer(p_token uuid, p_choice integer)
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  player_row asgq_rehearsal_private.players%rowtype;
  ev asgq_rehearsal_private.event%rowtype;
  q asgq_rehearsal_private.questions%rowtype;
begin
  player_row := asgq_rehearsal_private.player_for(p_token);
  if player_row.id is null then raise exception 'Session expirée.'; end if;
  perform asgq_rehearsal_private.tick();
  select * into ev from asgq_rehearsal_private.event where id=1 for update;
  if ev.phase <> 'question' or clock_timestamp() >= ev.phase_until then
    raise exception 'Le temps de réponse est terminé.';
  end if;
  select * into q from asgq_rehearsal_private.questions where position=ev.current_position;
  if p_choice is null or p_choice<0 or p_choice>=cardinality(q.choices) then raise exception 'Réponse invalide.'; end if;
  insert into asgq_rehearsal_private.answers(player_id,question_id,choice,answered_at)
    values (player_row.id,q.id,p_choice,clock_timestamp())
  on conflict (player_id,question_id) do update set choice=excluded.choice,answered_at=excluded.answered_at;
end $fn$;

revoke all on all functions in schema asgq_rehearsal_private from public, anon, authenticated;
revoke execute on function public.asgq_rehearsal_join(text,text,uuid) from public, anon, authenticated;
revoke execute on function public.asgq_rehearsal_state(uuid) from public, anon, authenticated;
revoke execute on function public.asgq_rehearsal_answer(uuid,integer) from public, anon, authenticated;
grant execute on function public.asgq_rehearsal_join(text,text,uuid) to anon, authenticated;
grant execute on function public.asgq_rehearsal_state(uuid) to anon, authenticated;
grant execute on function public.asgq_rehearsal_answer(uuid,integer) to anon, authenticated;

-- Follow-up: reject any new player after the scheduled kickoff, even if all phones were offline.
create or replace function public.asgq_rehearsal_join(p_code text, p_name text, p_token uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  player_row asgq_rehearsal_private.players%rowtype;
  clean_name text;
  generated_token uuid;
  normalized_code text;
begin
  select * into ev from asgq_rehearsal_private.event where id=1 for update;
  if not found then raise exception 'Événement indisponible.'; end if;

  if p_token is not null then
    player_row := asgq_rehearsal_private.player_for(p_token);
    if player_row.id is null then raise exception 'Session inconnue.'; end if;
    update asgq_rehearsal_private.players set last_seen_at=clock_timestamp() where id=player_row.id;
    perform asgq_rehearsal_private.tick();
    return jsonb_build_object('token',p_token,'name',player_row.name);
  end if;

  normalized_code := upper(regexp_replace(coalesce(p_code,''), '[^A-Za-z0-9]', '', 'g'));
  if encode(extensions.digest('asgq:' || normalized_code, 'sha256'),'hex') <> ev.code_hash then
    raise exception 'Code d’entrée incorrect.';
  end if;
  if ev.phase <> 'lobby' or (ev.starts_at is not null and clock_timestamp() >= ev.starts_at) then
    raise exception 'Le quiz a déjà commencé.';
  end if;
  if (select count(*) from asgq_rehearsal_private.players)>=ev.max_players then raise exception 'Le vestiaire est complet.'; end if;
  clean_name := btrim(regexp_replace(coalesce(p_name,''),'\s+',' ','g'));
  if char_length(clean_name) < 2 or char_length(clean_name) > 22 then raise exception 'Prénom : entre 2 et 22 caractères.'; end if;
  if exists(select 1 from asgq_rehearsal_private.players where lower(name)=lower(clean_name)) then
    raise exception 'Ce prénom est déjà pris dans le vestiaire.';
  end if;
  generated_token := gen_random_uuid();
  insert into asgq_rehearsal_private.players(event_id,name,token_hash)
    values (1,clean_name,encode(extensions.digest('asgq-token:' || generated_token::text,'sha256'),'hex'));
  perform asgq_rehearsal_private.tick();
  return jsonb_build_object('token', generated_token, 'name', clean_name);
end $fn$;

-- Grand Quiz AS Grinta: only arm a complete 10-20 + 10-20 question event.
-- Safety gate: the 4 technical placeholders can never launch a real game.
-- The event is armed once during preparation, never controlled during the quiz.
alter table asgq_rehearsal_private.event
  add column if not exists armed boolean not null default false;

create or replace function asgq_rehearsal_private.ready_for_kickoff()
returns boolean language sql stable security definer set search_path = '' as $fn$
  with validation as (
    select
      count(*) as total,
      count(*) filter(where half=1) as first_half,
      count(*) filter(where half=2) as second_half,
      min(position) as first_position,
      max(position) as last_position,
      max(position) filter(where half=1) as last_first_half_position,
      min(position) filter(where half=2) as first_second_half_position,
      count(*) filter(
        where lower(prompt) like '%question de test%'
           or lower(array_to_string(choices,' ')) like '%(test)%'
      ) as placeholders
    from asgq_rehearsal_private.questions
  )
  select first_half between 10 and 20
     and second_half between 10 and 20
     and first_position = 1
     and last_position = total
     and last_first_half_position = first_half
     and first_second_half_position = first_half + 1
     and placeholders = 0
  from validation;
$fn$;

create or replace function asgq_rehearsal_private.tick()
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  question_row asgq_rehearsal_private.questions%rowtype;
  next_row asgq_rehearsal_private.questions%rowtype;
  player_total integer;
  boundary timestamptz;
begin
  select * into ev from asgq_rehearsal_private.event where id = 1 for update;
  if not found then raise exception 'Événement non configuré.'; end if;

  -- Disarm/correct the event without a countdown accidentally surviving.
  if ev.phase = 'lobby' and ev.starts_at is not null
     and (not ev.armed or not asgq_rehearsal_private.ready_for_kickoff()) then
    update asgq_rehearsal_private.event set starts_at=null, phase_started_at=null where id=1;
    select * into ev from asgq_rehearsal_private.event where id=1;
  end if;

  if ev.phase = 'lobby' and ev.starts_at is null then
    select count(*) into player_total from asgq_rehearsal_private.players;
    if player_total >= ev.min_players and ev.armed and asgq_rehearsal_private.ready_for_kickoff() then
      update asgq_rehearsal_private.event
        set phase_started_at = clock_timestamp(),
            starts_at = clock_timestamp() + make_interval(secs => ev.lobby_seconds)
      where id = ev.id;
      select * into ev from asgq_rehearsal_private.event where id = 1;
    end if;
  end if;

  for i in 1..100 loop
    exit when ev.phase = 'finished';
    exit when ev.phase = 'lobby' and (ev.starts_at is null or clock_timestamp() < ev.starts_at);
    exit when ev.phase <> 'lobby' and (ev.phase_until is null or clock_timestamp() < ev.phase_until);

    boundary := case when ev.phase = 'lobby' then ev.starts_at else ev.phase_until end;

    if ev.phase = 'lobby' then
      update asgq_rehearsal_private.event set phase='intro', phase_started_at=boundary,
        phase_until=boundary + make_interval(secs=>ev.intro_seconds) where id=1;
    elsif ev.phase = 'intro' then
      select * into question_row from asgq_rehearsal_private.questions order by position limit 1;
      if not found then raise exception 'Aucune question configurée.'; end if;
      update asgq_rehearsal_private.event set phase='question', current_position=question_row.position,
        phase_started_at=boundary, phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
    elsif ev.phase = 'question' then
      select * into question_row from asgq_rehearsal_private.questions where position=ev.current_position;
      -- Snapshot / idempotence: only the question -> reveal transition awards points.
      update asgq_rehearsal_private.answers a
        set points_awarded = case when a.choice = question_row.correct_index then question_row.points else 0 end
      where a.question_id = question_row.id;
      update asgq_rehearsal_private.players p set score = p.score + t.earned
      from (select player_id, sum(points_awarded)::integer as earned
            from asgq_rehearsal_private.answers where question_id=question_row.id
            group by player_id) t
      where p.id=t.player_id;
      update asgq_rehearsal_private.event set phase='reveal',phase_started_at=boundary,
        phase_until=boundary + make_interval(secs=>ev.reveal_seconds) where id=1;
    elsif ev.phase = 'reveal' then
      select * into question_row from asgq_rehearsal_private.questions where position=ev.current_position;
      select * into next_row from asgq_rehearsal_private.questions where position>ev.current_position order by position limit 1;
      if not found then
        update asgq_rehearsal_private.event set phase='finished', phase_started_at=boundary,
          phase_until=null where id=1;
      elsif question_row.half=1 and next_row.half=2 then
        update asgq_rehearsal_private.event set phase='halftime',phase_started_at=boundary,
          phase_until=boundary + make_interval(secs=>ev.halftime_seconds) where id=1;
      else
        update asgq_rehearsal_private.event set phase='question', current_position=next_row.position,
          phase_started_at=boundary,phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
      end if;
    elsif ev.phase = 'halftime' then
      select * into next_row from asgq_rehearsal_private.questions where half=2 order by position limit 1;
      if not found then raise exception 'La seconde mi-temps est vide.'; end if;
      update asgq_rehearsal_private.event set phase='question', current_position=next_row.position,
        phase_started_at=boundary,phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
    end if;

    select * into ev from asgq_rehearsal_private.event where id=1;
  end loop;
end $fn$;

create or replace function public.asgq_rehearsal_state(p_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  player_row asgq_rehearsal_private.players%rowtype;
  ev asgq_rehearsal_private.event%rowtype;
  q asgq_rehearsal_private.questions%rowtype;
  my_answer asgq_rehearsal_private.answers%rowtype;
  show_result boolean;
  n integer;
  first_half integer;
  second_half integer;
  ordinal integer;
  people jsonb;
  ranking jsonb;
begin
  player_row := asgq_rehearsal_private.player_for(p_token);
  if player_row.id is null then raise exception 'Session expirée. Rejoins la partie.'; end if;
  perform asgq_rehearsal_private.tick();
  select * into ev from asgq_rehearsal_private.event where id=1;
  select count(*) into n from asgq_rehearsal_private.questions;
  select count(*) into first_half from asgq_rehearsal_private.questions where half=1;
  select count(*) into second_half from asgq_rehearsal_private.questions where half=2;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.joined_at), '[]'::jsonb)
    into people from asgq_rehearsal_private.players p;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'score',p.score) order by p.score desc,p.joined_at), '[]'::jsonb)
    into ranking from asgq_rehearsal_private.players p;
  select * into q from asgq_rehearsal_private.questions where position=ev.current_position;
  if q.id is not null then
    select * into my_answer from asgq_rehearsal_private.answers
    where question_id=q.id and player_id=player_row.id;
  end if;
  select count(*) into ordinal from asgq_rehearsal_private.questions where position <= ev.current_position;
  show_result := ev.phase='reveal';
  return jsonb_build_object(
    'phase', ev.phase, 'ready', (ev.armed and asgq_rehearsal_private.ready_for_kickoff()), 'title', ev.title, 'now',clock_timestamp(),
    'starts_at',ev.starts_at,'phase_started_at',ev.phase_started_at,'phase_until',ev.phase_until,
    'position',ordinal, 'total',n, 'first_half_count',first_half, 'second_half_count',second_half,
    'half',case when ev.phase='halftime' then 2 when q.id is not null then q.half else 1 end,
    'players',people, 'standings',case when ev.phase in ('reveal','halftime','finished') then ranking else null end,
    'me',jsonb_build_object('id',player_row.id,'name',player_row.name,
      'score',(select score from asgq_rehearsal_private.players where id=player_row.id)),
    'question', case when ev.phase in ('question','reveal') and q.id is not null then
      jsonb_build_object('text',q.prompt,'choices',q.choices,'points',q.points,
        'correct',case when show_result then q.correct_index else null end,
        'explanation',case when show_result then q.explanation else null end,
        'my_choice',my_answer.choice,'earned',case when show_result then my_answer.points_awarded else null end,
        'answered_count',(select count(*) from asgq_rehearsal_private.answers where question_id=q.id))
      else null end
  );
end $fn$;

-- No direct client access to the private data or internal checks.
revoke all on all functions in schema asgq_rehearsal_private from public, anon, authenticated;


-- AS Grinta : le QCM du Soulieteur mène à un événement unique.
-- Utilise exactement le vérificateur Admin+ existant, sans copier le secret
-- dans le navigateur et sans donner accès au catalogue de quiz.
-- Le code d'invitation de l'ancienne entrée cesse d'être exposé en RPC publique.
create or replace function public.asgq_rehearsal_join_admin_plus(p_password text, p_name text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  invitation_code text;
begin
  -- Le contrôle de mot de passe est effectué côté serveur, avec l'anti-bruteforce Admin+.
  if not public._is_admin_plus(p_password) then
    raise exception 'Mot de passe Admin+ incorrect.';
  end if;
  -- Le secret technique n'est jamais renvoyé au téléphone.
  select plaintext_code into invitation_code from asgq_rehearsal_private.invitation where event_id = 1;
  if invitation_code is null then
    raise exception 'Événement AS Grinta indisponible.';
  end if;
  return public.asgq_rehearsal_join(invitation_code, p_name, null);
end
$fn$;

revoke execute on function public.asgq_rehearsal_join_admin_plus(text,text) from public, anon, authenticated;
grant execute on function public.asgq_rehearsal_join_admin_plus(text,text) to anon, authenticated;

-- L'ancienne porte d'entrée par code technique n'est plus publique.
-- La reprise de session se fait via asgq_rehearsal_state(token) comme avant.
revoke execute on function public.asgq_rehearsal_join(text,text,uuid) from public, anon, authenticated;


-- Grand Quiz AS Grinta 2026: create once with Admin+, join with a normal 8-digit room code.
-- The event's two halves remain server-side, no question bank and no host control panel.

alter table asgq_rehearsal_private.event
  add column if not exists created boolean not null default false;
alter table asgq_rehearsal_private.event
  add column if not exists room_code text;
alter table asgq_rehearsal_private.event
  add constraint asgq_rehearsal_room_code_8_digits check (room_code is null or room_code ~ '^[0-9]{8}$');

-- Cryptographically random 8 digit room code (same representation as the other games).
create or replace function asgq_rehearsal_private.new_room_code()
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
create or replace function public.asgq_rehearsal_create(p_password text, p_name text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  private_code text;
  public_code text;
  joined jsonb;
begin
  if not public._is_admin_plus(p_password) then
    raise exception 'Mot de passe Admin+ incorrect.';
  end if;
  select * into ev from asgq_rehearsal_private.event where id=1 for update;
  if ev.id is null then raise exception 'Événement indisponible.'; end if;
  if ev.created or ev.phase <> 'lobby' then
    raise exception 'La partie AS Grinta existe déjà : rejoins-la avec son code.';
  end if;
  public_code := asgq_rehearsal_private.new_room_code();
  select plaintext_code into private_code from asgq_rehearsal_private.invitation where event_id=1;
  if private_code is null then raise exception 'Événement non configuré.'; end if;
  update asgq_rehearsal_private.event set created=true, room_code=public_code where id=1;
  joined := public.asgq_rehearsal_join(private_code, p_name, null);
  return joined || pg_catalog.jsonb_build_object('code',public_code);
end $fn$;

-- Guessing attempts use the same per-client hashing as normal Soulieteur rooms.
create table if not exists asgq_rehearsal_private.join_attempts(
  client_hash text primary key,
  window_started_at timestamptz not null default now(),
  attempts integer not null default 0
);
alter table asgq_rehearsal_private.join_attempts enable row level security;
revoke all on asgq_rehearsal_private.join_attempts from public, anon, authenticated;

create or replace function public.asgq_rehearsal_join_room(p_code text, p_name text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
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
    insert into asgq_rehearsal_private.join_attempts(client_hash,window_started_at,attempts)
      values(client_hash,clock_timestamp(),1)
      on conflict (client_hash) do update
        set attempts=case when asgq_rehearsal_private.join_attempts.window_started_at < clock_timestamp() - interval '10 minutes'
                          then 1 else asgq_rehearsal_private.join_attempts.attempts+1 end,
            window_started_at=case when asgq_rehearsal_private.join_attempts.window_started_at < clock_timestamp() - interval '10 minutes'
                          then clock_timestamp() else asgq_rehearsal_private.join_attempts.window_started_at end
      returning attempts into attempt_count;
    if attempt_count > 10 then
      return pg_catalog.jsonb_build_object('error','Trop de tentatives. Réessaie dans quelques minutes.');
    end if;
  end if;
  select * into ev from asgq_rehearsal_private.event where id=1;
  if ev.id is null or not ev.created then
    return pg_catalog.jsonb_build_object('error','La partie AS Grinta n’a pas encore été créée.');
  end if;
  if length(normalized_code) <> 8 or normalized_code <> ev.room_code then
    return pg_catalog.jsonb_build_object('error','Code de partie incorrect.');
  end if;
  select plaintext_code into private_code from asgq_rehearsal_private.invitation where event_id=1;
  if private_code is null then raise exception 'Événement non configuré.'; end if;
  joined := public.asgq_rehearsal_join(private_code,p_name,null);
  return joined || pg_catalog.jsonb_build_object('code',ev.room_code);
end $fn$;

create or replace function asgq_rehearsal_private.tick()
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  question_row asgq_rehearsal_private.questions%rowtype;
  next_row asgq_rehearsal_private.questions%rowtype;
  player_total integer;
  boundary timestamptz;
begin
  select * into ev from asgq_rehearsal_private.event where id = 1 for update;
  if not found then raise exception 'Événement non configuré.'; end if;

  -- Disarm/correct the event without a countdown accidentally surviving.
  if ev.phase = 'lobby' and ev.starts_at is not null
     and (not ev.armed or not asgq_rehearsal_private.ready_for_kickoff()) then
    update asgq_rehearsal_private.event set starts_at=null, phase_started_at=null where id=1;
    select * into ev from asgq_rehearsal_private.event where id=1;
  end if;

  if ev.phase = 'lobby' and ev.starts_at is null then
    select count(*) into player_total from asgq_rehearsal_private.players;
    if player_total >= ev.min_players and ev.created and ev.armed and asgq_rehearsal_private.ready_for_kickoff() then
      update asgq_rehearsal_private.event
        set phase_started_at = clock_timestamp(),
            starts_at = clock_timestamp() + make_interval(secs => ev.lobby_seconds)
      where id = ev.id;
      select * into ev from asgq_rehearsal_private.event where id = 1;
    end if;
  end if;

  for i in 1..100 loop
    exit when ev.phase = 'finished';
    exit when ev.phase = 'lobby' and (ev.starts_at is null or clock_timestamp() < ev.starts_at);
    exit when ev.phase <> 'lobby' and (ev.phase_until is null or clock_timestamp() < ev.phase_until);

    boundary := case when ev.phase = 'lobby' then ev.starts_at else ev.phase_until end;

    if ev.phase = 'lobby' then
      update asgq_rehearsal_private.event set phase='intro', phase_started_at=boundary,
        phase_until=boundary + make_interval(secs=>ev.intro_seconds) where id=1;
    elsif ev.phase = 'intro' then
      select * into question_row from asgq_rehearsal_private.questions order by position limit 1;
      if not found then raise exception 'Aucune question configurée.'; end if;
      update asgq_rehearsal_private.event set phase='question', current_position=question_row.position,
        phase_started_at=boundary, phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
    elsif ev.phase = 'question' then
      select * into question_row from asgq_rehearsal_private.questions where position=ev.current_position;
      -- Snapshot / idempotence: only the question -> reveal transition awards points.
      update asgq_rehearsal_private.answers a
        set points_awarded = case when a.choice = question_row.correct_index then question_row.points else 0 end
      where a.question_id = question_row.id;
      update asgq_rehearsal_private.players p set score = p.score + t.earned
      from (select player_id, sum(points_awarded)::integer as earned
            from asgq_rehearsal_private.answers where question_id=question_row.id
            group by player_id) t
      where p.id=t.player_id;
      update asgq_rehearsal_private.event set phase='reveal',phase_started_at=boundary,
        phase_until=boundary + make_interval(secs=>ev.reveal_seconds) where id=1;
    elsif ev.phase = 'reveal' then
      select * into question_row from asgq_rehearsal_private.questions where position=ev.current_position;
      select * into next_row from asgq_rehearsal_private.questions where position>ev.current_position order by position limit 1;
      if not found then
        update asgq_rehearsal_private.event set phase='finished', phase_started_at=boundary,
          phase_until=null where id=1;
      elsif question_row.half=1 and next_row.half=2 then
        update asgq_rehearsal_private.event set phase='halftime',phase_started_at=boundary,
          phase_until=boundary + make_interval(secs=>ev.halftime_seconds) where id=1;
      else
        update asgq_rehearsal_private.event set phase='question', current_position=next_row.position,
          phase_started_at=boundary,phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
      end if;
    elsif ev.phase = 'halftime' then
      select * into next_row from asgq_rehearsal_private.questions where half=2 order by position limit 1;
      if not found then raise exception 'La seconde mi-temps est vide.'; end if;
      update asgq_rehearsal_private.event set phase='question', current_position=next_row.position,
        phase_started_at=boundary,phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
    end if;

    select * into ev from asgq_rehearsal_private.event where id=1;
  end loop;
end $fn$;

create or replace function public.asgq_rehearsal_state(p_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  player_row asgq_rehearsal_private.players%rowtype;
  ev asgq_rehearsal_private.event%rowtype;
  q asgq_rehearsal_private.questions%rowtype;
  my_answer asgq_rehearsal_private.answers%rowtype;
  show_result boolean;
  n integer;
  first_half integer;
  second_half integer;
  ordinal integer;
  people jsonb;
  ranking jsonb;
begin
  player_row := asgq_rehearsal_private.player_for(p_token);
  if player_row.id is null then raise exception 'Session expirée. Rejoins la partie.'; end if;
  perform asgq_rehearsal_private.tick();
  select * into ev from asgq_rehearsal_private.event where id=1;
  select count(*) into n from asgq_rehearsal_private.questions;
  select count(*) into first_half from asgq_rehearsal_private.questions where half=1;
  select count(*) into second_half from asgq_rehearsal_private.questions where half=2;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.joined_at), '[]'::jsonb)
    into people from asgq_rehearsal_private.players p;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'score',p.score) order by p.score desc,p.joined_at), '[]'::jsonb)
    into ranking from asgq_rehearsal_private.players p;
  select * into q from asgq_rehearsal_private.questions where position=ev.current_position;
  if q.id is not null then
    select * into my_answer from asgq_rehearsal_private.answers
    where question_id=q.id and player_id=player_row.id;
  end if;
  select count(*) into ordinal from asgq_rehearsal_private.questions where position <= ev.current_position;
  show_result := ev.phase='reveal';
  return jsonb_build_object(
    'phase', ev.phase, 'ready', (ev.armed and asgq_rehearsal_private.ready_for_kickoff()), 'room_code', ev.room_code, 'title', ev.title, 'now',clock_timestamp(),
    'starts_at',ev.starts_at,'phase_started_at',ev.phase_started_at,'phase_until',ev.phase_until,
    'position',ordinal, 'total',n, 'first_half_count',first_half, 'second_half_count',second_half,
    'half',case when ev.phase='halftime' then 2 when q.id is not null then q.half else 1 end,
    'players',people, 'standings',case when ev.phase in ('reveal','halftime','finished') then ranking else null end,
    'me',jsonb_build_object('id',player_row.id,'name',player_row.name,
      'score',(select score from asgq_rehearsal_private.players where id=player_row.id)),
    'question', case when ev.phase in ('question','reveal') and q.id is not null then
      jsonb_build_object('text',q.prompt,'choices',q.choices,'points',q.points,
        'correct',case when show_result then q.correct_index else null end,
        'explanation',case when show_result then q.explanation else null end,
        'my_choice',my_answer.choice,'earned',case when show_result then my_answer.points_awarded else null end,
        'answered_count',(select count(*) from asgq_rehearsal_private.answers where question_id=q.id))
      else null end
  );
end $fn$;

-- Deactivate the previous Admin+ *joining* shortcut and the technical invitation RPC.
revoke execute on function public.asgq_rehearsal_join_admin_plus(text,text) from public, anon, authenticated;
revoke execute on function public.asgq_rehearsal_join(text,text,uuid) from public, anon, authenticated;
revoke execute on function public.asgq_rehearsal_create(text,text) from public, anon, authenticated;
revoke execute on function public.asgq_rehearsal_join_room(text,text) from public, anon, authenticated;
grant execute on function public.asgq_rehearsal_create(text,text) to anon, authenticated;
grant execute on function public.asgq_rehearsal_join_room(text,text) to anon, authenticated;
revoke all on all functions in schema asgq_rehearsal_private from public, anon, authenticated;


-- Corrective follow-up: join attempts are shared by multiple players on the same Wi-Fi.
-- Match the existing Soulieteur thresholds: 48 requests or 8 failures / 10 minutes.
-- Also avoid ambiguous PL/pgSQL variable / column names in ON CONFLICT.
alter table asgq_rehearsal_private.join_attempts
  add column if not exists failures integer not null default 0;

create or replace function public.asgq_rehearsal_join_room(p_code text, p_name text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  normalized_code text;
  private_code text;
  v_client_hash text;
  v_requests integer;
  v_failures integer;
  joined jsonb;
begin
  normalized_code := regexp_replace(coalesce(p_code,''),'[^0-9]','','g');
  v_client_hash := public._client_hash();
  if v_client_hash is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('asgq-join:'||v_client_hash,0));
    insert into asgq_rehearsal_private.join_attempts(client_hash,window_started_at,attempts,failures)
      values(v_client_hash,clock_timestamp(),1,0)
      on conflict on constraint join_attempts_pkey do update
        set attempts=case when asgq_rehearsal_private.join_attempts.window_started_at < clock_timestamp() - interval '10 minutes'
                          then 1 else asgq_rehearsal_private.join_attempts.attempts+1 end,
            failures=case when asgq_rehearsal_private.join_attempts.window_started_at < clock_timestamp() - interval '10 minutes'
                          then 0 else asgq_rehearsal_private.join_attempts.failures end,
            window_started_at=case when asgq_rehearsal_private.join_attempts.window_started_at < clock_timestamp() - interval '10 minutes'
                          then clock_timestamp() else asgq_rehearsal_private.join_attempts.window_started_at end
      returning attempts, failures into v_requests,v_failures;
    if v_requests>48 or v_failures>=8 then
      return pg_catalog.jsonb_build_object('error','Trop de tentatives. Réessaie dans quelques minutes.');
    end if;
  end if;

  select * into ev from asgq_rehearsal_private.event where id=1;
  if ev.id is null or not ev.created then
    return pg_catalog.jsonb_build_object('error','La partie AS Grinta n’a pas encore été créée.');
  end if;
  if length(normalized_code)<>8 or normalized_code <> ev.room_code then
    if v_client_hash is not null then
      update asgq_rehearsal_private.join_attempts set failures=failures+1
      where join_attempts.client_hash=v_client_hash;
    end if;
    perform pg_catalog.pg_sleep(0.15);
    return pg_catalog.jsonb_build_object('error','Code de partie incorrect.');
  end if;
  select plaintext_code into private_code from asgq_rehearsal_private.invitation where event_id=1;
  if private_code is null then raise exception 'Événement non configuré.'; end if;
  joined := public.asgq_rehearsal_join(private_code,p_name,null);
  return joined || pg_catalog.jsonb_build_object('code',ev.room_code);
end $fn$;

revoke execute on function public.asgq_rehearsal_join_room(text,text) from public, anon, authenticated;
grant execute on function public.asgq_rehearsal_join_room(text,text) to anon, authenticated;


-- Only the rehearsal data is reset; the production event and questions remain intact.
alter table asgq_rehearsal_private.players add column if not exists bot_order integer;
alter table asgq_rehearsal_private.players
  add constraint asgq_rehearsal_bot_order_check check (bot_order is null or bot_order between 1 and 20);

-- 20 representative but NOT final questions: exercise the actual 2x10 server game.
-- The main quiz's question table is never read or changed by rehearsal RPCs.
delete from asgq_rehearsal_private.questions;
insert into asgq_rehearsal_private.questions(position,half,prompt,choices,correct_index,points,explanation)
values
(1,1,'Quel club organise cette soirée quiz ?',ARRAY['AS Grinta','FC Barcelone','Manchester City','Real Madrid']::text[],0,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(2,1,'Quel appareil est utilisé pour répondre ?',ARRAY['Une console','Un téléphone','Un boîtier','Une télécommande']::text[],1,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(3,1,'Combien de mi-temps comprend notre quiz ?',ARRAY['Une','Trois','Deux','Quatre']::text[],2,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(4,1,'Quelle couleur caractérise notre interface ?',ARRAY['Rouge et vert','Bleu nuit et or','Rose','Orange']::text[],1,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(5,1,'Quel jeu accueille cette compétition ?',ARRAY['Petit Bac','Mimes','Le Soulieteur','Dilemme']::text[],2,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(6,1,'Quand les scores sont-ils comptabilisés ?',ARRAY['Après chaque question','Avant de répondre','Au hasard','Jamais']::text[],0,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(7,1,'Qu''est-ce qui fait gagner un point ?',ARRAY['Une mauvaise réponse','Une bonne réponse','Ne pas répondre','Fermer l''application']::text[],1,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(8,1,'Que fait le chronomètre d''une question ?',ARRAY['Il s''arrête au hasard','Il accélère','Il limite le temps de réponse','Il choisit un vainqueur']::text[],2,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(9,1,'Quel écran apparaît entre les deux séries ?',ARRAY['Le podium','La pause de mi-temps','Une publicité','Le formulaire d''inscription']::text[],1,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(10,1,'Quel élément apparaît à la fin du quiz ?',ARRAY['Un autre quiz','Un tirage au sort','Un classement final','Un nouveau salon']::text[],2,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(11,2,'Combien de joueurs une équipe aligne-t-elle au coup d''envoi ?',ARRAY['9','10','11','12']::text[],2,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(12,2,'Quel carton expulse directement un joueur ?',ARRAY['Vert','Rouge','Jaune','Bleu']::text[],1,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(13,2,'Combien de minutes dure une mi-temps réglementaire ?',ARRAY['30','40','45','50']::text[],2,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(14,2,'Quel joueur peut utiliser ses mains dans sa propre surface ?',ARRAY['L''attaquant','Le défenseur','Le gardien','Le capitaine']::text[],2,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(15,2,'Que signifie VAR ?',ARRAY['Assistance vidéo à l''arbitrage','Vitesse après reprise','Victoire avant règlement','Vidéo à répétition']::text[],0,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(16,2,'Quel est le nom de la compétition mondiale des sélections ?',ARRAY['Ligue 1','Coupe du Monde','Coupe de France','Ligue Europa']::text[],1,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(17,2,'Quel événement donne un penalty ?',ARRAY['Une touche','Une faute défensive dans la surface','Un corner','Un remplacement']::text[],1,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(18,2,'Combien de points vaut habituellement une victoire en championnat ?',ARRAY['1','2','3','4']::text[],2,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(19,2,'Où tire-t-on un corner ?',ARRAY['Au centre','Sur la ligne médiane','Dans l''arc de coin','Sur le point de penalty']::text[],2,1,'Question de répétition : les vraies questions de la soirée restent protégées.'),
(20,2,'Quel joueur porte souvent le brassard d''équipe ?',ARRAY['Le capitaine','L''arbitre','Le soigneur','Un spectateur']::text[],0,1,'Question de répétition : les vraies questions de la soirée restent protégées.');

create or replace function asgq_rehearsal_private.tick()
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  question_row asgq_rehearsal_private.questions%rowtype;
  next_row asgq_rehearsal_private.questions%rowtype;
  player_total integer;
  boundary timestamptz;
begin
  select * into ev from asgq_rehearsal_private.event where id = 1 for update;
  if not found then raise exception 'Événement non configuré.'; end if;

  -- Disarm/correct the event without a countdown accidentally surviving.
  if ev.phase = 'lobby' and ev.starts_at is not null
     and (not ev.armed or not asgq_rehearsal_private.ready_for_kickoff()) then
    update asgq_rehearsal_private.event set starts_at=null, phase_started_at=null where id=1;
    select * into ev from asgq_rehearsal_private.event where id=1;
  end if;

  if ev.phase = 'lobby' and ev.starts_at is null then
    select count(*) into player_total from asgq_rehearsal_private.players;
    if player_total >= ev.min_players and ev.created and ev.armed and asgq_rehearsal_private.ready_for_kickoff() then
      update asgq_rehearsal_private.event
        set phase_started_at = clock_timestamp(),
            starts_at = clock_timestamp() + make_interval(secs => ev.lobby_seconds)
      where id = ev.id;
      select * into ev from asgq_rehearsal_private.event where id = 1;
    end if;
  end if;

  for i in 1..100 loop
    -- Bots are REAL server participants. Their answers use the same table,
    -- deadlines, scoring transition and leaderboard as human answers.
    if ev.phase = 'question' and ev.phase_started_at is not null then
      select * into question_row from asgq_rehearsal_private.questions
        where position = ev.current_position;
      if question_row.id is not null then
        insert into asgq_rehearsal_private.answers(player_id,question_id,choice,answered_at)
        select p.id, question_row.id,
          case when mod(question_row.position * 17 + p.bot_order * 7, 10) < 6
               then question_row.correct_index
               else mod(question_row.correct_index + 1 +
                        mod(p.bot_order,cardinality(question_row.choices)-1),
                        cardinality(question_row.choices))
          end,
          ev.phase_started_at + make_interval(secs => 2 + mod(p.bot_order * 3, 21))
        from asgq_rehearsal_private.players p
        where p.bot_order is not null
          and ev.phase_started_at + make_interval(secs => 2 + mod(p.bot_order * 3, 21))
            <= least(clock_timestamp(),ev.phase_until)
        on conflict (player_id,question_id) do nothing;
      end if;
    end if;
    exit when ev.phase = 'finished';
    exit when ev.phase = 'lobby' and (ev.starts_at is null or clock_timestamp() < ev.starts_at);
    exit when ev.phase <> 'lobby' and (ev.phase_until is null or clock_timestamp() < ev.phase_until);

    boundary := case when ev.phase = 'lobby' then ev.starts_at else ev.phase_until end;

    if ev.phase = 'lobby' then
      update asgq_rehearsal_private.event set phase='intro', phase_started_at=boundary,
        phase_until=boundary + make_interval(secs=>ev.intro_seconds) where id=1;
    elsif ev.phase = 'intro' then
      select * into question_row from asgq_rehearsal_private.questions order by position limit 1;
      if not found then raise exception 'Aucune question configurée.'; end if;
      update asgq_rehearsal_private.event set phase='question', current_position=question_row.position,
        phase_started_at=boundary, phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
    elsif ev.phase = 'question' then
      select * into question_row from asgq_rehearsal_private.questions where position=ev.current_position;
      -- Snapshot / idempotence: only the question -> reveal transition awards points.
      update asgq_rehearsal_private.answers a
        set points_awarded = case when a.choice = question_row.correct_index then question_row.points else 0 end
      where a.question_id = question_row.id;
      update asgq_rehearsal_private.players p set score = p.score + t.earned
      from (select player_id, sum(points_awarded)::integer as earned
            from asgq_rehearsal_private.answers where question_id=question_row.id
            group by player_id) t
      where p.id=t.player_id;
      update asgq_rehearsal_private.event set phase='reveal',phase_started_at=boundary,
        phase_until=boundary + make_interval(secs=>ev.reveal_seconds) where id=1;
    elsif ev.phase = 'reveal' then
      select * into question_row from asgq_rehearsal_private.questions where position=ev.current_position;
      select * into next_row from asgq_rehearsal_private.questions where position>ev.current_position order by position limit 1;
      if not found then
        update asgq_rehearsal_private.event set phase='finished', phase_started_at=boundary,
          phase_until=null where id=1;
      elsif question_row.half=1 and next_row.half=2 then
        update asgq_rehearsal_private.event set phase='halftime',phase_started_at=boundary,
          phase_until=boundary + make_interval(secs=>ev.halftime_seconds) where id=1;
      else
        update asgq_rehearsal_private.event set phase='question', current_position=next_row.position,
          phase_started_at=boundary,phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
      end if;
    elsif ev.phase = 'halftime' then
      select * into next_row from asgq_rehearsal_private.questions where half=2 order by position limit 1;
      if not found then raise exception 'La seconde mi-temps est vide.'; end if;
      update asgq_rehearsal_private.event set phase='question', current_position=next_row.position,
        phase_started_at=boundary,phase_until=boundary + make_interval(secs=>ev.question_seconds) where id=1;
    end if;

    select * into ev from asgq_rehearsal_private.event where id=1;
  end loop;
end $fn$;

create or replace function public.asgq_rehearsal_create(
    p_password text, p_name text, p_bots integer default 5
) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  invite_secret text;
  join_result jsonb;
  public_room_code text;
  i integer;
begin
  if not public._is_admin_plus(p_password) then
    raise exception 'Mot de passe Admin+ incorrect.';
  end if;
  if p_bots is null or p_bots not in (2,5,10,20) then
    raise exception 'Nombre de bots non autorisé.';
  end if;
  select * into ev from asgq_rehearsal_private.event where id=1 for update;
  if not found then raise exception 'Répétition indisponible.'; end if;
  if ev.phase not in ('lobby','finished') then
    raise exception 'Une répétition est en cours. Termine-la avant d’en créer une autre.';
  end if;
  delete from asgq_rehearsal_private.players;
  delete from asgq_rehearsal_private.join_attempts;
  public_room_code := asgq_rehearsal_private.new_room_code();
  update asgq_rehearsal_private.event
    set created=true, armed=true, room_code=public_room_code,
        phase='lobby', phase_started_at=null, phase_until=null, starts_at=null,
        current_position=0, lobby_seconds=30,
        intro_seconds=7, question_seconds=25, reveal_seconds=9, halftime_seconds=40
    where id=1;
  select plaintext_code into invite_secret from asgq_rehearsal_private.invitation where event_id=1;
  if invite_secret is null then raise exception 'Code interne absent.'; end if;
  join_result := public.asgq_rehearsal_join(invite_secret, p_name, null);
  for i in 1..p_bots loop
    insert into asgq_rehearsal_private.players(event_id,name,token_hash,bot_order)
      values (1,'Bot '||pg_catalog.lpad(i::text,2,'0'),
              pg_catalog.encode(extensions.digest('asgq-rehearsal-bot:'||pg_catalog.gen_random_uuid()::text,'sha256'),'hex'),
              i);
  end loop;
  perform asgq_rehearsal_private.tick();
  return join_result || pg_catalog.jsonb_build_object('code',public_room_code);
end $fn$;

-- The legacy two-argument variant cannot create a botless hidden room.
revoke execute on function public.asgq_rehearsal_create(text,text) from public,anon,authenticated;
revoke execute on function public.asgq_rehearsal_create(text,text,integer) from public,anon,authenticated;
grant execute on function public.asgq_rehearsal_create(text,text,integer) to anon,authenticated;
revoke all on all functions in schema asgq_rehearsal_private from public,anon,authenticated;
