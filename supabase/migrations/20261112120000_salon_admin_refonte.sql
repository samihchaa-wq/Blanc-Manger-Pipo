-- Refonte du salon et de l'admin.
--
-- 1. Salon : l'hôte lance quand il veut. lancer_partie marque tout le monde
--    prêt avant d'appeler start_game ou punish_start, qui ne changent pas.
--
-- 2. Private Joke réservé au groupe : passer Phrases à trou en Private Joke
--    demande un code. Le code admin (simple ou +) marche toujours ; l'admin +
--    peut en plus définir un code de groupe à donner aux amis
--    (admin_set_private_code), sans révéler le code admin. Même garde que
--    l'admin : un essai à la fois, 1,5 s de pause après un mauvais code.
--    set_phrases_variant à trois arguments (anciens téléphones) n'accepte
--    plus que le mode Normal.
--
-- 3. Admin générique : quatre fonctions pour les sept catalogues, au lieu
--    d'une fonction par jeu et par action.
--      q questions · a réponses (Normal) · j réponses (Private Joke)
--      p Priorités · w Baromètre · m Mr White · x Mimes
--    admin_cards_list, admin_card_add, admin_card_update (texte, deux champs,
--    type nom/verbe), admin_card_delete. Chaque carte a la même forme :
--    text (texte principal), left / right (deux champs courts), plus form,
--    theme ou blanks selon le catalogue.
--    Les anciennes fonctions admin restent le temps que les téléphones se
--    mettent à jour ; plus rien dans l'appli ne les appelle.
--
-- Uniquement des fonctions créées ou remplacées : aucune table modifiée.

begin;

-- 1. Lancement sans « prêt » ---------------------------------------------------
-- L'hôte lance quand il veut : lancer_partie marque tous les joueurs prêts puis
-- passe par start_game (ou punish_start avec les punitions), comme le fait déjà
-- _punish_maybe_start. start_game et punish_start restent inchangées.
create or replace function public.lancer_partie(p_code text, p_token uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id;
  if r.host_id <> me.id then raise exception 'Seul l’hôte peut lancer la partie.'; end if;
  if r.status <> 'lobby' then raise exception 'La partie est déjà en cours.'; end if;
  update public.players set ready = true where room_id = r.id and active and not ready;
  if r.punish then perform public.punish_start(p_code, p_token);
  else perform public.start_game(p_code, p_token); end if;
end $fn$;

-- 2. Private Joke avec code ----------------------------------------------------
create or replace function public.set_phrases_variant(p_code text, p_token uuid, p_variant text, p_secret text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; ok boolean := false; h text; client_hash text;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id;
  if r.host_id <> me.id then raise exception 'Seul l’hôte choisit le mode.'; end if;
  if r.status <> 'lobby' then raise exception 'Le mode se choisit depuis le salon.'; end if;
  if r.mode <> 'phrases' then raise exception 'Ce réglage est propre à Phrases à trou.'; end if;
  if p_variant is null or p_variant not in ('normal','private') then raise exception 'Mode inconnu.'; end if;
  if p_variant = 'private' then
    if coalesce(btrim(p_secret), '') = '' then raise exception 'Il faut le code Private Joke.'; end if;
    -- un essai à la fois, pour tous les téléphones : pas de devinette en rafale
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('bmp-admin-global', 0));
    client_hash := coalesce(public._client_hash(), 'no-request-context');
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('bmp-admin:' || client_hash, 0));
    for h in select s.value from public.app_settings s
             where s.key in ('private_joke_hash', 'admin_hash', 'admin_plus_hash') and s.value is not null loop
      if h = extensions.crypt(p_secret, h) then ok := true; exit; end if;
    end loop;
    if not ok then
      perform pg_catalog.pg_sleep(1.5);
      raise exception 'Code Private Joke incorrect.';
    end if;
  end if;
  update public.rooms set phrases_variant = p_variant, updated_at = now()
    where id = r.id and status = 'lobby' and mode = 'phrases';
end $fn$;

