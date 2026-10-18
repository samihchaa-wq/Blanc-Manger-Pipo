-- Trois changements :
-- 1. Plus de tirage au sort : le lecteur de Phrases à trou est désigné à tour
--    de rôle, dans l'ordre d'arrivée, l'hôte en premier (Priorités et
--    Baromètre tournaient déjà dans cet ordre).
-- 2. L'écran de résultat d'une manche ne dure que 5 s, puis la manche suivante
--    démarre seule : plus de « Manche suivante » à valider.
-- 3. Un joueur qui ne joue pas en 2 min n'est plus exclu : on joue à sa place.
--    Phrases à trou : la première question proposée, ses premières cartes, la
--    première réponse en lice. Priorités : un classement au hasard.
--    Baromètre : l'aiguille au milieu, l'indice « Sans texte ».

-- ---------- Tour de rôle ----------
-- Joueur actif suivant après p_after dans l'ordre des sièges, en boucle.
-- Sans p_after (début de partie) : l'hôte.
create or replace function public._next_reader(p_room uuid, p_after uuid)
 returns uuid language sql stable security definer set search_path to '' as $function$
  select coalesce(
    case when p_after is null then
      (select r.host_id from public.rooms r join public.players p on p.id = r.host_id and p.active where r.id = p_room)
    else
      (select p.id from public.players p where p.room_id = p_room and p.active
         and p.seat > (select seat from public.players where id = p_after)
       order by p.seat limit 1)
    end,
    (select p.id from public.players p where p.room_id = p_room and p.active order by p.seat limit 1))
$function$;
revoke all on function public._next_reader(uuid, uuid) from public, anon, authenticated;

