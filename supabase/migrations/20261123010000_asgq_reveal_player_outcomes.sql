-- Grand Quiz AS Grinta: who answered correctly, incorrectly or not at all.
-- Presentation data only, available to participants AFTER the host reveals a question.
-- No new public RPC, no schema changes, no state reset, no scoring changes.
-- CREATE OR REPLACE retains the existing function ownership and execution grants.
--
-- Pre-reveal "question.responses" is JSON null; post-reveal it is an array
-- of {id,name,status}, excluding the game master and never including secret choices.

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
