-- Mr White en présentiel : mots sur chaque téléphone, indices et devinette à l'oral,
-- puis seulement votes secrets et arbitrage dans l'application.

-- La validation de la proposition orale est confiée à un Civil de la salle.
-- Cela évite d'afficher le vrai mot sur le téléphone de Mr White.
create or replace function public._white_referee(p_room uuid)
returns uuid language sql stable security definer set search_path to '' as $fn$
  select p.id
  from public.rooms r
  join public.white_roles wr on wr.room_id=r.id and wr.round=r.round and wr.role='civil'
  join public.players p on p.id=wr.player_id and p.active
  where r.id=p_room
  order by p.seat
  limit 1
$fn$;

-- Les indices sont prononcés autour de la table, plus saisis un par un.
-- L'hôte ouvre le vote quand tout le monde a parlé et débattu.
create or replace function public.white_open_vote(p_code text,p_token uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms;
begin
  me:=public._player(p_code,p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id=me.room_id for update;
  if r.mode<>'white' or r.status<>'white_clue' then raise exception 'Ce n’est pas le moment de voter.'; end if;
  if r.host_id<>me.id then raise exception 'Seul l’hôte peut ouvrir le vote.'; end if;
  update public.rooms set status='white_vote',white_note=null,phase_at=now(),updated_at=now() where id=r.id;
end $fn$;

-- Mr White propose sa réponse à voix haute. Le Civil arbitre en comparant
-- à son mot secret déjà connu. Aucune réponse ne doit être tapée.
create or replace function public.white_oral_verdict(p_code text,p_token uuid,p_correct boolean)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms;
begin
  me:=public._player(p_code,p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id=me.room_id for update;
  if r.mode<>'white' or r.status<>'white_guess' then raise exception 'La réponse ne peut plus être vérifiée.'; end if;
  if me.id is distinct from public._white_referee(r.id) then
    raise exception 'Seul le joueur chargé de vérifier le mot peut valider.';
  end if;
  if p_correct is null then raise exception 'Choisis si le mot est correct.'; end if;
  update public.white_rounds set guess_correct=p_correct where room_id=r.id and round=r.round;
  if p_correct then
    perform public._white_finish(r.id,'white');
  else
    update public.rooms set white_note='Mr White n’a pas trouvé le mot. La partie continue.',updated_at=now() where id=r.id;
    perform public._white_check_end(r.id);
  end if;
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
    'phase',r.status,'cycle',r.white_cycle,'note',r.white_note,'role',mine.role,
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
    'last_eliminated',round_data.last_eliminated,'winner',round_data.winner,'guess_correct',round_data.guess_correct,
    'civil_word',case when r.status in ('reveal','finished') or
      (r.status='white_guess' and me.id=public._white_referee(r.id)) then round_data.civil_word end,
    'undercover_word',case when r.status in ('reveal','finished') then round_data.undercover_word end
  );
end $fn$;

create or replace function public.white_bot_step(p_code text,p_token uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; bot public.players; sid uuid; tid uuid; clue text; guess text;
begin
  me:=public._player(p_code,p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id=me.room_id for update;
  if me.id<>r.host_id then raise exception 'Seul l’hôte pilote les bots.'; end if;
  if r.mode<>'white' then return; end if;
  if r.status='white_clue' then
    -- Une partie est jouée dans la même pièce : seuls les bots affichent
    -- un indice à lire à voix haute par les participants.
    for bot in select p.* from public.players p
      join public.white_roles wr on wr.player_id=p.id and wr.room_id=r.id and wr.round=r.round
      where p.room_id=r.id and p.active and p.is_bot and not wr.eliminated
        and not exists(select 1 from public.white_clues c where c.room_id=r.id
          and c.round=r.round and c.cycle=r.white_cycle and c.player_id=p.id)
      order by p.seat loop
      select (array['Ça se trouve facilement','Je connais bien ça','On en voit partout',
        'C’est assez populaire','Ça me rappelle des souvenirs','Ça dépend des goûts'])[1+floor(random()*6)::integer] into clue;
      insert into public.white_clues(room_id,round,cycle,player_id,clue)
        values(r.id,r.round,r.white_cycle,bot.id,clue) on conflict do nothing;
    end loop;
    update public.rooms set updated_at=now() where id=r.id;
  elsif r.status='white_vote' then
    for bot in select p.* from public.players p join public.white_roles wr on wr.player_id=p.id
        where wr.room_id=r.id and wr.round=r.round and not wr.eliminated and p.active and p.is_bot
        and not exists(select 1 from public.white_votes v where v.room_id=r.id and v.round=r.round and v.cycle=r.white_cycle and v.player_id=p.id)
        order by p.seat loop
      exit when (select status from public.rooms where id=r.id)<>'white_vote';
      select wr.player_id into tid from public.white_roles wr join public.players p on p.id=wr.player_id and p.active
        where wr.room_id=r.id and wr.round=r.round and not wr.eliminated and wr.player_id<>bot.id order by random() limit 1;
      if tid is not null then perform public.white_vote(r.code,bot.token,tid); end if;
    end loop;
  elsif r.status='white_guess' then
    select p.* into bot from public.players p join public.white_roles wr on wr.player_id=p.id
      join public.white_rounds w on w.room_id=wr.room_id and w.round=wr.round
      where wr.room_id=r.id and wr.round=r.round and wr.role='white' and wr.eliminated
        and w.last_eliminated=p.id and p.active and p.is_bot limit 1;
    if bot.id is not null then
      select civil into guess from public.white_words where deleted_at is null order by random() limit 1;
      perform public.white_guess(r.code,bot.token,coalesce(guess,'aucune idée'));
    end if;
  end if;
end $fn$;


-- Aucune des règles précédentes concernant le salon, les scores, les bots ou les
-- autres mini-jeux n'est remplacée.
revoke execute on function public._white_referee(uuid) from public,anon,authenticated;
grant execute on function public.white_open_vote(text,uuid),public.white_oral_verdict(text,uuid,boolean)
  to anon,authenticated;
