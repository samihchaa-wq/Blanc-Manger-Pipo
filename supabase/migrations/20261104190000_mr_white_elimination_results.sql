-- Écran de résultat après chaque vote de Mr White.
-- Sans victoire, on interrompt brièvement le jeu avant la reprise des indices.
-- Les mots et les rôles encore secrets ne sont dévoilés qu'à la vraie fin.

alter table public.rooms drop constraint if exists rooms_status_check;
alter table public.rooms add constraint rooms_status_check check(status in (
  'lobby','question_select','answering','judging','ranking','clue','guessing',
  'naming','writing','voting','reveal','finished','white_clue','white_vote',
  'white_guess','white_elimination'
));


-- Barème collectif : tous les joueurs d'un même rôle gagnent le même total,
-- qu'ils soient encore en jeu ou déjà éliminés.
-- Civils : survivants de départ si les Civils gagnent, sinon 0.
-- Imposteurs : 1 point par membre d'une AUTRE équipe éliminé (Civil ou Mr White),
-- indépendamment de leur propre élimination.
-- Mr White : 2 points par autre joueur éliminé avant lui (Civil ou Imposteur).
create or replace function public._white_finish(p_room uuid,p_winner text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare r public.rooms; civil_survivors integer; opposing_eliminated integer;
begin
  select * into r from public.rooms where id=p_room for update;
  if r.mode<>'white' or r.status not in ('white_clue','white_vote','white_guess','white_elimination') then return; end if;
  if p_winner not in ('civils','imposteurs','white') then raise exception 'Équipe inconnue.'; end if;
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
    when 'white' then 'Mr White a trouvé le mot !'
    when 'civils' then 'Les Civils ont démasqué les imposteurs.'
    else 'Les imposteurs remportent la manche.' end,
    phase_at=now(),updated_at=now() where id=p_room;
end $fn$;

create or replace function public._white_check_end(p_room uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare r public.rooms; nc integer; ni integer;
begin
  select * into r from public.rooms where id=p_room for update;
  select count(*) filter (where wr.role='civil'),count(*) filter (where wr.role<>'civil')
    into nc,ni from public.white_roles wr join public.players p on p.id=wr.player_id and p.active
    where wr.room_id=p_room and wr.round=r.round and not wr.eliminated;
  if ni=0 then
    perform public._white_finish(p_room,'civils');
  elsif nc<=ni then
    perform public._white_finish(p_room,'imposteurs');
  else
    update public.rooms set status='white_elimination',phase_at=now(),updated_at=now() where id=p_room;
  end if;
end $fn$;

create or replace function public._white_resolve_vote(p_room uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare r public.rooms; out_id uuid; out_role text; nmax integer; ties integer; out_name text;
begin
  select * into r from public.rooms where id=p_room for update;
  if r.status<>'white_vote' then return; end if;
  if exists(select 1 from public.white_roles wr join public.players p on p.id=wr.player_id and p.active
      where wr.room_id=p_room and wr.round=r.round and not wr.eliminated and
      not exists(select 1 from public.white_votes v where v.room_id=p_room and v.round=r.round and
        v.cycle=r.white_cycle and v.player_id=wr.player_id)) then return; end if;
  select max(n) into nmax from (select count(*) n from public.white_votes v
    where v.room_id=p_room and v.round=r.round and v.cycle=r.white_cycle group by target_id) z;
  select count(*) into ties from (select target_id,count(*) n from public.white_votes
    where room_id=p_room and round=r.round and cycle=r.white_cycle group by target_id) z where n=nmax;
  if nmax is null or ties<>1 then
    update public.rooms set status='white_elimination',white_note='Égalité : personne n’est éliminé.',
      phase_at=now(),updated_at=now() where id=p_room;
    return;
  end if;
  select v.target_id into out_id from public.white_votes v
    where v.room_id=p_room and v.round=r.round and v.cycle=r.white_cycle
    group by v.target_id order by count(*) desc limit 1;
  update public.white_roles set eliminated=true,eliminated_cycle=r.white_cycle
    where room_id=p_room and round=r.round and player_id=out_id returning role into out_role;
  select name into out_name from public.players where id=out_id;
  update public.white_rounds set last_eliminated=out_id where room_id=p_room and round=r.round;
  update public.rooms set white_note=out_name||' est éliminé ('||
    case out_role when 'civil' then 'Civil' when 'undercover' then 'Undercover' else 'Mr White' end||').',
    updated_at=now() where id=p_room;
  if out_role='white' then
    update public.rooms set status='white_guess',phase_at=now(),updated_at=now() where id=p_room;
  else perform public._white_check_end(p_room); end if;
end $fn$;

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
    'winner',round_data.winner,'guess_correct',round_data.guess_correct,
    'civil_word',case when r.status in ('reveal','finished') or
      (r.status='white_guess' and me.id=public._white_referee(r.id)) then round_data.civil_word end,
    'undercover_word',case when r.status in ('reveal','finished') then round_data.undercover_word end
  );
end $fn$;

-- Le bouton de reprise est réservé à l'hôte : tous les téléphones restent synchronisés.
create or replace function public.white_resume(p_code text,p_token uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; survivors integer;
begin
  me:=public._player(p_code,p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id=me.room_id for update;
  if r.mode<>'white' or r.status<>'white_elimination' then
    raise exception 'Le jeu n’est pas prêt à reprendre.';
  end if;
  if r.host_id<>me.id then raise exception 'Seul l’hôte peut reprendre la manche.'; end if;
  select count(*) into survivors from public.players where room_id=r.id and active;
  if survivors<3 then
    update public.rooms set status='lobby',white_note=null,phase_at=now(),updated_at=now() where id=r.id;
    return;
  end if;
  -- En cas de départ pendant cet écran, l'état des équipes a pu changer.
  perform public._white_check_end(r.id);
  select * into r from public.rooms where id=me.room_id for update;
  if r.status='reveal' then return; end if;
  update public.rooms set status='white_clue',white_cycle=white_cycle+1,
    white_note=null,phase_at=now(),updated_at=now() where id=r.id;
end $fn$;

revoke execute on function public._white_finish(uuid,text),
  public._white_check_end(uuid),public._white_resolve_vote(uuid)
  from public,anon,authenticated;
grant execute on function public.white_resume(text,uuid) to anon,authenticated;
