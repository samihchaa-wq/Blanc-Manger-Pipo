-- Priorités : nouvelle manche (juge suivant dans la rotation) ou fin de partie.

create or replace function public._begin_rank_round(p_room uuid, p_next_round integer)
 returns void language plpgsql security definer set search_path to '' as $function$
declare r public.rooms; j uuid; w uuid;
begin
  select * into r from public.rooms where id = p_room;
  -- rotation : le moins souvent juge passe en premier, à égalité l'ordre d'arrivée
  select id into j from public.players
    where room_id = p_room and active and judge_count < r.judge_turns
    order by judge_count, seat limit 1;

  if j is null then
    select id into w from public.players where room_id = p_room and active order by score desc, seat limit 1;
    update public.rooms set status = 'finished', winner_id = w, winning_submission_id = null,
      phase_at = now(), updated_at = now() where id = p_room;
    return;
  end if;

  update public.players set judge_count = judge_count + 1 where id = j;
  update public.players set next_ack_round = 0 where room_id = p_room and active;
  update public.rooms set
    status = 'ranking', round = p_next_round,
    previous_reader_id = reader_id, reader_id = j,
    rank_cards = public._draw_rank_cards(p_room),
    question_id = null, question_choices = '{}',
    winner_id = null, winning_submission_id = null,
    phase_at = now(), updated_at = now()
  where id = p_room;
end $function$;

revoke all on function public._begin_rank_round(uuid, integer) from public, anon, authenticated;
