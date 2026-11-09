-- Host-controlled Grand Quiz: no automatic timeouts, no deadlines and no timer scoring.
-- Existing rooms, player tokens, answers and scores are preserved.
-- The official question bank stays private and untouched.

alter table asgq_private.event
  add column if not exists host_token_hash text,
  add column if not exists manual_started boolean not null default false;

-- Existing official room was already created before host identity was stored.
-- Its first participant is necessarily the creator (creation joins before sharing the code).
update asgq_private.event e set host_token_hash=(
  select p.token_hash from asgq_private.players p
  where p.event_id=e.id order by p.joined_at,p.id limit 1
) where e.id=1 and e.created and e.host_token_hash is null;

-- Cancel previously scheduled deadlines, without resetting any game progress.
update asgq_private.event set starts_at=null,phase_until=null where id=1;
update asgq_rehearsal_private.event set starts_at=null,phase_until=null where id=1;

-- Creation continues to require Admin+; the resulting token alone grants host controls.
create or replace function public.asgq_create(p_password text,p_name text)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_private.event%rowtype;
  private_code text;
  public_code text;
  joined jsonb;
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe Admin+ incorrect.'; end if;
  select * into ev from asgq_private.event where id=1 for update;
  if ev.id is null then raise exception 'Événement indisponible.'; end if;
  if ev.created or ev.phase<>'lobby' then raise exception 'La partie AS Grinta existe déjà : rejoins-la avec son code.'; end if;
  public_code:=asgq_private.new_room_code();
  select plaintext_code into private_code from asgq_private.invitation where event_id=1;
  if private_code is null then raise exception 'Événement non configuré.'; end if;
  update asgq_private.event set created=true,room_code=public_code,manual_started=false where id=1;
  joined:=public.asgq_join(private_code,p_name,null);
  update asgq_private.event set host_token_hash=
    pg_catalog.encode(extensions.digest('asgq-token:'||(joined->>'token'),'sha256'),'hex') where id=1;
  return joined || pg_catalog.jsonb_build_object('code',public_code);
end $fn$;

-- Polling must never move a phase or expire answers.
create or replace function asgq_private.tick()
returns void language plpgsql security definer set search_path = '' as $fn$
begin
  return;
end $fn$;

create or replace function public.asgq_start(p_token uuid)
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_private.event%rowtype;
  host_player asgq_private.players%rowtype;
begin
  select * into ev from asgq_private.event where id=1 for update;
  host_player:=asgq_private.player_for(p_token);
  if host_player.id is null or ev.host_token_hash is distinct from host_player.token_hash then
    raise exception 'Seul le maître du jeu peut lancer la partie.';
  end if;
  if ev.phase<>'lobby' or ev.manual_started then raise exception 'La partie a déjà commencé.'; end if;
  if (select count(*) from asgq_private.players)<ev.min_players then
    raise exception 'Ajoute au moins un joueur avant de lancer.';
  end if;
  if not ev.created or not ev.armed or not asgq_private.ready_for_kickoff() then
    raise exception 'Le quiz n’est pas encore prêt.';
  end if;
  update asgq_private.event set manual_started=true,phase='intro',current_position=0,
    phase_started_at=clock_timestamp(),starts_at=null,phase_until=null where id=1;
end $fn$;

-- One guarded press moves exactly one phase; stale/double requests cannot skip a question.
create or replace function public.asgq_advance(p_token uuid,p_phase text,p_position integer)
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_private.event%rowtype;
  host_player asgq_private.players%rowtype;
  q asgq_private.questions%rowtype;
  next_q asgq_private.questions%rowtype;
