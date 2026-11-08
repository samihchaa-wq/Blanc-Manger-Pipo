-- Sécurité métier : les votes sont définitifs et seul l'hôte pilote les bots.
-- Fonctions copiées depuis Supabase le 8 novembre 2026, modification ciblée.
begin;

CREATE OR REPLACE FUNCTION public.bot_step(p_code text, p_token uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms; b public.players; aid integer; aid2 integer; sid uuid; qid integer; n int; sc int; rd uuid;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id is distinct from me.id then raise exception 'Seul l’hôte pilote les bots.'; end if;

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

  elsif r.status = 'naming' then
    select * into b from public.players where id = r.reader_id and active and is_bot;
    if b.id is not null then
      perform public.bac_category(r.code, b.token, public._bac_default_category(r.id));
    end if;

  elsif r.status = 'writing' then
    -- une case sur cinq reste vide, pour voir le 0 d'office
    for b in select * from public.players p where p.room_id = r.id and p.active and p.is_bot
             and not exists(select 1 from public.bac_answers x where x.room_id = r.id and x.round = r.round and x.player_id = p.id and x.done) loop
      perform public.bac_save(r.code, b.token,
        (select array_agg(case when random() < .2 then '' else r.bac_letter || ' comme bot' end) from generate_series(1, 6)),
        true);
    end loop;

  elsif r.status = 'voting' then
    for b in select * from public.players p where p.room_id = r.id and p.active and p.is_bot
             and exists(select 1 from public.bac_answers x where x.room_id = r.id and x.round = r.round
                        and x.player_id <> p.id and x.points[r.bac_step + 1] is null) loop
      perform public.bac_vote(r.code, b.token,
        (select case when v < .6 then 2 when v < .8 then 1 else 0 end from (select random() as v) t));
    end loop;

  elsif r.status = 'judging' and exists(select 1 from public.players where id = r.reader_id and active and is_bot) then
    select s.id, s.player_id into sid, b.id from public.submissions s
      join public.players p on p.id = s.player_id and p.active
      where s.room_id = r.id and s.round = r.round order by random() limit 1;
    if sid is not null then
      update public.players set score = score + 1 where id = b.id returning score into sc;
      update public.rooms set status = case when sc >= r.target_score then 'finished' else 'reveal' end,
        winner_id = b.id, winning_submission_id = sid, phase_at = now(), updated_at = now() where id = r.id;
    end if;

  elsif r.status = 'reveal' then
    update public.players set next_ack_round = r.round
      where room_id = r.id and active and is_bot and next_ack_round <> r.round;
    if not exists(select 1 from public.players where room_id = r.id and active and next_ack_round <> r.round) then
      rd := public._random_reader(r.id, r.reader_id);
      perform public._begin_round(r.id, rd, r.round + 1);
    else
      update public.rooms set updated_at = now() where id = r.id;
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

CREATE OR REPLACE FUNCTION public.dico_vote(p_code text, p_token uuid, p_def uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms; d public.dico_defs;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.mode <> 'dico' or r.status <> 'dico_vote' then raise exception 'Ce n’est pas le moment de voter.'; end if;
  if r.reader_id = me.id then raise exception 'Le meneur ne vote pas.'; end if;
  select * into d from public.dico_defs where id = p_def and room_id = r.id and round = r.round;
  if d.id is null then raise exception 'Définition inconnue.'; end if;
  if d.player_id is not distinct from me.id then raise exception 'Tu ne peux pas voter pour ta propre définition.'; end if;
  insert into public.dico_votes(room_id, round, voter_id, def_id) values (r.id, r.round, me.id, d.id)
    on conflict (room_id, round, voter_id) do nothing;
  if not found then raise exception 'Ton vote est déjà enregistré.'; end if;
  perform public._dico_advance(r.id);
end $function$;

CREATE OR REPLACE FUNCTION public.dilemme_vote(p_code text, p_token uuid, p_buts uuid[], p_yes boolean[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms; attendus integer; recus integer;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.mode <> 'dilemme' or r.status <> 'dilemme_vote' then raise exception 'Ce n’est pas le moment de voter.'; end if;
  if exists (select 1 from public.dilemme_votes
             where room_id = r.id and round = r.round and voter_id = me.id) then
    raise exception 'Ton vote est déjà enregistré.';
  end if;
  if (select count(distinct x) from unnest(p_buts) as x) <> coalesce(cardinality(p_buts), 0) then
    raise exception 'Une proposition est présente plusieurs fois.';
  end if;
  if coalesce(cardinality(p_buts), 0) <> coalesce(cardinality(p_yes), 0) then raise exception 'Votes incomplets.'; end if;
  if exists (select 1 from unnest(p_yes) y where y is null) then raise exception 'Réponds Oui ou Non à chaque proposition.'; end if;
  if exists (select 1 from unnest(p_buts) x left join public.dilemme_buts b on b.id = x and b.room_id = r.id and b.round = r.round
             where b.id is null) then raise exception 'Proposition inconnue.'; end if;
  if exists (select 1 from public.dilemme_buts b where b.id = any(p_buts) and b.player_id = me.id) then
    raise exception 'Tu ne votes pas pour ta propre proposition.'; end if;
  select count(*) into attendus from public.dilemme_buts b join public.players a on a.id = b.player_id and a.active
    where b.room_id = r.id and b.round = r.round and b.player_id <> me.id;
  select count(distinct x) into recus from unnest(p_buts) x
    join public.dilemme_buts b on b.id = x join public.players a on a.id = b.player_id and a.active;
  if recus < attendus then raise exception 'Réponds Oui ou Non à chaque proposition.'; end if;
  insert into public.dilemme_votes(room_id, round, voter_id, but_id, yes)
  select distinct on (x.b) r.id, r.round, me.id, x.b, x.y from unnest(p_buts, p_yes) as x(b, y);
  perform public._dilemme_advance(r.id);
end $function$;

commit;
