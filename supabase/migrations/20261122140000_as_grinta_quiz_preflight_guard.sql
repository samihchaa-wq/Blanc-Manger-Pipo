-- Grand Quiz AS Grinta: only arm a complete 10-20 + 10-20 question event.
-- Safety gate: the 4 technical placeholders can never launch a real game.
-- The event is armed once during preparation, never controlled during the quiz.
alter table asgq_private.event
  add column if not exists armed boolean not null default false;

create or replace function asgq_private.ready_for_kickoff()
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
    from asgq_private.questions
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
    if player_total >= ev.min_players and ev.armed and asgq_private.ready_for_kickoff() then
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
    'phase', ev.phase, 'ready', (ev.armed and asgq_private.ready_for_kickoff()), 'title', ev.title, 'now',clock_timestamp(),
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

-- No direct client access to the private data or internal checks.
revoke all on all functions in schema asgq_private from public, anon, authenticated;
