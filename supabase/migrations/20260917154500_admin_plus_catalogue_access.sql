-- Deux niveaux d'administration.
--
--   admin_hash       : ajouter une réponse au catalogue.
--   admin_plus_hash  : en plus, consulter, modifier et supprimer le catalogue.
--
-- Auparavant un seul secret gardait les cinq fonctions admin : toute personne
-- pouvant ajouter une carte pouvait aussi lire et effacer tout le catalogue.
-- Le second secret n'est pas posé ici : une migration versionnée ne doit pas
-- contenir de mot de passe en clair. Tant que la ligne 'admin_plus_hash' est
-- absente, la consultation et la suppression sont fermées à tout le monde.

-- Accepte l'un ou l'autre des deux secrets. Conserve le comportement d'origine :
-- verrou consultatif par client, re-hachage des coûts bcrypt trop faibles,
-- et pause de 1,5 s en cas d'échec.
create or replace function public._is_admin(p_password text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare k text; h text; ok boolean := false; cost integer := 0; client_hash text;
begin
  client_hash := coalesce(public._client_hash(), 'no-request-context');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('bmp-admin:' || client_hash, 0));
  for k, h in
    select key, value from public.app_settings
    where key in ('admin_hash', 'admin_plus_hash') order by key for update
  loop
    if h is not null and h = extensions.crypt(coalesce(p_password, ''), h) then
      ok := true;
      begin cost := split_part(h, '$', 3)::integer; exception when others then cost := 0; end;
      if cost < 10 then
        update public.app_settings set value = extensions.crypt(p_password, extensions.gen_salt('bf', 10)) where key = k;
      end if;
      exit;
    end if;
  end loop;
  if not ok then perform pg_catalog.pg_sleep(1.5); return false; end if;
  return true;
end
$$;

-- Le seul secret qui ouvre la consultation et la suppression.
create or replace function public._is_admin_plus(p_password text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare stored_hash text; ok boolean := false; cost integer := 0; client_hash text;
begin
  client_hash := coalesce(public._client_hash(), 'no-request-context');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('bmp-admin-plus:' || client_hash, 0));
  select value into stored_hash from public.app_settings where key = 'admin_plus_hash' for update;
  if stored_hash is not null then ok := stored_hash = extensions.crypt(coalesce(p_password, ''), stored_hash); end if;
  if not coalesce(ok, false) then perform pg_catalog.pg_sleep(1.5); return false; end if;
  begin cost := split_part(stored_hash, '$', 3)::integer; exception when others then cost := 0; end;
  if cost < 10 then
    update public.app_settings set value = extensions.crypt(p_password, extensions.gen_salt('bf', 10)) where key = 'admin_plus_hash';
  end if;
  return true;
end
$$;

-- Un seul aller-retour pour connaître le niveau, et une seule pause en cas d'échec.
create or replace function public.admin_level(p_password text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare plus_hash text; base_hash text; client_hash text;
begin
  client_hash := coalesce(public._client_hash(), 'no-request-context');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('bmp-admin:' || client_hash, 0));
  select value into plus_hash from public.app_settings where key = 'admin_plus_hash';
  select value into base_hash from public.app_settings where key = 'admin_hash';
  if plus_hash is not null and plus_hash = extensions.crypt(coalesce(p_password, ''), plus_hash) then return 'plus'; end if;
  if base_hash is not null and base_hash = extensions.crypt(coalesce(p_password, ''), base_hash) then return 'admin'; end if;
  perform pg_catalog.pg_sleep(1.5);
  return 'none';
end
$$;

-- Consulter, modifier et supprimer passent au second secret. Corps inchangés.
create or replace function public.admin_list_cards(p_password text,p_kind text,p_search text default '',p_offset integer default 0)
returns json language plpgsql security definer set search_path='' as $$
declare s text:='%'||lower(trim(coalesce(p_search,'')))||'%';
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  if p_kind='q' then
    return json_build_object('total',(select count(*) from public.questions q where q.deleted_at is null and lower(q.text) like s),'items',(select coalesce(json_agg(json_build_object('id',x.id,'text',x.text,'by',x.added_by) order by x.created_at desc,x.id desc),'[]'::json) from(select q.id,q.text,q.added_by,q.created_at from public.questions q where q.deleted_at is null and lower(q.text) like s order by q.created_at desc,q.id desc offset greatest(p_offset,0) limit 50)x));
  elsif p_kind='a' then
    return json_build_object('total',(select count(*) from public.answers a where a.deleted_at is null and lower(a.text) like s),'items',(select coalesce(json_agg(json_build_object('id',x.id,'text',x.text,'by',x.added_by) order by x.created_at desc,x.id desc),'[]'::json) from(select a.id,a.text,a.added_by,a.created_at from public.answers a where a.deleted_at is null and lower(a.text) like s order by a.created_at desc,a.id desc offset greatest(p_offset,0) limit 50)x));
  end if;
  raise exception 'Type de carte inconnu.';
end $$;

create or replace function public.admin_delete_card(p_password text,p_kind text,p_id integer)
returns void language plpgsql security definer set search_path='' as $$
declare rm uuid;
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  if p_kind='q' then
    update public.questions set deleted_at=now() where id=p_id and deleted_at is null; if not found then raise exception 'Carte introuvable.'; end if;
  elsif p_kind='a' then
    update public.answers set deleted_at=now() where id=p_id and deleted_at is null; if not found then raise exception 'Carte introuvable.'; end if;
    for rm in select distinct room_id from public.hands where answer_id=p_id loop
      delete from public.hands where room_id=rm and answer_id=p_id; perform public._deal(rm); update public.rooms set updated_at=now() where id=rm;
    end loop;
  else raise exception 'Type de carte inconnu.'; end if;
end $$;

create or replace function public.admin_update_card(p_password text,p_kind text,p_id integer,p_text text)
returns json language plpgsql security definer set search_path='' as $$
declare t text;
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  t:=public._clean_card(p_kind,p_text);
  if p_kind='q' then
    if exists(select 1 from public.questions q where lower(q.text)=lower(t) and q.id<>p_id) then raise exception 'Une autre question a déjà ce texte.'; end if;
    update public.questions set text=t where id=p_id and deleted_at is null;
  elsif p_kind='a' then
    if exists(select 1 from public.answers a where lower(a.text)=lower(t) and a.id<>p_id) then raise exception 'Une autre réponse a déjà ce texte.'; end if;
    update public.answers set text=t where id=p_id and deleted_at is null;
  else raise exception 'Type de carte inconnu.'; end if;
  if not found then raise exception 'Carte introuvable.'; end if;
  return json_build_object('id',p_id,'text',t);
end $$;

revoke all on function public._is_admin(text) from public, anon, authenticated;
revoke all on function public._is_admin_plus(text) from public, anon, authenticated;
revoke all on function public.admin_level(text) from public, anon, authenticated;
grant execute on function public.admin_level(text) to anon;
