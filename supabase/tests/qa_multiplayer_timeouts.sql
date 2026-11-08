-- QA des délais et des joueurs absents : actions avant/après expiration,
-- progression sans réponse, points non attribués deux fois, huit jeux.
-- Exécution transactionnelle ROLLBACK.
begin;
select pg_catalog.set_config('request.headers','{"x-forwarded-for":"192.0.2.186"}',true);

do $qa_timers$
declare
  g text; h json; a json; b json; c text; rid uuid; r public.rooms;
  th uuid; ra uuid; reader_tok uuid; p public.players; answer_id integer;
  qid integer; blanks integer; scores_before integer; i integer;
  st json; names text[]:=array['Animaux','Métiers','Villes','Noms','Objets','Pays'];
begin
  foreach g in array array['phrases','priorites','ondes','bac','white','mimes','dico','dilemme'] loop
    h:=public.create_room('QA Minuterie Hôte',2,g,1);
    c:=h->>'code';th:=(h->>'token')::uuid;
    a:=public.join_room(c,'QA Test A');ra:=(a->>'token')::uuid;
    if public._min_players(g)>=3 then
      b:=public.join_room(c,'QA Test B');
    end if;
    perform public.set_time_mode(c,th,'fast');
    perform public.lancer_partie(c,th);
    select * into r from public.rooms where code=c;rid:=r.id;
    select token into reader_tok from public.players where id=r.reader_id;
    if g='phrases' then
      qid:=r.question_choices[1];
      perform public.select_question(c,reader_tok,qid);
      select * into r from public.rooms where id=rid;
      select blanks into blanks from public.questions where id=qid;
      select answer_id into answer_id from public.hands where player_id<>(r.reader_id)
        and room_id=rid order by answer_id limit 1;
      -- Un joueur répond, l'autre dépasse le délai.
      select * into p from public.players where room_id=rid and active and id<>r.reader_id order by seat limit 1;
      perform public.submit_answer(c,p.token,answer_id,
        case when blanks=2 then (select hnd.answer_id from public.hands hnd
          where hnd.player_id=p.id and hnd.answer_id<>answer_id order by hnd.answer_id limit 1) end);
      update public.rooms set phase_at=now()-interval '1 hour' where id=rid;
      perform public.reap_idle(c,th);
      select status into r.status from public.rooms where id=rid;
      if r.status<>'judging' then raise exception 'Timer Phrases bloqué sur %',r.status; end if;

    elsif g='priorites' then
      -- Seul le juge classe : la phase expire sans les autres réponses.
      select * into r from public.rooms where id=rid;
      perform public.submit_ranking(c,reader_tok,r.rank_cards);
      update public.rooms set phase_at=now()-interval '1 hour' where id=rid;
      perform public.reap_idle(c,th);
      select * into r from public.rooms where id=rid;
      if r.status<>'reveal' then raise exception 'Timer Priorités : %',r.status; end if;
      select coalesce(sum(score),0) into scores_before from public.players where room_id=rid;
      perform public.reap_idle(c,th);
      if (select coalesce(sum(score),0) from public.players where room_id=rid)<>scores_before then
        raise exception 'Timer Priorités : points dupliqués';
      end if;

    elsif g='ondes' then
      perform public.submit_clue(c,reader_tok,'Mot de contrôle');
      select * into p from public.players where room_id=rid and active and id<>r.reader_id order by seat limit 1;
      perform public.submit_guess(c,p.token,r.wave_target);
      update public.rooms set phase_at=now()-interval '1 hour' where id=rid;
      perform public.reap_idle(c,th);
      select * into r from public.rooms where id=rid;
      if r.status<>'reveal' then raise exception 'Timer Baromètre : %',r.status; end if;
      scores_before:=(select coalesce(sum(score),0) from public.players where room_id=rid);
      perform public.reap_idle(c,th);
      if scores_before<>(select coalesce(sum(score),0) from public.players where room_id=rid) then
        raise exception 'Timer Baromètre : points dupliqués';
      end if;

    elsif g='bac' then
      for i in 1..6 loop
        select * into r from public.rooms where id=rid;
        select token into reader_tok from public.players where id=r.reader_id;
        perform public.bac_category(c,reader_tok,names[i]);
      end loop;
      select * into r from public.rooms where id=rid;
      if r.status<>'writing' then raise exception 'Timer Bac : écriture absente'; end if;
      update public.rooms set phase_at=now()-interval '1 hour' where id=rid;
      perform public.reap_idle(c,th);
      select * into r from public.rooms where id=rid;
      if r.status<>'reveal' or exists(select 1 from public.players where room_id=rid and score<>0) then
        raise exception 'Timer Bac : grilles absentes mal traitées (%)',r.status;
      end if;

    elsif g='white' then
      perform public.white_open_vote(c,th);
      update public.rooms set phase_at=now()-interval '1 hour' where id=rid;
      perform public.reap_idle(c,th);
      select * into r from public.rooms where id=rid;
      if r.status<>'white_elimination' or not r.white_note like 'Égalité%' then
        raise exception 'Timer Mr White : vote vide pas traité (%)',r.status;
      end if;

    elsif g='mimes' then
      -- Le timer est indicatif : le juge contrôle les passages.
      update public.rooms set phase_at=now()-interval '1 hour' where id=rid;
      perform public.reap_idle(c,th);
      select * into r from public.rooms where id=rid;
      if r.status<>'mime_play' then
        raise exception 'Mimes : la minuterie indicative a interrompu la prestation';
      end if;

    elsif g='dico' then
      perform public.dico_pick(c,reader_tok,'arbre','n. m.','Végétal ligneux.');
      select * into r from public.rooms where id=rid;
      select * into p from public.players where room_id=rid and active and id<>r.reader_id order by seat limit 1;
      perform public.dico_write(c,p.token,'Un petit animal.');
      update public.rooms set phase_at=now()-interval '1 hour' where id=rid;
      perform public.reap_idle(c,th);
      select * into r from public.rooms where id=rid;
      if r.status<>'dico_vote' then raise exception 'Timer Dico : vote non ouvert'; end if;
      update public.rooms set phase_at=now()-interval '1 hour' where id=rid;
      perform public.reap_idle(c,th);
      select * into r from public.rooms where id=rid;
      if r.status<>'reveal' then raise exception 'Timer Dico : révélation non déclenchée'; end if;

    elsif g='dilemme' then
      perform public.dilemme_pick(c,reader_tok,'Tu deviens riche');
      select * into r from public.rooms where id=rid;
      for p in select * from public.players where room_id=rid and active order by seat limit 2 loop
        perform public.dilemme_write(c,p.token,'mais tu changes de nom');
      end loop;
      update public.rooms set phase_at=now()-interval '1 hour' where id=rid;
      perform public.reap_idle(c,th);
      select * into r from public.rooms where id=rid;
      if r.status<>'dilemme_vote' then raise exception 'Timer Dilemme : vote non ouvert'; end if;
      update public.rooms set phase_at=now()-interval '1 hour' where id=rid;
      perform public.reap_idle(c,th);
      select * into r from public.rooms where id=rid;
      if r.status<>'reveal' then raise exception 'Timer Dilemme : révélation non déclenchée'; end if;
    end if;
  end loop;
  raise notice 'QA PASS : 8 jeux ; expiration, absence de réponse, reprise ou temporisation consultative';
end $qa_timers$;

rollback;
