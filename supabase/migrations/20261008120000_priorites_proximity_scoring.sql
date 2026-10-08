-- Priorités : barème à la proximité.
-- Une carte au bon rang rapporte 2 points, à un rang près 1 point. Un
-- sans-faute ajoute 2 points (12 au maximum). Avant, seul le rang exact
-- comptait : contre 1-2-3-4-5, le pronostic 2-3-4-5-1 faisait 0, il fait
-- désormais 4. Le juge marque 1 point par joueur qui atteint 5 points.

create or replace function public._maybe_score(p_room uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare r public.rooms; jc integer[];
begin
  select * into r from public.rooms where id = p_room;
  if r.status <> 'ranking' then return; end if;
  if exists (
    select 1 from public.players p
    where p.room_id = p_room and p.active
      and not exists (select 1 from public.rankings k where k.room_id = p_room and k.round = r.round and k.player_id = p.id)
  ) then return; end if;

  select cards into jc from public.rankings where room_id = p_room and round = r.round and player_id = r.reader_id;
  if jc is null then return; end if;

  update public.rankings k set points =
      (select coalesce(sum(case abs(i - array_position(jc, k.cards[i])) when 0 then 2 when 1 then 1 else 0 end), 0)
         from generate_subscripts(k.cards, 1) i)
      + case when k.cards = jc then 2 else 0 end
    where k.room_id = p_room and k.round = r.round and k.player_id <> r.reader_id;
  update public.rankings set points =
      (select count(*) from public.rankings k
        where k.room_id = p_room and k.round = r.round and k.player_id <> r.reader_id and k.points >= 5)
    where room_id = p_room and round = r.round and player_id = r.reader_id;

  update public.players p set score = p.score + k.points
    from public.rankings k
    where k.room_id = p_room and k.round = r.round and k.player_id = p.id and p.active;
  update public.rooms set status = 'reveal', phase_at = now(), updated_at = now() where id = p_room;
end $function$;

revoke all on function public._maybe_score(uuid) from public, anon, authenticated;
