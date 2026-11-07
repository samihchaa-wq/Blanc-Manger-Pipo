-- Phrases à trou : deux paquets de réponses, au choix de l'hôte dans le salon.
--   « Normal »       : le paquet grand public (answers.pack = 'normal').
--   « Private Joke » : les réponses du groupe, entrées à la main via l'admin
--                      (answers.pack = 'private'). Toutes les réponses déjà en
--                      base y passent.
-- Les questions restent communes aux deux modes.
--
-- Priorités ne pioche plus dans les réponses de Phrases à trou : _rank_pool ne
-- lit plus que priority_cards (les identifiants des deux tables se mélangeaient
-- en plus dans used_rank_cards).
--
-- Admin : catalogue « Private jokes » à côté de « Réponses », bascule d'une
-- réponse d'un paquet à l'autre (admin_set_card_pack), et catalogue Mimes
-- (admin_add_mime_card, admin_list_mime_cards, admin_delete_mime_card).
--
-- get_state enveloppe sa version précédente, renommée _get_state_v8, et ajoute
-- room.phrases_variant.

begin;

-- 1. Paquet de chaque réponse ------------------------------------------------
alter table public.answers add column if not exists pack text not null default 'normal';
alter table public.answers drop constraint if exists answers_pack_check;
alter table public.answers add constraint answers_pack_check check (pack in ('normal','private'));
update public.answers set pack = 'private';
create index if not exists answers_pack_form_idx on public.answers(pack, form) where deleted_at is null;

-- 2. Mode de la salle --------------------------------------------------------
alter table public.rooms add column if not exists phrases_variant text not null default 'normal';
alter table public.rooms drop constraint if exists rooms_phrases_variant_check;
alter table public.rooms add constraint rooms_phrases_variant_check check (phrases_variant in ('normal','private'));

