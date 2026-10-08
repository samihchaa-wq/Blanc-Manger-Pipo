-- Priorités : départs et minuteur pendant le classement.

-- ---------- Départs : le juge qui part relance la manche, les autres sont retirés du décompte ----------
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

  if r.status in ('question_select', 'answering', 'judging', 'ranking', 'reveal') then
    if (select count(*) from public.players where room_id = r.id and active) < 3 then
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

create or replace function public.reap_idle(p_code text, p_token uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; pl record; rd uuid;
begin
  me := public._player(p_code, p_token);
  if me.id is null then return; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.id is null then return; end if;
  if now() - r.phase_at < interval '120 seconds' then return; end if;

  if r.status = 'question_select' then
    perform public._remove_player(r.reader_id);

  elsif r.status = 'answering' then
    for pl in
      select p.id from public.players p
      where p.room_id = r.id and p.active and p.id <> r.reader_id
        and not exists (
          select 1 from public.submissions s
          where s.room_id = r.id and s.round = r.round and s.player_id = p.id
        )
    loop
      perform public._remove_player(pl.id);
    end loop;
    perform public._maybe_judge(r.id);

  elsif r.status = 'ranking' then
    -- les devineurs d'abord : retirer le juge relance aussitôt une autre manche
    for pl in
      select p.id from public.players p
      where p.room_id = r.id and p.active
        and not exists (
          select 1 from public.rankings k
          where k.room_id = r.id and k.round = r.round and k.player_id = p.id
        )
      order by (p.id = r.reader_id)
    loop
      perform public._remove_player(pl.id);
    end loop;
    perform public._maybe_score(r.id);

  elsif r.status = 'judging' then
    perform public._remove_player(r.reader_id);

  elsif r.status = 'reveal' then
    rd := public._random_reader(r.id, r.reader_id);
    perform public._begin_round(r.id, rd, r.round + 1);
  end if;
end $function$;

revoke all on function public._remove_player(uuid) from public, anon, authenticated;
revoke all on function public.reap_idle(text, uuid) from public, anon, authenticated;
grant execute on function public.reap_idle(text, uuid) to anon;
