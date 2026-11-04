-- Afficher uniquement le nombre d'Imposteurs encore en jeu après le vote.
-- Mr White forme une équipe distincte et n'entre pas dans ce décompte.
-- Les identités secrètes des survivants restent protégées.

create or replace function public.white_state(p_code text,p_token uuid)
returns json language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; round_data public.white_rounds; mine public.white_roles;
begin
  me:=public._player(p_code,p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id=me.room_id;
  if r.mode<>'white' then raise exception 'Ce salon ne joue pas à Mr White.'; end if;
  if r.status='lobby' then return json_build_object('phase','lobby'); end if;
  select * into round_data from public.white_rounds where room_id=r.id and round=r.round;
  select * into mine from public.white_roles where room_id=r.id and round=r.round and player_id=me.id;
  return json_build_object(
    'phase',r.status,'cycle',r.white_cycle,'note',r.white_note,
    -- Ne révéler aucun rôle aux Civils ni aux imposteurs, même dans la réponse réseau.
    'role',case when mine.role='white' then 'white' end,
    'word',case when mine.role='civil' then round_data.civil_word when mine.role='undercover' then round_data.undercover_word end,
    'eliminated',coalesce(mine.eliminated,false),
    'speaker_id',case when r.status='white_clue' then public._white_speaker(r.id) end,
    'has_clue',exists(select 1 from public.white_clues c where c.room_id=r.id and c.round=r.round and c.cycle=r.white_cycle and c.player_id=me.id),
    'voted',exists(select 1 from public.white_votes v where v.room_id=r.id and v.round=r.round and v.cycle=r.white_cycle and v.player_id=me.id),
    'can_validate',r.status='white_guess' and me.id=public._white_referee(r.id),
    'bot_pending',case when r.status='white_clue' then
      exists(select 1 from public.players p join public.white_roles wr on wr.player_id=p.id
        where p.room_id=r.id and p.active and p.is_bot and wr.room_id=r.id and wr.round=r.round
          and not wr.eliminated and not exists(select 1 from public.white_clues c where c.room_id=r.id
            and c.round=r.round and c.cycle=r.white_cycle and c.player_id=p.id))
      when r.status='white_vote' then
      exists(select 1 from public.players p join public.white_roles wr on wr.player_id=p.id and wr.room_id=r.id and wr.round=r.round
        where p.room_id=r.id and p.active and p.is_bot and not wr.eliminated
          and not exists(select 1 from public.white_votes v where v.room_id=r.id and v.round=r.round and v.cycle=r.white_cycle and v.player_id=p.id))
      when r.status='white_guess' then
      exists(select 1 from public.players p join public.white_roles wr on wr.player_id=p.id and wr.room_id=r.id and wr.round=r.round
        join public.white_rounds wrd on wrd.room_id=r.id and wrd.round=r.round
        where p.room_id=r.id and p.active and p.is_bot and wr.role='white' and wr.eliminated and wrd.last_eliminated=p.id)
      else false end,
    'votes_count',(select count(*) from public.white_votes v where v.room_id=r.id and v.round=r.round and v.cycle=r.white_cycle),
    'clues',(select coalesce(json_agg(json_build_object('player_id',c.player_id,'text',c.clue) order by c.created_at),'[]'::json)
             from public.white_clues c where c.room_id=r.id and c.round=r.round and c.cycle=r.white_cycle),
    'roles',(select coalesce(json_agg(json_build_object('player_id',wr.player_id,
      'out',wr.eliminated,'role',case when wr.eliminated or r.status in ('reveal','finished') then wr.role end,
      'voted',exists(select 1 from public.white_votes v where v.room_id=r.id and v.round=r.round
        and v.cycle=r.white_cycle and v.player_id=wr.player_id))
      order by p.seat),'[]'::json)
      from public.white_roles wr join public.players p on p.id=wr.player_id
      where wr.room_id=r.id and wr.round=r.round),
    'last_eliminated',case
      when r.status in ('reveal','finished') then round_data.last_eliminated
      when exists (select 1 from public.white_roles wr
        where wr.room_id=r.id and wr.round=r.round
          and wr.player_id=round_data.last_eliminated
          and wr.eliminated_cycle=r.white_cycle) then round_data.last_eliminated
      else null end,
    'impostors_remaining',case when r.status='white_elimination' then
      (select count(*) from public.white_roles wr
        join public.players p on p.id=wr.player_id and p.active
        where wr.room_id=r.id and wr.round=r.round
          and wr.role='undercover' and not wr.eliminated)
      else null end,
    'winner',round_data.winner,'guess_correct',round_data.guess_correct,
    'civil_word',case when r.status in ('reveal','finished') or
      (r.status='white_guess' and me.id=public._white_referee(r.id)) then round_data.civil_word end,
    'undercover_word',case when r.status in ('reveal','finished') then round_data.undercover_word end
  );
end $fn$;
