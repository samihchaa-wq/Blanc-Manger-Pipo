-- Deux changements :
-- 1. Priorités et Longueur d'onde se jouent dès 2 joueurs : un juge (ou un
--    médium) et un devineur suffisent. Phrases à trou reste à 3, sinon le
--    lecteur n'aurait qu'une seule réponse à juger.
-- 2. L'admin gère un quatrième catalogue, les « Extrêmes » de Longueur d'onde
--    (kind 'w') : une carte = deux textes, gauche et droite.

-- ---------- Nombre minimum de joueurs ----------
create or replace function public._min_players(p_mode text)
 returns integer
 language sql
 immutable
 set search_path to ''
as $function$
  select case when p_mode in ('priorites', 'ondes') then 2 else 3 end
$function$;

create or replace function public.start_game(p_code text, p_token uuid)
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare me public.players; r public.rooms; rd uuid; mn integer;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.host_id<>me.id then raise exception 'Seul l’hôte peut lancer la partie.'; end if;
 if r.status<>'lobby' then raise exception 'La partie est déjà en cours.'; end if;
 mn := public._min_players(r.mode);
 if (select count(*) from public.players where room_id=r.id and active)<mn then raise exception 'Il faut au moins % joueurs.', mn; end if;
 if exists(select 1 from public.players where room_id=r.id and active and not ready) then raise exception 'Tous les joueurs doivent être prêts.'; end if;
 update public.players set score=0,discard_round=0,next_ack_round=0,continue_requested=false,judge_count=0 where room_id=r.id and active;
 delete from public.hands where room_id=r.id; delete from public.used_answers where room_id=r.id; delete from public.submissions where room_id=r.id;
 delete from public.rankings where room_id=r.id;
 delete from public.wave_guesses where room_id=r.id;
 update public.rooms set used_questions='{}',round=0,previous_reader_id=null,reader_id=null,rank_cards='{}',
   wave_card=null,wave_target=null,wave_clue=null where id=r.id;
 rd:=public._random_reader(r.id,null);
 perform public._begin_round(r.id,rd,1);
end $function$;

-- Seul changement : le seuil de retour au salon suit le jeu en cours.
create or replace function public._remove_player(p_player uuid)
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare pl public.players; r public.rooms; nr uuid;
begin
  select * into pl from public.players where id = p_player;
  if pl.id is null or not pl.active then return; end if;

  select * into r from public.rooms where id = pl.room_id for update;

  update public.players set active = false where id = p_player;
  delete from public.hands where player_id = p_player;

  if r.host_id = p_player then
    update public.rooms
    set host_id = (select id from public.players where room_id = r.id and active order by seat limit 1)
    where id = r.id;
  end if;

  if r.status in ('question_select', 'answering', 'judging', 'ranking', 'clue', 'guessing', 'reveal') then
    if (select count(*) from public.players where room_id = r.id and active) < public._min_players(r.mode) then
      if r.status in ('answering', 'judging') then
        perform public._return_submissions(r.id, r.round);
      end if;
      update public.rooms set status = 'lobby', phase_at = now(), updated_at = now() where id = r.id;

    elsif r.reader_id = p_player then
      nr := public._random_reader(r.id, p_player);
      if r.status in ('answering', 'judging') then
        perform public._return_submissions(r.id, r.round);
      end if;
      perform public._begin_round(r.id, nr, case when r.status = 'question_select' then r.round else r.round + 1 end);

    elsif r.status = 'ranking' then
      delete from public.rankings where room_id = r.id and round = r.round and player_id = p_player;
      perform public._maybe_score(r.id);

    elsif r.status = 'guessing' then
      delete from public.wave_guesses where room_id = r.id and round = r.round and player_id = p_player;
      perform public._maybe_wave_score(r.id);

    elsif r.status in ('answering', 'judging') then
      delete from public.submissions where room_id = r.id and round = r.round and player_id = p_player;
      if r.status = 'judging'
         and not exists (select 1 from public.submissions where room_id = r.id and round = r.round) then
        update public.rooms set status = 'answering', phase_at = now(), updated_at = now() where id = r.id;
      elsif r.status = 'answering' then
        perform public._maybe_judge(r.id);
      end if;
    end if;
  end if;

  update public.rooms set updated_at = now() where id = r.id;
end $function$;

-- ---------- Admin : Extrêmes de Longueur d'onde ----------
create or replace function public._clean_extreme(p_text text)
 returns text
 language plpgsql
 immutable
 set search_path to ''
