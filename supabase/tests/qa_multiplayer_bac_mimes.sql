-- QA : Petit Bac et Mimes. Testeurs virtuels distincts, scores exacts.
-- Toutes les écritures de ces parties fictives sont annulées.
begin;
select pg_catalog.set_config('request.headers','{"x-forwarded-for":"192.0.2.182"}',true);

do $qa_bac$
declare
  h json; a json; c text; r public.rooms; rid uuid;
  rh uuid; ra uuid; th uuid; ta uuid;
  names text[]:=array['Animaux','Villes','Métiers','Prénoms','Pays','Objets'];
  chosen_token uuid; i integer; old_step integer; v integer;
  arr text[]; st json;
begin
  h:=public.create_room('QA Petit Bac Hôte',1,'bac',1);
  c:=h->>'code'; th:=(h->>'token')::uuid; rh:=(h->>'player_id')::uuid;
  a:=public.join_room(c,'QA Bac Alice'); ta:=(a->>'token')::uuid; ra:=(a->>'player_id')::uuid;
  perform public.lancer_partie(c,th);
  select * into r from public.rooms where code=c; rid:=r.id;
  if r.status<>'naming' then raise exception 'Bac : ne démarre pas sur les catégories'; end if;
  for i in 1..6 loop
    select * into r from public.rooms where id=rid;
    chosen_token:=case r.reader_id when rh then th when ra then ta end;
    if chosen_token is null then raise exception 'Bac : lecteur inconnu'; end if;
    perform public.bac_category(c,chosen_token,names[i]);
  end loop;
  select * into r from public.rooms where id=rid;
  if r.status<>'writing' or cardinality(r.bac_categories)<>6 or r.bac_letter is null then
    raise exception 'Bac : passage à la grille impossible (% / %)',r.status,r.bac_letter;
  end if;
  arr:=array_fill((r.bac_letter || 'mot')::text,array[6]);
  perform public.bac_save(c,th,arr,true);
  begin
    perform public.bac_save(c,th,array_fill('TRICHE',array[6]),true);
    raise exception 'QA_ECHEC : Bac permet de modifier sa grille terminée';
  exception when others then
    if sqlerrm like 'QA_ECHEC%' then raise; end if;
  end;
  perform public.bac_save(c,ta,arr,true);
  select * into r from public.rooms where id=rid;
  if r.status<>'voting' or r.bac_step<>0 then
    raise exception 'Bac : vote non déclenché';
  end if;
  for i in 1..6 loop
    select bac_step into old_step from public.rooms where id=rid;
    if old_step<>i-1 then raise exception 'Bac : mauvaise catégorie de vote %',old_step; end if;
    perform public.bac_vote(c,th,2);
    begin
      perform public.bac_vote(c,th,1);
      raise exception 'QA_ECHEC : deuxième note Bac acceptée';
    exception when others then
      if sqlerrm like 'QA_ECHEC%' then raise; end if;
    end;
    perform public.bac_vote(c,ta,2);
  end loop;
  select * into r from public.rooms where id=rid;
  if r.status<>'reveal' or r.bac_step<>6 then
    raise exception 'Bac : fin de manche absente (% / %)',r.status,r.bac_step;
  end if;
  if (select score from public.players where id=rh)<>12 or
     (select score from public.players where id=ra)<>12 then
    raise exception 'Bac : mauvais score sur 6 réponses validées';
  end if;
  st:=public.get_state(c,ta);
  if st->'bac'->'rows' is null then raise exception 'Bac : résultats indisponibles'; end if;
  raise notice 'QA PASS : Petit Bac 2 joueurs, 6 catégories, grille verrouillée, 12 votes, 12 pts/joueur';
end $qa_bac$;

do $qa_mimes$
declare h json; a json; b json; c text; th uuid; rid uuid; r public.rooms;
  judge_token uuid; ids uuid[]; notes integer[]; perf public.mime_parts; n integer;
begin
  h:=public.create_room('QA Mimes Hôte',1,'mimes',1); c:=h->>'code'; th:=(h->>'token')::uuid;
  a:=public.join_room(c,'QA Mimes Alice');
  b:=public.join_room(c,'QA Mimes Bob');
  perform public.lancer_partie(c,th);
  select * into r from public.rooms where code=c; rid:=r.id;
  if r.status<>'mime_play' or r.mime_card is null then
    raise exception 'Mimes : partie pas lancée';
  end if;
  select token into judge_token from public.players where id=r.reader_id;
  -- Le juge valide d'abord le défi standard (nouvelle préparation facultative).
  perform public.choose_mime_challenge(c,judge_token,false,null,null,null);
  select array_agg(m.player_id order by p.seat),
         array_agg(m.intensity order by p.seat)
    into ids,notes
    from public.mime_parts m join public.players p on p.id=m.player_id
    where m.room_id=rid and m.round=r.round and m.intensity is not null;
  if cardinality(ids)<>2 then raise exception 'Mimes : il faut deux joueurs à évaluer'; end if;
  begin
    perform public.mime_rate(c,judge_token,ids,array[11,0]);
    raise exception 'QA_ECHEC : notes Mimes hors plage acceptées';
  exception when others then
    if sqlerrm like 'QA_ECHEC%' then raise; end if;
  end;
  perform public.mime_progress(c,judge_token,'next');
  perform public.mime_progress(c,judge_token,'next');
  perform public.mime_rate(c,judge_token,ids,notes);
  select * into r from public.rooms where id=rid;
  if r.status<>'reveal' then raise exception 'Mimes : fin de manche absente'; end if;
  if exists(select 1 from public.players where room_id=rid and active and score<>3) then
    raise exception 'Mimes : mauvaise attribution du score parfait';
  end if;
  begin
    perform public.mime_rate(c,judge_token,ids,notes);
    raise exception 'QA_ECHEC : double notation Mimes acceptée';
  exception when others then
    if sqlerrm like 'QA_ECHEC%' then raise; end if;
  end;
  raise notice 'QA PASS : Mimes 3 joueurs, ordre de passage, notes et score exact';
end $qa_mimes$;
rollback;
