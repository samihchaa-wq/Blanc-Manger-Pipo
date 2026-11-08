-- Postgres jetable : vérifie la compatibilité vote/revote restaurée après
-- la migration d'intégrité. Ne dépend d'aucune donnée de production.
begin;
select pg_catalog.set_config('request.headers','{"x-forwarded-for":"192.0.2.189"}',true);

do $qa$
declare
  h json; a json; b json; c text; v_room uuid; v_host uuid; v_alice uuid; v_bob uuid;
  t_alice uuid; v_dico_bob uuid; v_dico_true uuid;
  v_dil_host uuid; v_dil_bob uuid; n integer;
begin
  h:=public.create_room('Hôte de test',1,'phrases',1);
  c:=h->>'code';v_host:=(h->>'player_id')::uuid;
  a:=public.join_room(c,'Alice');v_alice:=(a->>'player_id')::uuid;t_alice:=(a->>'token')::uuid;
  b:=public.join_room(c,'Bob');v_bob:=(b->>'player_id')::uuid;
  select id into v_room from public.rooms where code=c;

  update public.rooms set mode='dico',status='dico_vote',reader_id=v_host where id=v_room;
  insert into public.dico_defs(room_id,round,player_id,text)
  values(v_room,1,v_bob,'Définition inventée') returning id into v_dico_bob;
  insert into public.dico_defs(room_id,round,player_id,text)
  values(v_room,1,v_host,'Bonne définition') returning id into v_dico_true;
  perform public.dico_vote(c,t_alice,v_dico_bob);
  perform public.dico_vote(c,t_alice,v_dico_true);
  if (select def_id from public.dico_votes where room_id=v_room and voter_id=v_alice)<>v_dico_true then
    raise exception 'Le Dico : le revote avant fermeture est refusé';
  end if;
  select count(*) into n from public.dico_votes where room_id=v_room and voter_id=v_alice;
  if n<>1 then raise exception 'Le Dico : le revote a créé plusieurs votes'; end if;
  update public.rooms set status='reveal' where id=v_room;
  begin
    perform public.dico_vote(c,t_alice,v_dico_bob);
    raise exception 'QA_FAIL : le Dico accepte un vote après fin';
  exception when others then if sqlerrm like 'QA_FAIL%' then raise; end if; end;

  update public.rooms set mode='dilemme',status='dilemme_vote' where id=v_room;
  insert into public.dilemme_buts(room_id,round,player_id,text)
  values(v_room,1,v_host,'Dilemme Hôte') returning id into v_dil_host;
  insert into public.dilemme_buts(room_id,round,player_id,text)
  values(v_room,1,v_bob,'Dilemme Bob') returning id into v_dil_bob;
  perform public.dilemme_vote(c,t_alice,array[v_dil_host,v_dil_bob],array[true,false]);
  perform public.dilemme_vote(c,t_alice,array[v_dil_host,v_dil_bob],array[false,true]);
  select count(*) into n from public.dilemme_votes where room_id=v_room and voter_id=v_alice;
  if n<>2 then raise exception 'Dilemme : le revote crée des doublons'; end if;
  if not exists(select 1 from public.dilemme_votes
    where room_id=v_room and voter_id=v_alice and but_id=v_dil_bob and yes)
    then raise exception 'Dilemme : vote modifié non enregistré'; end if;
  begin
    perform public.dilemme_vote(c,t_alice,array[v_dil_host,v_dil_host],array[true,true]);
    raise exception 'QA_FAIL : le Dilemme accepte un ID en doublon';
  exception when others then if sqlerrm like 'QA_FAIL%' then raise; end if; end;
  update public.rooms set status='reveal' where id=v_room;
  begin
    perform public.dilemme_vote(c,t_alice,array[v_dil_host,v_dil_bob],array[true,true]);
    raise exception 'QA_FAIL : le Dilemme accepte un vote après fin';
  exception when others then if sqlerrm like 'QA_FAIL%' then raise; end if; end;
end $qa$;

rollback;
