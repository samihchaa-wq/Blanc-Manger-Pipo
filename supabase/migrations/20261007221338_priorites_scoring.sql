-- Priorités : décompte dès que tout le monde a classé.

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
      (select count(*) from generate_subscripts(k.cards, 1) i where k.cards[i] = jc[i])
    where k.room_id = p_room and k.round = r.round and k.player_id <> r.reader_id;
  update public.rankings set points = points + 2
    where room_id = p_room and round = r.round and player_id <> r.reader_id and points = cardinality(jc);
  update public.rankings set points =
      (select count(*) from public.rankings k
        where k.room_id = p_room and k.round = r.round and k.player_id <> r.reader_id and k.points >= 3)
    where room_id = p_room and round = r.round and player_id = r.reader_id;

  update public.players p set score = p.score + k.points
    from public.rankings k
    where k.room_id = p_room and k.round = r.round and k.player_id = p.id and p.active;
  update public.rooms set status = 'reveal', phase_at = now(), updated_at = now() where id = p_room;
end $function$;

revoke all on function public._maybe_score(uuid) from public, anon, authenticated;
