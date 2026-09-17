alter table public.players add column if not exists ready boolean not null default false;
alter table public.players add column if not exists is_bot boolean not null default false;
alter table public.players add column if not exists next_ack_round integer not null default 0;
alter table public.players add column if not exists continue_requested boolean not null default false;
alter table public.rooms add column if not exists question_choices integer[] not null default '{}';
alter table public.rooms add column if not exists previous_reader_id uuid;
alter table public.rooms alter column hand_size set default 6;
update public.rooms set hand_size=6 where status in ('lobby','finished');

alter table public.rooms drop constraint if exists rooms_status_check;
alter table public.rooms add constraint rooms_status_check check (status in ('lobby','question_select','answering','judging','reveal','finished'));

create or replace function public._random_reader(p_room uuid, p_exclude uuid default null)
returns uuid language sql stable security definer set search_path=''
as $$ select id from public.players where room_id=p_room and active and (p_exclude is null or id<>p_exclude) order by random() limit 1 $$;
revoke all on function public._random_reader(uuid,uuid) from public,anon,authenticated;

create or replace function public._question_choices(p_room uuid)
returns integer[] language plpgsql security definer set search_path=''
as $$
declare ids integer[]; used integer[];
begin
 select used_questions into used from public.rooms where id=p_room;
 select coalesce(array_agg(id),'{}') into ids from (select id from public.questions where deleted_at is null and not(id=any(used)) order by random() limit 4) q;
 if cardinality(ids)<4 then
   select coalesce(array_agg(id),'{}') into ids from (select id from public.questions where deleted_at is null order by random() limit 4) q;
 end if;
 if cardinality(ids)<1 then raise exception 'Aucune carte à trou disponible.'; end if;
 return ids;
end $$;
revoke all on function public._question_choices(uuid) from public,anon,authenticated;

create or replace function public._begin_round(p_room uuid,p_reader uuid,p_next_round integer)
returns void language plpgsql security definer set search_path=''
as $$
declare choices integer[];
begin
 perform public._deal(p_room);
 choices:=public._question_choices(p_room);
 delete from public.submissions where room_id=p_room and round=p_next_round;
 update public.players set next_ack_round=0 where room_id=p_room and active;
 update public.rooms set status='question_select',round=p_next_round,previous_reader_id=reader_id,reader_id=p_reader,question_id=null,question_choices=choices,winner_id=null,winning_submission_id=null,skips_used=0,updated_at=now() where id=p_room;
end $$;
revoke all on function public._begin_round(uuid,uuid,integer) from public,anon,authenticated;

create or replace function public.set_ready(p_code text,p_token uuid,p_ready boolean)
returns void language plpgsql security definer set search_path=''
as $$
declare me public.players; r public.rooms;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.status<>'lobby' then raise exception 'La partie n’est pas dans le salon.'; end if;
 update public.players set ready=coalesce(p_ready,false) where id=me.id;
 update public.rooms set updated_at=now() where id=r.id;
end $$;

grant execute on function public.set_ready(text,uuid,boolean) to anon,authenticated;

