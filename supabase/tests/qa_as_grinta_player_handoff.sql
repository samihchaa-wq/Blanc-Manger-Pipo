-- AS Grinta: guest session handoff without identity takeover. All changes rolled back.
begin;
do $qa$
declare
  host jsonb;
  guest jsonb;
  handoff jsonb;
  restored jsonb;
  blocked jsonb;
  host_token uuid;
  guest_token uuid;
  new_token uuid;
  host_id uuid;
  guest_id uuid;
  original_count integer;
  room_code text;
begin
  if (select count(*) from asgq_private.players)<>0 then
    raise exception 'ASGQ_HANDOFF_QA: dirty fixture';
  end if;
  host:=public.asgq_create('CI-TEST-ONLY-PASSWORD','Alban');
  host_token:=(host->>'token')::uuid;
  host_id:=(asgq_private.player_for(host_token)).id;
  room_code:=host->>'code';
  guest:=public.asgq_join_room(room_code,'Camille');
  guest_token:=(guest->>'token')::uuid;
  guest_id:=(asgq_private.player_for(guest_token)).id;
  original_count:=(select count(*) from asgq_private.players);
  update asgq_private.players set score=8 where id=guest_id;
  update asgq_private.event set phase='question',current_position=1 where id=1;

  begin
    perform public.asgq_issue_player_handoff(guest_token,guest_id);
    raise exception 'ASGQ_HANDOFF_QA: a guest issued a handoff code';
  exception when others then
    if sqlerrm like 'ASGQ_HANDOFF_QA:%' then raise; end if;
  end;
  begin
    perform public.asgq_issue_player_handoff(host_token,host_id);
    raise exception 'ASGQ_HANDOFF_QA: host handoff allowed';
  exception when others then
    if sqlerrm like 'ASGQ_HANDOFF_QA:%' then raise; end if;
  end;

  handoff:=public.asgq_issue_player_handoff(host_token,guest_id);
  if handoff->>'name'<>'Camille' or (handoff->>'code') !~ '^[0-9]{8}$' then
    raise exception 'ASGQ_HANDOFF_QA: handoff code format incorrect';
  end if;
  blocked:=public.asgq_claim_player_handoff(room_code,'Camille','999999999');
  if blocked->>'token' is not null or blocked->>'error' is null then
    raise exception 'ASGQ_HANDOFF_QA: incorrect code accepted';
  end if;
  if (asgq_private.player_for(guest_token)).id is distinct from guest_id then
    raise exception 'ASGQ_HANDOFF_QA: incorrect code revoked session';
  end if;

  restored:=public.asgq_claim_player_handoff(
    room_code,'Camille',handoff->>'code');
  if restored->>'name'<>'Camille' or restored->>'token' is null then
    raise exception 'ASGQ_HANDOFF_QA: correct handoff failed';
  end if;
  new_token:=(restored->>'token')::uuid;
  if guest_token=new_token
      or (asgq_private.player_for(guest_token)).id is not null
      or (asgq_private.player_for(new_token)).id is distinct from guest_id then
    raise exception 'ASGQ_HANDOFF_QA: old guest token was not rotated';
  end if;
  if (select count(*) from asgq_private.players)<>original_count
      or (select score from asgq_private.players where id=guest_id)<>8
      or (select phase from asgq_private.event where id=1)<>'question'
      or (asgq_private.player_for(host_token)).id is distinct from host_id
      or public.asgq_state(new_token)->>'is_host'<>'false' then
    raise exception 'ASGQ_HANDOFF_QA: state, score, host or player count changed';
  end if;
  blocked:=public.asgq_claim_player_handoff(room_code,'Camille',handoff->>'code');
  if blocked->>'token' is not null then
    raise exception 'ASGQ_HANDOFF_QA: one-time code was reused';
  end if;

  handoff:=public.asgq_issue_player_handoff(host_token,guest_id);
  update asgq_private.player_handoffs
     set expires_at=clock_timestamp()-interval '1 minute' where player_id=guest_id;
  blocked:=public.asgq_claim_player_handoff(room_code,'Camille',handoff->>'code');
  if blocked->>'token' is not null then
    raise exception 'ASGQ_HANDOFF_QA: expired code was accepted';
  end if;
  if (asgq_private.player_for(new_token)).id is distinct from guest_id then
    raise exception 'ASGQ_HANDOFF_QA: expired code invalidated a valid token';
  end if;
  raise notice 'ASGQ_HANDOFF_QA: OK — host-only issue, one-time code, no score loss';
end $qa$;
rollback;
