-- Mr White : confidentialité, répartition, autorisations, vote, égalité/départ.
-- Six vrais jetons de joueurs, 100% rollback.
begin;
select pg_catalog.set_config('request.headers','{"x-forwarded-for":"192.0.2.183"}',true);

do $qa_white$
declare
  h json; guest json; code_salon text; host_id uuid; host_token uuid;
  v_room_id uuid; r public.rooms; p public.players; s json; w json; count_intruders integer;
  civil_target uuid; other_target uuid; target_token uuid; first_token uuid;
  n integer; n_civil integer; host_role text;
begin
  h:=public.create_room('QA Mr White Hôte',2,'white',1);
  code_salon:=h->>'code';host_token:=(h->>'token')::uuid;host_id:=(h->>'player_id')::uuid;
  for n in 2..6 loop
    guest:=public.join_room(code_salon,'QA White '||n);
    if guest->>'token' is null then raise exception 'Mr White : invitation ratée'; end if;
  end loop;
  select * into r from public.rooms where code=code_salon; v_room_id:=r.id;
  perform public.lancer_partie(code_salon,host_token);
  select * into r from public.rooms where id=v_room_id;
  if r.status<>'white_clue' then raise exception 'Mr White : début de partie impossible'; end if;
  select count(*) into count_intruders from public.white_roles
    where room_id=v_room_id and round=1 and role in ('undercover','white');
  if count_intruders<>2 then raise exception 'Mr White : 6 joueurs nécessitent 2 intrus, obtenu %',count_intruders; end if;

  for p in select * from public.players where room_id=v_room_id and active order by seat loop
    s:=public.get_full_state(code_salon,p.token);
    w:=s->'white';
    if w is null or w->>'civil_word' is not null or w->>'undercover_word' is not null then
      raise exception 'Mr White : fuite de mot vers %',p.name;
    end if;
    if exists(select 1 from json_array_elements(w->'roles') role_info
      where role_info->>'role' is not null and coalesce((role_info->>'out')::boolean,false)=false) then
      raise exception 'Mr White : rôles adverses révélés avant la fin';
    end if;
    if (select role from public.white_roles where room_id=v_room_id and player_id=p.id and round=1)='white' then
      if w->>'word' is not null or w->>'role'<>'white' then
        raise exception 'Mr White : carte secrète incorrecte';
      end if;
    else
      if w->>'word' is null then raise exception 'Mr White : joueur sans mot'; end if;
    end if;
  end loop;

  select wr.player_id into civil_target from public.white_roles wr
    join public.players pp on pp.id=wr.player_id
    where wr.room_id=v_room_id and wr.round=1 and wr.role='civil' order by pp.seat limit 1;
  if civil_target is null then raise exception 'Mr White : aucun Civil'; end if;
  select wr.player_id into other_target from public.white_roles wr
    where wr.room_id=v_room_id and wr.round=1 and wr.player_id<>civil_target limit 1;

  select token into first_token from public.players where room_id=v_room_id and id<>host_id order by seat limit 1;
  begin
    perform public.white_open_vote(code_salon,first_token);
    raise exception 'QA_ECHEC : ouverture du vote par un invité';
  exception when others then
    if sqlerrm like 'QA_ECHEC%' then raise; end if;
  end;
  perform public.white_open_vote(code_salon,host_token);
  select * into r from public.rooms where id=v_room_id;
  if r.status<>'white_vote' then raise exception 'Mr White : vote pas ouvert'; end if;

  select token into target_token from public.players where id=civil_target;
  begin
    perform public.white_vote(code_salon,target_token,civil_target);
    raise exception 'QA_ECHEC : le vote pour soi est possible';
  exception when others then
    if sqlerrm like 'QA_ECHEC%' then raise; end if;
  end;

  for p in select * from public.players where room_id=v_room_id and active order by seat loop
    perform public.white_vote(code_salon,p.token,
       case when p.id=civil_target then other_target else civil_target end);
  end loop;
  select * into r from public.rooms where id=v_room_id;
  if r.status<>'white_elimination' then
    raise exception 'Mr White : état post-vote incorrect (%), Civil ciblé',r.status;
  end if;
  if not exists(select 1 from public.white_roles where room_id=v_room_id and round=1 and player_id=civil_target and eliminated) then
    raise exception 'Mr White : le Civil désigné ne sort pas';
  end if;

  -- Le joueur éliminé reste connecté, mais ne pourra plus voter au cycle suivant.
  perform public.white_resume(code_salon,host_token);
  select * into r from public.rooms where id=v_room_id;
  if r.status<>'white_clue' or r.white_cycle<>2 then
    raise exception 'Mr White : la reprise ne démarre pas le deuxième cycle';
  end if;
  perform public.white_open_vote(code_salon,host_token);
  begin
    perform public.white_vote(code_salon,target_token,other_target);
    raise exception 'QA_ECHEC : vote du joueur éliminé accepté';
  exception when others then
    if sqlerrm like 'QA_ECHEC%' then raise; end if;
  end;
  raise notice 'QA PASS : Mr White 6 joueurs, 2 intrus, confidentialité, votes, élimination et reprise';
end $qa_white$;

rollback;