create or replace function public.add_bot(p_code text,p_token uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare me public.players; r public.rooms; n integer; botname text;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.host_id<>me.id then raise exception 'Seul l’hôte peut ajouter un bot.'; end if;
 if r.status<>'lobby' then raise exception 'Les bots s’ajoutent depuis le salon.'; end if;
 if (select count(*) from public.players where room_id=r.id and active)>=12 then raise exception 'La partie est pleine.'; end if;
 select coalesce(max(seat),-1)+1 into n from public.players where room_id=r.id;
 botname:='Bot '||(select count(*)+1 from public.players where room_id=r.id and is_bot);
 insert into public.players(room_id,name,seat,is_bot,ready) values(r.id,botname,n,true,true);
 update public.rooms set updated_at=now() where id=r.id;
end $$;
grant execute on function public.add_bot(text,uuid) to anon,authenticated;

create or replace function public.start_game(p_code text,p_token uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare me public.players; r public.rooms; rd uuid;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.host_id<>me.id then raise exception 'Seul l’hôte peut lancer la partie.'; end if;
 if r.status<>'lobby' then raise exception 'La partie est déjà en cours.'; end if;
 if (select count(*) from public.players where room_id=r.id and active)<3 then raise exception 'Il faut au moins 3 joueurs.'; end if;
 if exists(select 1 from public.players where room_id=r.id and active and not ready) then raise exception 'Tous les joueurs doivent être prêts.'; end if;
 update public.players set score=0,discard_round=0,next_ack_round=0,continue_requested=false where room_id=r.id and active;
 delete from public.hands where room_id=r.id; delete from public.used_answers where room_id=r.id; delete from public.submissions where room_id=r.id;
 update public.rooms set used_questions='{}',round=0,reward_used=false,reward_kind=null,reward_text=null,previous_reader_id=null,reader_id=null where id=r.id;
 rd:=public._random_reader(r.id,null);
 perform public._begin_round(r.id,rd,1);
end $$;

create or replace function public.select_question(p_code text,p_token uuid,p_question_id integer)
returns void language plpgsql security definer set search_path=''
as $$
declare me public.players; r public.rooms;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.status<>'question_select' then raise exception 'La question est déjà choisie.'; end if;
 if r.reader_id<>me.id then raise exception 'Seul le lecteur choisit la carte à trou.'; end if;
 if not(p_question_id=any(r.question_choices)) then raise exception 'Cette carte n’est pas proposée.'; end if;
 update public.rooms set question_id=p_question_id,used_questions=used_questions||p_question_id,question_choices='{}',status='answering',updated_at=now() where id=r.id;
 perform public._maybe_judge(r.id);
end $$;
grant execute on function public.select_question(text,uuid,integer) to anon,authenticated;

create or replace function public.bot_step(p_code text,p_token uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare me public.players; r public.rooms; b public.players; aid integer; sid uuid; qid integer;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.status='question_select' then
   select * into b from public.players where id=r.reader_id and active and is_bot;
   if b.id is not null then select x into qid from unnest(r.question_choices) x order by random() limit 1; update public.rooms set question_id=qid,used_questions=used_questions||qid,question_choices='{}',status='answering',updated_at=now() where id=r.id; end if;
 elsif r.status='answering' then
   for b in select * from public.players where room_id=r.id and active and is_bot and id<>r.reader_id and not exists(select 1 from public.submissions s where s.room_id=r.id and s.round=r.round and s.player_id=players.id) loop
     select h.answer_id into aid from public.hands h where h.player_id=b.id order by random() limit 1;
     if aid is not null then insert into public.submissions(room_id,round,player_id,answer_id) values(r.id,r.round,b.id,aid) on conflict do nothing; delete from public.hands where player_id=b.id and answer_id=aid; end if;
   end loop;
   perform public._deal(r.id); perform public._maybe_judge(r.id); update public.rooms set updated_at=now() where id=r.id;
 elsif r.status='judging' and exists(select 1 from public.players where id=r.reader_id and active and is_bot) then
   select s.id,s.player_id into sid,b.id from public.submissions s join public.players p on p.id=s.player_id and p.active where s.room_id=r.id and s.round=r.round order by random() limit 1;
   if sid is not null then update public.players set score=score+1 where id=b.id returning * into b; update public.rooms set status=case when b.score>=r.target_score then 'finished' else 'reveal' end,winner_id=b.id,winning_submission_id=sid,updated_at=now() where id=r.id; end if;
 end if;
end $$;
grant execute on function public.bot_step(text,uuid) to anon,authenticated;

create or replace function public.next_round(p_code text,p_token uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare me public.players; r public.rooms; rd uuid;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.status<>'reveal' then raise exception 'Le tour n’est pas terminé.'; end if;
 update public.players set next_ack_round=r.round where id=me.id;
 if not exists(select 1 from public.players where room_id=r.id and active and not is_bot and next_ack_round<>r.round) then
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
 if not exists(select 1 from public.players where room_id=r.id and active and not is_bot and not continue_requested) then
   update public.players set ready=is_bot,score=0,discard_round=0,next_ack_round=0,continue_requested=false where room_id=r.id and active;
   delete from public.hands where room_id=r.id; delete from public.used_answers where room_id=r.id; delete from public.submissions where room_id=r.id;
   update public.rooms set status='lobby',round=0,reader_id=null,previous_reader_id=null,question_id=null,question_choices='{}',winner_id=null,winning_submission_id=null,used_questions='{}',updated_at=now() where id=r.id;
 else update public.rooms set updated_at=now() where id=r.id; end if;
end $$;
grant execute on function public.continue_game(text,uuid) to anon,authenticated;

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
 'question_choices',case when r.status='question_select' and r.reader_id=me.id then (select coalesce(json_agg(json_build_object('id',q.id,'text',q.text)),'[]'::json) from public.questions q where q.id=any(r.question_choices)) else '[]'::json end,
 'players',(select coalesce(json_agg(json_build_object('id',p.id,'name',p.name,'score',p.score,'active',p.active,'ready',p.ready,'is_bot',p.is_bot,'next_ack',p.next_ack_round,'continue_requested',p.continue_requested,'submitted',exists(select 1 from public.submissions s where s.room_id=r.id and s.round=r.round and s.player_id=p.id)) order by p.seat),'[]'::json) from public.players p where p.room_id=r.id and (p.active or (r.status in('reveal','finished') and p.id=r.winner_id))),
 'hand',(select coalesce(json_agg(json_build_object('id',a.id,'text',a.text) order by a.text),'[]'::json) from public.hands h join public.answers a on a.id=h.answer_id where h.player_id=me.id),
 'my_submission',(select a.text from public.submissions s join public.answers a on a.id=s.answer_id where s.room_id=r.id and s.round=r.round and s.player_id=me.id),
 'submissions',case when r.status in('reveal','finished') or (r.status='judging' and r.reader_id=me.id) then (select coalesce(json_agg(json_build_object('id',s.id,'text',a.text,'author',case when r.status in('reveal','finished') then p.name end) order by s.sort_key),'[]'::json) from public.submissions s join public.answers a on a.id=s.answer_id join public.players p on p.id=s.player_id where s.room_id=r.id and s.round=r.round) else '[]'::json end);
end $$;

create or replace function public.submit_answer(p_code text,p_token uuid,p_answer_id integer)
returns void language plpgsql security definer set search_path=''
as $$
declare me public.players; r public.rooms;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.status<>'answering' then raise exception 'Les réponses sont fermées pour ce tour.'; end if; if r.reader_id=me.id then raise exception 'Tu lis la question ce tour-ci.'; end if;
 if exists(select 1 from public.submissions where room_id=r.id and round=r.round and player_id=me.id) then raise exception 'Tu as déjà joué une carte.'; end if;
 if not exists(select 1 from public.hands where player_id=me.id and answer_id=p_answer_id) then raise exception 'Cette carte n’est pas dans ta main.'; end if;
 insert into public.submissions(room_id,round,player_id,answer_id) values(r.id,r.round,me.id,p_answer_id); delete from public.hands where player_id=me.id and answer_id=p_answer_id;
 perform public._deal(r.id); perform public._maybe_judge(r.id); update public.rooms set updated_at=now() where id=r.id;
end $$;

create or replace function public.pick_winner(p_code text,p_token uuid,p_submission_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare me public.players; r public.rooms; w uuid; sc integer;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if; select * into r from public.rooms where id=me.room_id for update;
 if r.reader_id<>me.id then raise exception 'Seul le lecteur choisit la gagnante.'; end if; if r.status<>'judging' then raise exception 'Ce n’est pas le moment de voter.'; end if;
 select s.player_id into w from public.submissions s join public.players p on p.id=s.player_id and p.active where s.id=p_submission_id and s.room_id=r.id and s.round=r.round; if w is null then raise exception 'Réponse introuvable ou joueur parti.'; end if;
 update public.players set score=score+1 where id=w and active returning score into sc;
 update public.rooms set status=case when sc>=r.target_score then 'finished' else 'reveal' end,winner_id=w,winning_submission_id=p_submission_id,updated_at=now() where id=r.id;
end $$;

-- Bots are never granted direct credentials; only the host's normal RPCs can create them.
revoke all on function public._begin_round(uuid,uuid,integer) from public,anon,authenticated;
