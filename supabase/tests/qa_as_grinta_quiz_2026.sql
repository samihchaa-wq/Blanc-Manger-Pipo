-- Grand Quiz AS Grinta: transaction-scoped full-game rehearsal.
-- All players, changes, scores and phase transitions are rolled back.
begin;
do $qa$
declare
  invite text;
  alpha jsonb; beta jsonb; s jsonb; other_state jsonb;
  ta uuid; tb uuid; phase_name text;
  steps integer; saw_halftime boolean := false; saw_finish boolean := false;
begin
  if (select count(*) from asgq_private.players) <> 0 then
    raise exception 'ASGQ_QA: do not run rehearsal with existing participants';
  end if;
  select plaintext_code into invite from asgq_private.invitation where event_id=1;
  if invite is null then raise exception 'ASGQ_QA: no invitation code installed'; end if;

  -- The false event code cannot create a participant.
  begin
    perform public.asgq_join('WRONG-CODE', 'Intrus');
    raise exception 'ASGQ_QA: wrong code accepted';
  exception when others then
    if sqlerrm like 'ASGQ_QA:%' then raise; end if;
    if sqlerrm not like '%Code d’entrée incorrect%' then raise exception 'ASGQ_QA: bad-code error: %',sqlerrm; end if;
  end;

  -- An even armed event must never start on the four example questions.
  update asgq_private.event set armed=true where id=1;
  alpha := public.asgq_join(invite,'Alpha');
  beta := public.asgq_join(invite,'Bravo');
  ta := (alpha->>'token')::uuid; tb := (beta->>'token')::uuid;
  s := public.asgq_state(ta);
  if s->>'phase'<>'lobby' or s->>'ready'<>'false' or s->>'starts_at' is not null then
    raise exception 'ASGQ_QA: placeholder questions started a game';
  end if;
  begin
    perform public.asgq_join(invite,'alpha');
    raise exception 'ASGQ_QA: duplicate name accepted';
  exception when others then
    if sqlerrm like 'ASGQ_QA:%' then raise; end if;
  end;

  -- Build a valid, contiguous 10 + 10 question pack only for this transaction.
  delete from asgq_private.questions;
  insert into asgq_private.questions(position,half,prompt,choices,correct_index,points,explanation)
    select i, case when i <= 10 then 1 else 2 end, 'Validation SQL question '||i,
      array['A '||i,'B '||i,'C '||i,'D '||i],0,1,'Explication SQL '||i
    from generate_series(1,20) i;

  s := public.asgq_state(ta);
  if s->>'ready'<>'true' or s->>'starts_at' is null then
    raise exception 'ASGQ_QA: 10 + 10 valid questions did not arm countdown';
  end if;

  -- The identity of later questions and their answer keys remain private.
  if s->>'question' is not null or s->>'total'<>'20' then
    raise exception 'ASGQ_QA: secret questions exposed in lobby';
  end if;
  if has_schema_privilege('anon','asgq_private','USAGE') then
    raise exception 'ASGQ_QA: private schema exposed';
  end if;

  update asgq_private.event set starts_at=clock_timestamp()-interval '1 second' where id=1;
  s := public.asgq_state(ta);
  if s->>'phase'<>'intro' then raise exception 'ASGQ_QA: missing kickoff intro'; end if;
  begin
    perform public.asgq_join(invite,'Charlie');
    raise exception 'ASGQ_QA: late entrant accepted';
  exception when others then
    if sqlerrm like 'ASGQ_QA:%' then raise; end if;
    if sqlerrm not like '%déjà commencé%' then raise exception 'ASGQ_QA: late join error: %',sqlerrm; end if;
  end;

  -- Reconnection remains permitted for an existing participant.
  if (public.asgq_join('', '',ta)->>'token')::uuid <> ta then
    raise exception 'ASGQ_QA: reconnect failed';
  end if;

  update asgq_private.event set phase_until=clock_timestamp()-interval '1 second' where id=1;
  s := public.asgq_state(ta);
  if s->>'phase'<>'question' or s->'question'->>'correct' is not null
      or s->'question'->>'explanation' is not null
      or s->'standings' is not null then
    raise exception 'ASGQ_QA: question secrets or standings leaked';
  end if;

  -- Alpha changes their choice before the deadline; Bravo is incorrect.
  perform public.asgq_answer(ta,1);
  perform public.asgq_answer(ta,0);
  perform public.asgq_answer(tb,1);
  update asgq_private.event set phase_until=clock_timestamp()-interval '1 second' where id=1;
  s := public.asgq_state(ta);
  other_state := public.asgq_state(tb);
  if s->>'phase'<>'reveal' or (s->'me'->>'score')::integer <> 1
     or (other_state->'me'->>'score')::integer <> 0
     or (s->'question'->>'correct')::integer <> 0
     or (s->'question'->>'earned')::integer <> 1 then
    raise exception 'ASGQ_QA: reveal or answer-change scoring incorrect';
  end if;
  perform public.asgq_state(ta);
  if (public.asgq_state(ta)->'me'->>'score')::integer <> 1 then
    raise exception 'ASGQ_QA: duplicate points after polling';
  end if;

  -- Progress the remaining 19 questions automatically, through halftime.
  for steps in 1..65 loop
    select phase into phase_name from asgq_private.event where id=1;
    exit when phase_name='finished';
    update asgq_private.event set phase_until=clock_timestamp()-interval '1 second' where id=1;
    s := public.asgq_state(ta);
    if s->>'phase'='halftime' then saw_halftime:=true; end if;
    if s->>'phase'='finished' then saw_finish:=true; end if;
  end loop;
  if not saw_halftime or not saw_finish then
    raise exception 'ASGQ_QA: no halftime or finish';
  end if;
  if (s->'me'->>'score')::integer <> 1
      or jsonb_array_length(s->'standings')<>2 then
    raise exception 'ASGQ_QA: final scoring or podium incorrect';
  end if;
  raise notice 'ASGQ_QA: OK — lock, 20 questions, privacy, reconnection, halftime, score and podium';
end $qa$;
rollback;
