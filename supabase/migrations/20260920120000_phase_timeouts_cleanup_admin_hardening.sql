-- Minuteurs de phase (exclusion/avance auto après 2 min d'inactivité),
-- message côté client quand la partie tombe sous 3 joueurs (via phase_at),
-- retrait des fonctionnalités mortes (changer de question, carte bonus),
-- durcissement de l'authentification admin.

-- 1) Horodatage du début de chaque phase, indépendant de updated_at
--    (updated_at bouge à chaque petite action ; phase_at ne bouge qu'au changement de phase).
alter table public.rooms add column if not exists phase_at timestamptz not null default now();

-- 2) Poser phase_at à chaque transition de statut.

create or replace function public._begin_round(p_room uuid, p_reader uuid, p_next_round integer)
 returns void language plpgsql security definer set search_path to '' as $function$
declare choices integer[];
begin
  perform public._deal(p_room);
  choices := public._question_choices(p_room);
  delete from public.submissions where room_id = p_room and round = p_next_round;
  update public.players set next_ack_round = 0 where room_id = p_room and active;
  update public.rooms set
    status = 'question_select', round = p_next_round,
    previous_reader_id = reader_id, reader_id = p_reader,
    question_id = null, question_choices = choices,
    winner_id = null, winning_submission_id = null,
    phase_at = now(), updated_at = now()
  where id = p_room;
end $function$;

create or replace function public.select_question(p_code text, p_token uuid, p_question_id integer)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.status<>'question_select' then raise exception 'La question est déjà choisie.'; end if;
 if r.reader_id<>me.id then raise exception 'Seul le lecteur choisit la carte à trou.'; end if;
 if not(p_question_id=any(r.question_choices)) then raise exception 'Cette carte n’est pas proposée.'; end if;
 update public.rooms set question_id=p_question_id,used_questions=used_questions||p_question_id,question_choices='{}',status='answering',phase_at=now(),updated_at=now() where id=r.id;
 perform public._maybe_judge(r.id);
end $function$;

