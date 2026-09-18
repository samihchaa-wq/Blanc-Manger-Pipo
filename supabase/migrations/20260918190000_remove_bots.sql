-- Les bots sont retirés du jeu : plus de joueur automatique, ni dans le salon,
-- ni en partie.

-- Les salons ouverts peuvent encore en héberger. _remove_player fait le
-- ménage qu'une suppression sèche laisserait de côté : la main du bot, l'hôte
-- si c'était lui, le tour en cours s'il était lecteur, et la partie qui
-- retombe sous trois joueurs.
do $$
declare b uuid;
begin
  for b in select id from public.players where is_bot and active loop
    perform public._remove_player(b);
  end loop;
end $$;
delete from public.players where is_bot;

drop function if exists public.add_bot(text, uuid);
drop function if exists public.bot_step(text, uuid);

-- Les trois fonctions qui lisaient la colonne. « not is_bot » ne filtrait plus
-- rien une fois les bots partis, mais la colonne ne peut pas tomber tant
-- qu'elles y font référence.
create or replace function public.next_round(p_code text,p_token uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare me public.players; r public.rooms; rd uuid;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.status<>'reveal' then raise exception 'Le tour n’est pas terminé.'; end if;
 update public.players set next_ack_round=r.round where id=me.id;
 if not exists(select 1 from public.players where room_id=r.id and active and next_ack_round<>r.round) then
   rd:=public._random_reader(r.id,r.reader_id); perform public._begin_round(r.id,rd,r.round+1);
 else update public.rooms set updated_at=now() where id=r.id; end if;
end $$;

create or replace function public.continue_game(p_code text,p_token uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare me public.players; r public.rooms;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.status<>'finished' then raise exception 'La partie n’est pas terminée.'; end if;
 update public.players set continue_requested=true where id=me.id;
 if not exists(select 1 from public.players where room_id=r.id and active and not continue_requested) then
   update public.players set ready=false,score=0,discard_round=0,next_ack_round=0,continue_requested=false where room_id=r.id and active;
   delete from public.hands where room_id=r.id; delete from public.used_answers where room_id=r.id; delete from public.submissions where room_id=r.id;
   update public.rooms set status='lobby',round=0,reader_id=null,previous_reader_id=null,question_id=null,question_choices='{}',winner_id=null,winning_submission_id=null,used_questions='{}',updated_at=now() where id=r.id;
 else update public.rooms set updated_at=now() where id=r.id; end if;
end $$;

create or replace function public.get_state(p_code text,p_token uuid)
returns json language plpgsql security definer set search_path=''
as $$
declare me public.players; r public.rooms;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 if me.last_seen<now()-interval '5 minutes' then update public.players set last_seen=now() where id=me.id; end if;
 select * into r from public.rooms where id=me.room_id;
 return json_build_object(
 'room',json_build_object('code',r.code,'status',r.status,'round',r.round,'target',r.target_score,'host_id',r.host_id,'reader_id',r.reader_id,'winner_id',r.winner_id,'winning_submission_id',r.winning_submission_id,'updated_at',r.updated_at,'submission_count',(select count(*) from public.submissions s where s.room_id=r.id and s.round=r.round)),
 'me',json_build_object('id',me.id,'name',me.name,'ready',me.ready,'next_ack',me.next_ack_round,'continue_requested',me.continue_requested,'can_discard',r.status='answering' and r.reader_id<>me.id and me.discard_round<>r.round and not exists(select 1 from public.submissions s where s.room_id=r.id and s.round=r.round and s.player_id=me.id)),
 'question',(select q.text from public.questions q where q.id=r.question_id),
 'blanks',coalesce((select q.blanks from public.questions q where q.id=r.question_id),1),
 'question_choices',case when r.status='question_select' and r.reader_id=me.id then (select coalesce(json_agg(json_build_object('id',q.id,'text',q.text)),'[]'::json) from public.questions q where q.id=any(r.question_choices)) else '[]'::json end,
 'players',(select coalesce(json_agg(json_build_object('id',p.id,'name',p.name,'score',p.score,'active',p.active,'ready',p.ready,'next_ack',p.next_ack_round,'continue_requested',p.continue_requested,'submitted',exists(select 1 from public.submissions s where s.room_id=r.id and s.round=r.round and s.player_id=p.id)) order by p.seat),'[]'::json) from public.players p where p.room_id=r.id and (p.active or (r.status in('reveal','finished') and p.id=r.winner_id))),
 'hand',(select coalesce(json_agg(json_build_object('id',a.id,'text',a.text,'form',a.form) order by a.text),'[]'::json) from public.hands h join public.answers a on a.id=h.answer_id where h.player_id=me.id),
 'my_cards',(select coalesce(json_agg(json_build_object('text',a.text,'form',a.form) order by x.rang),'[]'::json)
             from public.submissions s
             cross join lateral unnest(array_remove(array[s.answer_id,s.answer_id2],null)) with ordinality as x(aid,rang)
             join public.answers a on a.id=x.aid
             where s.room_id=r.id and s.round=r.round and s.player_id=me.id),
 'submissions',case when r.status in('reveal','finished') or (r.status='judging' and r.reader_id=me.id) then
   (select coalesce(json_agg(json_build_object('id',s.id,'author',case when r.status in('reveal','finished') then p.name end,
      'cards',(select coalesce(json_agg(json_build_object('text',a.text,'form',a.form) order by x.rang),'[]'::json)
               from unnest(array_remove(array[s.answer_id,s.answer_id2],null)) with ordinality as x(aid,rang)
               join public.answers a on a.id=x.aid)) order by s.sort_key),'[]'::json)
    from public.submissions s join public.players p on p.id=s.player_id
    where s.room_id=r.id and s.round=r.round) else '[]'::json end);
end $$;
grant execute on function public.get_state(text,uuid) to anon;
revoke execute on function public.get_state(text,uuid) from authenticated;

alter table public.players drop column if exists is_bot;
