-- Priorités : _begin_round aiguille vers _begin_rank_round quand la salle est en mode « priorites ».

create or replace function public._begin_round(p_room uuid, p_reader uuid, p_next_round integer)
 returns void language plpgsql security definer set search_path to '' as $function$
declare choices integer[];
begin
  if (select mode from public.rooms where id = p_room) = 'priorites' then
    perform public._begin_rank_round(p_room, p_next_round);
    return;
  end if;
  perform public._deal(p_room);
  choices := public._question_choices(p_room);
  delete from public.submissions where room_id = p_room and round = p_next_round;
  update public.players set next_ack_round = 0 where room_id = p_room and active;
  update public.rooms set
    status = 'question_select', round = p_next_round,
    previous_reader_id = reader_id, reader_id = p_reader,
    question_id = null, question_choices = choices,
    winner_id = null, winning_submission_id = null,
    phase_at = now(), updated_at = now()
  where id = p_room;
end $function$;

revoke all on function public._begin_round(uuid, uuid, integer) from public, anon, authenticated;
