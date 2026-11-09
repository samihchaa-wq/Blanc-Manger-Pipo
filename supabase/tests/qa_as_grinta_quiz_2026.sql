-- Host-driven official quiz, all mutations rolled back.
begin;
do $qa$
declare
  creator jsonb; guest jsonb; s jsonb; g jsonb;
  host_token uuid; guest_token uuid; code text;
  steps integer; saw_halftime boolean:=false;
begin
  if (select count(*) from asgq_private.players)<>0 then raise exception 'ASGQ_QA: dirty fixture'; end if;
  creator:=public.asgq_create('CI-TEST-ONLY-PASSWORD','Alban');
  host_token:=(creator->>'token')::uuid;
  code:=creator->>'code';
  guest:=public.asgq_join_room(code,'Camille');
  guest_token:=(guest->>'token')::uuid;
  s:=public.asgq_state(host_token);
  if s->>'phase'<>'lobby' or s->>'is_host'<>'true' or s->>'ready'<>'false' then
    raise exception 'ASGQ_QA: host identity or placeholder guard broken'; end if;
  if public.asgq_state(guest_token)->>'is_host'<>'false' then raise exception 'ASGQ_QA: guest is host'; end if;
  begin
    perform public.asgq_start(guest_token);
    raise exception 'ASGQ_QA: guest started the quiz';
  exception when others then if sqlerrm like 'ASGQ_QA:%' then raise; end if; end;
  update asgq_private.event set armed=true where id=1;
  begin
    perform public.asgq_start(host_token);
    raise exception 'ASGQ_QA: placeholder questions were playable';
  exception when others then if sqlerrm like 'ASGQ_QA:%' then raise; end if; end;
  delete from asgq_private.questions where id is not null;
  insert into asgq_private.questions(position,half,prompt,choices,correct_index,points,explanation)
    select i,case when i<=10 then 1 else 2 end,'Validation SQL question '||i,
      array['A '||i,'B '||i,'C '||i,'D '||i],0,1,'Explication SQL '||i
    from generate_series(1,20) i;
  if not asgq_private.ready_for_kickoff() then raise exception 'ASGQ_QA: questions not ready'; end if;
  perform public.asgq_state(guest_token);
  perform public.asgq_state(guest_token);
  if (select phase from asgq_private.event where id=1)<>'lobby' then
    raise exception 'ASGQ_QA: polling auto-started the quiz'; end if;
  perform public.asgq_start(host_token);
  s:=public.asgq_state(host_token);
  if s->>'phase'<>'intro' or s->>'phase_until' is not null or s->>'starts_at' is not null then
    raise exception 'ASGQ_QA: kickoff has a deadline'; end if;
  begin
    perform public.asgq_advance(guest_token,'intro',0);
    raise exception 'ASGQ_QA: guest advanced the quiz';
  exception when others then if sqlerrm like 'ASGQ_QA:%' then raise; end if; end;
  perform public.asgq_advance(host_token,'intro',0);
  s:=public.asgq_state(host_token);
  if s->>'phase'<>'question' or s->'question'->>'correct' is not null then
    raise exception 'ASGQ_QA: answer leaked before reveal'; end if;
  begin
    perform public.asgq_answer(host_token,0);
    raise exception 'ASGQ_QA: host submitted an answer';
  exception when others then if sqlerrm like 'ASGQ_QA:%' then raise; end if; end;
  perform public.asgq_answer(guest_token,1);
  perform public.asgq_answer(guest_token,0);
  perform public.asgq_state(guest_token);
  if (select phase from asgq_private.event where id=1)<>'question' then
    raise exception 'ASGQ_QA: polling closed an answer'; end if;
  perform public.asgq_advance(host_token,'question',1);
  g:=public.asgq_state(guest_token);
  if g->>'phase'<>'reveal' or (g->'me'->>'score')::integer<>1
    or (g->'question'->>'correct')::integer<>0 or jsonb_array_length(g->'standings')<>1 then
    raise exception 'ASGQ_QA: reveal, scoring or host exclusion failed'; end if;
  perform public.asgq_advance(host_token,'question',1);
  if (public.asgq_state(host_token)->>'phase')<>'reveal' then
    raise exception 'ASGQ_QA: duplicate request skipped a phase'; end if;
  begin
    perform public.asgq_answer(guest_token,1);
    raise exception 'ASGQ_QA: answer accepted after reveal';
  exception when others then if sqlerrm like 'ASGQ_QA:%' then raise; end if; end;
  for steps in 1..65 loop
    s:=public.asgq_state(host_token);
    exit when s->>'phase'='finished';
    if s->>'phase'='halftime' then
      saw_halftime:=true;
      perform public.asgq_state(guest_token);
      if (public.asgq_state(host_token)->>'phase')<>'halftime' then
        raise exception 'ASGQ_QA: halftime advanced without host'; end if;
    end if;
    perform public.asgq_advance(host_token,s->>'phase',(s->>'position')::integer);
  end loop;
  s:=public.asgq_state(host_token);
  if not saw_halftime or s->>'phase'<>'finished' or jsonb_array_length(s->'standings')<>1 then
    raise exception 'ASGQ_QA: no halftime or podium'; end if;
  if (public.asgq_state(guest_token)->'me'->>'score')::integer<>1 then
    raise exception 'ASGQ_QA: duplicate points awarded'; end if;
  raise notice 'ASGQ_QA: OK — host only, no deadlines, secret answers, manual 2x10, podium';
end $qa$;
rollback;