as $function$
declare t text;
begin
  t := regexp_replace(trim(coalesce(p_text, '')), '\s+', ' ', 'g');
  t := regexp_replace(t, '[.]+$', '');
  if length(t) < 1 then raise exception 'Remplis les deux extrêmes.'; end if;
  if length(t) > 40 then raise exception 'Un extrême dépasse 40 caractères.'; end if;
  return t;
end
$function$;

-- Comme les autres ajouts : le code admin simple suffit.
create or replace function public.admin_add_wave_card(p_password text, p_left text, p_right text)
 returns json
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare l text; r text;
begin
  if not public._is_admin(p_password) then
    raise exception 'Mot de passe incorrect.';
  end if;
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
    do update set deleted_at = null, left_text = excluded.left_text, right_text = excluded.right_text, added_by = 'admin';
  return json_build_object('left', l, 'right', r,
    'total', (select count(*) from public.wave_cards where deleted_at is null));
end
$function$;

create or replace function public.admin_list_cards(p_password text, p_kind text, p_search text default '', p_offset integer default 0)
 returns json
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare s text := '%' || lower(trim(coalesce(p_search, ''))) || '%';
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe incorrect.'; end if;
  if p_kind = 'q' then
    return json_build_object(
      'total', (select count(*) from public.questions q where q.deleted_at is null and lower(q.text) like s),
      'items', (select coalesce(json_agg(json_build_object('id',x.id,'text',x.text,'by',x.added_by,'blanks',x.blanks) order by x.created_at desc, x.id desc),'[]'::json)
                from (select q.id,q.text,q.added_by,q.blanks,q.created_at from public.questions q
                      where q.deleted_at is null and lower(q.text) like s
                      order by q.created_at desc, q.id desc offset greatest(p_offset,0) limit 50) x));
  elsif p_kind = 'a' then
    return json_build_object(
      'total', (select count(*) from public.answers a where a.deleted_at is null and lower(a.text) like s),
      'items', (select coalesce(json_agg(json_build_object('id',x.id,'text',x.text,'by',x.added_by,'form',x.form) order by x.created_at desc, x.id desc),'[]'::json)
                from (select a.id,a.text,a.added_by,a.form,a.created_at from public.answers a
                      where a.deleted_at is null and lower(a.text) like s
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
end
$function$;

create or replace function public.admin_delete_card(p_password text, p_kind text, p_id integer)
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $function$
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
  elsif p_kind='p' then
    update public.priority_cards set deleted_at=now() where id=p_id and deleted_at is null; if not found then raise exception 'Carte introuvable.'; end if;
  elsif p_kind='w' then
    -- une manche en cours garde sa carte : get_state la lit sans filtre
    update public.wave_cards set deleted_at=now() where id=p_id and deleted_at is null; if not found then raise exception 'Carte introuvable.'; end if;
  else raise exception 'Type de carte inconnu.'; end if;
end $function$;

create or replace function public.card_counts()
 returns json
 language sql
 stable security definer
 set search_path to ''
as $function$
  select json_build_object(
    'questions', (select count(*) from public.questions where deleted_at is null),
    'answers', (select count(*) from public.answers where deleted_at is null),
    'priorites', (select count(*) from public.priority_cards where deleted_at is null),
    'ondes', (select count(*) from public.wave_cards where deleted_at is null))
$function$;

revoke all on function public._min_players(text) from public, anon, authenticated;
revoke all on function public._clean_extreme(text) from public, anon, authenticated;
revoke all on function public._remove_player(uuid) from public, anon, authenticated;
revoke all on function public.start_game(text, uuid) from public, anon, authenticated;
grant execute on function public.start_game(text, uuid) to anon;
revoke all on function public.admin_add_wave_card(text, text, text) from public, anon, authenticated;
grant execute on function public.admin_add_wave_card(text, text, text) to anon;
revoke all on function public.admin_list_cards(text, text, text, integer) from public, anon, authenticated;
grant execute on function public.admin_list_cards(text, text, text, integer) to anon;
revoke all on function public.admin_delete_card(text, text, integer) from public, anon, authenticated;
grant execute on function public.admin_delete_card(text, text, integer) to anon;
revoke all on function public.card_counts() from public, anon, authenticated;
grant execute on function public.card_counts() to anon;

notify pgrst, 'reload schema';
