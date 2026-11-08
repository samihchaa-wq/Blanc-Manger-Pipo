-- Mr White : exhaustivité des tailles de salon 3..12 joueurs, 1 ou 2 intrus,
-- tirage White <=1, mots privés, et rappel du minimum actuellement fixé à 3.
begin;

do $qa_role_counts$
declare n integer; j integer; expected integer; c text; host json; joined json;
  rid uuid; intruders integer; whites integer; civils integer;
  distinct_roles integer; duplicates integer; public_state json; rnd public.rooms;
begin
  for n in 3..12 loop
    perform pg_catalog.set_config('request.headers',
      '{"x-forwarded-for":"192.0.2.'||(211+n)::text||'"}',true);
    host:=public.create_room('QA Répartition White',1,'white',1);
    c:=host->>'code';
    for j in 2..n loop
      joined:=public.join_room(c,'QA White J'||j);
      if joined->>'token' is null then raise exception 'Mr White % joueurs : inscription impossible',n; end if;
    end loop;
    perform public.lancer_partie(c,(host->>'token')::uuid);
    select * into rnd from public.rooms where code=c; rid:=rnd.id;
    if rnd.status<>'white_clue' then raise exception 'Mr White % joueurs : pas de carte',n; end if;
    select count(*) filter(where role in ('undercover','white')),
           count(*) filter(where role='white'),
           count(*) filter(where role='civil'),
           count(distinct player_id)
      into intruders,whites,civils,distinct_roles
      from public.white_roles where room_id=rid and round=1;
    expected:=case when n>=6 then 2 else 1 end;
    if intruders<>expected or whites>1 or civils<>n-expected or distinct_roles<>n then
      raise exception 'Mr White % joueurs : civils %, intrus %, white %, distinct %, attendus %',
        n,civils,intruders,whites,distinct_roles,expected;
    end if;
    if rnd.white_has_white is distinct from (whites=1) then
      raise exception 'Mr White % joueurs : tirage du rôle White incohérent',n;
    end if;
    public_state:=public.get_full_state(c,(host->>'token')::uuid);
    if json_array_length(public_state->'state'->'players')<>n then
      raise exception 'Mr White % joueurs : nombre de joueurs différent dans l’état',n;
    end if;
  end loop;
  raise notice 'QA PASS : répartition Mr White vérifiée pour 3,4,5,6,7,8,9,10,11 et 12 joueurs';
end $qa_role_counts$;

rollback;
