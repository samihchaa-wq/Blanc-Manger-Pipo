-- Real PostgreSQL 29-guest stress *functional* fixture, not a 29-device network load test.
-- This script runs only in the isolated CI database. All writes rolled back.
begin;
do $qa$
declare
  host jsonb;
  joined jsonb;
  room_code text;
  host_token uuid;
  guest_tokens uuid[] := array[]::uuid[];
  state jsonb;
  i integer;
  qcount integer;
  correct_count integer;
  incorrect_count integer;
  no_answer_count integer;
begin
  if (select count(*) from asgq_private.players)<>0 then
    raise exception 'ASGQ_CAPACITY_QA: dirty event';
  end if;
  host:=public.asgq_create('CI-TEST-ONLY-PASSWORD','Animateur');
  host_token:=(host->>'token')::uuid;
  room_code:=host->>'code';
  for i in 1..29 loop
    joined:=public.asgq_join_room(room_code,'Joueur '||i);
    if joined->>'token' is null or joined->>'error' is not null then
      raise exception 'ASGQ_CAPACITY_QA: guest % could not join: %',i,joined;
    end if;
    guest_tokens:=array_append(guest_tokens,(joined->>'token')::uuid);
  end loop;
  state:=public.asgq_state(host_token);
  if (select count(*) from asgq_private.players)<>30
    or jsonb_array_length(state->'players')<>30
    or state->>'is_host'<>'true'
    or (select count(*) from asgq_private.players
        where token_hash <> (select host_token_hash from asgq_private.event where id=1))<>29
  then raise exception 'ASGQ_CAPACITY_QA: 29 guests + 1 host were not preserved'; end if;

  begin
    perform public.asgq_join_room(room_code,'Joueur 30');
    raise exception 'ASGQ_CAPACITY_QA: a 30th guest was accepted';
  exception when others then
    if sqlerrm like 'ASGQ_CAPACITY_QA:%' then raise; end if;
  end;

  delete from asgq_private.questions where id is not null;
  insert into asgq_private.questions(position,half,prompt,choices,correct_index,points,explanation)
    select gs.n,case when gs.n<=10 then 1 else 2 end,'CI capacity question '||gs.n,
      array['A','B','C','D'],0,1,'Exemple privé de test'
    from generate_series(1,20) as gs(n);
  update asgq_private.event set armed=true where id=1;
  if not asgq_private.ready_for_kickoff() then
    raise exception 'ASGQ_CAPACITY_QA: real pack did not pass preflight';
  end if;
  perform public.asgq_start(host_token);
  perform public.asgq_advance(host_token,'intro',0);
  state:=public.asgq_state(host_token);
  if state->>'phase'<>'question' or
     jsonb_array_length(state->'question'->'waiting_players')<>29 then
    raise exception 'ASGQ_CAPACITY_QA: 29 pending names are missing';
  end if;

  for i in 1..20 loop
    perform public.asgq_answer(guest_tokens[i],case when i<=10 then 0 else 1 end);
  end loop;
  state:=public.asgq_state(host_token);
  if jsonb_array_length(state->'question'->'waiting_players')<>9
      or state->'question'->'responses' <> 'null'::jsonb then
    raise exception 'ASGQ_CAPACITY_QA: pending list wrong or outcomes leaked';
  end if;
  perform public.asgq_advance(host_token,'question',1);
  state:=public.asgq_state(host_token);
  if state->>'phase'<>'reveal'
      or jsonb_array_length(state->'standings')<>29
      or jsonb_array_length(state->'question'->'responses')<>29 then
    raise exception 'ASGQ_CAPACITY_QA: missing standings/outcomes';
  end if;
  select
    count(*) filter(where item->>'status'='correct'),
    count(*) filter(where item->>'status'='incorrect'),
    count(*) filter(where item->>'status'='unanswered')
    into correct_count,incorrect_count,no_answer_count
  from jsonb_array_elements(state->'question'->'responses') item;
  if correct_count<>10 or incorrect_count<>10 or no_answer_count<>9 then
    raise exception 'ASGQ_CAPACITY_QA: wrong result split %, %, %',
      correct_count,incorrect_count,no_answer_count;
  end if;
  select count(*) into qcount from asgq_private.players
    where score=1 and token_hash <> (select host_token_hash from asgq_private.event where id=1);
  if qcount<>10 then
    raise exception 'ASGQ_CAPACITY_QA: actual score awards differ from results';
  end if;
  perform public.asgq_advance(host_token,'question',1);
  if (public.asgq_state(host_token)->>'phase')<>'reveal' then
    raise exception 'ASGQ_CAPACITY_QA: stale command skipped the reveal';
  end if;
  raise notice 'ASGQ_CAPACITY_QA: OK — 29 guests, 1 host, 10 correct, 10 incorrect, 9 unanswered, scores consistent';
end $qa$;
rollback;
