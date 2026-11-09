-- The Grand Quiz is fully host-operated. No countdown, auto-advance or timed answer lock.

-- Applies to BOTH official AS Grinta and isolated bot rehearsal without touching existing scores.

alter table asgq_private.event add column if not exists host_token_hash text;

alter table asgq_rehearsal_private.event add column if not exists host_token_hash text;

create or replace function asgq_private.tick()
returns void language plpgsql security definer set search_path = '' as $fn$
begin
  -- Intentionally inert: only the master-of-game RPCs advance phases.
  return;
end $fn$;

create or replace function asgq_rehearsal_private.tick()
returns void language plpgsql security definer set search_path = '' as $fn$
begin
  -- Intentionally inert: only the master-of-game RPCs advance phases.
  return;
end $fn$;

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
  update asgq_private.event set host_token_hash =
    pg_catalog.encode(extensions.digest('asgq-token:'||(joined->>'token'),'sha256'),'hex')
    where id=1;
  return joined || pg_catalog.jsonb_build_object('code',public_code);
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
    into ranking from asgq_private.players p where p.token_hash is distinct from ev.host_token_hash;
  select * into q from asgq_private.questions where position=ev.current_position;
  if q.id is not null then
    select * into my_answer from asgq_private.answers
    where question_id=q.id and player_id=player_row.id;
  end if;
  select count(*) into ordinal from asgq_private.questions where position <= ev.current_position;
  show_result := ev.phase='reveal';
  return jsonb_build_object(
    'phase', ev.phase, 'ready', (ev.armed and asgq_private.ready_for_kickoff()), 'room_code', ev.room_code, 'is_host', (ev.host_token_hash=player_row.token_hash), 'title', ev.title, 'now',clock_timestamp(),
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
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'is_bot',(p.bot_order is not null)) order by p.joined_at), '[]'::jsonb)
    into people from asgq_rehearsal_private.players p;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'score',p.score) order by p.score desc,p.joined_at), '[]'::jsonb)
    into ranking from asgq_rehearsal_private.players p where p.token_hash is distinct from ev.host_token_hash;
  select * into q from asgq_rehearsal_private.questions where position=ev.current_position;
  if q.id is not null then
    select * into my_answer from asgq_rehearsal_private.answers
    where question_id=q.id and player_id=player_row.id;
  end if;
  select count(*) into ordinal from asgq_rehearsal_private.questions where position <= ev.current_position;
  show_result := ev.phase='reveal';
  return jsonb_build_object(
    'phase', ev.phase, 'ready', asgq_rehearsal_private.ready_for_kickoff(), 'room_code', ev.room_code, 'is_host', (ev.host_token_hash=player_row.token_hash), 'max_players', ev.max_players, 'title', ev.title, 'now',clock_timestamp(),
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

create or replace function public.asgq_start(p_token uuid)
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_private.event%rowtype;
  host_player asgq_private.players%rowtype;
begin
  select * into ev from asgq_private.event where id=1 for update;
  host_player := asgq_private.player_for(p_token);
  if host_player.id is null or ev.host_token_hash is distinct from host_player.token_hash then
    raise exception 'Seul le maître du jeu peut contrôler la partie.';
  end if;
  if ev.phase <> 'lobby' then raise exception 'La partie a déjà commencé.'; end if;
  if not ev.created or not ev.armed or not asgq_private.ready_for_kickoff() then
    raise exception 'Les deux mi-temps ne sont pas prêtes.';
  end if;
  if (select count(*) from asgq_private.players) < ev.min_players then
    raise exception 'Il faut au moins un joueur pour lancer la partie.';
  end if;
  update asgq_private.event
    set phase='intro', phase_started_at=clock_timestamp(), starts_at=null,
        phase_until=null
    where id=1;
end $fn$;

create or replace function public.asgq_rehearsal_start(p_token uuid)
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  host_player asgq_rehearsal_private.players%rowtype;
begin
  select * into ev from asgq_rehearsal_private.event where id=1 for update;
  host_player := asgq_rehearsal_private.player_for(p_token);
  if host_player.id is null or ev.host_token_hash is distinct from host_player.token_hash then
    raise exception 'Seul le maître du jeu peut contrôler la partie.';
  end if;
  if ev.phase <> 'lobby' then raise exception 'La partie a déjà commencé.'; end if;
  if not ev.created or not ev.armed or not asgq_rehearsal_private.ready_for_kickoff() then
    raise exception 'Les deux mi-temps ne sont pas prêtes.';
  end if;
  if (select count(*) from asgq_rehearsal_private.players) < ev.min_players then
    raise exception 'Il faut au moins un joueur pour lancer la partie.';
  end if;
  update asgq_rehearsal_private.event
    set phase='intro', phase_started_at=clock_timestamp(), starts_at=null,
        phase_until=null, manual_started=true
    where id=1;
end $fn$;

create or replace function public.asgq_next(p_token uuid)
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_private.event%rowtype;
  host_player asgq_private.players%rowtype;
  question_row asgq_private.questions%rowtype;
  next_row asgq_private.questions%rowtype;
begin
  select * into ev from asgq_private.event where id=1 for update;
  host_player := asgq_private.player_for(p_token);
  if host_player.id is null or ev.host_token_hash is distinct from host_player.token_hash then
    raise exception 'Seul le maître du jeu peut contrôler la partie.';
  end if;
  if ev.phase in ('intro','halftime') then
    select * into next_row from asgq_private.questions
      where (ev.phase='intro' or half=2)
      order by position limit 1;
    if next_row.id is null then raise exception 'Aucune question disponible.'; end if;
    update asgq_private.event set phase='question',current_position=next_row.position,
      phase_started_at=clock_timestamp(),phase_until=null where id=1;
  elsif ev.phase='question' then
    select * into question_row from asgq_private.questions where position=ev.current_position;
    if question_row.id is null then raise exception 'Question introuvable.'; end if;
    -- The row lock and phase guard ensure points are awarded exactly once.
    update asgq_private.answers a
      set points_awarded=case when a.choice=question_row.correct_index then question_row.points else 0 end
      where a.question_id=question_row.id;
    update asgq_private.players pl set score=pl.score+t.earned
      from (select player_id,sum(points_awarded)::integer earned
            from asgq_private.answers where question_id=question_row.id group by player_id) t
      where pl.id=t.player_id;
    update asgq_private.event set phase='reveal',phase_started_at=clock_timestamp(),phase_until=null where id=1;
  elsif ev.phase='reveal' then
    select * into question_row from asgq_private.questions where position=ev.current_position;
    select * into next_row from asgq_private.questions where position>ev.current_position order by position limit 1;
    if next_row.id is null then
      update asgq_private.event set phase='finished',phase_started_at=clock_timestamp(),phase_until=null where id=1;
    elsif question_row.half=1 and next_row.half=2 then
      update asgq_private.event set phase='halftime',phase_started_at=clock_timestamp(),phase_until=null where id=1;
    else
      update asgq_private.event set phase='question',current_position=next_row.position,
        phase_started_at=clock_timestamp(),phase_until=null where id=1;
    end if;
  else
    raise exception 'Cette étape ne peut pas être avancée.';
  end if;
end $fn$;

create or replace function public.asgq_rehearsal_next(p_token uuid)
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  host_player asgq_rehearsal_private.players%rowtype;
  question_row asgq_rehearsal_private.questions%rowtype;
  next_row asgq_rehearsal_private.questions%rowtype;
begin
  select * into ev from asgq_rehearsal_private.event where id=1 for update;
  host_player := asgq_rehearsal_private.player_for(p_token);
  if host_player.id is null or ev.host_token_hash is distinct from host_player.token_hash then
    raise exception 'Seul le maître du jeu peut contrôler la partie.';
  end if;
  if ev.phase in ('intro','halftime') then
    select * into next_row from asgq_rehearsal_private.questions
      where (ev.phase='intro' or half=2)
      order by position limit 1;
    if next_row.id is null then raise exception 'Aucune question disponible.'; end if;
    update asgq_rehearsal_private.event set phase='question',current_position=next_row.position,
      phase_started_at=clock_timestamp(),phase_until=null where id=1;
  elsif ev.phase='question' then
    select * into question_row from asgq_rehearsal_private.questions where position=ev.current_position;
    if question_row.id is null then raise exception 'Question introuvable.'; end if;
    -- The row lock and phase guard ensure points are awarded exactly once.
    update asgq_rehearsal_private.answers a
      set points_awarded=case when a.choice=question_row.correct_index then question_row.points else 0 end
      where a.question_id=question_row.id;
    update asgq_rehearsal_private.players pl set score=pl.score+t.earned
      from (select player_id,sum(points_awarded)::integer earned
            from asgq_rehearsal_private.answers where question_id=question_row.id group by player_id) t
      where pl.id=t.player_id;
    update asgq_rehearsal_private.event set phase='reveal',phase_started_at=clock_timestamp(),phase_until=null where id=1;
  elsif ev.phase='reveal' then
    select * into question_row from asgq_rehearsal_private.questions where position=ev.current_position;
    select * into next_row from asgq_rehearsal_private.questions where position>ev.current_position order by position limit 1;
    if next_row.id is null then
      update asgq_rehearsal_private.event set phase='finished',phase_started_at=clock_timestamp(),phase_until=null where id=1;
    elsif question_row.half=1 and next_row.half=2 then
      update asgq_rehearsal_private.event set phase='halftime',phase_started_at=clock_timestamp(),phase_until=null where id=1;
    else
      update asgq_rehearsal_private.event set phase='question',current_position=next_row.position,
        phase_started_at=clock_timestamp(),phase_until=null where id=1;
    end if;
  else
    raise exception 'Cette étape ne peut pas être avancée.';
  end if;
  -- Each bot answers once when the master opens a question; no deadline or delay.
  if (select phase from asgq_rehearsal_private.event where id=1)='question' then
    select * into question_row from asgq_rehearsal_private.questions
      where position=(select current_position from asgq_rehearsal_private.event where id=1);
    insert into asgq_rehearsal_private.answers(player_id,question_id,choice,answered_at)
      select bot.id,question_row.id,
        case when mod(question_row.position * 17 + bot.bot_order * 7, 10) < 6
          then question_row.correct_index
          else mod(question_row.correct_index+1+mod(bot.bot_order,cardinality(question_row.choices)-1),
            cardinality(question_row.choices))
        end,
        clock_timestamp()
      from asgq_rehearsal_private.players bot
      where bot.bot_order is not null
      on conflict (player_id,question_id) do nothing;
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
  player_row := asgq_private.player_for(p_token);
  if player_row.id is null then raise exception 'Session expirée.'; end if;
  if ev.host_token_hash = player_row.token_hash then
    raise exception 'Le maître du jeu ne participe pas aux réponses.';
  end if;
  if ev.phase <> 'question' then raise exception 'Les réponses sont fermées.'; end if;
  select * into q from asgq_private.questions where position=ev.current_position;
  if q.id is null or p_choice is null or p_choice<0 or p_choice>=cardinality(q.choices) then
    raise exception 'Réponse invalide.';
  end if;
  insert into asgq_private.answers(player_id,question_id,choice,answered_at)
    values(player_row.id,q.id,p_choice,clock_timestamp())
    on conflict (player_id,question_id) do update
      set choice=excluded.choice,answered_at=excluded.answered_at;
end $fn$;

create or replace function public.asgq_rehearsal_answer(p_token uuid,p_choice integer)
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  player_row asgq_rehearsal_private.players%rowtype;
  ev asgq_rehearsal_private.event%rowtype;
  q asgq_rehearsal_private.questions%rowtype;
begin
  select * into ev from asgq_rehearsal_private.event where id=1 for update;
  player_row := asgq_rehearsal_private.player_for(p_token);
  if player_row.id is null then raise exception 'Session expirée.'; end if;
  if ev.host_token_hash = player_row.token_hash then
    raise exception 'Le maître du jeu ne participe pas aux réponses.';
  end if;
  if ev.phase <> 'question' then raise exception 'Les réponses sont fermées.'; end if;
  select * into q from asgq_rehearsal_private.questions where position=ev.current_position;
  if q.id is null or p_choice is null or p_choice<0 or p_choice>=cardinality(q.choices) then
    raise exception 'Réponse invalide.';
  end if;
  insert into asgq_rehearsal_private.answers(player_id,question_id,choice,answered_at)
    values(player_row.id,q.id,p_choice,clock_timestamp())
    on conflict (player_id,question_id) do update
      set choice=excluded.choice,answered_at=excluded.answered_at;
end $fn$;

revoke execute on function public.asgq_start(uuid),public.asgq_next(uuid),
  public.asgq_rehearsal_start(uuid),public.asgq_rehearsal_next(uuid) from public,anon,authenticated;
grant execute on function public.asgq_start(uuid),public.asgq_next(uuid),
  public.asgq_rehearsal_start(uuid),public.asgq_rehearsal_next(uuid) to anon,authenticated;
revoke all on all functions in schema asgq_private from public,anon,authenticated;
revoke all on all functions in schema asgq_rehearsal_private from public,anon,authenticated;
