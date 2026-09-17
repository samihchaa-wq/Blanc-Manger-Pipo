create or replace function public.join_room(p_code text,p_name text)
returns json language plpgsql security definer set search_path=''
as $$
declare r public.rooms; p public.players; n text:=left(trim(coalesce(p_name,'')),20); client_hash text;
begin
 if n='' then raise exception 'Choisis un pseudo.'; end if; client_hash:=public._client_hash();
 if client_hash is not null then perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('bmp-join:'||client_hash,0)); if (select count(*) from public.players x where x.joined_by_hash=client_hash and x.created_at>now()-interval '10 minutes')>=30 then raise exception 'Trop de tentatives récentes. Réessaie dans quelques minutes.'; end if; end if;
 select * into r from public.rooms where code=upper(trim(p_code)) for update;
 if r.id is null then if client_hash is not null then perform pg_catalog.pg_sleep(.15); end if; raise exception 'Aucune partie avec ce code.'; end if;
 if r.status<>'lobby' then raise exception 'Cette partie a déjà commencé.'; end if;
 if (select count(*) from public.players where room_id=r.id and active)>=12 then raise exception 'La partie est pleine (12 joueurs max).'; end if;
 if exists(select 1 from public.players where room_id=r.id and active and lower(name)=lower(n)) then raise exception 'Ce pseudo est déjà pris dans cette partie.'; end if;
 insert into public.players(room_id,name,seat,joined_by_hash) values(r.id,n,(select coalesce(max(seat),-1)+1 from public.players where room_id=r.id),client_hash) returning * into p;
 update public.rooms set updated_at=now() where id=r.id;
 return json_build_object('code',r.code,'player_id',p.id,'token',p.token);
end $$;

create or replace function public._begin_round(p_room uuid,p_reader uuid,p_next_round integer)
returns void language plpgsql security definer set search_path=''
as $$
declare choices integer[];
begin
 -- The previous reader rejoins the hand; the new reader does not need answer cards this round.
 perform public._deal(p_room);
 delete from public.hands where player_id=p_reader;
 choices:=public._question_choices(p_room);
 delete from public.submissions where room_id=p_room and round=p_next_round;
 update public.players set next_ack_round=0 where room_id=p_room and active;
 update public.rooms set status='question_select',round=p_next_round,previous_reader_id=reader_id,reader_id=p_reader,question_id=null,question_choices=choices,winner_id=null,winning_submission_id=null,skips_used=0,updated_at=now() where id=p_room;
end $$;
revoke all on function public._begin_round(uuid,uuid,integer) from public,anon,authenticated;
