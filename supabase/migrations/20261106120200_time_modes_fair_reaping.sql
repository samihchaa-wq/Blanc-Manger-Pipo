-- Les délais sont calculés par public._time_phase_seconds.
-- Aucune carte, classement ou position factice n'est créé à l'expiration.
create or replace function public.reap_idle(p_code text,p_token uuid)
returns void language plpgsql security definer set search_path to ''
as $time$
declare me public.players; r public.rooms; jc integer[]; submitted integer; rd uuid;
begin
 me:=public._player(p_code,p_token);
 if me.id is null then return; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.id is null or not public._time_expired(r) then return; end if;
 if r.status='answering' and r.mode='phrases' then
   select count(*) into submitted from public.submissions s
     join public.players p on p.id=s.player_id and p.active
     where s.room_id=r.id and s.round=r.round;
   if submitted>0 then
     update public.rooms set status='judging',phase_at=now(),updated_at=now() where id=r.id;
   else
     rd:=public._next_reader(r.id,r.reader_id);
     perform public._begin_round(r.id,rd,r.round+1);
   end if;
 elsif r.status='ranking' and r.mode='priorites' then
   select cards into jc from public.rankings
    where room_id=r.id and round=r.round and player_id=r.reader_id;
   if jc is null then
     perform public._begin_round(r.id,null,r.round+1);
   else
     update public.rankings k set points =
      (select coalesce(sum(case abs(i - array_position(jc,k.cards[i]))
           when 0 then 2 when 1 then 1 else 0 end),0)
        from generate_subscripts(k.cards,1) i)
      + case when k.cards=jc then 2 else 0 end
      where k.room_id=r.id and k.round=r.round and k.player_id<>r.reader_id;
     update public.rankings set points=
       (select count(*) from public.rankings k where k.room_id=r.id and k.round=r.round
         and k.player_id<>r.reader_id and k.points>=5)
       where room_id=r.id and round=r.round and player_id=r.reader_id;
     update public.players p set score=p.score+k.points
      from public.rankings k
      where k.room_id=r.id and k.round=r.round and k.player_id=p.id and p.active;
     update public.rooms set status='reveal',phase_at=now(),updated_at=now() where id=r.id;
   end if;
 elsif r.status='clue' and r.mode='ondes' then
   -- Pas d'indice : on saute la manche, aucun joueur ne marque de points.
   perform public._begin_round(r.id,null,r.round+1);
 elsif r.status='guessing' and r.mode='ondes' then
   update public.wave_guesses g set points=
     case when abs(g.value-r.wave_target)<=3 then 4
          when abs(g.value-r.wave_target)<=9 then 3
          when abs(g.value-r.wave_target)<=15 then 2 else 0 end
    where g.room_id=r.id and g.round=r.round;
   insert into public.wave_guesses(room_id,round,player_id,value,points)
    select r.id,r.round,r.reader_id,r.wave_target,
      coalesce((select round(avg(g.points))::integer from public.wave_guesses g
        where g.room_id=r.id and g.round=r.round and g.player_id<>r.reader_id),0)
    on conflict (room_id,round,player_id) do update set value=excluded.value,points=excluded.points;
   update public.players p set score=p.score+g.points from public.wave_guesses g
    where g.room_id=r.id and g.round=r.round and g.player_id=p.id and p.active;
   update public.rooms set status='reveal',phase_at=now(),updated_at=now() where id=r.id;
 elsif r.status='naming' and r.mode='bac' then
   if exists(select 1 from public.players where id=r.reader_id and active) then
     perform public.bac_category(r.code,
       (select token from public.players where id=r.reader_id),
       public._bac_default_category(r.id));
   end if;
 elsif r.status='writing' and r.mode='bac' then
   perform public._bac_start_vote(r.id);
 elsif r.status='white_vote' and r.mode='white' then
   perform public._white_resolve_vote(r.id);
 end if;
end $time$;

-- L'ancienne routine attribuait des réponses ou classements aléatoires :
-- elle n'est plus appelée par reap_idle et n'est pas accessible directement.
revoke execute on function public._reap_idle_timed(text,uuid) from public,anon,authenticated;