create or replace function public._maybe_judge(p_room uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare r public.rooms;
begin
  select * into r from public.rooms where id = p_room;
  if r.status <> 'answering' then return; end if;
  if not exists (
    select 1 from public.players p
    where p.room_id = p_room and p.active and p.id <> r.reader_id
      and not exists (
        select 1 from public.submissions s
        where s.room_id = p_room and s.round = r.round and s.player_id = p.id
      )
  ) and exists (
    select 1 from public.submissions s where s.room_id = p_room and s.round = r.round
  ) then
    update public.rooms set status = 'judging', phase_at = now(), updated_at = now() where id = p_room;
  end if;
end $function$;

create or replace function public.force_judging(p_code text, p_token uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if me.id not in (r.reader_id, r.host_id) then raise exception 'Seul le lecteur ou l''hôte peut faire ça.'; end if;
  if r.status <> 'answering' then raise exception 'Les réponses sont déjà fermées.'; end if;
  if not exists (select 1 from public.submissions where room_id = r.id and round = r.round) then
    raise exception 'Personne n''a encore répondu.';
  end if;
  update public.rooms set status = 'judging', phase_at = now(), updated_at = now() where id = r.id;
end $function$;

create or replace function public.pick_winner(p_code text, p_token uuid, p_submission_id uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; w uuid; sc integer;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if; select * into r from public.rooms where id=me.room_id for update;
 if r.reader_id<>me.id then raise exception 'Seul le lecteur choisit la gagnante.'; end if; if r.status<>'judging' then raise exception 'Ce n’est pas le moment de voter.'; end if;
 select s.player_id into w from public.submissions s join public.players p on p.id=s.player_id and p.active where s.id=p_submission_id and s.room_id=r.id and s.round=r.round; if w is null then raise exception 'Réponse introuvable ou joueur parti.'; end if;
 update public.players set score=score+1 where id=w and active returning score into sc;
 update public.rooms set status=case when sc>=r.target_score then 'finished' else 'reveal' end,winner_id=w,winning_submission_id=p_submission_id,phase_at=now(),updated_at=now() where id=r.id;
end $function$;

-- start_game : ne réinitialise plus les colonnes de la carte bonus / des skips (supprimées plus bas).
create or replace function public.start_game(p_code text, p_token uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
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
 update public.rooms set used_questions='{}',round=0,previous_reader_id=null,reader_id=null where id=r.id;
 rd:=public._random_reader(r.id,null);
 perform public._begin_round(r.id,rd,1);
end $function$;

-- _remove_player : quand un départ rouvre la phase de réponses, on redémarre le minuteur.
create or replace function public._remove_player(p_player uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
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

  if r.status in ('question_select', 'answering', 'judging', 'reveal') then
    if (select count(*) from public.players where room_id = r.id and active) < 3 then
      if r.status not in ('question_select', 'reveal') then
        perform public._return_submissions(r.id, r.round);
      end if;
      update public.rooms set status = 'lobby', phase_at = now(), updated_at = now() where id = r.id;

    elsif r.reader_id = p_player then
      nr := public._random_reader(r.id, p_player);
      if r.status not in ('question_select', 'reveal') then
        perform public._return_submissions(r.id, r.round);
      end if;
      perform public._begin_round(r.id, nr, case when r.status = 'question_select' then r.round else r.round + 1 end);

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

-- 3) get_state expose phase_at pour piloter le minuteur côté client.
create or replace function public.get_state(p_code text, p_token uuid)
 returns json language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 if me.last_seen<now()-interval '5 minutes' then update public.players set last_seen=now() where id=me.id; end if;
 select * into r from public.rooms where id=me.room_id;
 return json_build_object(
 'room',json_build_object('code',r.code,'status',r.status,'round',r.round,'target',r.target_score,'host_id',r.host_id,'reader_id',r.reader_id,'winner_id',r.winner_id,'winning_submission_id',r.winning_submission_id,'updated_at',r.updated_at,'phase_at',r.phase_at,'submission_count',(select count(*) from public.submissions s where s.room_id=r.id and s.round=r.round)),
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
end $function$;

-- 4) Minuteur : n'importe quel client appelle reap_idle ; le serveur revérifie le délai
--    de 2 min et débloque la phase. Aucune tâche planifiée côté serveur n'étant possible,
--    c'est le premier téléphone qui constate l'expiration qui déclenche l'action.
create or replace function public.reap_idle(p_code text, p_token uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; pl record; rd uuid;
begin
  me := public._player(p_code, p_token);
  if me.id is null then return; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.id is null then return; end if;
  if now() - r.phase_at < interval '120 seconds' then return; end if;

  if r.status = 'question_select' then
    -- le lecteur n'a pas choisi sa carte : on l'exclut, un nouveau lecteur est tiré.
    perform public._remove_player(r.reader_id);

  elsif r.status = 'answering' then
    -- on exclut les joueurs (hors lecteur) qui n'ont pas répondu à temps.
    for pl in
      select p.id from public.players p
      where p.room_id = r.id and p.active and p.id <> r.reader_id
        and not exists (
          select 1 from public.submissions s
          where s.room_id = r.id and s.round = r.round and s.player_id = p.id
        )
    loop
      perform public._remove_player(pl.id);
    end loop;
    perform public._maybe_judge(r.id);

  elsif r.status = 'judging' then
    -- le lecteur n'a pas départagé : on l'exclut, un nouveau lecteur relance la manche.
    perform public._remove_player(r.reader_id);

  elsif r.status = 'reveal' then
    -- personne n'a besoin d'être exclu : la manche est finie, on passe à la suivante.
    rd := public._random_reader(r.id, r.reader_id);
    perform public._begin_round(r.id, rd, r.round + 1);
  end if;
end $function$;

grant execute on function public.reap_idle(text,uuid) to anon;

-- 5) Durcissement de l'authentification admin.
--    a) Préférer l'en-tête posé par le CDN (cf-connecting-ip), non falsifiable par le client,
--       au x-forwarded-first-element qui, lui, est contrôlable côté client.
create or replace function public._client_hash()
 returns text language plpgsql stable security definer set search_path to '' as $function$
declare headers jsonb; ip text; pepper text;
begin
  begin headers := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then headers := null; end;
  if headers is null then return null; end if;
  ip := nullif(btrim(coalesce(
          headers->>'cf-connecting-ip',
          split_part(coalesce(headers->>'x-forwarded-for', ''), ',', 1)
        )), '');
  if ip is null then return null; end if;
  select s.value into pepper from public.app_settings s where s.key = 'rate_pepper';
  if pepper is null then return null; end if;
  return encode(extensions.digest(pepper || ':' || ip, 'sha256'), 'hex');
end $function$;

--    b) Sérialiser globalement toute vérification de mot de passe admin : en falsifiant
--       son IP un attaquant obtenait un verrou distinct par IP et pouvait tenter en
--       parallèle. Un verrou global force une tentative à la fois, ce qui rend le
--       pg_sleep(1.5s) sur échec réellement bloquant.
create or replace function public._is_admin(p_password text)
 returns boolean language plpgsql security definer set search_path to '' as $function$
declare k text; h text; ok boolean := false; cost integer := 0; client_hash text;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('bmp-admin-global', 0));
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
end $function$;

create or replace function public._is_admin_plus(p_password text)
 returns boolean language plpgsql security definer set search_path to '' as $function$
declare stored_hash text; ok boolean := false; cost integer := 0; client_hash text;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('bmp-admin-global', 0));
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
end $function$;

create or replace function public.admin_level(p_password text)
 returns text language plpgsql security definer set search_path to '' as $function$
declare plus_hash text; base_hash text; client_hash text;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('bmp-admin-global', 0));
  client_hash := coalesce(public._client_hash(), 'no-request-context');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('bmp-admin:' || client_hash, 0));
  select value into plus_hash from public.app_settings where key = 'admin_plus_hash';
  select value into base_hash from public.app_settings where key = 'admin_hash';
  if plus_hash is not null and plus_hash = extensions.crypt(coalesce(p_password, ''), plus_hash) then return 'plus'; end if;
  if base_hash is not null and base_hash = extensions.crypt(coalesce(p_password, ''), base_hash) then return 'admin'; end if;
  perform pg_catalog.pg_sleep(1.5);
  return 'none';
end $function$;

-- 6) Retrait des fonctionnalités mortes : changer de question et carte bonus du gagnant.
drop function if exists public.skip_question(text, uuid);
drop function if exists public.add_reward_card(text, uuid, text, text);
drop function if exists public._draw_question(uuid);

alter table public.rooms drop column if exists skips_used;
alter table public.rooms drop column if exists reward_used;
alter table public.rooms drop column if exists reward_kind;
alter table public.rooms drop column if exists reward_text;
