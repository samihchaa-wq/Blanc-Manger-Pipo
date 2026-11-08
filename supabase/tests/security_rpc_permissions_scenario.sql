-- Tests de non-régression des autorisations sur la vraie logique Supabase.
-- À lancer en transaction : les salons, votes et rôles de test sont annulés.
begin;

do $auth$
declare
  host_room json; guest_a json; guest_b json; other_room json;
  code1 text; code2 text;
  th uuid; ta uuid; tb uuid; tother uuid;
  h_id uuid; before_count integer; after_count integer;
  ws json;
begin
  host_room := public.create_room('Audit Hôte', 1, 'white', 1);
  code1 := host_room->>'code';
  th := (host_room->>'token')::uuid;
  h_id := (host_room->>'player_id')::uuid;
  guest_a := public.join_room(code1, 'Audit Alice');
  guest_b := public.join_room(code1, 'Audit Bob');
  ta := (guest_a->>'token')::uuid;
  tb := (guest_b->>'token')::uuid;

  other_room := public.create_room('Audit Autre',1,'phrases',1);
  code2 := other_room->>'code';
  tother := (other_room->>'token')::uuid;

  -- La possession d'un code, sans son jeton, ne donne accès à aucun état.
  begin
    perform public.get_full_state(code1, tother);
    raise exception 'TEST_PERMISSIONS : accès au salon avec le jeton d’un autre';
  exception when others then
    if sqlerrm like 'TEST_PERMISSIONS%' then raise; end if;
    if sqlerrm not like '%Session expirée%' then
      raise exception 'Erreur inattendue get_full_state : %', sqlerrm;
    end if;
  end;

  begin
    perform public.get_state(code2, ta);
    raise exception 'TEST_PERMISSIONS : accès à un autre salon avec son jeton';
  exception when others then
    if sqlerrm like 'TEST_PERMISSIONS%' then raise; end if;
    if sqlerrm not like '%Session expirée%' then
      raise exception 'Erreur inattendue get_state : %', sqlerrm;
    end if;
  end;

  -- Un invité ne peut ni expulser l'hôte ni démarrer la partie.
  select count(*) into before_count from public.players p
  where p.room_id = (select id from public.rooms where code=code1) and p.active;
  begin
    perform public.kick_player(code1, ta, h_id);
    raise exception 'TEST_PERMISSIONS : invité autorisé à expulser';
  exception when others then
    if sqlerrm like 'TEST_PERMISSIONS%' then raise; end if;
    if sqlerrm not like '%Seul l%hôte%' then
      raise exception 'Erreur inattendue kick_player : %', sqlerrm;
    end if;
  end;

  begin
    perform public.lancer_partie(code1, ta);
    raise exception 'TEST_PERMISSIONS : invité autorisé à démarrer';
  exception when others then
    if sqlerrm like 'TEST_PERMISSIONS%' then raise; end if;
    if sqlerrm not like '%Seul l%hôte%' then
      raise exception 'Erreur inattendue lancer_partie : %', sqlerrm;
    end if;
  end;

  select count(*) into after_count from public.players p
  where p.room_id = (select id from public.rooms where code=code1) and p.active;
  if before_count <> after_count then
    raise exception 'TEST_PERMISSIONS : joueur désactivé malgré un refus';
  end if;

  -- Secret Mr White : l'état des invités ne révèle ni l'équipe des autres
  -- ni les mots adverses avant la phase de révélation.
  perform public.lancer_partie(code1, th);
  ws := public.white_state(code1, ta);
  if ws->>'civil_word' is not null or ws->>'undercover_word' is not null then
    raise exception 'TEST_PERMISSIONS : mots des équipes divulgués';
  end if;
  if exists (
    select 1 from json_array_elements(ws->'roles') x
    where x->>'role' is not null and coalesce((x->>'out')::boolean,false)=false
  ) then
    raise exception 'TEST_PERMISSIONS : rôle encore secret divulgué';
  end if;

  begin
    perform public.white_open_vote(code1, ta);
    raise exception 'TEST_PERMISSIONS : invité peut ouvrir le vote';
  exception when others then
    if sqlerrm like 'TEST_PERMISSIONS%' then raise; end if;
    if sqlerrm not like '%Seul l%hôte%' then
      raise exception 'Erreur inattendue white_open_vote : %', sqlerrm;
    end if;
  end;

  if exists(
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace
      and p.proname like '\_%' escape '\'
      and p.prosecdef and has_function_privilege('anon',p.oid,'EXECUTE')
  ) then
    raise exception 'TEST_PERMISSIONS : une fonction interne privilégiée est exécutable anonymement';
  end if;
end $auth$;

rollback;