begin
  select * into ev from asgq_private.event where id=1 for update;
  host_player:=asgq_private.player_for(p_token);
  if host_player.id is null or ev.host_token_hash is distinct from host_player.token_hash then
    raise exception 'Seul le maître du jeu peut faire avancer le quiz.';
  end if;
  if ev.phase is distinct from p_phase or ev.current_position is distinct from p_position then return; end if;
  if ev.phase='intro' then
    select * into q from asgq_private.questions order by position limit 1;
    if q.id is null then raise exception 'Aucune question configurée.'; end if;
    update asgq_private.event set phase='question',current_position=q.position,
      phase_started_at=clock_timestamp(),phase_until=null where id=1;
  elsif ev.phase='question' then
    select * into q from asgq_private.questions where position=ev.current_position;
    if q.id is null then raise exception 'Question introuvable.'; end if;
    -- Award once: a second advance request sees phase='reveal' or fails the expected-phase guard.
    update asgq_private.answers a
      set points_awarded=case when a.choice=q.correct_index then q.points else 0 end
      where a.question_id=q.id;
    update asgq_private.players p set score=p.score+t.earned
      from (select player_id,sum(points_awarded)::integer earned
            from asgq_private.answers where question_id=q.id group by player_id) t
      where p.id=t.player_id and p.token_hash is distinct from ev.host_token_hash;
    update asgq_private.event set phase='reveal',phase_started_at=clock_timestamp(),phase_until=null where id=1;
  elsif ev.phase='reveal' then
    select * into q from asgq_private.questions where position=ev.current_position;
    select * into next_q from asgq_private.questions where position>ev.current_position order by position limit 1;
    if next_q.id is null then
      update asgq_private.event set phase='finished',phase_started_at=clock_timestamp(),phase_until=null where id=1;
    elsif q.half=1 and next_q.half=2 then
      update asgq_private.event set phase='halftime',phase_started_at=clock_timestamp(),phase_until=null where id=1;
    else
      update asgq_private.event set phase='question',current_position=next_q.position,
        phase_started_at=clock_timestamp(),phase_until=null where id=1;
    end if;
  elsif ev.phase='halftime' then
    select * into next_q from asgq_private.questions where half=2 order by position limit 1;
    if next_q.id is null then raise exception 'La seconde mi-temps est vide.'; end if;
    update asgq_private.event set phase='question',current_position=next_q.position,
      phase_started_at=clock_timestamp(),phase_until=null where id=1;
  else
    raise exception 'Cette étape ne peut pas être avancée.';
  end if;
end $fn$;

create or replace function public.asgq_answer(p_token uuid,p_choice integer)
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  player_row asgq_private.players%rowtype;
  ev asgq_private.event%rowtype;
  q asgq_private.questions%rowtype;
begin
  select * into ev from asgq_private.event where id=1 for update;
  player_row:=asgq_private.player_for(p_token);
  if player_row.id is null then raise exception 'Session expirée.'; end if;
  if ev.host_token_hash=player_row.token_hash then raise exception 'Le maître du jeu ne répond pas.'; end if;
  if ev.phase<>'question' then raise exception 'Les réponses sont clôturées.'; end if;
  select * into q from asgq_private.questions where position=ev.current_position;
  if p_choice is null or p_choice<0 or p_choice>=cardinality(q.choices) then raise exception 'Réponse invalide.'; end if;
  insert into asgq_private.answers(player_id,question_id,choice,answered_at)
    values(player_row.id,q.id,p_choice,clock_timestamp())
    on conflict (player_id,question_id) do update
      set choice=excluded.choice,answered_at=excluded.answered_at;
end $fn$;

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
        'answered_count',(select count(*) from asgq_private.answers where question_id=q.id))
      else null end
  );
end $fn$;

revoke execute on function public.asgq_start(uuid) from public,anon,authenticated;
revoke execute on function public.asgq_advance(uuid,text,integer) from public,anon,authenticated;
grant execute on function public.asgq_start(uuid) to anon,authenticated;
grant execute on function public.asgq_advance(uuid,text,integer) to anon,authenticated;
revoke all on all functions in schema asgq_private from public,anon,authenticated;

-- Polling must never move a phase or expire answers.
create or replace function asgq_rehearsal_private.tick()
returns void language plpgsql security definer set search_path = '' as $fn$
begin
  return;
end $fn$;

create or replace function public.asgq_rehearsal_start(p_token uuid)
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  host_player asgq_rehearsal_private.players%rowtype;
begin
  select * into ev from asgq_rehearsal_private.event where id=1 for update;
  host_player:=asgq_rehearsal_private.player_for(p_token);
  if host_player.id is null or ev.host_token_hash is distinct from host_player.token_hash then
    raise exception 'Seul le maître du jeu peut lancer la partie.';
  end if;
  if ev.phase<>'lobby' or ev.manual_started then raise exception 'La partie a déjà commencé.'; end if;
  if (select count(*) from asgq_rehearsal_private.players)<ev.min_players then
    raise exception 'Ajoute au moins un joueur avant de lancer.';
  end if;
  if not ev.created or not ev.armed or not asgq_rehearsal_private.ready_for_kickoff() then
    raise exception 'Le quiz n’est pas encore prêt.';
  end if;
  update asgq_rehearsal_private.event set manual_started=true,phase='intro',current_position=0,
    phase_started_at=clock_timestamp(),starts_at=null,phase_until=null where id=1;
end $fn$;

-- One guarded press moves exactly one phase; stale/double requests cannot skip a question.
create or replace function public.asgq_rehearsal_advance(p_token uuid,p_phase text,p_position integer)
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  host_player asgq_rehearsal_private.players%rowtype;
  q asgq_rehearsal_private.questions%rowtype;
  next_q asgq_rehearsal_private.questions%rowtype;
