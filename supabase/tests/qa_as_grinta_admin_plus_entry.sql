-- Separate transactional verification of AS Grinta create vs join.
-- The Admin+ password below exists only in the isolated CI fixture.
begin;
do $qa$
declare
  creator jsonb;
  guest jsonb;
  rejected jsonb;
  token_one uuid;
  token_two uuid;
  room_code text;
  i integer;
begin
  if has_function_privilege('anon','public.asgq_join_admin_plus(text,text)','EXECUTE')
     or has_function_privilege('anon','public.asgq_join(text,text,uuid)','EXECUTE') then
    raise exception 'ASGQ_ADMIN_QA: obsolete entry methods remain public';
  end if;
  if not has_function_privilege('anon','public.asgq_create(text,text)','EXECUTE')
     or not has_function_privilege('anon','public.asgq_join_room(text,text)','EXECUTE') then
    raise exception 'ASGQ_ADMIN_QA: expected create/join RPC permissions missing';
  end if;
  if (select count(*) from asgq_private.players) <> 0 then
    raise exception 'ASGQ_ADMIN_QA: existing players in CI fixture';
  end if;

  -- Nobody can join until an authorized host creates the only room.
  rejected := public.asgq_join_room('00000000','Avant');
  if rejected->>'error' not like '%pas encore été créée%' then
    raise exception 'ASGQ_ADMIN_QA: allowed join before creation: %',rejected;
  end if;
  begin
    perform public.asgq_create('WRONG-PASSWORD','Intrus');
    raise exception 'ASGQ_ADMIN_QA: wrong Admin+ password admitted';
  exception when others then
    if sqlerrm like 'ASGQ_ADMIN_QA:%' then raise; end if;
    if sqlerrm not like '%Mot de passe Admin+ incorrect%' then
      raise exception 'ASGQ_ADMIN_QA: unexpected error: %',sqlerrm;
    end if;
  end;
  if (select count(*) from asgq_private.players) <> 0 then
    raise exception 'ASGQ_ADMIN_QA: wrong Admin+ password created a player';
  end if;

  creator := public.asgq_create('CI-TEST-ONLY-PASSWORD','Alban');
  room_code := creator->>'code';
  token_one := (creator->>'token')::uuid;
  if room_code !~ '^[0-9]{8}$' or token_one is null then
    raise exception 'ASGQ_ADMIN_QA: invalid room creation result: %', creator;
  end if;
  if (select count(*) from asgq_private.players)<>1 then
    raise exception 'ASGQ_ADMIN_QA: host not part of the game';
  end if;
  if (public.asgq_state(token_one)->>'room_code') <> room_code then
    raise exception 'ASGQ_ADMIN_QA: room code not shared by server state';
  end if;
  begin
    perform public.asgq_create('CI-TEST-ONLY-PASSWORD','SecondHost');
    raise exception 'ASGQ_ADMIN_QA: a second quiz was created';
  exception when others then
    if sqlerrm like 'ASGQ_ADMIN_QA:%' then raise; end if;
    if sqlerrm not like '%existe déjà%' then
      raise exception 'ASGQ_ADMIN_QA: second create error: %',sqlerrm;
    end if;
  end;
  rejected := public.asgq_join_room('00000000','Intrus');
  if rejected->>'error' not like '%Code de partie incorrect%' then
    raise exception 'ASGQ_ADMIN_QA: wrong 8-digit code admitted';
  end if;
  guest := public.asgq_join_room(room_code,'Camille');
  token_two := (guest->>'token')::uuid;
  if token_two is null or guest->>'code' <> room_code then
    raise exception 'ASGQ_ADMIN_QA: failed guest join without Admin+: %',guest;
  end if;
  if (public.asgq_state(token_two)->'me'->>'name') <> 'Camille' then
    raise exception 'ASGQ_ADMIN_QA: second player state missing';
  end if;
  if (select count(*) from asgq_private.players)<>2 then
    raise exception 'ASGQ_ADMIN_QA: expected exactly host + guest';
  end if;
  -- A whole football squad may share one public IP behind the clubhouse Wi-Fi.
  -- All 30 players must be able to join using the exact same code/client hash.
  for i in 3..30 loop
    guest := public.asgq_join_room(room_code,'Grinta_'||i);
    if guest->>'token' is null then
      raise exception 'ASGQ_ADMIN_QA: player % blocked on shared Wi-Fi: %',i,guest;
    end if;
  end loop;
  if (select count(*) from asgq_private.players)<>30 then
    raise exception 'ASGQ_ADMIN_QA: a full 30-player roster cannot join';
  end if;
  if (select failures from asgq_private.join_attempts where client_hash='grinta-ci-user') <> 1 then
    raise exception 'ASGQ_ADMIN_QA: failed code attempts were not counted';
  end if;
  if (select starts_at is not null from asgq_private.event where id=1) then
    raise exception 'ASGQ_ADMIN_QA: placeholder questions auto-started';
  end if;
  raise notice 'ASGQ_ADMIN_QA: OK (Admin+ creates once, guests join by 8-digit code, no early start)';
end $qa$;
rollback;
