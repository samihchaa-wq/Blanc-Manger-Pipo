-- QA : Le Dico et Dilemme, quatre/trois participants, revotes avant clôture.
-- Les vrais RPC des jeux sont utilisés. Cette suite est exécutée en transaction
-- avec la migration correctrice avant son déploiement. Aucun état persistant.
begin;
select pg_catalog.set_config('request.headers','{"x-forwarded-for":"192.0.2.184"}',true);

do $qa_dico$
declare h json; a json; b json; z json; c text; r public.rooms; rid uuid;
  th uuid; ta uuid; tb uuid; tz uuid; rh uuid; ra uuid; rb uuid; rz uuid;
  d_a uuid; d_b uuid; d_z uuid; d_real uuid; st json; n integer;
begin
  h:=public.create_room('QA Dico Hôte',1,'dico',1); c:=h->>'code'; th:=(h->>'token')::uuid; rh:=(h->>'player_id')::uuid;
  a:=public.join_room(c,'QA Alice'); ta:=(a->>'token')::uuid; ra:=(a->>'player_id')::uuid;
  b:=public.join_room(c,'QA Bob'); tb:=(b->>'token')::uuid; rb:=(b->>'player_id')::uuid;
  z:=public.join_room(c,'QA Zoé'); tz:=(z->>'token')::uuid; rz:=(z->>'player_id')::uuid;
  perform public.lancer_partie(c,th);
  select * into r from public.rooms where code=c; rid:=r.id;
  if r.status<>'dico_pick' or r.reader_id<>rh then raise exception 'Dico : meneur initial erroné'; end if;
  begin
    perform public.dico_pick(c,ta,'test','n.','Triche');
    raise exception 'QA_ECHEC : faux meneur autorisé';
  exception when others then if sqlerrm like 'QA_ECHEC%' then raise; end if; end;
  perform public.dico_pick(c,th,'pomme','n. f.','Fruit du pommier.');
  st:=public.get_full_state(c,ta);
  if st->'dico'->>'definition' is not null then raise exception 'Dico : définition réelle révélée trop tôt'; end if;
  perform public.dico_write(c,ta,'Une machine volante.');
  perform public.dico_write(c,tb,'Un animal aquatique.');
  perform public.dico_write(c,tz,'Un instrument de musique.');
  select * into r from public.rooms where id=rid;
  if r.status<>'dico_vote' then raise exception 'Dico : votes non ouverts'; end if;
  st:=public.get_full_state(c,tb);
  if exists(select 1 from json_array_elements(st->'dico'->'defs') dd where dd->>'is_true' is not null
    or dd->>'author_id' is not null) then
    raise exception 'Dico : réponses et auteurs divulgués avant le vote';
  end if;
  select id into d_a from public.dico_defs where room_id=rid and round=1 and player_id=ra;
  select id into d_b from public.dico_defs where room_id=rid and round=1 and player_id=rb;
  select id into d_z from public.dico_defs where room_id=rid and round=1 and player_id=rz;
  select id into d_real from public.dico_defs where room_id=rid and round=1 and is_true;
  if d_real is null then raise exception 'Dico : la définition correcte manque'; end if;

  begin
    perform public.dico_vote(c,ta,d_a);
    raise exception 'QA_ECHEC : auto-vote Dico accepté';
  exception when others then if sqlerrm like 'QA_ECHEC%' then raise; end if; end;
  perform public.dico_vote(c,ta,d_b);
  perform public.dico_vote(c,ta,d_real);
  if (select def_id from public.dico_votes where room_id=rid and round=1 and voter_id=ra) is distinct from d_real then
    raise exception 'Dico : changement de vote avant clôture refusé';
  end if;
  perform public.dico_vote(c,tb,d_real);
  perform public.dico_vote(c,tz,d_a);
  select * into r from public.rooms where id=rid;
  if r.status<>'reveal' then raise exception 'Dico : non révélé à 4 joueurs'; end if;
  if (select score from public.players where id=ra)<>3
     or (select score from public.players where id=rb)<>2 then
    raise exception 'Dico : scores erronés après vote';
  end if;
  begin
    perform public.dico_vote(c,ta,d_b);
    raise exception 'QA_ECHEC : vote Dico accepté après révélation';
  exception when others then if sqlerrm like 'QA_ECHEC%' then raise; end if; end;
  raise notice 'QA PASS : Dico, 4 joueurs, confidentialité, changement avant clôture, points et clôture';
