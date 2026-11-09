-- True-multiplayer rehearsal with real server bots and manual-only master controls.
-- Entire test runs inside a transaction and rolls back.
begin;
do $test$
declare
  creator jsonb; guest jsonb; state jsonb;
  t uuid; guest_token uuid; code text; bot_id uuid;
  idx integer; bot_responses integer;
  saw_halftime boolean:=false; saw_finished boolean:=false;
begin
  if (select count(*) from asgq_rehearsal_private.players)<>0 then
    raise exception 'ASGQ_TEST: dirty rehearsal fixture';
  end if;
  if (select count(*) from asgq_private.players)<>0 then
    raise exception 'ASGQ_TEST: official event has participants';
  end if;
  if not asgq_rehearsal_private.ready_for_kickoff() then
    raise exception 'ASGQ_TEST: rehearsal requires both 10-question halves';
  end if;
  begin
    perform public.asgq_rehearsal_create('bad password','Intrus',5);
    raise exception 'ASGQ_TEST: Admin+ bypass';
  exception when others then
    if sqlerrm like 'ASGQ_TEST:%' then raise; end if;
    if sqlerrm not like '%Mot de passe Admin+ incorrect%' then raise; end if;
  end;
  creator:=public.asgq_rehearsal_create('CI-TEST-ONLY-PASSWORD','Alban',0);
  t:=(creator->>'token')::uuid;
  code:=creator->>'code';
  if code !~ '^[0-9]{8}$' or t is null then raise exception 'ASGQ_TEST: bad room creation'; end if;
  if (select count(*) from asgq_rehearsal_private.players)<>1 then
    raise exception 'ASGQ_TEST: creator is not alone initially';
  end if;
  for idx in 1..5 loop perform public.asgq_rehearsal_add_bot(t); end loop;
  if (select count(*) from asgq_rehearsal_private.players where bot_order is not null)<>5 then
    raise exception 'ASGQ_TEST: bots missing';
  end if;
  select id into bot_id from asgq_rehearsal_private.players where bot_order=5;
  perform public.asgq_rehearsal_remove_bot(t,bot_id);
  if (select count(*) from asgq_rehearsal_private.players where bot_order is not null)<>4 then
    raise exception 'ASGQ_TEST: bot removal failed';
  end if;
  begin
    perform public.asgq_rehearsal_remove_bot(gen_random_uuid(),
      (select id from asgq_rehearsal_private.players where bot_order=4));
    raise exception 'ASGQ_TEST: outsider removed bot';
  exception when others then
    if sqlerrm like 'ASGQ_TEST:%' then raise; end if;
  end;
  perform public.asgq_rehearsal_add_bot(t);
  guest:=public.asgq_rehearsal_join_room(code,'Camille');
  guest_token:=(guest->>'token')::uuid;
  if guest_token is null then raise exception 'ASGQ_TEST: guest failed to join'; end if;
  if public.asgq_rehearsal_join_room('00000000','Intrus')->>'error' is null then
    raise exception 'ASGQ_TEST: incorrect room code worked';
  end if;
  state:=public.asgq_rehearsal_state(t);
  if state->>'phase'<>'lobby' or state->>'is_host'<>'true'
    or state->>'starts_at' is not null or jsonb_array_length(state->'players')<>7 then
    raise exception 'ASGQ_TEST: lobby auto-started or host role lost';
  end if;
  if (public.asgq_rehearsal_state(guest_token)->>'is_host')<>'false' then
    raise exception 'ASGQ_TEST: guest became master';
  end if;
  if has_schema_privilege('anon','asgq_rehearsal_private','USAGE') then
    raise exception 'ASGQ_TEST: private rehearsal exposed';
  end if;
  begin
    perform public.asgq_rehearsal_start(guest_token);
    raise exception 'ASGQ_TEST: guest started rehearsal';
  exception when others then
    if sqlerrm like 'ASGQ_TEST:%' then raise; end if;
  end;
  perform public.asgq_rehearsal_start(t);
  state:=public.asgq_rehearsal_state(t);
  if state->>'phase'<>'intro' or state->>'phase_until' is not null then
    raise exception 'ASGQ_TEST: no untimed manual kickoff intro';
  end if;
  begin
    perform public.asgq_rehearsal_advance(guest_token,(select phase from asgq_rehearsal_private.event where id=1),(select current_position from asgq_rehearsal_private.event where id=1));
    raise exception 'ASGQ_TEST: guest advanced quiz';
  exception when others then
    if sqlerrm like 'ASGQ_TEST:%' then raise; end if;
  end;
  perform public.asgq_rehearsal_advance(t,(select phase from asgq_rehearsal_private.event where id=1),(select current_position from asgq_rehearsal_private.event where id=1));
  state:=public.asgq_rehearsal_state(guest_token);
  if state->>'phase'<>'question' or state->'question'->>'correct' is not null
    or state->>'phase_until' is not null then
    raise exception 'ASGQ_TEST: question leaked or has a deadline';
  end if;
  select count(*) into bot_responses from asgq_rehearsal_private.answers a
    join asgq_rehearsal_private.players p on p.id=a.player_id where p.bot_order is not null;
  if bot_responses<>0 then raise exception 'ASGQ_TEST: bots must not answer before the host reveals'; end if;
  begin
    perform public.asgq_rehearsal_answer(t,0);
    raise exception 'ASGQ_TEST: master answered own quiz';
  exception when others then
    if sqlerrm like 'ASGQ_TEST:%' then raise; end if;
  end;
  perform public.asgq_rehearsal_answer(guest_token,1);
  perform public.asgq_rehearsal_answer(guest_token,0);
  state:=public.asgq_rehearsal_state(guest_token);
  if state->>'phase'<>'question' or state->'question'->>'my_choice'<>'0' then
    raise exception 'ASGQ_TEST: untimed answer update failed';
  end if;
  perform public.asgq_rehearsal_advance(t,(select phase from asgq_rehearsal_private.event where id=1),(select current_position from asgq_rehearsal_private.event where id=1));
  state:=public.asgq_rehearsal_state(t);
  select count(*) into bot_responses from asgq_rehearsal_private.answers a
    join asgq_rehearsal_private.players p on p.id=a.player_id where p.bot_order is not null;
  if bot_responses<>5 then raise exception 'ASGQ_TEST: bots did not answer during manual reveal'; end if;
  if state->>'phase'<>'reveal' or jsonb_array_length(state->'standings')<>6 then
    raise exception 'ASGQ_TEST: scoring or host exclusion failed';
  end if;
  for idx in 1..80 loop
    exit when (select phase from asgq_rehearsal_private.event where id=1)='finished';
    perform public.asgq_rehearsal_advance(t,(select phase from asgq_rehearsal_private.event where id=1),(select current_position from asgq_rehearsal_private.event where id=1));
    state:=public.asgq_rehearsal_state(t);
    if state->>'phase'='halftime' then saw_halftime:=true; end if;
    if state->>'phase'='finished' then saw_finished:=true; end if;
    if state->>'phase_until' is not null then
      raise exception 'ASGQ_TEST: deadline introduced into manual game';
    end if;
  end loop;
  if not saw_halftime or not saw_finished then raise exception 'ASGQ_TEST: missing halftime or podium'; end if;
  if jsonb_array_length(state->'standings')<>6 then
    raise exception 'ASGQ_TEST: host appears in ranking';
  end if;
  select count(*) into bot_responses from asgq_rehearsal_private.answers a
    join asgq_rehearsal_private.players p on p.id=a.player_id where p.bot_order is not null;
  if bot_responses<>100 then raise exception 'ASGQ_TEST: expected 5 bot answers x 20 questions, got %',bot_responses; end if;

  creator:=public.asgq_rehearsal_create('CI-TEST-ONLY-PASSWORD','Alban',0);
  t:=(creator->>'token')::uuid;
  perform public.asgq_rehearsal_add_bot(t);
  perform public.asgq_rehearsal_add_bot(t);
  if (select count(*) from asgq_rehearsal_private.players)<>3
    or (select count(*) from asgq_rehearsal_private.answers)<>0 then
    raise exception 'ASGQ_TEST: fresh rehearsal reset failed';
  end if;
  for idx in 3..20 loop perform public.asgq_rehearsal_add_bot(t); end loop;
  if (select count(*) from asgq_rehearsal_private.players where bot_order is not null)<>20 then
    raise exception 'ASGQ_TEST: 20 bot limit broken';
  end if;
  select id into bot_id from asgq_rehearsal_private.players where bot_order=1;
  perform public.asgq_rehearsal_remove_bot(t,bot_id);
  perform public.asgq_rehearsal_add_bot(t);
  if (select count(*) from asgq_rehearsal_private.players where bot_order is not null)<>20
    or not exists(select 1 from asgq_rehearsal_private.players where bot_order=1) then
    raise exception 'ASGQ_TEST: bot number recycling failed';
  end if;
  if (select count(*) from asgq_private.players)<>0 or (select armed from asgq_private.event where id=1) then
    raise exception 'ASGQ_TEST: production event affected by rehearsal';
  end if;
  raise notice 'ASGQ rehearsal OK: host-only buttons, untimed 2x10, real bots, scores, podium, isolation';
end $test$;
rollback;
