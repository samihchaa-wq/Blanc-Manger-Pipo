-- Rehearsal host control, bots and 20-question scoring, all rolled back.
begin;
do $qa$
declare
  creator jsonb; guest jsonb; s jsonb;
  host_token uuid; guest_token uuid; code text; bot_id uuid;
  idx integer; bot_responses integer; saw_halftime boolean:=false;
begin
  if (select count(*) from asgq_rehearsal_private.players)<>0 then
    raise exception 'ASGQ_TEST: dirty rehearsal fixture'; end if;
  if (select count(*) from asgq_private.players)<>0 then
    raise exception 'ASGQ_TEST: official fixture not isolated'; end if;
  begin
    perform public.asgq_rehearsal_create('bad password','Intrus',0);
    raise exception 'ASGQ_TEST: invalid Admin+ accepted';
  exception when others then if sqlerrm like 'ASGQ_TEST:%' then raise; end if; end;
  creator:=public.asgq_rehearsal_create('CI-TEST-ONLY-PASSWORD','Alban',0);
  host_token:=(creator->>'token')::uuid; code:=creator->>'code';
  if (select count(*) from asgq_rehearsal_private.players)<>1 then
    raise exception 'ASGQ_TEST: creation should add host only'; end if;
  for idx in 1..5 loop perform public.asgq_rehearsal_add_bot(host_token); end loop;
  select id into bot_id from asgq_rehearsal_private.players where bot_order=5;
  perform public.asgq_rehearsal_remove_bot(host_token,bot_id);
  perform public.asgq_rehearsal_add_bot(host_token);
  if (select count(*) from asgq_rehearsal_private.players where bot_order is not null)<>5 then
    raise exception 'ASGQ_TEST: bot count after remove/re-add'; end if;
  guest:=public.asgq_rehearsal_join_room(code,'Camille');
  guest_token:=(guest->>'token')::uuid;
  perform public.asgq_rehearsal_join_room(code,'Nina'); -- deliberately leaves the question unanswered
  s:=public.asgq_rehearsal_state(host_token);
  if s->>'phase'<>'lobby' or s->>'is_host'<>'true' or jsonb_array_length(s->'players')<>8 then
    raise exception 'ASGQ_TEST: host lobby invalid'; end if;
  perform public.asgq_rehearsal_state(guest_token);
  if (select phase from asgq_rehearsal_private.event where id=1)<>'lobby' then
    raise exception 'ASGQ_TEST: bots auto-started'; end if;
  begin
    perform public.asgq_rehearsal_start(guest_token);
    raise exception 'ASGQ_TEST: guest started';
  exception when others then if sqlerrm like 'ASGQ_TEST:%' then raise; end if; end;
  perform public.asgq_rehearsal_start(host_token);
  s:=public.asgq_rehearsal_state(host_token);
  if s->>'phase'<>'intro' or s->>'starts_at' is not null or s->>'phase_until' is not null then
    raise exception 'ASGQ_TEST: intro deadline exists'; end if;
  perform public.asgq_rehearsal_advance(host_token,'intro',0);
  s:=public.asgq_rehearsal_state(guest_token);
  if s->>'phase'<>'question' or s->'question'->>'correct' is not null
    or s->'question'->>'responses' is not null then
    raise exception 'ASGQ_TEST: question secret leaked'; end if;
  begin
    perform public.asgq_rehearsal_answer(host_token,0);
    raise exception 'ASGQ_TEST: host answered';
  exception when others then if sqlerrm like 'ASGQ_TEST:%' then raise; end if; end;
  perform public.asgq_rehearsal_answer(guest_token,0);
  s:=public.asgq_rehearsal_state(host_token);
  if s->'question'->>'responses' is not null then
    raise exception 'ASGQ_TEST: participant statuses leaked before reveal'; end if;
  if (select phase from asgq_rehearsal_private.event where id=1)<>'question' then
    raise exception 'ASGQ_TEST: answer closed automatically'; end if;
  perform public.asgq_rehearsal_advance(host_token,'question',1);
  s:=public.asgq_rehearsal_state(host_token);
  if s->>'phase'<>'reveal' or jsonb_array_length(s->'standings')<>7 then
    raise exception 'ASGQ_TEST: host in standings or reveal absent'; end if;
  if jsonb_array_length(s->'question'->'responses')<>7 then
    raise exception 'ASGQ_TEST: expected seven distinct participant outcomes'; end if;
  if (select count(*) from jsonb_array_elements(s->'question'->'responses') item
        where item->>'name'='Nina' and item->>'status'='unanswered')<>1 then
    raise exception 'ASGQ_TEST: omitted answer is not identified'; end if;
  if (select count(*) from jsonb_array_elements(s->'question'->'responses') item
        where item->>'name'='Camille' and item->>'status'='incorrect')<>1 then
    raise exception 'ASGQ_TEST: wrong guest answer is not identified'; end if;
  if (select count(*) from jsonb_array_elements(s->'question'->'responses') item
        where item->>'status'='correct')<1 then
    raise exception 'ASGQ_TEST: correct bot answer is not identified'; end if;
  if (select count(*) from jsonb_array_elements(s->'question'->'responses') item
        where item->>'name'='Alban')<>0 then
    raise exception 'ASGQ_TEST: host must not appear in participant outcomes'; end if;
  select count(*) into bot_responses from asgq_rehearsal_private.answers a
    join asgq_rehearsal_private.players p on p.id=a.player_id where p.bot_order is not null;
  if bot_responses<>5 then raise exception 'ASGQ_TEST: bots did not answer at reveal'; end if;
  perform public.asgq_rehearsal_advance(host_token,'question',1);
  if (public.asgq_rehearsal_state(host_token)->>'phase')<>'reveal' then
    raise exception 'ASGQ_TEST: duplicate skipped reveal'; end if;
  for idx in 1..65 loop
    s:=public.asgq_rehearsal_state(host_token);
    exit when s->>'phase'='finished';
    if s->>'phase'='halftime' then saw_halftime:=true; end if;
    perform public.asgq_rehearsal_advance(host_token,s->>'phase',(s->>'position')::integer);
  end loop;
  s:=public.asgq_rehearsal_state(host_token);
  if not saw_halftime or s->>'phase'<>'finished' then raise exception 'ASGQ_TEST: no final podium'; end if;
  select count(*) into bot_responses from asgq_rehearsal_private.answers a
    join asgq_rehearsal_private.players p on p.id=a.player_id where p.bot_order is not null;
  if bot_responses<>100 then raise exception 'ASGQ_TEST: expected 100 bot answers, got %',bot_responses; end if;
  creator:=public.asgq_rehearsal_create('CI-TEST-ONLY-PASSWORD','Alban',0);
  if (select count(*) from asgq_rehearsal_private.players)<>1 then
    raise exception 'ASGQ_TEST: new rehearsal did not reset test participants'; end if;
  if (select created from asgq_private.event where id=1) then
    raise exception 'ASGQ_TEST: rehearsal changed official quiz'; end if;
  raise notice 'ASGQ_TEST: OK — host only, no timers, 5 bots, 20 questions, reset';
end $qa$;
rollback;