-- Anciens téléphones : le mode Normal seulement.
create or replace function public.set_phrases_variant(p_code text, p_token uuid, p_variant text)
returns void language plpgsql security definer set search_path to '' as $fn$
begin
  if p_variant = 'private' then raise exception 'Il faut le code Private Joke : mets l’appli à jour.'; end if;
  perform public.set_phrases_variant(p_code, p_token, p_variant, null);
end $fn$;

create or replace function public.admin_set_private_code(p_password text, p_secret text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare c text := btrim(coalesce(p_secret, ''));
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  if length(c) < 4 or length(c) > 40 then raise exception 'Le code fait de 4 à 40 caractères.'; end if;
  insert into public.app_settings(key, value)
    values ('private_joke_hash', extensions.crypt(c, extensions.gen_salt('bf', 10)))
    on conflict (key) do update set value = excluded.value;
end $fn$;

-- 3. Admin générique -----------------------------------------------------------
create or replace function public.admin_cards_list(p_password text, p_kind text, p_search text default '', p_offset integer default 0)
returns json language plpgsql security definer set search_path to '' as $fn$
declare s text := '%' || lower(btrim(coalesce(p_search, ''))) || '%';
        o integer := greatest(coalesce(p_offset, 0), 0);
        pk text;
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  if p_kind = 'q' then
    return json_build_object(
      'total', (select count(*) from public.questions c where c.deleted_at is null and lower(c.text) like s),
      'items', (select coalesce(json_agg(json_build_object('id', x.id, 'text', x.text, 'blanks', x.blanks, 'by', x.added_by)
                  order by x.created_at desc, x.id desc), '[]'::json)
                from (select c.id, c.text, c.blanks, c.added_by, c.created_at from public.questions c
                      where c.deleted_at is null and lower(c.text) like s
                      order by c.created_at desc, c.id desc offset o limit 50) x));
  elsif p_kind in ('a','j') then
    pk := case p_kind when 'j' then 'private' else 'normal' end;
    return json_build_object(
      'total', (select count(*) from public.answers c where c.deleted_at is null and c.pack = pk and lower(c.text) like s),
      'items', (select coalesce(json_agg(json_build_object('id', x.id, 'text', x.text, 'form', x.form, 'by', x.added_by)
                  order by x.created_at desc, x.id desc), '[]'::json)
                from (select c.id, c.text, c.form, c.added_by, c.created_at from public.answers c
                      where c.deleted_at is null and c.pack = pk and lower(c.text) like s
                      order by c.created_at desc, c.id desc offset o limit 50) x));
  elsif p_kind = 'p' then
    return json_build_object(
      'total', (select count(*) from public.priority_cards c where c.deleted_at is null and (lower(c.text) like s or lower(c.theme) like s)),
      'items', (select coalesce(json_agg(json_build_object('id', x.id, 'text', x.text, 'theme', x.theme, 'by', x.added_by)
                  order by x.created_at desc, x.id desc), '[]'::json)
                from (select c.id, c.text, c.theme, c.added_by, c.created_at from public.priority_cards c
                      where c.deleted_at is null and (lower(c.text) like s or lower(c.theme) like s)
                      order by c.created_at desc, c.id desc offset o limit 50) x));
  elsif p_kind = 'w' then
    return json_build_object(
      'total', (select count(*) from public.wave_cards c where c.deleted_at is null and (lower(c.left_text) like s or lower(c.right_text) like s)),
      'items', (select coalesce(json_agg(json_build_object('id', x.id, 'left', x.left_text, 'right', x.right_text, 'by', x.added_by)
                  order by x.created_at desc, x.id desc), '[]'::json)
                from (select c.id, c.left_text, c.right_text, c.added_by, c.created_at from public.wave_cards c
                      where c.deleted_at is null and (lower(c.left_text) like s or lower(c.right_text) like s)
                      order by c.created_at desc, c.id desc offset o limit 50) x));
  elsif p_kind = 'm' then
    return json_build_object(
      'total', (select count(*) from public.white_words c where c.deleted_at is null and (lower(c.civil) like s or lower(c.undercover) like s)),
      'items', (select coalesce(json_agg(json_build_object('id', x.id, 'left', x.civil, 'right', x.undercover, 'by', x.added_by)
                  order by x.created_at desc, x.id desc), '[]'::json)
                from (select c.id, c.civil, c.undercover, c.added_by, c.created_at from public.white_words c
                      where c.deleted_at is null and (lower(c.civil) like s or lower(c.undercover) like s)
                      order by c.created_at desc, c.id desc offset o limit 50) x));
  elsif p_kind = 'x' then
    return json_build_object(
      'total', (select count(*) from public.mime_cards c where c.deleted_at is null
                 and (lower(c.action) like s or lower(c.low_text) like s or lower(c.high_text) like s)),
      'items', (select coalesce(json_agg(json_build_object('id', x.id, 'text', x.action, 'left', x.low_text, 'right', x.high_text, 'by', x.added_by)
                  order by x.created_at desc, x.id desc), '[]'::json)
                from (select c.id, c.action, c.low_text, c.high_text, c.added_by, c.created_at from public.mime_cards c
                      where c.deleted_at is null and (lower(c.action) like s or lower(c.low_text) like s or lower(c.high_text) like s)
                      order by c.created_at desc, c.id desc offset o limit 50) x));
  end if;
  raise exception 'Catalogue inconnu.';
end $fn$;

-- Espaces en trop retirés, longueur bornée (Mr White et Mimes).
create or replace function public._admin_short(p_text text, p_min integer, p_max integer, p_label text)
returns text language plpgsql immutable set search_path to '' as $fn$
declare t text := btrim(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g'));
begin
  if length(t) < p_min or length(t) > p_max then
    raise exception '% : de % à % caractères.', p_label, p_min, p_max;
  end if;
  return t;
end $fn$;

create or replace function public.admin_card_add(p_password text, p_kind text, p_text text default null, p_left text default null, p_right text default null)
returns json language plpgsql security definer set search_path to '' as $fn$
declare t text; l text; r text; res json; item integer; pk text;
begin
  if not public._is_admin(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  if p_kind = 'q' then
    res := public.add_question(p_text, 'admin');
    return json_build_object('id', (res->>'id')::integer, 'total', (res->>'total')::integer);
  elsif p_kind in ('a','j') then
    pk := case p_kind when 'j' then 'private' else 'normal' end;
    res := public.add_answer(p_text, 'admin');
    update public.answers set pack = pk where id = (res->>'id')::integer;
    return json_build_object('id', (res->>'id')::integer,
      'total', (select count(*) from public.answers where deleted_at is null and pack = pk));
  elsif p_kind = 'p' then
    t := public._clean_card('a', p_text);
    if exists (select 1 from public.priority_cards c where lower(c.text) = lower(t) and c.deleted_at is null) then
      raise exception 'Cette carte existe déjà.';
    end if;
    insert into public.priority_cards(text, theme, added_by) values (t, 'perso', 'admin')
      on conflict (lower(text)) do update set deleted_at = null, text = excluded.text, added_by = 'admin'
      returning id into item;
    return json_build_object('id', item, 'total', (select count(*) from public.priority_cards where deleted_at is null));
  elsif p_kind = 'w' then
    l := public._clean_extreme(p_left);
    r := public._clean_extreme(p_right);
    if lower(l) = lower(r) then raise exception 'Les deux extrêmes doivent être différents.'; end if;
    -- « Froid / Chaud » ferait doublon avec « Chaud / Froid ».
    if exists (select 1 from public.wave_cards c where c.deleted_at is null
               and ((lower(c.left_text) = lower(l) and lower(c.right_text) = lower(r))
                 or (lower(c.left_text) = lower(r) and lower(c.right_text) = lower(l)))) then
      raise exception 'Cette carte existe déjà.';
    end if;
    insert into public.wave_cards(left_text, right_text, added_by) values (l, r, 'admin')
      on conflict (lower(left_text), lower(right_text))
      do update set deleted_at = null, left_text = excluded.left_text, right_text = excluded.right_text, added_by = 'admin'
      returning id into item;
    return json_build_object('id', item, 'total', (select count(*) from public.wave_cards where deleted_at is null));
  elsif p_kind = 'm' then
    l := public._admin_short(p_left, 2, 60, 'Le mot des Civils');
    r := public._admin_short(p_right, 2, 60, 'Le mot Undercover');
    if lower(l) = lower(r) then raise exception 'Indique deux mots différents.'; end if;
    if exists (select 1 from public.white_words c where c.deleted_at is null
               and lower(c.civil) = lower(l) and lower(c.undercover) = lower(r)) then
      raise exception 'Cette paire existe déjà.';
    end if;
    insert into public.white_words(civil, undercover, added_by) values (l, r, 'admin')
      on conflict (civil, undercover) do update set deleted_at = null, added_by = 'admin'
      returning id into item;
    return json_build_object('id', item, 'total', (select count(*) from public.white_words where deleted_at is null));
  elsif p_kind = 'x' then
    t := public._admin_short(p_text, 3, 80, 'L’action');
    t := upper(left(t, 1)) || substr(t, 2);
    l := public._admin_short(p_left, 2, 60, 'L’intensité 1');
    r := public._admin_short(p_right, 2, 60, 'L’intensité 10');
    select c.id into item from public.mime_cards c where lower(c.action) = lower(t) order by c.deleted_at nulls first limit 1;
    if item is not null and exists (select 1 from public.mime_cards c where c.id = item and c.deleted_at is null) then
      raise exception 'Cette action existe déjà.';
    end if;
    if item is not null then
      update public.mime_cards set action = t, low_text = l, high_text = r, deleted_at = null, added_by = 'admin' where id = item;
    else
      insert into public.mime_cards(action, low_text, high_text, added_by) values (t, l, r, 'admin') returning id into item;
    end if;
    return json_build_object('id', item, 'total', (select count(*) from public.mime_cards where deleted_at is null));
  end if;
  raise exception 'Catalogue inconnu.';
end $fn$;

create or replace function public.admin_card_update(p_password text, p_kind text, p_id integer,
  p_text text default null, p_left text default null, p_right text default null, p_form text default null)
returns json language plpgsql security definer set search_path to '' as $fn$
declare t text; l text; r text;
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  if p_kind = 'q' then
    t := public._clean_card('q', p_text);
    if exists (select 1 from public.questions c where lower(c.text) = lower(t) and c.id <> p_id) then
      raise exception 'Une autre question a déjà ce texte.';
    end if;
    update public.questions set text = t where id = p_id and deleted_at is null;
  elsif p_kind in ('a','j') then
    if p_form is not null and p_form not in ('v','n') then raise exception 'Type de réponse inconnu.'; end if;
    if p_text is not null then
      t := public._clean_card('a', p_text);
      if exists (select 1 from public.answers c where lower(c.text) = lower(t) and c.id <> p_id) then
        raise exception 'Une autre réponse a déjà ce texte.';
      end if;
    end if;
    update public.answers set text = coalesce(t, text), form = coalesce(p_form, form)
      where id = p_id and deleted_at is null and pack = case p_kind when 'j' then 'private' else 'normal' end;
  elsif p_kind = 'p' then
    t := public._clean_card('a', p_text);
    if exists (select 1 from public.priority_cards c where lower(c.text) = lower(t) and c.id <> p_id) then
      raise exception 'Une autre carte a déjà ce texte.';
    end if;
    update public.priority_cards set text = t where id = p_id and deleted_at is null;
  elsif p_kind = 'w' then
    l := public._clean_extreme(p_left);
    r := public._clean_extreme(p_right);
    if lower(l) = lower(r) then raise exception 'Les deux extrêmes doivent être différents.'; end if;
    if exists (select 1 from public.wave_cards c where c.id <> p_id
               and ((lower(c.left_text) = lower(l) and lower(c.right_text) = lower(r))
                 or (lower(c.left_text) = lower(r) and lower(c.right_text) = lower(l)))) then
      raise exception 'Une autre carte a déjà ces extrêmes.';
    end if;
    update public.wave_cards set left_text = l, right_text = r where id = p_id and deleted_at is null;
  elsif p_kind = 'm' then
    l := public._admin_short(p_left, 2, 60, 'Le mot des Civils');
    r := public._admin_short(p_right, 2, 60, 'Le mot Undercover');
    if lower(l) = lower(r) then raise exception 'Indique deux mots différents.'; end if;
    if exists (select 1 from public.white_words c where c.id <> p_id and c.civil = l and c.undercover = r) then
      raise exception 'Une autre paire a déjà ces mots.';
    end if;
    update public.white_words set civil = l, undercover = r where id = p_id and deleted_at is null;
  elsif p_kind = 'x' then
    t := public._admin_short(p_text, 3, 80, 'L’action');
    t := upper(left(t, 1)) || substr(t, 2);
    l := public._admin_short(p_left, 2, 60, 'L’intensité 1');
    r := public._admin_short(p_right, 2, 60, 'L’intensité 10');
    if exists (select 1 from public.mime_cards c where lower(c.action) = lower(t) and c.id <> p_id and c.deleted_at is null) then
      raise exception 'Une autre carte a déjà cette action.';
    end if;
    update public.mime_cards set action = t, low_text = l, high_text = r where id = p_id and deleted_at is null;
  else
    raise exception 'Catalogue inconnu.';
  end if;
  if not found then raise exception 'Carte introuvable.'; end if;
  return json_build_object('id', p_id, 'text', t, 'left', l, 'right', r);
end $fn$;

create or replace function public.admin_card_delete(p_password text, p_kind text, p_id integer)
returns void language plpgsql security definer set search_path to '' as $fn$
declare rm uuid;
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  if p_kind = 'q' then
    update public.questions set deleted_at = now() where id = p_id and deleted_at is null;
  elsif p_kind in ('a','j') then
    update public.answers set deleted_at = now()
      where id = p_id and deleted_at is null and pack = case p_kind when 'j' then 'private' else 'normal' end;
    if found then
      -- la carte quitte aussi les mains, qui sont complétées aussitôt
      for rm in select distinct room_id from public.hands where answer_id = p_id loop
        delete from public.hands where room_id = rm and answer_id = p_id;
        perform public._deal(rm);
        update public.rooms set updated_at = now() where id = rm;
      end loop;
      return;
    end if;
  elsif p_kind = 'p' then
    update public.priority_cards set deleted_at = now() where id = p_id and deleted_at is null;
  elsif p_kind = 'w' then
    -- une manche en cours garde sa carte : l'état la relit sans filtre
    update public.wave_cards set deleted_at = now() where id = p_id and deleted_at is null;
  elsif p_kind = 'm' then
    update public.white_words set deleted_at = now() where id = p_id and deleted_at is null;
  elsif p_kind = 'x' then
    update public.mime_cards set deleted_at = now() where id = p_id and deleted_at is null;
  else
    raise exception 'Catalogue inconnu.';
  end if;
  if not found then raise exception 'Carte introuvable.'; end if;
end $fn$;

grant execute on function public.lancer_partie(text, uuid) to anon, authenticated;
grant execute on function public.set_phrases_variant(text, uuid, text, text) to anon, authenticated;
grant execute on function public.admin_set_private_code(text, text) to anon;
grant execute on function public.admin_cards_list(text, text, text, integer) to anon;
grant execute on function public.admin_card_add(text, text, text, text, text) to anon;
grant execute on function public.admin_card_update(text, text, integer, text, text, text, text) to anon;
grant execute on function public.admin_card_delete(text, text, integer) to anon;

do $hist$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    if not exists (select 1 from supabase_migrations.schema_migrations where version = '20261112120000') then
      insert into supabase_migrations.schema_migrations(version, name) values ('20261112120000', 'salon_admin_refonte');
    end if;
  end if;
end $hist$;

commit;
