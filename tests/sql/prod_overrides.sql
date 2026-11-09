-- Fonctions recopiées telles qu'elles tournent en production (relues le 2026-11-09)
-- là où l'historique du dépôt diverge : après le rejeu des migrations, la base
-- de test se comporte comme la production pour les salons, départs et états.
-- Aucune donnée ni aucun secret : uniquement du code déjà public par ailleurs.
CREATE OR REPLACE FUNCTION public._player(p_code text, p_token uuid)
 RETURNS players
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select p.* from public.players p join public.rooms r on r.id = p.room_id
  where r.code = upper(trim(p_code)) and p.token = p_token and p.active
$function$;

CREATE OR REPLACE FUNCTION public._create_room_base(p_name text, p_target integer DEFAULT 5, p_mode text DEFAULT 'phrases'::text, p_turns integer DEFAULT 2)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r public.rooms;
  p public.players;
  n text := left(trim(coalesce(p_name, '')), 20);
  client_hash text;
  attempt integer;
begin
  if n = '' then
    raise exception 'Choisis un pseudo.';
  end if;
  if p_target is null or p_target not between 1 and 20 then
    raise exception 'Le nombre de manches doit être entre 1 et 20.';
  end if;
  if p_mode is null or p_mode not in ('phrases', 'priorites', 'ondes', 'bac', 'white') then
    raise exception 'Jeu inconnu.';
  end if;
  if p_turns is null or p_turns not between 1 and 5 then
    raise exception 'Le nombre de tours doit être entre 1 et 5.';
  end if;

  client_hash := public._client_hash();

  if client_hash is not null then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('bmp-create:' || client_hash, 0)
    );
    if (
      select count(*)
      from public.rooms x
      where x.created_by_hash = client_hash
        and x.created_at > now() - interval '10 minutes'
    ) >= 10 then
      raise exception 'Trop de parties créées récemment. Réessaie dans quelques minutes.';
    end if;
  end if;

  delete from public.rooms
  where updated_at < now() - interval '1 day';

  for attempt in 1..5 loop
    begin
      insert into public.rooms(code, target_score, mode, judge_turns, created_by_hash)
      values (public._new_code(), p_target, p_mode, p_turns, client_hash)
      returning * into r;
      exit;
    exception when unique_violation then
      if attempt = 5 then
        raise exception 'Impossible de générer un code de partie. Réessaie.';
      end if;
    end;
  end loop;

  insert into public.players(room_id, name, seat, joined_by_hash)
  values (r.id, n, 0, client_hash)
  returning * into p;

  update public.rooms
  set host_id = p.id
  where id = r.id;

  return json_build_object('code', r.code, 'player_id', p.id, 'token', p.token);
end
$function$;

CREATE OR REPLACE FUNCTION public._set_room_options_base(p_code text, p_token uuid, p_mode text, p_target integer, p_turns integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception 'Seul l’hôte choisit le jeu.'; end if;
  if r.status <> 'lobby' then raise exception 'Le jeu se choisit depuis le salon.'; end if;
  if p_mode is null or p_mode not in ('phrases', 'priorites', 'ondes', 'bac', 'white') then raise exception 'Jeu inconnu.'; end if;
  if p_target is null or p_target not between 1 and 20 then raise exception 'Le nombre de manches doit être entre 1 et 20.'; end if;
  if p_turns is null or p_turns not between 1 and 5 then raise exception 'Le nombre de tours doit être entre 1 et 5.'; end if;
  if (select count(*) from public.players where room_id = r.id and active) > public._max_players(p_mode) then
    raise exception 'Le Petit bac se joue à deux.';
  end if;
  update public.rooms set mode = p_mode, target_score = p_target, judge_turns = p_turns, updated_at = now()
    where id = r.id;
end $function$;

CREATE OR REPLACE FUNCTION public.kick_player(p_code text, p_token uuid, p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id;
  if r.host_id <> me.id then raise exception 'Seul l''hôte peut retirer un joueur.'; end if;
  if p_player_id = me.id then raise exception 'Utilise « Quitter » pour partir.'; end if;
  if not exists (select 1 from public.players where id = p_player_id and room_id = r.id and active) then
    raise exception 'Joueur introuvable.';
  end if;
  perform public._remove_player(p_player_id);
end
$function$;

CREATE OR REPLACE FUNCTION public.leave_room(p_code text, p_token uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players;
begin
  me := public._player(p_code, p_token);
  if me.id is null then return; end if;
  perform public._remove_player(me.id);
end
$function$;

CREATE OR REPLACE FUNCTION public._remove_player_base(p_player uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pl public.players; r public.rooms; nr uuid;
begin
  select * into pl from public.players where id = p_player;
  if pl.id is null or not pl.active then return; end if;

  select * into r from public.rooms where id = pl.room_id for update;

  update public.players set active = false where id = p_player;
  delete from public.hands where player_id = p_player;
  if r.mode = 'white' and r.status in ('white_clue','white_vote','white_guess') then
    perform public.white_depart(r.id,p_player);
  end if;

  if r.host_id = p_player then
    update public.rooms
    set host_id = (select id from public.players where room_id = r.id and active order by seat limit 1)
    where id = r.id;
  end if;

  if r.status in ('question_select', 'answering', 'judging', 'ranking', 'clue', 'guessing',
                  'naming', 'writing', 'voting', 'reveal') then
    if (select count(*) from public.players where room_id = r.id and active) < public._min_players(r.mode) then
      if r.status in ('answering', 'judging') then
        perform public._return_submissions(r.id, r.round);
      end if;
      update public.rooms set status = 'lobby', phase_at = now(), updated_at = now() where id = r.id;

    elsif r.reader_id = p_player then
      nr := public._random_reader(r.id, p_player);
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

CREATE OR REPLACE FUNCTION public._get_state_base(p_code text, p_token uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    'guessed',exists(select 1 from public.wave_guesses g where g.room_id=r.id and g.round=r.round and g.player_id=p.id),
    'bac_done',exists(select 1 from public.bac_answers b where b.room_id=r.id and b.round=r.round and b.player_id=p.id and b.done)) order by p.seat),'[]'::json)
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
   end,
 'bac',case when r.mode='bac' and r.status in('naming','writing','voting','reveal') then
   json_build_object(
     'categories',r.bac_categories,
     'letter',case when r.status<>'naming' then r.bac_letter end,
     'step',r.bac_step,
     'mine',(select b.answers from public.bac_answers b where b.room_id=r.id and b.round=r.round and b.player_id=me.id),
     'done',coalesce((select b.done from public.bac_answers b where b.room_id=r.id and b.round=r.round and b.player_id=me.id),false),
     'rows',case when r.status in('voting','reveal') then
       (select coalesce(json_agg(json_build_object('player_id',b.player_id,
          'answers',case when r.status='voting' then b.answers[1:r.bac_step+1] else b.answers end,
          'points',case when r.status='voting' then b.points[1:r.bac_step] else b.points end,
          'pending',r.status='voting' and b.points[r.bac_step+1] is null) order by p.seat),'[]'::json)
        from public.bac_answers b join public.players p on p.id=b.player_id and p.active
        where b.room_id=r.id and b.round=r.round) else '[]'::json end)
   end);
end $function$;
