-- Victoire commune Mr White + Imposteur quand les Civils ont perdu
-- leur majorité et que les deux rôles ennemis sont encore en jeu.
-- Conserve les barèmes distincts des Civils, Imposteurs et de Mr White.
begin;

CREATE OR REPLACE FUNCTION public._white_check_end(p_room uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.rooms; nc integer; ni integer;
begin
  select * into r from public.rooms where id=p_room for update;
  select count(*) filter (where wr.role='civil'),count(*) filter (where wr.role<>'civil')
    into nc,ni from public.white_roles wr join public.players p on p.id=wr.player_id and p.active
    where wr.room_id=p_room and wr.round=r.round and not wr.eliminated;
  if ni=0 then
    perform public._white_finish(p_room,'civils');
  elsif nc<=ni then
    -- Si Mr White ET un Imposteur survivent, ils gagnent ensemble :
    -- la défaite des Civils n'efface pas la victoire de Mr White.
    if exists (select 1 from public.white_roles wr join public.players p on p.id=wr.player_id and p.active
        where wr.room_id=p_room and wr.round=r.round and not wr.eliminated and wr.role='undercover')
       and exists (select 1 from public.white_roles wr join public.players p on p.id=wr.player_id and p.active
        where wr.room_id=p_room and wr.round=r.round and not wr.eliminated and wr.role='white') then
      perform public._white_finish(p_room,'alliance');
    elsif exists (select 1 from public.white_roles wr join public.players p on p.id=wr.player_id and p.active
        where wr.room_id=p_room and wr.round=r.round and not wr.eliminated and wr.role='undercover') then
      perform public._white_finish(p_room,'imposteurs');
    else
      perform public._white_finish(p_room,'white');
    end if;
  else
    update public.rooms set status='white_elimination',phase_at=now(),updated_at=now() where id=p_room;
  end if;
end $function$;

CREATE OR REPLACE FUNCTION public._white_finish(p_room uuid, p_winner text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.rooms; civil_survivors integer; opposing_eliminated integer;
begin
  select * into r from public.rooms where id=p_room for update;
  if r.mode<>'white' or r.status not in ('white_clue','white_vote','white_guess','white_elimination') then return; end if;
  if p_winner not in ('civils','imposteurs','white','alliance') then raise exception 'Équipe inconnue.'; end if;
  select count(*) into civil_survivors from public.white_roles wr
    where wr.room_id=p_room and wr.round=r.round
      and wr.role='civil' and not wr.eliminated;
  select count(*) into opposing_eliminated from public.white_roles wr
    where wr.room_id=p_room and wr.round=r.round
      and wr.role in ('civil','white') and wr.eliminated_cycle is not null;
  update public.white_rounds set winner=p_winner where room_id=p_room and round=r.round;
  update public.players p set score=p.score+
    case wr.role
      when 'civil' then case when p_winner='civils' then civil_survivors else 0 end
      when 'undercover' then opposing_eliminated
      when 'white' then (
        select count(*) from public.white_roles other
        where other.room_id=p_room and other.round=r.round
          and other.player_id<>wr.player_id
          and other.eliminated_cycle is not null
          and (wr.eliminated_cycle is null or other.eliminated_cycle<wr.eliminated_cycle)
      )*2
      else 0
    end
  from public.white_roles wr
  where wr.room_id=p_room and wr.round=r.round and wr.player_id=p.id and p.active;
  update public.rooms set status='reveal',white_note=case p_winner
    when 'white' then case when (select w.guess_correct from public.white_rounds w
         where w.room_id=p_room and w.round=r.round) is true
         then 'Mr White a trouvé le mot !'
         else 'Mr White remporte la manche.' end
    when 'alliance' then 'Mr White et l’Imposteur gagnent ensemble.'
    when 'civils' then 'Les Civils ont démasqué les imposteurs.'
    else 'Les imposteurs remportent la manche.' end,
    phase_at=now(),updated_at=now() where id=p_room;
end $function$;

commit;
