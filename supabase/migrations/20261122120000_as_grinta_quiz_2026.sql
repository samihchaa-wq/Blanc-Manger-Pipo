-- AS Grinta 2026: standalone, one-night, mobile-first quiz.
-- Independent of the Soulieteur rooms/QCM tables and RPCs.
-- One 10-character secret invitation code; never bundle this code in client assets.
-- All quiz answers stay in a non-exposed schema until the reveal phase.

create schema if not exists asgq_private;
revoke all on schema asgq_private from public, anon, authenticated;

create table if not exists asgq_private.event (
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
create table if not exists asgq_private.invitation (
  event_id integer primary key references asgq_private.event(id) on delete cascade,
  plaintext_code text not null
);

create table if not exists asgq_private.players (
  id uuid primary key default gen_random_uuid(),
  event_id integer not null default 1 references asgq_private.event(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 22),
  token_hash text not null unique,
  score integer not null default 0,
  joined_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create unique index if not exists asgq_player_unique_name on asgq_private.players(event_id, lower(name));

create table if not exists asgq_private.questions (
  id bigint generated always as identity primary key,
  position integer not null unique check (position between 1 and 40),
  half smallint not null check (half in (1, 2)),
  prompt text not null check (char_length(prompt) between 3 and 220),
  choices text[] not null check (cardinality(choices) between 2 and 4),
  correct_index smallint not null check (correct_index between 0 and 3 and correct_index < cardinality(choices)),
  points smallint not null default 1 check (points between 1 and 3),
  explanation text
);

create table if not exists asgq_private.answers (
  player_id uuid not null references asgq_private.players(id) on delete cascade,
  question_id bigint not null references asgq_private.questions(id) on delete cascade,
  choice smallint not null check (choice between 0 and 3),
  answered_at timestamptz not null default clock_timestamp(),
  points_awarded integer not null default 0,
  primary key (player_id, question_id)
);
create index if not exists asgq_answers_question on asgq_private.answers(question_id);

-- Defensive RLS on every table, even though this schema is not exposed by Data API.
alter table asgq_private.event enable row level security;
alter table asgq_private.invitation enable row level security;
alter table asgq_private.players enable row level security;
alter table asgq_private.questions enable row level security;
alter table asgq_private.answers enable row level security;
revoke all on all tables in schema asgq_private from public, anon, authenticated;

-- Generate the single event's invitation code once. DB-only; not committed in git.
with code as materialized (
  select upper(encode(extensions.gen_random_bytes(5), 'hex')) as plaintext_code
), seeded as (
  insert into asgq_private.event(id, code_hash)
  select 1, encode(extensions.digest('asgq:' || plaintext_code, 'sha256'), 'hex') from code
  on conflict (id) do nothing
  returning id
)
insert into asgq_private.invitation(event_id, plaintext_code)
select seeded.id, code.plaintext_code from seeded cross join code
on conflict (event_id) do nothing;

-- Four clearly marked placeholders, two per half, ONLY for the first technical test.
-- Replace all of them with the actual 10-20 questions per half before the event.
insert into asgq_private.questions(position, half, prompt, choices, correct_index, points)
select p, case when p <= 2 then 1 else 2 end,
  'QUESTION DE TEST ' || p || ' — à remplacer avant la soirée',
  array['Réponse A (test)', 'Réponse B (test)', 'Réponse C (test)', 'Réponse D (test)'],
  0, 1
from generate_series(1,4) as p
on conflict (position) do nothing;

-- Internal authenticated participant lookup; never executable over PostgREST.
create or replace function asgq_private.player_for(p_token uuid)
returns asgq_private.players
language sql stable security definer set search_path = '' as $fn$
  select p from asgq_private.players p
  where p_token is not null and p.token_hash = encode(extensions.digest('asgq-token:' || p_token::text, 'sha256'), 'hex')
$fn$;

-- State-machine transitions are executed transactionally on ANY state read.
-- The event row is locked so simultaneous polls cannot award points twice.
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

  if ev.phase = 'lobby' and ev.starts_at is null then
    select count(*) into player_total from asgq_private.players;
    if player_total >= ev.min_players and exists (select 1 from asgq_private.questions) then
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

-- Entry is secret-code gated. Reconnection always uses the original token.
create or replace function public.asgq_join(p_code text, p_name text, p_token uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_private.event%rowtype;
  player_row asgq_private.players%rowtype;
  clean_name text;
  generated_token uuid;
  normalized_code text;
begin
  select * into ev from asgq_private.event where id=1 for update;
  if not found then raise exception 'Événement indisponible.'; end if;

  if p_token is not null then
    player_row := asgq_private.player_for(p_token);
    if player_row.id is null then raise exception 'Session inconnue.'; end if;
    update asgq_private.players set last_seen_at=clock_timestamp() where id=player_row.id;
    perform asgq_private.tick();
    return jsonb_build_object('token',p_token,'name',player_row.name);
  end if;

  normalized_code := upper(regexp_replace(coalesce(p_code,''), '[^A-Za-z0-9]', '', 'g'));
  if encode(extensions.digest('asgq:' || normalized_code, 'sha256'),'hex') <> ev.code_hash then
    raise exception 'Code d’entrée incorrect.';
  end if;
  if ev.phase <> 'lobby' then raise exception 'Le quiz a déjà commencé.'; end if;
  if (select count(*) from asgq_private.players)>=ev.max_players then raise exception 'Le vestiaire est complet.'; end if;
  clean_name := btrim(regexp_replace(coalesce(p_name,''),'\s+',' ','g'));
  if char_length(clean_name) < 2 or char_length(clean_name) > 22 then raise exception 'Prénom : entre 2 et 22 caractères.'; end if;
  if exists(select 1 from asgq_private.players where lower(name)=lower(clean_name)) then
    raise exception 'Ce prénom est déjà pris dans le vestiaire.';
  end if;
  generated_token := gen_random_uuid();
  insert into asgq_private.players(event_id,name,token_hash)
    values (1,clean_name,encode(extensions.digest('asgq-token:' || generated_token::text,'sha256'),'hex'));
  perform asgq_private.tick();
  return jsonb_build_object('token', generated_token, 'name', clean_name);
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
    'phase', ev.phase, 'title', ev.title, 'now',clock_timestamp(),
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

create or replace function public.asgq_answer(p_token uuid, p_choice integer)
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  player_row asgq_private.players%rowtype;
  ev asgq_private.event%rowtype;
  q asgq_private.questions%rowtype;
begin
  player_row := asgq_private.player_for(p_token);
  if player_row.id is null then raise exception 'Session expirée.'; end if;
  perform asgq_private.tick();
  select * into ev from asgq_private.event where id=1 for update;
  if ev.phase <> 'question' or clock_timestamp() >= ev.phase_until then
    raise exception 'Le temps de réponse est terminé.';
  end if;
  select * into q from asgq_private.questions where position=ev.current_position;
  if p_choice is null or p_choice<0 or p_choice>=cardinality(q.choices) then raise exception 'Réponse invalide.'; end if;
  insert into asgq_private.answers(player_id,question_id,choice,answered_at)
    values (player_row.id,q.id,p_choice,clock_timestamp())
  on conflict (player_id,question_id) do update set choice=excluded.choice,answered_at=excluded.answered_at;
end $fn$;

revoke all on all functions in schema asgq_private from public, anon, authenticated;
revoke execute on function public.asgq_join(text,text,uuid) from public, anon, authenticated;
revoke execute on function public.asgq_state(uuid) from public, anon, authenticated;
revoke execute on function public.asgq_answer(uuid,integer) from public, anon, authenticated;
grant execute on function public.asgq_join(text,text,uuid) to anon, authenticated;
grant execute on function public.asgq_state(uuid) to anon, authenticated;
grant execute on function public.asgq_answer(uuid,integer) to anon, authenticated;