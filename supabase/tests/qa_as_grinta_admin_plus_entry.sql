-- Test d'intégration du mot de passe Admin+ sur une base PostgreSQL de CI.
-- Le véritable mot de passe Admin+ n'est jamais lu, utilisé ou exposé.
begin;
do $qa$
declare
  joined jsonb;
  player_token uuid;
begin
  if has_function_privilege('anon','public.asgq_join(text,text,uuid)','EXECUTE') then
    raise exception 'ASGQ_ADMIN_QA: old invite code still publicly executable';
  end if;
  if not has_function_privilege('anon','public.asgq_join_admin_plus(text,text)','EXECUTE') then
    raise exception 'ASGQ_ADMIN_QA: Admin+ entry inaccessible';
  end if;
  if not (select count(*)=0 from asgq_private.players) then
    raise exception 'ASGQ_ADMIN_QA: test base not empty';
  end if;
  begin
    perform public.asgq_join_admin_plus('BAD-TEST-PASSWORD', 'Intrus');
    raise exception 'ASGQ_ADMIN_QA: invalid password admitted';
  exception when others then
    if sqlerrm like 'ASGQ_ADMIN_QA:%' then raise; end if;
    if sqlerrm not like '%Mot de passe Admin+ incorrect%' then
      raise exception 'ASGQ_ADMIN_QA: unexpected invalid-password error: %', sqlerrm;
    end if;
  end;
  if (select count(*) from asgq_private.players) <> 0 then
    raise exception 'ASGQ_ADMIN_QA: invalid password created a player';
  end if;
  joined := public.asgq_join_admin_plus('CI-TEST-ONLY-PASSWORD', 'Alban');
  player_token := (joined->>'token')::uuid;
  if player_token is null then
    raise exception 'ASGQ_ADMIN_QA: valid password did not yield a token';
  end if;
  if (public.asgq_state(player_token)->'me'->>'name') <> 'Alban' then
    raise exception 'ASGQ_ADMIN_QA: invalid session';
  end if;
  if (select count(*) from asgq_private.players) <> 1 then
    raise exception 'ASGQ_ADMIN_QA: unexpected player count';
  end if;
  raise notice 'ASGQ_ADMIN_QA: OK (wrong password rejected, correct password joins, code unavailable)';
end $qa$;
rollback;
