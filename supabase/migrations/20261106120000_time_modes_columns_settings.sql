-- Modes : illimité, lent, moyen, rapide. Le choix est commun au salon.
alter table public.rooms add column if not exists time_mode text not null default 'medium';
alter table public.rooms add column if not exists mime_index integer not null default 0;
alter table public.rooms add column if not exists mime_started_at timestamptz;
alter table public.rooms drop constraint if exists rooms_time_mode_check;
alter table public.rooms add constraint rooms_time_mode_check
  check (time_mode in ('unlimited','slow','medium','fast'));
update public.rooms set time_mode='unlimited'
 where status='lobby' and mode in ('bac','white','mimes') and time_mode='medium';

create or replace function public._time_phase_seconds(p_room public.rooms)
returns integer language plpgsql stable security invoker set search_path to ''
as $time$
declare s integer; pace text := coalesce(p_room.time_mode,'medium'); n integer;
begin
 if pace='unlimited' then return null; end if;
 s:=case
  when p_room.mode='phrases' and p_room.status='answering'
    then case pace when 'slow' then 120 when 'fast' then 45 else 75 end
  when p_room.mode='priorites' and p_room.status='ranking'
    then case pace when 'slow' then 180 when 'fast' then 60 else 120 end
  when p_room.mode='ondes' and p_room.status='clue' and p_room.wave_variant='inverse' and p_room.wave_theme is null
    then case pace when 'slow' then 90 when 'fast' then 30 else 60 end
  when p_room.mode='ondes' and p_room.status='clue'
    then case pace when 'slow' then 150 when 'fast' then 45 else 90 end
  when p_room.mode='ondes' and p_room.status='guessing'
    then case pace when 'slow' then 75 when 'fast' then 25 else 45 end
  when p_room.mode='bac' and p_room.status='naming'
    then case pace when 'slow' then 60 when 'fast' then 20 else 40 end
  when p_room.mode='bac' and p_room.status='writing'
    then case pace when 'slow' then 300 when 'fast' then 90 else 180 end
  when p_room.mode='white' and p_room.status='white_clue'
    then case pace when 'slow' then 60 when 'fast' then 25 else 40 end
  when p_room.mode='white' and p_room.status='white_vote'
    then case pace when 'slow' then 60 when 'fast' then 20 else 35 end
  when p_room.mode='mimes' and p_room.status='mime_play'
    then case pace when 'slow' then 45 when 'fast' then 20 else 30 end
  else null end;
 if s is null then return null; end if;
 if p_room.mode='phrases' and p_room.status='answering'
    and coalesce((select q.blanks from public.questions q where q.id=p_room.question_id),1)=2 then
   s:=s+case pace when 'slow' then 30 when 'fast' then 15 else 20 end;
 end if;
 if p_room.mode='white' and p_room.status='white_clue' then
   select count(*) into n from public.white_roles w join public.players p on p.id=w.player_id and p.active
    where w.room_id=p_room.id and w.round=p_room.round and not w.eliminated;
   s:=s*greatest(1,n);
 end if;
 return s;
end $time$;

create or replace function public._time_expired(p_room public.rooms)
returns boolean language sql stable security invoker set search_path to ''
as $time$
 select public._time_phase_seconds(p_room) is not null
   and p_room.status not in ('white_clue','mime_play')
   and now() >= p_room.phase_at + make_interval(secs => public._time_phase_seconds(p_room));
$time$;

create or replace function public.set_time_mode(p_code text,p_token uuid,p_mode text)
returns void language plpgsql security definer set search_path to ''
as $time$
declare me public.players; r public.rooms;
begin
 me:=public._player(p_code,p_token);
 if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.host_id<>me.id or r.status<>'lobby' then raise exception 'Seul l’hôte règle le temps avant la partie.'; end if;
 if p_mode is null or p_mode not in ('unlimited','slow','medium','fast') then
   raise exception 'Temporalité invalide.';
 end if;
 update public.rooms set time_mode=p_mode,updated_at=now() where id=r.id;
end $time$;

create or replace function public.mime_progress(p_code text,p_token uuid,p_action text)
returns void language plpgsql security definer set search_path to ''
as $time$
declare me public.players; r public.rooms; n integer;
begin
 me:=public._player(p_code,p_token);
 if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.mode<>'mimes' or r.status<>'mime_play' or r.reader_id<>me.id then
   raise exception 'Seul le juge peut diriger les prestations.';
 end if;
 if p_action<>'next' then raise exception 'Action invalide.'; end if;
 select count(*) into n from public.mime_parts m
  join public.players p on p.id=m.player_id and p.active
  where m.room_id=r.id and m.round=r.round;
 if r.mime_index>=n then raise exception 'Tous les mimes sont passés.'; end if;
 update public.rooms set mime_index=r.mime_index+1,mime_started_at=now(),updated_at=now() where id=r.id;
end $time$;

create or replace function public.create_room(p_name text,p_target integer default 5,
  p_mode text default 'phrases',p_turns integer default 2)
returns json language plpgsql security definer set search_path to ''
as $time$
declare res json;
begin
 if p_mode='mimes' then
   res:=public._create_room_base(p_name,p_target,'priorites',p_turns);
   update public.rooms set mode='mimes' where code=res->>'code';
 else
   res:=public._create_room_base(p_name,p_target,p_mode,p_turns);
 end if;
 update public.rooms set time_mode=case when p_mode in ('bac','white','mimes')
     then 'unlimited' else 'medium' end where code=res->>'code';
 return res;
end $time$;

grant execute on function public.set_time_mode(text,uuid,text) to anon,authenticated;
grant execute on function public.mime_progress(text,uuid,text) to anon,authenticated;