create or replace function public.set_phrases_variant(p_code text, p_token uuid, p_variant text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception 'Seul l’hôte choisit le mode.'; end if;
  if r.status <> 'lobby' then raise exception 'Le mode se choisit depuis le salon.'; end if;
  if r.mode <> 'phrases' then raise exception 'Ce réglage est propre à Phrases à trou.'; end if;
  if p_variant is null or p_variant not in ('normal','private') then raise exception 'Mode inconnu.'; end if;
  update public.rooms set phrases_variant = p_variant, updated_at = now() where id = r.id;
end $fn$;
revoke all on function public.set_phrases_variant(text, uuid, text) from public;
grant execute on function public.set_phrases_variant(text, uuid, text) to anon, authenticated;

-- 3. Distribution : seulement le paquet de la salle --------------------------
create or replace function public._deal(p_room uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare pl record; hs int; v text; f text; want int; need int; avail int; reste int;
begin
  select hand_size, phrases_variant into hs, v from public.rooms where id = p_room;
  for pl in select id from public.players where room_id = p_room and active order by seat loop

    foreach f in array array['v','n'] loop
      want := case when f = 'v' then (hs + 1) / 2 else hs / 2 end;
      select want - count(*) into need
        from public.hands h join public.answers a on a.id = h.answer_id
        where h.player_id = pl.id and a.form = f;

      if need > 0 then
        select count(*) into avail from public.answers a
          where a.deleted_at is null and a.form = f and a.pack = v
            and not exists(select 1 from public.used_answers u where u.room_id = p_room and u.answer_id = a.id);

        if avail < need then
          delete from public.used_answers u
          using public.answers a
          where u.answer_id = a.id and a.form = f and a.pack = v and u.room_id = p_room
            and not exists(select 1 from public.hands h where h.room_id = p_room and h.answer_id = u.answer_id);
        end if;

        insert into public.hands(player_id, answer_id, room_id)
        select pl.id, a.id, p_room from public.answers a
          where a.deleted_at is null and a.form = f and a.pack = v
            and not exists(select 1 from public.used_answers u where u.room_id = p_room and u.answer_id = a.id)
          order by random() limit need;
      end if;
    end loop;

    select hs - count(*) into reste from public.hands where player_id = pl.id;
    if reste > 0 then
      insert into public.hands(player_id, answer_id, room_id)
      select pl.id, a.id, p_room from public.answers a
        where a.deleted_at is null and a.pack = v
          and not exists(select 1 from public.used_answers u where u.room_id = p_room and u.answer_id = a.id)
          and not exists(select 1 from public.hands h where h.player_id = pl.id and h.answer_id = a.id)
        order by random() limit reste;
    end if;

    insert into public.used_answers(room_id, answer_id)
    select p_room, h.answer_id from public.hands h where h.player_id = pl.id
    on conflict do nothing;
  end loop;
end $fn$;

-- 4. Priorités : plus de réponses de Phrases à trou --------------------------
create or replace function public._rank_pool(p_all boolean default false)
returns table(id integer, text text, kind text)
language sql stable security definer set search_path to '' as $fn$
  select c.id, c.text, c.theme from public.priority_cards c where p_all or c.deleted_at is null
$fn$;
-- la seule carte Priorités recopiée d'une réponse
update public.priority_cards c set deleted_at = now()
  where c.deleted_at is null and exists (select 1 from public.answers a where lower(a.text) = lower(c.text));

-- 5. get_state : room.phrases_variant ----------------------------------------
alter function public.get_state(text, uuid) rename to _get_state_v8;
revoke all on function public._get_state_v8(text, uuid) from public, anon, authenticated;

create or replace function public.get_state(p_code text, p_token uuid)
returns json language plpgsql security definer set search_path to '' as $fn$
declare base jsonb; me public.players;
begin
  base := public._get_state_v8(p_code, p_token)::jsonb;
  if base ? 'room' then
    me := public._player(p_code, p_token);
    base := jsonb_set(base, '{room,phrases_variant}',
      to_jsonb(coalesce((select r.phrases_variant from public.rooms r where r.id = me.room_id), 'normal')));
  end if;
  return base::json;
end $fn$;
revoke all on function public.get_state(text, uuid) from public;
grant execute on function public.get_state(text, uuid) to anon, authenticated;

-- 6. Admin : deux catalogues de réponses -------------------------------------
create or replace function public.admin_add_card(p_password text, p_kind text, p_text text)
returns json language plpgsql security definer set search_path to '' as $fn$
declare t text; res json; pk text;
begin
  if not public._is_admin(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  if p_kind = 'q' then return public.add_question(p_text, 'admin'); end if;
  if p_kind in ('a','j') then
    pk := case when p_kind = 'j' then 'private' else 'normal' end;
    res := public.add_answer(p_text, 'admin');
    update public.answers set pack = pk where id = (res->>'id')::integer;
    return json_build_object('id', res->>'id', 'text', res->>'text',
      'total', (select count(*) from public.answers where deleted_at is null and pack = pk));
  end if;
  if p_kind = 'p' then
    t := public._clean_card('a', p_text);
    if exists (select 1 from public.priority_cards c where lower(c.text) = lower(t) and c.deleted_at is null) then
      raise exception 'Cette carte existe déjà.';
    end if;
    insert into public.priority_cards(text, theme, added_by) values (t, 'perso', 'admin')
      on conflict (lower(text)) do update set deleted_at = null, added_by = 'admin';
    return json_build_object('text', t, 'total', (select count(*) from public.priority_cards where deleted_at is null));
  end if;
  raise exception 'Type de carte inconnu.';
end $fn$;

create or replace function public.admin_list_cards(p_password text, p_kind text, p_search text default '', p_offset integer default 0)
returns json language plpgsql security definer set search_path to '' as $fn$
declare s text := '%' || lower(trim(coalesce(p_search, ''))) || '%'; pk text;
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  if p_kind = 'q' then
    return json_build_object(
      'total', (select count(*) from public.questions q where q.deleted_at is null and lower(q.text) like s),
      'items', (select coalesce(json_agg(json_build_object('id',x.id,'text',x.text,'by',x.added_by,'blanks',x.blanks) order by x.created_at desc, x.id desc),'[]'::json)
                from (select q.id,q.text,q.added_by,q.blanks,q.created_at from public.questions q
                      where q.deleted_at is null and lower(q.text) like s
                      order by q.created_at desc, q.id desc offset greatest(p_offset,0) limit 50) x));
  elsif p_kind in ('a','j') then
    pk := case when p_kind = 'j' then 'private' else 'normal' end;
    return json_build_object(
      'total', (select count(*) from public.answers a where a.deleted_at is null and a.pack = pk and lower(a.text) like s),
      'items', (select coalesce(json_agg(json_build_object('id',x.id,'text',x.text,'by',x.added_by,'form',x.form,'pack',x.pack) order by x.created_at desc, x.id desc),'[]'::json)
                from (select a.id,a.text,a.added_by,a.form,a.pack,a.created_at from public.answers a
                      where a.deleted_at is null and a.pack = pk and lower(a.text) like s
                      order by a.created_at desc, a.id desc offset greatest(p_offset,0) limit 50) x));
  elsif p_kind = 'p' then
    return json_build_object(
      'total', (select count(*) from public.priority_cards c where c.deleted_at is null and (lower(c.text) like s or lower(c.theme) like s)),
      'items', (select coalesce(json_agg(json_build_object('id',x.id,'text',x.text,'by',x.added_by,'theme',x.theme) order by x.created_at desc, x.id desc),'[]'::json)
                from (select c.id,c.text,c.added_by,c.theme,c.created_at from public.priority_cards c
                      where c.deleted_at is null and (lower(c.text) like s or lower(c.theme) like s)
                      order by c.created_at desc, c.id desc offset greatest(p_offset,0) limit 50) x));
  elsif p_kind = 'w' then
    return json_build_object(
      'total', (select count(*) from public.wave_cards c where c.deleted_at is null and (lower(c.left_text) like s or lower(c.right_text) like s)),
      'items', (select coalesce(json_agg(json_build_object('id',x.id,'left',x.left_text,'right',x.right_text,
                  'text',x.left_text || ' ↔ ' || x.right_text,'by',x.added_by) order by x.created_at desc, x.id desc),'[]'::json)
                from (select c.id,c.left_text,c.right_text,c.added_by,c.created_at from public.wave_cards c
                      where c.deleted_at is null and (lower(c.left_text) like s or lower(c.right_text) like s)
                      order by c.created_at desc, c.id desc offset greatest(p_offset,0) limit 50) x));
  end if;
  raise exception 'Type de carte inconnu.';
end $fn$;

create or replace function public.admin_delete_card(p_password text, p_kind text, p_id integer)
returns void language plpgsql security definer set search_path to '' as $fn$
declare rm uuid;
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  if p_kind = 'q' then
    update public.questions set deleted_at = now() where id = p_id and deleted_at is null;
    if not found then raise exception 'Carte introuvable.'; end if;
  elsif p_kind in ('a','j') then
    update public.answers set deleted_at = now() where id = p_id and deleted_at is null;
    if not found then raise exception 'Carte introuvable.'; end if;
    for rm in select distinct room_id from public.hands where answer_id = p_id loop
      delete from public.hands where room_id = rm and answer_id = p_id;
      perform public._deal(rm);
      update public.rooms set updated_at = now() where id = rm;
    end loop;
  elsif p_kind = 'p' then
    update public.priority_cards set deleted_at = now() where id = p_id and deleted_at is null;
    if not found then raise exception 'Carte introuvable.'; end if;
  elsif p_kind = 'w' then
    -- une manche en cours garde sa carte : get_state la lit sans filtre
    update public.wave_cards set deleted_at = now() where id = p_id and deleted_at is null;
    if not found then raise exception 'Carte introuvable.'; end if;
  else raise exception 'Type de carte inconnu.'; end if;
end $fn$;

-- Faire passer une réponse d'un paquet à l'autre. Les mains déjà distribuées
-- gardent la carte jusqu'à ce qu'elle soit jouée ou défaussée.
create or replace function public.admin_set_card_pack(p_password text, p_id integer, p_pack text)
returns void language plpgsql security definer set search_path to '' as $fn$
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  if p_pack is null or p_pack not in ('normal','private') then raise exception 'Paquet inconnu.'; end if;
  update public.answers set pack = p_pack where id = p_id and deleted_at is null;
  if not found then raise exception 'Carte introuvable.'; end if;
end $fn$;
revoke all on function public.admin_set_card_pack(text, integer, text) from public;
grant execute on function public.admin_set_card_pack(text, integer, text) to anon;

-- 7. Admin : Mimes -----------------------------------------------------------
create or replace function public.admin_add_mime_card(p_password text, p_action text, p_low text, p_high text)
returns json language plpgsql security definer set search_path to '' as $fn$
declare act text := btrim(regexp_replace(coalesce(p_action,''), '\s+', ' ', 'g'));
        lo text := btrim(regexp_replace(coalesce(p_low,''), '\s+', ' ', 'g'));
        hi text := btrim(regexp_replace(coalesce(p_high,''), '\s+', ' ', 'g'));
        item integer;
begin
  if not public._is_admin(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  if length(act) not between 3 and 80 then raise exception 'L’action fait de 3 à 80 caractères.'; end if;
  if length(lo) not between 2 and 60 or length(hi) not between 2 and 60 then
    raise exception 'Les intensités 1 et 10 font de 2 à 60 caractères.';
  end if;
  act := upper(left(act, 1)) || substr(act, 2);
  select c.id into item from public.mime_cards c where lower(c.action) = lower(act) order by c.deleted_at nulls first limit 1;
  if item is not null and exists (select 1 from public.mime_cards c where c.id = item and c.deleted_at is null) then
    raise exception 'Cette action existe déjà.';
  end if;
  if item is not null then
    update public.mime_cards set action = act, low_text = lo, high_text = hi, deleted_at = null, added_by = 'admin' where id = item;
  else
    insert into public.mime_cards(action, low_text, high_text, added_by) values (act, lo, hi, 'admin') returning id into item;
  end if;
  return json_build_object('id', item, 'text', act,
    'total', (select count(*) from public.mime_cards where deleted_at is null));
end $fn$;

create or replace function public.admin_list_mime_cards(p_password text, p_search text default '', p_offset integer default 0)
returns json language plpgsql security definer set search_path to '' as $fn$
declare s text := '%' || lower(trim(coalesce(p_search, ''))) || '%';
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  return json_build_object(
    'total', (select count(*) from public.mime_cards c where c.deleted_at is null
               and (lower(c.action) like s or lower(c.low_text) like s or lower(c.high_text) like s)),
    'items', (select coalesce(json_agg(json_build_object('id',x.id,'text',x.action,'low',x.low_text,'high',x.high_text,'by',x.added_by)
                order by x.created_at desc, x.id desc),'[]'::json)
              from (select c.id,c.action,c.low_text,c.high_text,c.added_by,c.created_at from public.mime_cards c
                    where c.deleted_at is null and (lower(c.action) like s or lower(c.low_text) like s or lower(c.high_text) like s)
                    order by c.created_at desc, c.id desc offset greatest(p_offset,0) limit 50) x));
end $fn$;

create or replace function public.admin_delete_mime_card(p_password text, p_id integer)
returns void language plpgsql security definer set search_path to '' as $fn$
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  -- une manche en cours garde sa carte : get_state la lit sans filtre
  update public.mime_cards set deleted_at = now() where id = p_id and deleted_at is null;
  if not found then raise exception 'Carte introuvable.'; end if;
end $fn$;

revoke all on function public.admin_add_mime_card(text, text, text, text) from public;
revoke all on function public.admin_list_mime_cards(text, text, integer) from public;
revoke all on function public.admin_delete_mime_card(text, integer) from public;
grant execute on function public.admin_add_mime_card(text, text, text, text) to anon;
grant execute on function public.admin_list_mime_cards(text, text, integer) to anon;
grant execute on function public.admin_delete_mime_card(text, integer) to anon;

-- 8. Compteurs : réponses par paquet -----------------------------------------
create or replace function public.card_counts()
returns json language sql stable security definer set search_path to '' as $fn$
  select json_build_object(
    'questions', (select count(*) from public.questions where deleted_at is null),
    'answers', (select count(*) from public.answers where deleted_at is null and pack = 'normal'),
    'private', (select count(*) from public.answers where deleted_at is null and pack = 'private'),
    'priorites', (select count(*) from public.priority_cards where deleted_at is null),
    'ondes', (select count(*) from public.wave_cards where deleted_at is null),
    'mimes', (select count(*) from public.mime_cards where deleted_at is null))
$fn$;

commit;
