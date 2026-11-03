-- Mr White en présentiel : mots sur chaque téléphone, indices et devinette à l'oral,
-- puis seulement votes secrets et arbitrage dans l'application.
-- MrWhitz remplace un imposteur tiré au sort une partie sur cinq (20 %).
alter table public.rooms add column if not exists white_has_white boolean not null default false;

-- La validation de la proposition orale est confiée à un Civil de la salle.
-- Cela évite d'afficher le vrai mot sur le téléphone de Mr White.
create or replace function public._white_referee(p_room uuid)
returns uuid language sql stable security definer set search_path to '' as $fn$
  select p.id
  from public.rooms r
  join public.white_roles wr on wr.room_id=r.id and wr.round=r.round and wr.role='civil'
  join public.players p on p.id=wr.player_id and p.active
  where r.id=p_room
  order by p.is_bot, p.seat
  limit 1
$fn$;

create or replace function public._begin_white_round(p_room uuid,p_next_round integer)
returns void language plpgsql security definer set search_path to '' as $fn$
declare r public.rooms; c public.white_words; n integer; intruders integer; white_count integer; champ uuid;
begin
  select * into r from public.rooms where id=p_room for update;
  if p_next_round>r.target_score then
    select id into champ from public.players where room_id=p_room and active order by score desc,seat limit 1;
    update public.rooms set status='finished',winner_id=champ,phase_at=now(),updated_at=now() where id=p_room;
    return;
  end if;
  if p_next_round=1 then
    delete from public.white_rounds where room_id=p_room;
    -- Un tirage par partie complète, et non à chaque manche :
    -- MrWhitz apparaît dans environ 20 % des parties.
    r.white_has_white := random() < 0.20;
    update public.rooms set white_used_words='{}',white_has_white=r.white_has_white where id=p_room;
    r.white_used_words:='{}';
  end if;
  select * into c from public.white_words
   where deleted_at is null and not (id=any(r.white_used_words)) order by random() limit 1;
  if c.id is null then
    select * into c from public.white_words where deleted_at is null order by random() limit 1;
    update public.rooms set white_used_words='{}' where id=p_room;
  end if;
  if c.id is null then raise exception 'Aucune paire de mots Mr White disponible.'; end if;
  select count(*) into n from public.players where room_id=p_room and active;
  if n<3 then raise exception 'Mr White demande au moins 3 joueurs.'; end if;
  -- Total d'imposteurs, MrWhitz compris :
  -- 3–4 joueurs : 1 ; 5–7 : 2 ; 8–11 : 3 ; 12 : 4.
  intruders := case when n>=12 then 4 when n>=8 then 3 when n>=5 then 2 else 1 end;
  white_count := case when r.white_has_white then 1 else 0 end;
  insert into public.white_rounds(room_id,round,word_id,civil_word,undercover_word)
  values(p_room,p_next_round,c.id,c.civil,c.undercover);
  with distribution as (
    select p.id,row_number() over(order by random()) as tirage
    from public.players p where p.room_id=p_room and p.active
  )
  insert into public.white_roles(room_id,round,player_id,role)
  select p_room,p_next_round,d.id,
    case when d.tirage <= white_count then 'white'
         when d.tirage <= intruders then 'undercover'
         else 'civil' end
  from distribution d;
  update public.players set next_ack_round=0 where room_id=p_room and active;
  update public.rooms set status='white_clue',round=p_next_round,
    previous_reader_id=reader_id,reader_id=(select id from public.players where room_id=p_room and active order by random() limit 1),
    white_cycle=1,white_note=null,white_used_words=white_used_words||c.id,
    question_id=null,question_choices='{}',winner_id=null,winning_submission_id=null,
    phase_at=now(),updated_at=now() where id=p_room;
end $fn$;

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
    -- Un MrWhitz bot peut deviner automatiquement, comme avant :
    -- les vraies personnes, elles, annoncent leur proposition à voix haute.
    select p.* into bot from public.players p join public.white_roles wr on wr.player_id=p.id
      join public.white_rounds w on w.room_id=wr.room_id and w.round=wr.round
      where wr.room_id=r.id and wr.round=r.round and wr.role='white' and wr.eliminated
        and w.last_eliminated=p.id and p.active and p.is_bot limit 1;
    if bot.id is not null then
      select civil into guess from public.white_words where deleted_at is null order by random() limit 1;
      perform public.white_guess(r.code,bot.token,coalesce(guess,'aucune idée'));
    end if;
end $fn$;


-- Aucune des règles précédentes concernant le salon, les scores, les bots ou les
-- autres mini-jeux n'est remplacée.
revoke execute on function public._white_referee(uuid) from public,anon,authenticated;
grant execute on function public.white_open_vote(text,uuid),public.white_oral_verdict(text,uuid,boolean)
  to anon,authenticated;
