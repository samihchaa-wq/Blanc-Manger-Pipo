-- Arriver au milieu d'une manche donnait une main fraîche à un joueur qui n'a
-- rien joué des manches précédentes, et décalait le tour de table. On ne peut
-- plus rejoindre que dans le salon d'attente, ou une fois la partie terminée
-- (l'hôte peut alors en relancer une avec tout le monde).
create or replace function public.join_room(p_code text, p_name text)
returns json
language plpgsql
security definer
set search_path = ''
as $$
declare r public.rooms; p public.players; n text:=left(trim(coalesce(p_name,'')),20); client_hash text;
begin
  if n='' then raise exception 'Choisis un pseudo.'; end if;
  client_hash:=public._client_hash();
  if client_hash is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('bmp-join:'||client_hash,0));
    if (select count(*) from public.players where joined_by_hash=client_hash and created_at>now()-interval '10 minutes')>=30 then
      raise exception 'Trop de tentatives de connexion récentes. Réessaie dans quelques minutes.';
    end if;
  end if;
  select * into r from public.rooms where code=upper(trim(p_code)) for update;
  if r.id is null then if client_hash is not null then perform pg_catalog.pg_sleep(0.15); end if; raise exception 'Aucune partie avec ce code.'; end if;
  if r.status not in ('lobby','finished') then raise exception 'La partie a déjà commencé. Attends qu''elle se termine.'; end if;
  if (select count(*) from public.players where room_id=r.id and active)>=12 then raise exception 'La partie est pleine (12 joueurs max).'; end if;
  if exists(select 1 from public.players where room_id=r.id and active and lower(name)=lower(n)) then raise exception 'Ce pseudo est déjà pris dans cette partie.'; end if;
  insert into public.players(room_id,name,seat,joined_by_hash)
  values(r.id,n,(select coalesce(max(seat),-1)+1 from public.players where room_id=r.id),client_hash) returning * into p;
  update public.rooms set updated_at=now() where id=r.id;
  return json_build_object('code',r.code,'player_id',p.id,'token',p.token);
end
$$;
