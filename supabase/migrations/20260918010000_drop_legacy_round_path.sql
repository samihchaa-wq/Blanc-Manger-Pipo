-- _remove_player était resté branché sur l'ancien circuit de manche
-- (_next_reader + _start_round), abandonné depuis le passage au tirage
-- aléatoire du lecteur et à l'écran de choix de la carte à trou. Un départ en
-- cours de partie relançait donc une manche sans écran de choix, avec un
-- lecteur pris dans l'ordre des sièges et sans réinitialiser next_ack_round.
--
-- Il ignorait aussi complètement le statut question_select, apparu après lui :
-- si le lecteur partait pendant la roue, la partie restait bloquée sur un
-- lecteur absent, sans aucun moyen d'avancer.
create or replace function public._remove_player(p_player uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
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

  if r.status in ('question_select', 'answering', 'judging', 'reveal') then
    if (select count(*) from public.players where room_id = r.id and active) < 3 then
      if r.status not in ('question_select', 'reveal') then
        insert into public.hands(player_id, answer_id, room_id)
        select s.player_id, s.answer_id, r.id
        from public.submissions s join public.players p on p.id = s.player_id and p.active
        where s.room_id = r.id and s.round = r.round
        on conflict do nothing;
        delete from public.submissions where room_id = r.id and round = r.round;
      end if;
      update public.rooms set status = 'lobby', updated_at = now() where id = r.id;

    elsif r.reader_id = p_player then
      -- Le lecteur s'en va : on rend leurs cartes aux autres et on relance une
      -- manche par le circuit normal, lecteur retiré du tirage.
      nr := public._random_reader(r.id, p_player);
      if r.status not in ('question_select', 'reveal') then
        insert into public.hands(player_id, answer_id, room_id)
        select s.player_id, s.answer_id, r.id
        from public.submissions s join public.players p on p.id = s.player_id and p.active
        where s.room_id = r.id and s.round = r.round
        on conflict do nothing;
        delete from public.submissions where room_id = r.id and round = r.round;
      end if;
      -- Une manche restée au choix de la carte n'a jamais été jouée : on la
      -- rejoue sous le même numéro plutôt que d'en sauter une.
      perform public._begin_round(r.id, nr, case when r.status = 'question_select' then r.round else r.round + 1 end);

    elsif r.status in ('answering', 'judging') then
      delete from public.submissions where room_id = r.id and round = r.round and player_id = p_player;
      if r.status = 'judging'
         and not exists (select 1 from public.submissions where room_id = r.id and round = r.round) then
        update public.rooms set status = 'answering', updated_at = now() where id = r.id;
      elsif r.status = 'answering' then
        perform public._maybe_judge(r.id);
      end if;
    end if;
  end if;

  update public.rooms set updated_at = now() where id = r.id;
end
$$;
revoke all on function public._remove_player(uuid) from public, anon, authenticated;

-- Plus aucun appelant : l'ordre par siège et la manche sans écran de choix
-- ont été remplacés par _random_reader et _begin_round.
drop function if exists public._start_round(uuid, uuid, integer);
drop function if exists public._next_reader(uuid, uuid);