end $qa_dico$;

do $qa_dilemme$
declare h json; a json; b json; c text; r public.rooms; rid uuid;
  th uuid; ta uuid; tb uuid; rh uuid; ra uuid; rb uuid; bh uuid; ba uuid; bb uuid; st json; n integer;
begin
  h:=public.create_room('QA Dilemme Hôte',1,'dilemme',1); c:=h->>'code'; th:=(h->>'token')::uuid; rh:=(h->>'player_id')::uuid;
  a:=public.join_room(c,'QA Alice'); ta:=(a->>'token')::uuid; ra:=(a->>'player_id')::uuid;
  b:=public.join_room(c,'QA Bob'); tb:=(b->>'token')::uuid; rb:=(b->>'player_id')::uuid;
  perform public.lancer_partie(c,th);
  select * into r from public.rooms where code=c; rid:=r.id;
  if r.status<>'dilemme_pick' or r.reader_id<>rh then raise exception 'Dilemme : début/meneur incorrect'; end if;
  perform public.dilemme_pick(c,th,'Tu gagnes un million mais');
  perform public.dilemme_write(c,th,'tu perds tes chaussures.');
  perform public.dilemme_write(c,ta,'tu dors debout.');
  perform public.dilemme_write(c,tb,'tu deviens un pingouin.');
  select * into r from public.rooms where id=rid;
  if r.status<>'dilemme_vote' then raise exception 'Dilemme : phase vote absente'; end if;
  st:=public.get_full_state(c,ta);
  if exists(select 1 from json_array_elements(st->'dilemme'->'buts') xx
    where xx->>'author_id' is not null) then
    raise exception 'Dilemme : auteurs divulgués';
  end if;
  select id into bh from public.dilemme_buts where room_id=rid and round=1 and player_id=rh;
  select id into ba from public.dilemme_buts where room_id=rid and round=1 and player_id=ra;
  select id into bb from public.dilemme_buts where room_id=rid and round=1 and player_id=rb;
  begin
    perform public.dilemme_vote(c,ta,array[ba,bh],array[true,true]);
    raise exception 'QA_ECHEC : Dilemme laisse voter pour soi';
  exception when others then if sqlerrm like 'QA_ECHEC%' then raise; end if; end;
  begin
    perform public.dilemme_vote(c,ta,array[bh,bh,bb],array[true,false,true]);
    raise exception 'QA_ECHEC : Dilemme accepte un double ID';
  exception when others then if sqlerrm like 'QA_ECHEC%' then raise; end if; end;
  perform public.dilemme_vote(c,th,array[ba,bb],array[true,false]);
  perform public.dilemme_vote(c,th,array[ba,bb],array[false,true]);
  if (select count(*) from public.dilemme_votes where room_id=rid and round=1 and voter_id=rh)<>2 then
    raise exception 'Dilemme : le changement a créé des doublons';
  end if;
  if not exists(select 1 from public.dilemme_votes where room_id=rid and round=1 and voter_id=rh and but_id=bb and yes) then
    raise exception 'Dilemme : le nouveau vote ne remplace pas l’ancien';
  end if;
  perform public.dilemme_vote(c,ta,array[bh,bb],array[true,false]);
  perform public.dilemme_vote(c,tb,array[bh,ba],array[false,false]);
  select * into r from public.rooms where id=rid;
  if r.status<>'reveal' then raise exception 'Dilemme : phase révélation absente'; end if;
  if exists(select 1 from public.players p join public.dilemme_points d on p.id=d.player_id
    where p.room_id=rid and d.room_id=rid and d.round=1 and p.score is distinct from d.points) then
    raise exception 'Dilemme : points incohérents';
  end if;
  begin
    perform public.dilemme_vote(c,th,array[ba,bb],array[true,true]);
    raise exception 'QA_ECHEC : changement accepté après révélation';
  exception when others then if sqlerrm like 'QA_ECHEC%' then raise; end if; end;
  raise notice 'QA PASS : Dilemme, 3 joueurs, votes complets, changement avant clôture, barème, fin';
end $qa_dilemme$;

rollback;
