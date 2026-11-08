-- Mr White : deux imposteurs au total dès 6 joueurs (Mr White peut en remplacer un).
-- Minimum inchangé (3 joueurs) car le vote à deux nécessite une règle spécifique.
-- À tester sur une copie avant déploiement en production.
begin;

CREATE OR REPLACE FUNCTION public._begin_white_round_base(p_room uuid, p_next_round integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    -- Mr White apparaît dans environ 20 % des parties.
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
  -- Distribution décidée pour les Civils et les imposteurs :
  -- 3–5 joueurs : 1 imposteur ; 6–12 joueurs : 2 imposteurs.
  -- Mr White remplace un imposteur, il ne s'ajoute jamais au groupe.
  intruders := case when n>=6 then 2 else 1 end;
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
end $function$;


commit;
