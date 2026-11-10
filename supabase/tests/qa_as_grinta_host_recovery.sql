-- Isolated transaction: Admin+ host recovery must never create another participant.
begin;
do $qa$
declare
  original jsonb;
  guest jsonb;
  recovered jsonb;
  attempt jsonb;
  host_token uuid;
  new_token uuid;
  guest_token uuid;
  host_id uuid;
  first_phase text;
  first_code text;
begin
  if (select count(*) from asgq_private.players)<>0 then
    raise exception 'ASGQ_RECOVERY_QA: fixture already contains players';
  end if;
  original:=public.asgq_create('CI-TEST-ONLY-PASSWORD','Alban');
  host_token:=(original->>'token')::uuid;
  host_id:=(asgq_private.player_for(host_token)).id;
  first_code:=original->>'code';
  guest:=public.asgq_join_room(first_code,'Camille');
  guest_token:=(guest->>'token')::uuid;
  first_phase:=(select phase from asgq_private.event where id=1);
  update asgq_private.players set score=7 where id=host_id;

  attempt:=public.asgq_recover_host('incorrect');
  if attempt->>'error'<>'Mot de passe Admin+ incorrect.' then
    raise exception 'ASGQ_RECOVERY_QA: invalid Admin+ should fail';
  end if;
  if public.asgq_state(host_token)->>'is_host'<>'true' then
    raise exception 'ASGQ_RECOVERY_QA: wrong password revoked valid host';
  end if;

  recovered:=public.asgq_recover_host('CI-TEST-ONLY-PASSWORD');
  if recovered->>'name'<>'Alban' or recovered->>'code'<>first_code
      or recovered->>'token' is null then
    raise exception 'ASGQ_RECOVERY_QA: recovery did not restore original host';
  end if;
  new_token:=(recovered->>'token')::uuid;
  if host_token=new_token then
    raise exception 'ASGQ_RECOVERY_QA: recovery did not rotate token';
  end if;
  if (asgq_private.player_for(host_token)).id is not null then
    raise exception 'ASGQ_RECOVERY_QA: old host token still active';
  end if;
  if (asgq_private.player_for(new_token)).id is distinct from host_id
      or public.asgq_state(new_token)->>'is_host'<>'true' then
    raise exception 'ASGQ_RECOVERY_QA: new token not mapped to the original host';
  end if;
  if (select count(*) from asgq_private.players)<>2
      or (select score from asgq_private.players where id=host_id)<>7
      or (select phase from asgq_private.event where id=1)<>first_phase
      or public.asgq_state(guest_token)->'me'->>'name'<>'Camille' then
    raise exception 'ASGQ_RECOVERY_QA: recovery changed players, phase or score';
  end if;

  -- Five attempts allowed within the window; the sixth must be blocked.
  perform public.asgq_recover_host('incorrect');
  perform public.asgq_recover_host('incorrect');
  perform public.asgq_recover_host('incorrect');
  attempt:=public.asgq_recover_host('CI-TEST-ONLY-PASSWORD');
  if attempt->>'error' not like 'Trop de tentatives%' then
    raise exception 'ASGQ_RECOVERY_QA: rate limit did not block the sixth attempt';
  end if;
  if public.asgq_state(new_token)->>'is_host'<>'true' then
    raise exception 'ASGQ_RECOVERY_QA: blocked attempt modified host';
  end if;
  raise notice 'ASGQ_RECOVERY_QA: OK — Admin+, rate limit, token rotation, stable scores';
end $qa$;
rollback;
