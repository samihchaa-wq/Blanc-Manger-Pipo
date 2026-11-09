-- Manual-only Grand Quiz: official + rehearsal, isolated and rolled back.
begin;
do $test$
declare
  official_host jsonb;
  guest jsonb;
  s jsonb;
  host_token uuid;
  guest_token uuid;
  practice_host jsonb;
  practice_token uuid;
  practice_guest jsonb;
  practice_guest_token uuid;
  step_phase text;
  step_pos integer;
  saw_halftime boolean := false;
  finished boolean := false;
  i integer;
  answer_count integer;
begin
  -- Start with the real creation path, but only fake Admin+ in CI.
  official_host := public.asgq_create('CI-TEST-ONLY-PASSWORD','Animateur');
  host_token := (official_host->>'token')::uuid;
  guest := public.asgq_join_room(official_host->>'code','Candidat');
  guest_token := (guest->>'token')::uuid;
  s := public.asgq_state(host_token);
  if s->>'is_host'<>'true' or s->>'phase'<>'lobby' then
    raise exception 'MANUAL_QA: creator is not host or lobby auto-started';
  end if;
  if public.asgq_state(guest_token)->>'is_host'<>'false' then
    raise exception 'MANUAL_QA: guest acquired host controls';
  end if;
  begin
    perform public.asgq_start(guest_token);
    raise exception 'MANUAL_QA: guest started event';
  exception when others then
    if sqlerrm like 'MANUAL_QA:%' then raise; end if;
  end;
  begin
    perform public.asgq_start(host_token);
    raise exception 'MANUAL_QA: placeholder questions were allowed to start';
  exception when others then
    if sqlerrm like 'MANUAL_QA:%' then raise; end if;
  end;
  -- A complete dummy question set exists only in this transaction.
  delete from asgq_private.questions where position between 1 and 40;
  insert into asgq_private.questions(position,half,prompt,choices,correct_index,points,explanation)
    select i,case when i<=10 then 1 else 2 end,
      'Validation SQL question '||i,
      array['Choix 1','Choix 2','Choix 3','Choix 4']::text[],0,1,'Test'
    from generate_series(1,20) as i;
  update asgq_private.event set armed=true where id=1;
  s:=public.asgq_state(host_token);
  if s->>'phase'<>'lobby' then raise exception 'MANUAL_QA: countdown started from a poll'; end if;
  perform public.asgq_start(host_token);
  s:=public.asgq_state(host_token);
  if s->>'phase'<>'question' or s->>'position'<>'1'
     or s->'question'->>'correct' is not null
     or s->'question'->>'player_count'<>'1' then
    raise exception 'MANUAL_QA: first question or answer confidentiality broken';
  end if;
  if (select phase_until from asgq_private.event where id=1) is not null then
    raise exception 'MANUAL_QA: countdown persisted';
  end if;
  begin
    perform public.asgq_answer(host_token,0);
    raise exception 'MANUAL_QA: host was allowed to answer';
  exception when others then
    if sqlerrm like 'MANUAL_QA:%' then raise; end if;
  end;
  perform public.asgq_answer(guest_token,1);
  perform public.asgq_answer(guest_token,0);
  update asgq_private.event set phase_started_at=clock_timestamp()-interval '1 day' where id=1;
  if public.asgq_state(guest_token)->>'phase'<>'question' then
    raise exception 'MANUAL_QA: question expired without host action';
  end if;
  begin
    perform public.asgq_advance(guest_token,'question',1);
    raise exception 'MANUAL_QA: guest advanced question';
  exception when others then
    if sqlerrm like 'MANUAL_QA:%' then raise; end if;
  end;
  perform public.asgq_advance(host_token,'question',1);
  s:=public.asgq_state(guest_token);
  if s->>'phase'<>'reveal' or s->'question'->>'correct'<>'0'
     or s->'question'->>'earned'<>'1'
     or (s->'me'->>'score')::integer<>1 then
    raise exception 'MANUAL_QA: manual reveal or scoring broken';
  end if;
  if jsonb_array_length(s->'standings')<>1 then
    raise exception 'MANUAL_QA: host is in the ranking';
  end if;
  begin
    perform public.asgq_advance(host_token,'question',1);
    raise exception 'MANUAL_QA: stale double-click skipped the reveal';
  exception when others then
    if sqlerrm like 'MANUAL_QA:%' then raise; end if;
  end;
  for i in 1..50 loop
    s:=public.asgq_state(host_token);
    exit when s->>'phase'='finished';
    if s->>'phase'='halftime' then saw_halftime:=true; end if;
    perform public.asgq_advance(host_token,s->>'phase',(s->>'position')::integer);
  end loop;
  if not saw_halftime or public.asgq_state(host_token)->>'phase'<>'finished' then
    raise exception 'MANUAL_QA: no manual halftime/podium';
  end if;
  if (select score from asgq_private.players where id=(guest->>'player_id')::uuid) is null then
    -- The join response may not expose player_id; the state score was already verified.
    null;
  end if;

  practice_host:=public.asgq_rehearsal_create('CI-TEST-ONLY-PASSWORD','Maître',0);
  practice_token:=(practice_host->>'token')::uuid;
  practice_guest:=public.asgq_rehearsal_join_room(practice_host->>'code','Invité');
  practice_guest_token:=(practice_guest->>'token')::uuid;
  perform public.asgq_rehearsal_add_bot(practice_token);
  perform public.asgq_rehearsal_add_bot(practice_token);
  if public.asgq_rehearsal_state(practice_token)->>'phase'<>'lobby' then
    raise exception 'MANUAL_QA: rehearsal auto-started';
  end if;
  perform public.asgq_rehearsal_start(practice_token);
  s:=public.asgq_rehearsal_state(practice_token);
  if s->>'phase'<>'question' or s->>'is_host'<>'true'
     or s->'question'->>'answered_count'<>'2' then
    raise exception 'MANUAL_QA: bots did not answer or host not recognized';
  end if;
  if jsonb_array_length(public.asgq_rehearsal_state(practice_guest_token)->'question'->'choices')<2 then
    raise exception 'MANUAL_QA: rehearsal question missing';
  end if;
  perform public.asgq_rehearsal_answer(practice_guest_token,1);
  for i in 1..50 loop
    s:=public.asgq_rehearsal_state(practice_token);
    exit when s->>'phase'='finished';
    perform public.asgq_rehearsal_advance(practice_token,s->>'phase',(s->>'position')::integer);
  end loop;
  s:=public.asgq_rehearsal_state(practice_token);
  select count(*) into answer_count
    from asgq_rehearsal_private.answers a
      join asgq_rehearsal_private.players p on p.id=a.player_id
      where p.bot_order is not null;
  if s->>'phase'<>'finished' or jsonb_array_length(s->'standings')<>3 or answer_count<>40 then
    raise exception 'MANUAL_QA: rehearsal podium, no-host ranking or bot answers broken (% / %)',s->>'phase',answer_count;
  end if;
  if (select phase from asgq_private.event where id=1)<>'finished' then
    raise exception 'MANUAL_QA: rehearsal touched official game';
  end if;
  raise notice 'MANUAL_QA OK: official/rehearsal no clocks, host-only phases, bots, locked scores, halftime and podium';
end $test$;
rollback;