create or replace function public.start_game(p_code text, p_token uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; rd uuid; mn integer;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.host_id<>me.id then raise exception 'Seul l’hôte peut lancer la partie.'; end if;
 if r.status<>'lobby' then raise exception 'La partie est déjà en cours.'; end if;
 mn := public._min_players(r.mode);
 if (select count(*) from public.players where room_id=r.id and active)<mn then raise exception 'Il faut au moins % joueurs.', mn; end if;
 if exists(select 1 from public.players where room_id=r.id and active and not ready) then raise exception 'Tous les joueurs doivent être prêts.'; end if;
 update public.players set score=0,discard_round=0,next_ack_round=0,continue_requested=false,judge_count=0 where room_id=r.id and active;
 delete from public.hands where room_id=r.id; delete from public.used_answers where room_id=r.id; delete from public.submissions where room_id=r.id;
 delete from public.rankings where room_id=r.id;
 delete from public.wave_guesses where room_id=r.id;
 update public.rooms set used_questions='{}',round=0,previous_reader_id=null,reader_id=null,rank_cards='{}',
   wave_card=null,wave_target=null,wave_clue=null where id=r.id;
 rd:=public._next_reader(r.id,null);
 perform public._begin_round(r.id,rd,1);
end $function$;

create or replace function public._remove_player(p_player uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare pl public.players; r public.rooms; nr uuid;
begin
  select * into pl from public.players where id = p_player;
  if pl.id is null or not pl.active then return; end if;

  select * into r from public.rooms where id = pl.room_id for update;

  update public.players set active = false where id = p_player;
  delete from public.hands where player_id = p_player;

  if r.host_id = p_player then
    update public.rooms
    set host_id = (select id from public.players where room_id = r.id and active order by seat limit 1)
    where id = r.id;
  end if;

  if r.status in ('question_select', 'answering', 'judging', 'ranking', 'clue', 'guessing', 'reveal') then
    if (select count(*) from public.players where room_id = r.id and active) < public._min_players(r.mode) then
      if r.status in ('answering', 'judging') then
        perform public._return_submissions(r.id, r.round);
      end if;
      update public.rooms set status = 'lobby', phase_at = now(), updated_at = now() where id = r.id;

    elsif r.reader_id = p_player then
      nr := public._next_reader(r.id, p_player);
      if r.status in ('answering', 'judging') then
        perform public._return_submissions(r.id, r.round);
      end if;
      perform public._begin_round(r.id, nr, case when r.status = 'question_select' then r.round else r.round + 1 end);

    elsif r.status = 'ranking' then
      delete from public.rankings where room_id = r.id and round = r.round and player_id = p_player;
      perform public._maybe_score(r.id);

    elsif r.status = 'guessing' then
      delete from public.wave_guesses where room_id = r.id and round = r.round and player_id = p_player;
      perform public._maybe_wave_score(r.id);

    elsif r.status in ('answering', 'judging') then
      delete from public.submissions where room_id = r.id and round = r.round and player_id = p_player;
      if r.status = 'judging'
         and not exists (select 1 from public.submissions where room_id = r.id and round = r.round) then
        update public.rooms set status = 'answering', phase_at = now(), updated_at = now() where id = r.id;
      elsif r.status = 'answering' then
        perform public._maybe_judge(r.id);
      end if;
    end if;
  end if;

  update public.rooms set updated_at = now() where id = r.id;
end $function$;

-- ---------- Minuteurs : jouer à la place des absents ----------
-- 2 min par phase de jeu, 5 s pour l'écran de résultat. Le premier client qui
-- constate l'expiration appelle reap_idle ; le délai est revérifié ici.
create or replace function public.reap_idle(p_code text, p_token uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; pl record; n integer; aid integer; aid2 integer; sid uuid; w uuid; sc integer; delai interval;
begin
  me := public._player(p_code, p_token);
  if me.id is null then return; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.id is null then return; end if;
  delai := case when r.status = 'reveal' then interval '5 seconds' else interval '120 seconds' end;
  if now() - r.phase_at < delai then return; end if;

  if r.status = 'question_select' then
    -- la première carte proposée, dans l'ordre où le lecteur les voit
    select x into aid from unnest(r.question_choices) with ordinality as c(x, i) order by i limit 1;
    if aid is null then return; end if;
    update public.rooms set question_id = aid, used_questions = used_questions || aid,
      question_choices = '{}', status = 'answering', phase_at = now(), updated_at = now() where id = r.id;
    perform public._maybe_judge(r.id);

  elsif r.status = 'answering' then
    select coalesce(blanks, 1) into n from public.questions where id = r.question_id;
    n := coalesce(n, 1);
    -- les premières cartes de la main, dans l'ordre où elle s'affiche
    for pl in
      select p.id from public.players p
      where p.room_id = r.id and p.active and p.id <> r.reader_id
        and not exists (select 1 from public.submissions s where s.room_id = r.id and s.round = r.round and s.player_id = p.id)
    loop
      select h.answer_id into aid from public.hands h join public.answers a on a.id = h.answer_id
        where h.player_id = pl.id order by a.text, a.id limit 1;
      aid2 := null;
      if n = 2 then
        select h.answer_id into aid2 from public.hands h join public.answers a on a.id = h.answer_id
          where h.player_id = pl.id and h.answer_id <> aid order by a.text, a.id limit 1;
      end if;
      if aid is not null and (n = 1 or aid2 is not null) then
        insert into public.submissions(room_id, round, player_id, answer_id, answer_id2)
        values (r.id, r.round, pl.id, aid, aid2) on conflict do nothing;
        delete from public.hands where player_id = pl.id and answer_id in (aid, aid2);
      end if;
    end loop;
    perform public._deal(r.id);
    perform public._maybe_judge(r.id);
    update public.rooms set updated_at = now() where id = r.id;

  elsif r.status = 'judging' then
    -- la première réponse lue par le lecteur gagne le point
    select s.id, s.player_id into sid, w from public.submissions s
      join public.players p on p.id = s.player_id and p.active
      where s.room_id = r.id and s.round = r.round order by s.sort_key limit 1;
    if sid is null then return; end if;
    update public.players set score = score + 1 where id = w returning score into sc;
    update public.rooms set status = case when sc >= r.target_score then 'finished' else 'reveal' end,
      winner_id = w, winning_submission_id = sid, phase_at = now(), updated_at = now() where id = r.id;

  elsif r.status = 'ranking' then
    insert into public.rankings(room_id, round, player_id, cards)
    select r.id, r.round, p.id, (select array_agg(x order by random()) from unnest(r.rank_cards) x)
      from public.players p
      where p.room_id = r.id and p.active
        and not exists (select 1 from public.rankings k where k.room_id = r.id and k.round = r.round and k.player_id = p.id)
    on conflict do nothing;
    perform public._maybe_score(r.id);
    update public.rooms set updated_at = now() where id = r.id;

  elsif r.status = 'clue' then
    update public.rooms set wave_clue = 'Sans texte', status = 'guessing', phase_at = now(), updated_at = now()
      where id = r.id;

  elsif r.status = 'guessing' then
    insert into public.wave_guesses(room_id, round, player_id, value)
    select r.id, r.round, p.id, 50
      from public.players p
      where p.room_id = r.id and p.active and p.id <> r.reader_id
        and not exists (select 1 from public.wave_guesses g where g.room_id = r.id and g.round = r.round and g.player_id = p.id)
    on conflict do nothing;
    perform public._maybe_wave_score(r.id);
    update public.rooms set updated_at = now() where id = r.id;

  elsif r.status = 'reveal' then
    perform public._begin_round(r.id, public._next_reader(r.id, r.reader_id), r.round + 1);
  end if;
end $function$;
revoke all on function public.reap_idle(text, uuid) from public, anon, authenticated;
grant execute on function public.reap_idle(text, uuid) to anon;

-- ---------- Plus de validation de fin de manche ----------
drop function if exists public.next_round(text, uuid);
drop function if exists public._random_reader(uuid, uuid);

-- ---------- Bots : la fin de manche passe seule, plus rien à valider ----------
create or replace function public.bot_step(p_code text, p_token uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; b public.players; aid integer; aid2 integer; sid uuid; qid integer; n int; sc int;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;

  if r.status = 'question_select' then
    select * into b from public.players where id = r.reader_id and active and is_bot;
    if b.id is not null then
      select x into qid from unnest(r.question_choices) x order by random() limit 1;
      update public.rooms set question_id = qid, used_questions = used_questions || qid,
        question_choices = '{}', status = 'answering', phase_at = now(), updated_at = now() where id = r.id;
    end if;

  elsif r.status = 'answering' then
    select blanks into n from public.questions where id = r.question_id;
    n := coalesce(n, 1);
    for b in select * from public.players p where p.room_id = r.id and p.active and p.is_bot and p.id <> r.reader_id
             and not exists(select 1 from public.submissions s where s.room_id = r.id and s.round = r.round and s.player_id = p.id) loop
      aid := null; aid2 := null;
      select h.answer_id into aid from public.hands h where h.player_id = b.id order by random() limit 1;
      if n = 2 then
        select h.answer_id into aid2 from public.hands h where h.player_id = b.id and h.answer_id <> aid order by random() limit 1;
      end if;
      if aid is not null and (n = 1 or aid2 is not null) then
        insert into public.submissions(room_id, round, player_id, answer_id, answer_id2)
        values (r.id, r.round, b.id, aid, aid2) on conflict do nothing;
        delete from public.hands where player_id = b.id and answer_id in (aid, aid2);
      end if;
    end loop;
    perform public._deal(r.id);
    perform public._maybe_judge(r.id);
    update public.rooms set updated_at = now() where id = r.id;

  elsif r.status = 'ranking' then
    for b in select * from public.players p where p.room_id = r.id and p.active and p.is_bot
             and not exists(select 1 from public.rankings k where k.room_id = r.id and k.round = r.round and k.player_id = p.id) loop
      insert into public.rankings(room_id, round, player_id, cards)
      values (r.id, r.round, b.id, (select array_agg(x order by random()) from unnest(r.rank_cards) x))
      on conflict do nothing;
    end loop;
    perform public._maybe_score(r.id);
    update public.rooms set updated_at = now() where id = r.id;

  elsif r.status = 'clue' then
    if exists(select 1 from public.players where id = r.reader_id and active and is_bot) then
      update public.rooms set wave_clue = 'Indice de bot (vers ' || r.wave_target || ')',
        status = 'guessing', phase_at = now(), updated_at = now() where id = r.id;
    end if;

  elsif r.status = 'guessing' then
    for b in select * from public.players p where p.room_id = r.id and p.active and p.is_bot and p.id <> r.reader_id
             and not exists(select 1 from public.wave_guesses g where g.room_id = r.id and g.round = r.round and g.player_id = p.id) loop
      insert into public.wave_guesses(room_id, round, player_id, value)
      values (r.id, r.round, b.id, greatest(0, least(100, r.wave_target - 20 + floor(random() * 41)::integer)))
      on conflict do nothing;
    end loop;
    perform public._maybe_wave_score(r.id);
    update public.rooms set updated_at = now() where id = r.id;

  elsif r.status = 'judging' and exists(select 1 from public.players where id = r.reader_id and active and is_bot) then
    select s.id, s.player_id into sid, b.id from public.submissions s
      join public.players p on p.id = s.player_id and p.active
      where s.room_id = r.id and s.round = r.round order by random() limit 1;
    if sid is not null then
      update public.players set score = score + 1 where id = b.id returning score into sc;
      update public.rooms set status = case when sc >= r.target_score then 'finished' else 'reveal' end,
        winner_id = b.id, winning_submission_id = sid, phase_at = now(), updated_at = now() where id = r.id;
    end if;

  elsif r.status = 'finished' then
    update public.players set continue_requested = true
      where room_id = r.id and active and is_bot and not continue_requested;
    if not exists(select 1 from public.players where room_id = r.id and active and not continue_requested) then
      update public.players set ready = false, score = 0, discard_round = 0, next_ack_round = 0, continue_requested = false
        where room_id = r.id and active;
      delete from public.hands where room_id = r.id;
      delete from public.used_answers where room_id = r.id;
      delete from public.submissions where room_id = r.id;
      update public.rooms set status = 'lobby', round = 0, reader_id = null, previous_reader_id = null,
        question_id = null, question_choices = '{}', winner_id = null, winning_submission_id = null,
        used_questions = '{}', phase_at = now(), updated_at = now() where id = r.id;
    else
      update public.rooms set updated_at = now() where id = r.id;
    end if;
  end if;
end $function$;

-- ---------- État : les cartes à trou dans l'ordre du tirage (« la première » est la même pour tous) ----------
create or replace function public.get_state(p_code text, p_token uuid)
 returns json language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 if me.last_seen<now()-interval '5 minutes' then update public.players set last_seen=now() where id=me.id; end if;
 select * into r from public.rooms where id=me.room_id;
 return json_build_object(
 'room',json_build_object('code',r.code,'status',r.status,'round',r.round,'target',r.target_score,'mode',r.mode,'turns',r.judge_turns,'host_id',r.host_id,'reader_id',r.reader_id,'winner_id',r.winner_id,'winning_submission_id',r.winning_submission_id,'updated_at',r.updated_at,'phase_at',r.phase_at,'submission_count',(select count(*) from public.submissions s where s.room_id=r.id and s.round=r.round)),
 'me',json_build_object('id',me.id,'name',me.name,'ready',me.ready,'next_ack',me.next_ack_round,'continue_requested',me.continue_requested,'can_discard',r.status='answering' and r.reader_id<>me.id and me.discard_round<>r.round and not exists(select 1 from public.submissions s where s.room_id=r.id and s.round=r.round and s.player_id=me.id)),
 'question',(select q.text from public.questions q where q.id=r.question_id),
 'blanks',coalesce((select q.blanks from public.questions q where q.id=r.question_id),1),
 'question_choices',case when r.status='question_select' and r.reader_id=me.id then (select coalesce(json_agg(json_build_object('id',q.id,'text',q.text) order by array_position(r.question_choices,q.id)),'[]'::json) from public.questions q where q.id=any(r.question_choices)) else '[]'::json end,
 'players',(select coalesce(json_agg(json_build_object('id',p.id,'name',p.name,'score',p.score,'active',p.active,'ready',p.ready,'is_bot',p.is_bot,'next_ack',p.next_ack_round,'continue_requested',p.continue_requested,'judge_count',p.judge_count,
    'submitted',exists(select 1 from public.submissions s where s.room_id=r.id and s.round=r.round and s.player_id=p.id),
    'ranked',exists(select 1 from public.rankings k where k.room_id=r.id and k.round=r.round and k.player_id=p.id),
    'guessed',exists(select 1 from public.wave_guesses g where g.room_id=r.id and g.round=r.round and g.player_id=p.id)) order by p.seat),'[]'::json)
   from public.players p where p.room_id=r.id and (p.active or (r.status in('reveal','finished') and p.id=r.winner_id))),
 'hand',(select coalesce(json_agg(json_build_object('id',a.id,'text',a.text,'form',a.form) order by a.text),'[]'::json) from public.hands h join public.answers a on a.id=h.answer_id where h.player_id=me.id),
 'my_cards',(select coalesce(json_agg(json_build_object('text',a.text,'form',a.form) order by x.rang),'[]'::json)
             from public.submissions s
             cross join lateral unnest(array_remove(array[s.answer_id,s.answer_id2],null)) with ordinality as x(aid,rang)
             join public.answers a on a.id=x.aid
             where s.room_id=r.id and s.round=r.round and s.player_id=me.id),
 'submissions',case when r.status in('reveal','finished') or (r.status='judging' and r.reader_id=me.id) then
   (select coalesce(json_agg(json_build_object('id',s.id,'author',case when r.status in('reveal','finished') then p.name end,
      'cards',(select coalesce(json_agg(json_build_object('text',a.text,'form',a.form) order by x.rang),'[]'::json)
               from unnest(array_remove(array[s.answer_id,s.answer_id2],null)) with ordinality as x(aid,rang)
               join public.answers a on a.id=x.aid)) order by s.sort_key),'[]'::json)
    from public.submissions s join public.players p on p.id=s.player_id
    where s.room_id=r.id and s.round=r.round) else '[]'::json end,
 'rank_cards',case when r.mode='priorites' and r.status in('ranking','reveal','finished') then
   (select coalesce(json_agg(json_build_object('id',a.id,'text',a.text,'kind',a.kind) order by x.i),'[]'::json)
    from unnest(r.rank_cards) with ordinality as x(aid,i) join public._rank_pool(true) a on a.id=x.aid) else '[]'::json end,
 'my_ranking',(select k.cards from public.rankings k where k.room_id=r.id and k.round=r.round and k.player_id=me.id),
 'rankings',case when r.mode='priorites' and r.status in('reveal','finished') then
   (select coalesce(json_agg(json_build_object('player_id',k.player_id,'cards',k.cards,'points',k.points)),'[]'::json)
    from public.rankings k where k.room_id=r.id and k.round=r.round) else '[]'::json end,
 'wave',case when r.mode='ondes' and r.status in('clue','guessing','reveal','finished') and r.wave_card is not null then
   json_build_object(
     'left',(select c.left_text from public.wave_cards c where c.id=r.wave_card),
     'right',(select c.right_text from public.wave_cards c where c.id=r.wave_card),
     'clue',r.wave_clue,
     'target',case when r.reader_id=me.id or r.status in('reveal','finished') then r.wave_target end,
     'my_guess',(select g.value from public.wave_guesses g where g.room_id=r.id and g.round=r.round and g.player_id=me.id and g.player_id<>r.reader_id),
     'guesses',case when r.status in('reveal','finished') then
       (select coalesce(json_agg(json_build_object('player_id',g.player_id,'value',g.value,'points',g.points)),'[]'::json)
        from public.wave_guesses g where g.room_id=r.id and g.round=r.round) else '[]'::json end)
   end);
end $function$;
