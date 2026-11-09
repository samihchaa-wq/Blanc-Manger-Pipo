-- Grand Quiz AS Grinta: transaction-scoped manual master-of-game QA.
-- Never run with official participants; every change rolls back.
begin;
do $qa$
declare
  invite text;
  host jsonb; guest jsonb; s jsonb; other_state jsonb;
  th uuid; tg uuid;
  idx integer;
  saw_halftime boolean := false;
  saw_finish boolean := false;
begin
  if (select count(*) from asgq_private.players)<>0 then
    raise exception 'ASGQ_QA: do not run with existing official participants';
  end if;
  select plaintext_code into invite from asgq_private.invitation where event_id=1;
  if invite is null then raise exception 'ASGQ_QA: private invitation code not installed'; end if;
  begin
    perform public.asgq_join('WRONG-CODE','Intrus');
    raise exception 'ASGQ_QA: incorrect code accepted';
  exception when others then
    if sqlerrm like 'ASGQ_QA:%' then raise; end if;
    if sqlerrm not like '%Code d’entrée incorrect%' then raise exception 'ASGQ_QA: wrong code error: %',sqlerrm; end if;
  end;

  update asgq_private.event set armed=true,created=true,room_code='12345678' where id=1;
  host := public.asgq_join(invite,'Alpha');
  guest := public.asgq_join(invite,'Bravo');
  th := (host->>'token')::uuid;
  tg := (guest->>'token')::uuid;
  update asgq_private.event set host_token_hash=
    (select token_hash from asgq_private.players where name='Alpha') where id=1;
  s:=public.asgq_state(th);
  if s->>'phase'<>'lobby' or s->>'ready'<>'false' or s->>'starts_at' is not null then
    raise exception 'ASGQ_QA: placeholder questions opened the event';
  end if;
  begin
    perform public.asgq_start(th);
    raise exception 'ASGQ_QA: incomplete event started';
  exception when others then
    if sqlerrm like 'ASGQ_QA:%' then raise; end if;
    if sqlerrm not like '%deux mi-temps ne sont pas prêtes%' then raise exception 'ASGQ_QA: wrong preflight response: %',sqlerrm; end if;
  end;
  delete from asgq_private.questions;
  insert into asgq_private.questions(position,half,prompt,choices,correct_index,points,explanation)
    select i,case when i<=10 then 1 else 2 end,'Validation SQL question '||i,
      array['A '||i,'B '||i,'C '||i,'D '||i],0,1,'Explication SQL '||i
    from generate_series(1,20) i;
  s:=public.asgq_state(th);
  if s->>'ready'<>'true' or s->>'starts_at' is not null or s->>'phase'<>'lobby' or s->>'is_host'<>'true' then
    raise exception 'ASGQ_QA: ready event auto-started or master not recognized';
  end if;
  if (public.asgq_state(tg)->>'is_host')<>'false' then raise exception 'ASGQ_QA: guest received host role'; end if;
  if has_schema_privilege('anon','asgq_private','USAGE') then raise exception 'ASGQ_QA: private schema exposed'; end if;
  begin
    perform public.asgq_start(tg);
    raise exception 'ASGQ_QA: guest started event';
  exception when others then
    if sqlerrm like 'ASGQ_QA:%' then raise; end if;
    if sqlerrm not like '%maître du jeu%' then raise; end if;
  end;
  perform public.asgq_start(th);
  s:=public.asgq_state(th);
  if s->>'phase'<>'intro' or s->>'phase_until' is not null then
    raise exception 'ASGQ_QA: no manual untimed intro';
  end if;
  begin
    perform public.asgq_join(invite,'Charlie');
    raise exception 'ASGQ_QA: late entrant accepted';
  exception when others then
    if sqlerrm like 'ASGQ_QA:%' then raise; end if;
    if sqlerrm not like '%déjà commencé%' then raise; end if;
  end;
  if (public.asgq_join('','',th)->>'token')::uuid<>th then
    raise exception 'ASGQ_QA: master reconnection failed';
  end if;
  begin
    perform public.asgq_next(tg);
    raise exception 'ASGQ_QA: guest advanced event';
  exception when others then
    if sqlerrm like 'ASGQ_QA:%' then raise; end if;
  end;
  perform public.asgq_next(th);
  s:=public.asgq_state(tg);
  if s->>'phase'<>'question' or s->'question'->>'correct' is not null
    or s->>'phase_until' is not null or s->>'standings' is not null then
    raise exception 'ASGQ_QA: question timed or answer leaked';
  end if;
  begin
    perform public.asgq_answer(th,0);
    raise exception 'ASGQ_QA: host answered';
  exception when others then
    if sqlerrm like 'ASGQ_QA:%' then raise; end if;
  end;
  perform public.asgq_answer(tg,1);
  perform public.asgq_answer(tg,0);
  s:=public.asgq_state(tg);
  if s->>'phase'<>'question' or s->'question'->>'my_choice'<>'0' then
    raise exception 'ASGQ_QA: question closed without host or answer edit failed';
  end if;
  perform public.asgq_next(th);
  s:=public.asgq_state(tg);
  other_state:=public.asgq_state(th);
  if s->>'phase'<>'reveal' or (s->'me'->>'score')::int<>1
    or (s->'question'->>'correct')::int<>0
    or jsonb_array_length(s->'standings')<>1
    or (other_state->'me'->>'score')::int<>0 then
    raise exception 'ASGQ_QA: reveal, host exclusion or scoring invalid';
  end if;
  perform public.asgq_state(tg);
  if (public.asgq_state(tg)->'me'->>'score')::int<>1 then
    raise exception 'ASGQ_QA: duplicate score on repeated read';
  end if;

  for idx in 1..80 loop
    exit when (select phase from asgq_private.event where id=1)='finished';
    perform public.asgq_next(th);
    s:=public.asgq_state(tg);
    if s->>'phase'='halftime' then saw_halftime:=true; end if;
    if s->>'phase'='finished' then saw_finish:=true; end if;
    if s->>'phase' not in ('finished','halftime') and s->>'phase_until' is not null then
      raise exception 'ASGQ_QA: unexpected phase deadline';
    end if;
  end loop;
  if not saw_halftime or not saw_finish then raise exception 'ASGQ_QA: no manual halftime or podium'; end if;
  if jsonb_array_length(s->'standings')<>1 or (s->'me'->>'score')::int<>1 then
    raise exception 'ASGQ_QA: final ranking invalid';
  end if;
  raise notice 'ASGQ_QA OK: master-only manual flow, untimed answers, 2x10, scoring, privacy, halftime, podium';
end $qa$;
rollback;
