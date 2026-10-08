-- « Longueur d'onde » devient « Baromètre » : message d'erreur mis à jour.
create or replace function public._begin_wave_round(p_room uuid, p_next_round integer)
 returns void language plpgsql security definer set search_path to '' as $function$
declare r public.rooms; j uuid; w uuid; c integer;
begin
  select * into r from public.rooms where id = p_room;
  select id into j from public.players
    where room_id = p_room and active and judge_count < r.judge_turns
    order by judge_count, seat limit 1;

  if j is null then
    select id into w from public.players where room_id = p_room and active order by score desc, seat limit 1;
    update public.rooms set status = 'finished', winner_id = w, winning_submission_id = null,
      phase_at = now(), updated_at = now() where id = p_room;
    return;
  end if;

  select id into c from public.wave_cards
    where deleted_at is null and not (id = any(r.used_waves)) order by random() limit 1;
  if c is null then
    update public.rooms set used_waves = '{}' where id = p_room;
    select id into c from public.wave_cards where deleted_at is null order by random() limit 1;
  end if;
  if c is null then raise exception 'Aucune carte Baromètre disponible.'; end if;

  update public.players set judge_count = judge_count + 1 where id = j;
  update public.players set next_ack_round = 0 where room_id = p_room and active;
  delete from public.wave_guesses where room_id = p_room and round = p_next_round;
  update public.rooms set
    status = 'clue', round = p_next_round,
    previous_reader_id = reader_id, reader_id = j,
    wave_card = c, wave_target = 2 + floor(random() * 97)::integer, wave_clue = null,
    used_waves = (select used_waves from public.rooms where id = p_room) || c,
    question_id = null, question_choices = '{}',
    winner_id = null, winning_submission_id = null,
    phase_at = now(), updated_at = now()
  where id = p_room;
end $function$;

