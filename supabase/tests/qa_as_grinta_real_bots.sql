-- Full server-side rehearsal, live scoring and bot responses. Entire run rolled back.
-- CI fake Admin+ password only; never the real application Admin+ secret.
begin;
do $test$
declare
  creator jsonb;
  guest jsonb;
  state jsonb;
  t uuid;
  guest_token uuid;
  code text;
  bot_id uuid;
  phase_name text;
  idx integer;
  bot_responses integer;
  saw_halftime boolean := false;
  saw_finished boolean := false;
begin
  if (select count(*) from asgq_rehearsal_private.players)<>0 then
    raise exception 'ASGQ_TEST: dirty rehearsal fixture';
  end if;
  if (select count(*) from asgq_private.players)<>0 then
    raise exception 'ASGQ_TEST: production already has participants';
  end if;
  if not asgq_rehearsal_private.ready_for_kickoff() then
    raise exception 'ASGQ_TEST: rehearsal pool must be exactly two real 10-question halves';
  end if;
  begin
    perform public.asgq_rehearsal_create('bad password', 'Illegal',5);
    raise exception 'ASGQ_TEST: bad Admin+ password created rehearsal';
  exception when others then
    if sqlerrm like 'ASGQ_TEST:%' then raise; end if;
    if sqlerrm not like '%Mot de passe Admin+ incorrect%' then raise exception 'ASGQ_TEST: wrong error: %',sqlerrm; end if;
  end;
  creator := public.asgq_rehearsal_create('CI-TEST-ONLY-PASSWORD','Alban',0);
  if (select count(*) from asgq_rehearsal_private.players)<>1 then raise exception 'ASGQ_TEST: creation should only add the host'; end if;
  for idx in 1..5 loop perform public.asgq_rehearsal_add_bot((creator->>'token')::uuid); end loop;
  code := creator->>'code';
  t := (creator->>'token')::uuid;
  if code !~ '^[0-9]{8}$' or t is null then raise exception 'ASGQ_TEST: bad creator result %',creator; end if;
  if (select count(*) from asgq_rehearsal_private.players where bot_order is not null)<>5 then
    raise exception 'ASGQ_TEST: 5 server-side bots missing';
  end if;
  select id into bot_id from asgq_rehearsal_private.players
    where bot_order=5;
  perform public.asgq_rehearsal_remove_bot(t,bot_id);
  if (select count(*) from asgq_rehearsal_private.players where bot_order is not null)<>4 then
    raise exception 'ASGQ_TEST: host cannot remove bots';
  end if;
  begin
    perform public.asgq_rehearsal_remove_bot(gen_random_uuid(),
      (select id from asgq_rehearsal_private.players where bot_order=4));
    raise exception 'ASGQ_TEST: outsider removed a bot';
  exception when others then
    if sqlerrm like 'ASGQ_TEST:%' then raise; end if;
  end;
  perform public.asgq_rehearsal_add_bot(t);
  if (select count(*) from asgq_rehearsal_private.players where bot_order is not null)<>5 then
    raise exception 'ASGQ_TEST: host cannot re-add bot after removal';
  end if;
  if (select created from asgq_private.event where id=1) then
    raise exception 'ASGQ_TEST: official event created by rehearsal';
  end if;
  state := public.asgq_rehearsal_state(t);
  if state->>'phase'<>'lobby' or state->>'room_code'<>code or jsonb_array_length(state->'players')<>6 then
    raise exception 'ASGQ_TEST: wrong lobby %',state;
  end if;
  if state->'question' is not null and state->'question'<>'null'::jsonb then
    raise exception 'ASGQ_TEST: answers leaked from the lobby';
  end if;
  if has_schema_privilege('anon','asgq_rehearsal_private','USAGE') then
    raise exception 'ASGQ_TEST: practice questions schema public';
  end if;

  guest := public.asgq_rehearsal_join_room(code,'Camille');
  guest_token := (guest->>'token')::uuid;
  if guest_token is null then raise exception 'ASGQ_TEST: human guest unable to join'; end if;
  if public.asgq_rehearsal_join_room('00000000','Intrus')->>'error' is null then
    raise exception 'ASGQ_TEST: incorrect room code worked';
  end if;

  if (select starts_at from asgq_rehearsal_private.event where id=1) is not null then raise exception 'ASGQ_TEST: bots auto-started'; end if;
  perform public.asgq_rehearsal_start(t);
  if (select starts_at from asgq_rehearsal_private.event where id=1) is null then raise exception 'ASGQ_TEST: start did not begin countdown'; end if;
  update asgq_rehearsal_private.event set starts_at=clock_timestamp()-interval '1 second' where id=1;
  state := public.asgq_rehearsal_state(t);
  if state->>'phase'<>'intro' then raise exception 'ASGQ_TEST: intro absent'; end if;
  update asgq_rehearsal_private.event set phase_until=clock_timestamp()-interval '1 second' where id=1;
  state := public.asgq_rehearsal_state(t);
  if state->>'phase'<>'question' or state->'question'->>'correct' is not null then
    raise exception 'ASGQ_TEST: question privacy broken';
  end if;
  perform public.asgq_rehearsal_answer(t,0);
  perform public.asgq_rehearsal_answer(guest_token,1);
  update asgq_rehearsal_private.event set phase_started_at=clock_timestamp()-interval '25 seconds',
    phase_until=clock_timestamp()-interval '1 second' where id=1;
  state := public.asgq_rehearsal_state(t);
  if state->>'phase'<>'reveal' then raise exception 'ASGQ_TEST: reveal missing'; end if;
  select count(*) into bot_responses from asgq_rehearsal_private.answers a
    join asgq_rehearsal_private.players p on p.id=a.player_id where p.bot_order is not null;
  if bot_responses<>5 then raise exception 'ASGQ_TEST: bot responses not saved by engine: %',bot_responses; end if;
  for idx in 1..65 loop
    select phase into phase_name from asgq_rehearsal_private.event where id=1;
    exit when phase_name='finished';
    if phase_name='question' then
      update asgq_rehearsal_private.event set phase_started_at=clock_timestamp()-interval '25 seconds',
        phase_until=clock_timestamp()-interval '1 second' where id=1;
    else
      update asgq_rehearsal_private.event set phase_until=clock_timestamp()-interval '1 second' where id=1;
    end if;
    state := public.asgq_rehearsal_state(t);
    if state->>'phase'='halftime' then saw_halftime := true; end if;
    if state->>'phase'='finished' then saw_finished := true; end if;
  end loop;
  if not saw_halftime or not saw_finished then
    raise exception 'ASGQ_TEST: no halftime or podium after 20 live timed questions';
  end if;
  if jsonb_array_length(state->'standings')<>7 then
    raise exception 'ASGQ_TEST: ranking should include 5 bots + 2 humans';
  end if;
  select count(*) into bot_responses from asgq_rehearsal_private.answers a
    join asgq_rehearsal_private.players p on p.id=a.player_id where p.bot_order is not null;
  if bot_responses<>100 then
    raise exception 'ASGQ_TEST: expected 5 bots times 20 questions, got %',bot_responses;
  end if;
  -- Admin+ can start a completely fresh rehearsal when the previous one is done.
  creator := public.asgq_rehearsal_create('CI-TEST-ONLY-PASSWORD','Alban',0);
  perform public.asgq_rehearsal_add_bot((creator->>'token')::uuid);
  perform public.asgq_rehearsal_add_bot((creator->>'token')::uuid);
  if (select count(*) from asgq_rehearsal_private.players)<>3
     or (select count(*) from asgq_rehearsal_private.answers)<>0 then
    raise exception 'ASGQ_TEST: rehearsal reset failed';
  end if;
  -- Roster test: 20 bots, removal of number 1, and successful re-addition.
  for idx in 3..20 loop perform public.asgq_rehearsal_add_bot((creator->>'token')::uuid); end loop;
  if (select count(*) from asgq_rehearsal_private.players where bot_order is not null)<>20 then
    raise exception 'ASGQ_TEST: could not reach 20 bots';
  end if;
  select id into bot_id from asgq_rehearsal_private.players where bot_order=1;
  perform public.asgq_rehearsal_remove_bot((creator->>'token')::uuid,bot_id);
  perform public.asgq_rehearsal_add_bot((creator->>'token')::uuid);
  if (select count(*) from asgq_rehearsal_private.players where bot_order is not null)<>20
    or not exists (select 1 from asgq_rehearsal_private.players where bot_order=1) then
    raise exception 'ASGQ_TEST: bot numbers were not reusable';
  end if;
  if (select count(*) from asgq_private.players)<>0
     or (select armed from asgq_private.event where id=1) then
    raise exception 'ASGQ_TEST: production event modified by rehearsal';
  end if;
  raise notice 'ASGQ rehearsal OK: true multiplayer, bot responses, 2x10, scores, podium, reset, production isolation';
end $test$;
rollback;