begin
  select * into ev from asgq_rehearsal_private.event where id=1 for update;
  host_player:=asgq_rehearsal_private.player_for(p_token);
  if host_player.id is null or ev.host_token_hash is distinct from host_player.token_hash then
    raise exception 'Seul le maître du jeu peut faire avancer le quiz.';
  end if;
  if ev.phase is distinct from p_phase or ev.current_position is distinct from p_position then return; end if;
  if ev.phase='intro' then
    select * into q from asgq_rehearsal_private.questions order by position limit 1;
    if q.id is null then raise exception 'Aucune question configurée.'; end if;
    update asgq_rehearsal_private.event set phase='question',current_position=q.position,
      phase_started_at=clock_timestamp(),phase_until=null where id=1;
  elsif ev.phase='question' then
    select * into q from asgq_rehearsal_private.questions where position=ev.current_position;
    if q.id is null then raise exception 'Question introuvable.'; end if;
    -- Bots answer when the host closes the question, not after any delay.
    insert into asgq_rehearsal_private.answers(player_id,question_id,choice,answered_at)
      select p.id,q.id,
        case when mod(q.position*17+p.bot_order*7,10)<6 then q.correct_index
             else mod(q.correct_index+1+mod(p.bot_order,cardinality(q.choices)-1),cardinality(q.choices)) end,
        clock_timestamp()
      from asgq_rehearsal_private.players p where p.bot_order is not null
      on conflict (player_id,question_id) do nothing;
    -- Award once: a second advance request sees phase='reveal' or fails the expected-phase guard.
    update asgq_rehearsal_private.answers a
      set points_awarded=case when a.choice=q.correct_index then q.points else 0 end
      where a.question_id=q.id;
    update asgq_rehearsal_private.players p set score=p.score+t.earned
      from (select player_id,sum(points_awarded)::integer earned
            from asgq_rehearsal_private.answers where question_id=q.id group by player_id) t
      where p.id=t.player_id and p.token_hash is distinct from ev.host_token_hash;
    update asgq_rehearsal_private.event set phase='reveal',phase_started_at=clock_timestamp(),phase_until=null where id=1;
  elsif ev.phase='reveal' then
    select * into q from asgq_rehearsal_private.questions where position=ev.current_position;
    select * into next_q from asgq_rehearsal_private.questions where position>ev.current_position order by position limit 1;
    if next_q.id is null then
      update asgq_rehearsal_private.event set phase='finished',phase_started_at=clock_timestamp(),phase_until=null where id=1;
    elsif q.half=1 and next_q.half=2 then
      update asgq_rehearsal_private.event set phase='halftime',phase_started_at=clock_timestamp(),phase_until=null where id=1;
    else
      update asgq_rehearsal_private.event set phase='question',current_position=next_q.position,
        phase_started_at=clock_timestamp(),phase_until=null where id=1;
    end if;
  elsif ev.phase='halftime' then
    select * into next_q from asgq_rehearsal_private.questions where half=2 order by position limit 1;
    if next_q.id is null then raise exception 'La seconde mi-temps est vide.'; end if;
    update asgq_rehearsal_private.event set phase='question',current_position=next_q.position,
      phase_started_at=clock_timestamp(),phase_until=null where id=1;
  else
    raise exception 'Cette étape ne peut pas être avancée.';
  end if;
end $fn$;

create or replace function public.asgq_rehearsal_answer(p_token uuid,p_choice integer)
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  player_row asgq_rehearsal_private.players%rowtype;
  ev asgq_rehearsal_private.event%rowtype;
  q asgq_rehearsal_private.questions%rowtype;
begin
  select * into ev from asgq_rehearsal_private.event where id=1 for update;
  player_row:=asgq_rehearsal_private.player_for(p_token);
  if player_row.id is null then raise exception 'Session expirée.'; end if;
  if ev.host_token_hash=player_row.token_hash then raise exception 'Le maître du jeu ne répond pas.'; end if;
  if ev.phase<>'question' then raise exception 'Les réponses sont clôturées.'; end if;
  select * into q from asgq_rehearsal_private.questions where position=ev.current_position;
  if p_choice is null or p_choice<0 or p_choice>=cardinality(q.choices) then raise exception 'Réponse invalide.'; end if;
  insert into asgq_rehearsal_private.answers(player_id,question_id,choice,answered_at)
    values(player_row.id,q.id,p_choice,clock_timestamp())
    on conflict (player_id,question_id) do update
      set choice=excluded.choice,answered_at=excluded.answered_at;
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
        'answered_count',(select count(*) from asgq_rehearsal_private.answers where question_id=q.id))
      else null end
  );
end $fn$;

revoke execute on function public.asgq_rehearsal_start(uuid) from public,anon,authenticated;
revoke execute on function public.asgq_rehearsal_advance(uuid,text,integer) from public,anon,authenticated;
grant execute on function public.asgq_rehearsal_start(uuid) to anon,authenticated;
grant execute on function public.asgq_rehearsal_advance(uuid,text,integer) to anon,authenticated;
revoke all on all functions in schema asgq_rehearsal_private from public,anon,authenticated;

