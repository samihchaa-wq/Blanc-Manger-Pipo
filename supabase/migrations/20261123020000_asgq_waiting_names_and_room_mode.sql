-- AS Grinta 2026: host-only names of participants who have not yet answered.
-- Guests continue joining through Soulieteur's ordinary 8-digit room code screen.
-- Existing RPC functions are replaced in place; no event, players, scores or questions reset.
-- The rehearsal waiting list excludes bots: their simulated answers are generated at reveal.

create or replace function public.asgq_state(p_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  player_row asgq_private.players%rowtype;
  ev asgq_private.event%rowtype;
  q asgq_private.questions%rowtype;
  my_answer asgq_private.answers%rowtype;
  n integer;
  first_half integer;
  second_half integer;
  ordinal integer;
  people jsonb;
  ranking jsonb;
begin
  player_row:=asgq_private.player_for(p_token);
  if player_row.id is null then raise exception 'Session expirée. Rejoins la partie.'; end if;
  select * into ev from asgq_private.event where id=1;
  select count(*) into n from asgq_private.questions;
  select count(*) into first_half from asgq_private.questions where half=1;
  select count(*) into second_half from asgq_private.questions where half=2;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,
    'is_host',(p.token_hash=ev.host_token_hash)) order by p.joined_at),'[]'::jsonb)
    into people from asgq_private.players p;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'score',p.score)
    order by p.score desc,p.joined_at),'[]'::jsonb)
    into ranking from asgq_private.players p where p.token_hash is distinct from ev.host_token_hash;
  select * into q from asgq_private.questions where position=ev.current_position;
  if q.id is not null then
    select * into my_answer from asgq_private.answers where question_id=q.id and player_id=player_row.id;
  end if;
  select count(*) into ordinal from asgq_private.questions where position<=ev.current_position;
  return jsonb_build_object(
    'phase',ev.phase,'ready',(ev.armed and asgq_private.ready_for_kickoff()),
    'room_code',ev.room_code,'is_host',(ev.host_token_hash=player_row.token_hash),
    'max_players',ev.max_players,'title',ev.title,'now',clock_timestamp(),
    'starts_at',null,'phase_started_at',ev.phase_started_at,'phase_until',null,
    'position',ordinal,'total',n,'first_half_count',first_half,'second_half_count',second_half,
    'half',case when ev.phase='halftime' then 2 when q.id is not null then q.half else 1 end,
    'players',people,'standings',case when ev.phase in ('reveal','halftime','finished') then ranking else null end,
    'me',jsonb_build_object('id',player_row.id,'name',player_row.name,'score',player_row.score),
    'question',case when ev.phase in ('question','reveal') and q.id is not null then
      jsonb_build_object('text',q.prompt,'choices',q.choices,'points',q.points,
        'correct',case when ev.phase='reveal' then q.correct_index else null end,
        'explanation',case when ev.phase='reveal' then q.explanation else null end,
        'my_choice',my_answer.choice,
        'earned',case when ev.phase='reveal' then my_answer.points_awarded else null end,
        'answered_count',(select count(*) from asgq_private.answers where question_id=q.id),
        -- Only the host, and only during the question, sees who is still waiting.
        'waiting_players',case when ev.phase='question'
             and player_row.token_hash=ev.host_token_hash then (
          select coalesce(jsonb_agg(jsonb_build_object('id',participant.id,'name',participant.name)
            order by participant.joined_at,participant.id),'[]'::jsonb)
          from asgq_private.players participant
          where participant.token_hash is distinct from ev.host_token_hash
            
            and not exists(
              select 1 from asgq_private.answers answer
              where answer.player_id=participant.id and answer.question_id=q.id)
        ) else null end,
        -- Never expose anyone's answer status while the question is still open.
        'responses',case when ev.phase='reveal' then (
          select coalesce(jsonb_agg(jsonb_build_object(
            'id',participant.id,
            'name',participant.name,
            'status',case
              when response.choice is null then 'unanswered'
              when response.choice=q.correct_index then 'correct'
              else 'incorrect'
            end
          ) order by participant.joined_at,participant.id),'[]'::jsonb)
          from asgq_private.players participant
          left join asgq_private.answers response
            on response.player_id=participant.id and response.question_id=q.id
          where participant.token_hash is distinct from ev.host_token_hash
        ) else null end)
      else null end
  );
end $fn$;

