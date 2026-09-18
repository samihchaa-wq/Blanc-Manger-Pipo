-- Devenir lecteur effaçait la main : _begin_round supprimait les cartes du
-- nouveau lecteur au motif qu'il n'en a pas besoin pour lire. Mais elles
-- étaient détruites, pas mises de côté : au tour suivant _deal recomplétait à
-- hand_size et le joueur récupérait six cartes entièrement neuves, perdant
-- celles qu'il gardait depuis le début de la partie.
--
-- Les cartes supprimées restaient par ailleurs dans used_answers, donc
-- consommées pour toute la partie sans être dans aucune main : à chaque
-- manche, six réponses disparaissaient du tirage.
--
-- Le lecteur garde donc sa main. Il ne peut de toute façon pas la jouer :
-- submit_answer refuse déjà les cartes du lecteur.
create or replace function public._begin_round(p_room uuid, p_reader uuid, p_next_round integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare choices integer[];
begin
  perform public._deal(p_room);
  choices := public._question_choices(p_room);
  delete from public.submissions where room_id = p_room and round = p_next_round;
  update public.players set next_ack_round = 0 where room_id = p_room and active;
  update public.rooms set
    status = 'question_select', round = p_next_round,
    previous_reader_id = reader_id, reader_id = p_reader,
    question_id = null, question_choices = choices,
    winner_id = null, winning_submission_id = null, skips_used = 0, updated_at = now()
  where id = p_room;
end $$;
revoke all on function public._begin_round(uuid, uuid, integer) from public, anon, authenticated;
