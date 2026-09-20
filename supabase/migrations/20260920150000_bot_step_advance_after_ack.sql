-- Correctif bots : en reveal et en fin de partie, les bots valident, mais si
-- l'humain a validé avant eux, personne ne relançait la manche (ou la partie).
-- bot_step déclenche donc l'avancement quand les bots sont les derniers à valider.
create or replace function public.bot_step(p_code text, p_token uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; b public.players; aid integer; aid2 integer; sid uuid; qid integer; n int; sc int; rd uuid;
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
    -- si les bots étaient les derniers à valider, on relance la manche.
    if not exists(select 1 from public.players where room_id = r.id and active and next_ack_round <> r.round) then
      rd := public._random_reader(r.id, r.reader_id);
      perform public._begin_round(r.id, rd, r.round + 1);
    else
      update public.rooms set updated_at = now() where id = r.id;
    end if;

  elsif r.status = 'finished' then
    update public.players set continue_requested = true
      where room_id = r.id and active and is_bot and not continue_requested;
    -- si les bots étaient les derniers, on repart au salon.
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