create or replace function public.asgq_rehearsal_state(p_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  player_row asgq_rehearsal_private.players%rowtype;
  ev asgq_rehearsal_private.event%rowtype;
  q asgq_rehearsal_private.questions%rowtype;
  my_answer asgq_rehearsal_private.answers%rowtype;
  n integer;
  first_half integer;
  second_half integer;
  ordinal integer;
  people jsonb;
  ranking jsonb;
begin
  player_row:=asgq_rehearsal_private.player_for(p_token);
  if player_row.id is null then raise exception 'Session expirée. Rejoins la partie.'; end if;
  select * into ev from asgq_rehearsal_private.event where id=1;
  select count(*) into n from asgq_rehearsal_private.questions;
  select count(*) into first_half from asgq_rehearsal_private.questions where half=1;
  select count(*) into second_half from asgq_rehearsal_private.questions where half=2;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,
    'is_host',(p.token_hash=ev.host_token_hash),'is_bot',(p.bot_order is not null)) order by p.joined_at),'[]'::jsonb)
    into people from asgq_rehearsal_private.players p;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'score',p.score)
    order by p.score desc,p.joined_at),'[]'::jsonb)
    into ranking from asgq_rehearsal_private.players p where p.token_hash is distinct from ev.host_token_hash;
  select * into q from asgq_rehearsal_private.questions where position=ev.current_position;
  if q.id is not null then
    select * into my_answer from asgq_rehearsal_private.answers where question_id=q.id and player_id=player_row.id;
  end if;
  select count(*) into ordinal from asgq_rehearsal_private.questions where position<=ev.current_position;
  return jsonb_build_object(
    'phase',ev.phase,'ready',(ev.armed and asgq_rehearsal_private.ready_for_kickoff()),
    'room_code',ev.room_code,'is_host',(ev.host_token_hash=player_row.token_hash),
    'max_players',ev.max_players,'title',ev.title,'now',clock_timestamp(),
    'starts_at',null,'phase_started_at',ev.phase_started_at,'phase_until',null,
    'position',ordinal,'total',n,'first_half_count',first_half,'second_half_count',second_half,
    'half',case when ev.phase='halftime' then 2 when q.id is not null then q.half else 1 end,
    'players',people,'standings',case when ev.phase in ('reveal','halftime','finished') then ranking else null end,
    'me',jsonb_build_object('id',player_row.id,'name',player_row.name,'score',player_row.score),
    'question',case when ev.phase in ('question','reveal') and q.id is not null then
      jsonb_build_object('text',q.prompt,'choices',q.choices,'points',q.points,
        'correct',case when ev.phase='reveal' then q.correct_index else null end,
        'explanation',case when ev.phase='reveal' then q.explanation else null end,
        'my_choice',my_answer.choice,
        'earned',case when ev.phase='reveal' then my_answer.points_awarded else null end,
        'answered_count',(select count(*) from asgq_rehearsal_private.answers where question_id=q.id),
        -- Only the host, and only during the question, sees who is still waiting.
        'waiting_players',case when ev.phase='question'
             and player_row.token_hash=ev.host_token_hash then (
          select coalesce(jsonb_agg(jsonb_build_object('id',participant.id,'name',participant.name)
            order by participant.joined_at,participant.id),'[]'::jsonb)
          from asgq_rehearsal_private.players participant
          where participant.token_hash is distinct from ev.host_token_hash
            and participant.bot_order is null -- Bots answer automatically on reveal; do not count them as pending.
            and not exists(
              select 1 from asgq_rehearsal_private.answers answer
              where answer.player_id=participant.id and answer.question_id=q.id)
        ) else null end,
        -- Never expose anyone's answer status while the question is still open.
        'responses',case when ev.phase='reveal' then (
          select coalesce(jsonb_agg(jsonb_build_object(
            'id',participant.id,
            'name',participant.name,
            'status',case
              when response.choice is null then 'unanswered'
              when response.choice=q.correct_index then 'correct'
              else 'incorrect'
            end
          ) order by participant.joined_at,participant.id),'[]'::jsonb)
          from asgq_rehearsal_private.players participant
          left join asgq_rehearsal_private.answers response
            on response.player_id=participant.id and response.question_id=q.id
          where participant.token_hash is distinct from ev.host_token_hash
        ) else null end)
      else null end
  );
end $fn$;


-- Room-code recognition is distinct from joining a quiz. A separate limiter
-- avoids counting one guest twice against the official AS Grinta join quota,
-- especially when teammates share a Wi-Fi IP address.
create table if not exists asgq_private.route_attempts(
  client_hash text primary key,
  window_started_at timestamptz not null default pg_catalog.clock_timestamp(),
  attempts integer not null default 0,
  failures integer not null default 0
);
revoke all on table asgq_private.route_attempts from public,anon,authenticated;

create or replace function public.asgq_room_mode(p_code text)
returns text language plpgsql security definer set search_path = '' as $route$
declare
  normalized_code text;
  v_client_hash text;
  v_requests integer;
  v_failures integer;
  checked_at timestamptz:=pg_catalog.clock_timestamp();
  result_mode text;
begin
  normalized_code:=pg_catalog.regexp_replace(coalesce(p_code,''),'[^0-9]','','g');
  if pg_catalog.length(normalized_code)<>8 then return null; end if;
  v_client_hash:=public._client_hash();
  if v_client_hash is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('asgq-mode:'||v_client_hash,0));
    insert into asgq_private.route_attempts(client_hash,window_started_at,attempts,failures)
      values(v_client_hash,checked_at,1,0)
    on conflict (client_hash) do update set
      attempts=case
        when asgq_private.route_attempts.window_started_at < checked_at-interval '10 minutes'
          then 1 else asgq_private.route_attempts.attempts+1 end,
      failures=case
        when asgq_private.route_attempts.window_started_at < checked_at-interval '10 minutes'
          then 0 else asgq_private.route_attempts.failures end,
      window_started_at=case
        when asgq_private.route_attempts.window_started_at < checked_at-interval '10 minutes'
          then checked_at else asgq_private.route_attempts.window_started_at end
    returning attempts,failures into v_requests,v_failures;
    if v_requests>200 or v_failures>=12 then return null; end if;
  end if;
  if exists(select 1 from asgq_private.event e
      where e.id=1 and e.created and e.room_code=normalized_code) then
    result_mode:='official';
  elsif exists(select 1 from asgq_rehearsal_private.event e
      where e.id=1 and e.created and e.room_code=normalized_code) then
    result_mode:='rehearsal';
  end if;
  if result_mode is null and v_client_hash is not null then
    update asgq_private.route_attempts
      set failures=failures+1 where client_hash=v_client_hash;
  end if;
  return result_mode;
end $route$;
revoke all on function public.asgq_room_mode(text) from public;
grant execute on function public.asgq_room_mode(text) to anon,authenticated,service_role;
