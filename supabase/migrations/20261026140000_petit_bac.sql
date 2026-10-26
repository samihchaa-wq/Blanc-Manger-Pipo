-- Quatrième jeu : « Petit bac », à deux exactement.
-- 1. naming (une fois par partie) : les joueurs proposent chacun leur tour une
--    catégorie, l'hôte d'abord, jusqu'à six. Elles ne vivent que dans la
--    partie : aucun catalogue, rien n'est gardé d'une partie à l'autre.
-- Puis cinq manches sur ces six catégories :
-- 2. writing : une lettre est tirée (la roue tourne côté client, 5 s), puis
--    2 min pour trouver un mot par catégorie. Les réponses sont enregistrées au
--    fil de la frappe ; la phase se clôt quand les deux ont fini ou au temps.
-- 3. voting : catégorie par catégorie, chacun juge la réponse de l'autre :
--    👍 = 2 points, 🟰 (même mot) = 1, 👎 = 0. Une case vide vaut 0 d'office.
-- 4. reveal (5 s), puis manche suivante. Le meilleur total gagne.
-- Migration additive : les autres jeux et les clients pas encore à jour ne
-- voient aucun changement.

alter table public.rooms
  add column if not exists bac_categories text[] not null default '{}',
  add column if not exists bac_letter text,
  add column if not exists used_bac_letters text[] not null default '{}',
  add column if not exists bac_step integer not null default 0;
alter table public.rooms drop constraint if exists rooms_mode_check;
alter table public.rooms add constraint rooms_mode_check check (mode in ('phrases', 'priorites', 'ondes', 'bac'));
alter table public.rooms drop constraint if exists rooms_status_check;
alter table public.rooms add constraint rooms_status_check
  check (status in ('lobby', 'question_select', 'answering', 'judging', 'ranking', 'clue', 'guessing',
                    'naming', 'writing', 'voting', 'reveal', 'finished'));

-- Une grille par joueur et par manche. points[i] = ce que l'adversaire a
-- accordé à la réponse i (null tant qu'il n'a pas voté).
create table if not exists public.bac_answers (
  room_id uuid not null references public.rooms(id) on delete cascade,
  round integer not null,
  player_id uuid not null references public.players(id) on delete cascade,
  answers text[] not null default '{}',
  done boolean not null default false,
  points integer[],
  primary key (room_id, round, player_id)
);
create index if not exists bac_answers_player_idx on public.bac_answers (player_id);
alter table public.bac_answers enable row level security;
revoke all on table public.bac_answers from public, anon, authenticated;

-- ---------- Deux joueurs, ni plus ni moins ----------
create or replace function public._min_players(p_mode text)
 returns integer language sql immutable set search_path to '' as $function$
  select case when p_mode in ('priorites', 'ondes', 'bac') then 2 else 3 end
$function$;

create or replace function public._max_players(p_mode text)
 returns integer language sql immutable set search_path to '' as $function$
  select case when p_mode = 'bac' then 2 else 12 end
$function$;

-- ---------- Nouvelle manche : une lettre, la grille à remplir ----------
-- Manche 1 : on commence par proposer les catégories. Ensuite, on tire
-- directement la lettre suivante (jamais deux fois la même dans la partie).
create or replace function public._begin_bac_round(p_room uuid, p_next_round integer)
 returns void language plpgsql security definer set search_path to '' as $function$
declare r public.rooms; w uuid; l text;
  lettres text[] := string_to_array('A,B,C,D,E,F,G,H,I,J,L,M,N,O,P,R,S,T,U,V', ',');
begin
  select * into r from public.rooms where id = p_room;
  if p_next_round > 5 then
    select id into w from public.players where room_id = p_room and active order by score desc, seat limit 1;
    update public.rooms set status = 'finished', winner_id = w, winning_submission_id = null,
      phase_at = now(), updated_at = now() where id = p_room;
    return;
  end if;

  update public.players set next_ack_round = 0 where room_id = p_room and active;
  delete from public.bac_answers where room_id = p_room and round = p_next_round;

  if cardinality(r.bac_categories) < 6 then
    update public.rooms set
      status = 'naming', round = p_next_round,
      previous_reader_id = reader_id, reader_id = public._next_reader(p_room, null),
      bac_letter = null, bac_step = 0,
      question_id = null, question_choices = '{}',
      winner_id = null, winning_submission_id = null,
      phase_at = now(), updated_at = now()
    where id = p_room;
    return;
  end if;

  -- K, Q, W, X, Y et Z sont écartées : trop peu de mots pour six catégories.
  select x into l from unnest(lettres) x where not (x = any(r.used_bac_letters)) order by random() limit 1;
  -- Les 2 min démarrent après la roue : phase_at est posé 5 s plus tard.
  update public.rooms set
    status = 'writing', round = p_next_round,
    previous_reader_id = reader_id,
    bac_letter = l, used_bac_letters = r.used_bac_letters || l, bac_step = 0,
    question_id = null, question_choices = '{}',
    winner_id = null, winning_submission_id = null,
    phase_at = now() + interval '5 seconds', updated_at = now()
  where id = p_room;
end $function$;

-- ---------- Les catégories, proposées chacun son tour ----------
create or replace function public.bac_category(p_code text, p_token uuid, p_name text)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms;
  t text := regexp_replace(btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')), '[.]+$', '');
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.status <> 'naming' then raise exception 'Les catégories sont déjà choisies.'; end if;
  if r.reader_id <> me.id then raise exception 'Ce n’est pas ton tour de proposer.'; end if;
  if t = '' then raise exception 'Écris une catégorie.'; end if;
  if char_length(t) > 40 then raise exception 'Une catégorie fait 40 caractères au maximum.'; end if;
  t := upper(left(t, 1)) || substr(t, 2);
  if lower(t) = any(select lower(x) from unnest(r.bac_categories) x) then
    raise exception 'Cette catégorie est déjà prise.';
  end if;

  if cardinality(r.bac_categories) < 5 then
    update public.rooms set bac_categories = r.bac_categories || t,
      reader_id = public._next_reader(r.id, me.id), phase_at = now(), updated_at = now()
    where id = r.id;
  else
    update public.rooms set bac_categories = r.bac_categories || t where id = r.id;
    perform public._begin_bac_round(r.id, r.round);
  end if;
end $function$;

-- Pour un absent ou un bot : une catégorie classique qui n'est pas déjà prise.
create or replace function public._bac_default_category(p_room uuid)
 returns text language sql stable security definer set search_path to '' as $function$
  select x from unnest(array['Prénom','Pays','Ville','Animal','Métier','Objet','Fruit ou légume',
                             'Marque','Sport','Célébrité','Plat','Vêtement']) x
  where not lower(x) = any(select lower(y) from public.rooms r cross join unnest(r.bac_categories) y where r.id = p_room)
  order by random() limit 1
$function$;

-- ---------- Passage au vote ----------
create or replace function public._bac_advance(p_room uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare r public.rooms; s integer;
begin
  select * into r from public.rooms where id = p_room;
  if r.status <> 'voting' then return; end if;
  s := r.bac_step;
  -- on passe chaque catégorie où plus aucun vote n'est attendu
  while s < 6 and not exists (
    select 1 from public.bac_answers b join public.players p on p.id = b.player_id and p.active
    where b.room_id = p_room and b.round = r.round and b.points[s + 1] is null
  ) loop
    s := s + 1;
  end loop;

  if s >= 6 then
    update public.players p set score = p.score + coalesce((select sum(x) from unnest(b.points) x), 0)
      from public.bac_answers b
      where b.room_id = p_room and b.round = r.round and b.player_id = p.id and p.active;
    update public.rooms set bac_step = 6, status = 'reveal', phase_at = now(), updated_at = now() where id = p_room;
  elsif s <> r.bac_step then
    -- chaque catégorie a ses 2 min de vote
    update public.rooms set bac_step = s, phase_at = now(), updated_at = now() where id = p_room;
  end if;
end $function$;

create or replace function public._bac_start_vote(p_room uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare r public.rooms;
begin
  select * into r from public.rooms where id = p_room;
  if r.status <> 'writing' then return; end if;
  -- celui qui n'a rien enregistré rend une grille vide
  insert into public.bac_answers as b (room_id, round, player_id, answers, done)
  select p_room, r.round, p.id, array_fill(''::text, array[6]), true
    from public.players p where p.room_id = p_room and p.active
  on conflict (room_id, round, player_id) do update set done = true;
  -- une case vide vaut 0 d'office : rien à juger
  update public.bac_answers b set points = (
      select array_agg(case when coalesce(b.answers[i], '') = '' then 0 end order by i)
      from generate_series(1, 6) i)
    where b.room_id = p_room and b.round = r.round;
  update public.rooms set status = 'voting', bac_step = 0, phase_at = now(), updated_at = now() where id = p_room;
  perform public._bac_advance(p_room);
end $function$;

-- ---------- Réponses : enregistrées au fil de la frappe, closes par « J'ai fini » ----------
create or replace function public.bac_save(p_code text, p_token uuid, p_answers text[], p_done boolean default false)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; a text[];
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.status <> 'writing' then raise exception 'Le temps est écoulé.'; end if;
  if cardinality(coalesce(p_answers, '{}')) > 6 then raise exception 'Six réponses au maximum.'; end if;
  select array_agg(left(btrim(regexp_replace(coalesce(p_answers[i], ''), '\s+', ' ', 'g')), 40) order by i)
    into a from generate_series(1, 6) i;

  -- une grille rendue ne bouge plus
  insert into public.bac_answers as b (room_id, round, player_id, answers, done)
  values (r.id, r.round, me.id, a, coalesce(p_done, false))
  on conflict (room_id, round, player_id) do update
    set answers = excluded.answers, done = excluded.done
    where not b.done;

  if coalesce(p_done, false) then
    if not exists (
      select 1 from public.players p where p.room_id = r.id and p.active
        and not exists (select 1 from public.bac_answers b
                        where b.room_id = r.id and b.round = r.round and b.player_id = p.id and b.done)
    ) then
      perform public._bac_start_vote(r.id);
    end if;
    update public.rooms set updated_at = now() where id = r.id;
  end if;
end $function$;

-- ---------- Vote sur la réponse de l'adversaire, catégorie en cours ----------
create or replace function public.bac_vote(p_code text, p_token uuid, p_vote integer)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.status <> 'voting' then raise exception 'Ce n’est pas le moment de voter.'; end if;
  if p_vote is null or p_vote not in (0, 1, 2) then raise exception 'Vote invalide.'; end if;
  update public.bac_answers b set points[r.bac_step + 1] = p_vote
    where b.room_id = r.id and b.round = r.round and b.player_id <> me.id
      and b.points[r.bac_step + 1] is null
      and exists (select 1 from public.players p where p.id = b.player_id and p.active);
  if not found then raise exception 'Ton vote est déjà enregistré.'; end if;
  perform public._bac_advance(r.id);
  update public.rooms set updated_at = now() where id = r.id;
end $function$;

-- ---------- Aiguillage des manches ----------
create or replace function public._begin_round(p_room uuid, p_reader uuid, p_next_round integer)
 returns void language plpgsql security definer set search_path to '' as $function$
declare choices integer[]; m text;
begin
  select mode into m from public.rooms where id = p_room;
  if m = 'priorites' then
    perform public._begin_rank_round(p_room, p_next_round);
    return;
  end if;
  if m = 'ondes' then
    perform public._begin_wave_round(p_room, p_next_round);
    return;
  end if;
  if m = 'bac' then
    perform public._begin_bac_round(p_room, p_next_round);
    return;
  end if;
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

-- ---------- Choix du jeu ----------
create or replace function public.create_room(p_name text, p_target integer default 5,
                                              p_mode text default 'phrases', p_turns integer default 2)
 returns json language plpgsql security definer set search_path to '' as $function$
declare
  r public.rooms;
  p public.players;
  n text := left(trim(coalesce(p_name, '')), 20);
  client_hash text;
  attempt integer;
begin
  if n = '' then
    raise exception 'Choisis un pseudo.';
  end if;
  if p_target is null or p_target not in (3, 5, 7, 10) then
    raise exception 'Le score cible doit être 3, 5, 7 ou 10.';
  end if;
  if p_mode is null or p_mode not in ('phrases', 'priorites', 'ondes', 'bac') then
    raise exception 'Jeu inconnu.';
  end if;
  if p_turns is null or p_turns not in (1, 2, 3) then
    raise exception 'Le nombre de tours doit être 1, 2 ou 3.';
  end if;

  client_hash := public._client_hash();

  if client_hash is not null then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('bmp-create:' || client_hash, 0)
    );
    if (
      select count(*)
      from public.rooms x
      where x.created_by_hash = client_hash
        and x.created_at > now() - interval '10 minutes'
    ) >= 10 then
      raise exception 'Trop de parties créées récemment. Réessaie dans quelques minutes.';
    end if;
  end if;

  delete from public.rooms
  where updated_at < now() - interval '1 day';

  for attempt in 1..5 loop
    begin
      insert into public.rooms(code, target_score, mode, judge_turns, created_by_hash)
      values (public._new_code(), p_target, p_mode, p_turns, client_hash)
      returning * into r;
      exit;
    exception when unique_violation then
      if attempt = 5 then
        raise exception 'Impossible de générer un code de partie. Réessaie.';
      end if;
    end;
  end loop;

  insert into public.players(room_id, name, seat, joined_by_hash)
  values (r.id, n, 0, client_hash)
  returning * into p;

  update public.rooms
  set host_id = p.id
  where id = r.id;

  return json_build_object('code', r.code, 'player_id', p.id, 'token', p.token);
end
$function$;

create or replace function public.set_room_options(p_code text, p_token uuid, p_mode text, p_target integer, p_turns integer)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception 'Seul l’hôte choisit le jeu.'; end if;
  if r.status <> 'lobby' then raise exception 'Le jeu se choisit depuis le salon.'; end if;
  if p_mode is null or p_mode not in ('phrases', 'priorites', 'ondes', 'bac') then raise exception 'Jeu inconnu.'; end if;
  if p_target is null or p_target not in (3, 5, 7, 10) then raise exception 'Le score cible doit être 3, 5, 7 ou 10.'; end if;
  if p_turns is null or p_turns not in (1, 2, 3) then raise exception 'Le nombre de tours doit être 1, 2 ou 3.'; end if;
  if (select count(*) from public.players where room_id = r.id and active) > public._max_players(p_mode) then
    raise exception 'Le Petit bac se joue à deux.';
  end if;
  update public.rooms set mode = p_mode, target_score = p_target, judge_turns = p_turns, updated_at = now()
    where id = r.id;
end $function$;

-- ---------- Arrivées : pas de troisième joueur au Petit bac ----------
create or replace function public.join_room(p_code text, p_name text)
 returns json language plpgsql security definer set search_path to '' as $function$
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
  if (select count(*) from public.players where room_id=r.id and active)>=public._max_players(r.mode) then
    raise exception '%', case when r.mode='bac' then 'La partie est pleine : le Petit bac se joue à deux.' else 'La partie est pleine (12 joueurs max).' end;
  end if;
  if exists(select 1 from public.players where room_id=r.id and active and lower(name)=lower(n)) then raise exception 'Ce pseudo est déjà pris dans cette partie.'; end if;
  insert into public.players(room_id,name,seat,joined_by_hash)
  values(r.id,n,(select coalesce(max(seat),-1)+1 from public.players where room_id=r.id),client_hash) returning * into p;
  update public.rooms set updated_at=now() where id=r.id;
  return json_build_object('code',r.code,'player_id',p.id,'token',p.token);
end
$function$;

create or replace function public.add_bot(p_code text, p_token uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; n integer; botname text;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception 'Seul l’hôte peut ajouter un bot.'; end if;
  if r.status <> 'lobby' then raise exception 'Les bots s’ajoutent depuis le salon.'; end if;
  if (select count(*) from public.players where room_id = r.id and active) >= public._max_players(r.mode) then
    raise exception 'La partie est pleine.';
  end if;
  select coalesce(max(seat), -1) + 1 into n from public.players where room_id = r.id;
  botname := 'Bot ' || (select count(*) + 1 from public.players where room_id = r.id and is_bot);
  insert into public.players(room_id, name, seat, is_bot, ready) values (r.id, botname, n, true, true);
  update public.rooms set updated_at = now() where id = r.id;
end $function$;

create or replace function public.start_game(p_code text, p_token uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; rd uuid; mn integer; nb integer;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.host_id<>me.id then raise exception 'Seul l’hôte peut lancer la partie.'; end if;
 if r.status<>'lobby' then raise exception 'La partie est déjà en cours.'; end if;
 mn := public._min_players(r.mode);
 select count(*) into nb from public.players where room_id=r.id and active;
 if nb<mn then raise exception 'Il faut au moins % joueurs.', mn; end if;
 if nb>public._max_players(r.mode) then raise exception 'Le Petit bac se joue à deux.'; end if;
 if exists(select 1 from public.players where room_id=r.id and active and not ready) then raise exception 'Tous les joueurs doivent être prêts.'; end if;
 update public.players set score=0,discard_round=0,next_ack_round=0,continue_requested=false,judge_count=0 where room_id=r.id and active;
 delete from public.hands where room_id=r.id; delete from public.used_answers where room_id=r.id; delete from public.submissions where room_id=r.id;
 delete from public.rankings where room_id=r.id;
 delete from public.wave_guesses where room_id=r.id;
 delete from public.bac_answers where room_id=r.id;
 update public.rooms set used_questions='{}',round=0,previous_reader_id=null,reader_id=null,rank_cards='{}',
   wave_card=null,wave_target=null,wave_clue=null,
   bac_categories='{}',bac_letter=null,used_bac_letters='{}',bac_step=0 where id=r.id;
 rd:=public._random_reader(r.id,null);
 perform public._begin_round(r.id,rd,1);
end $function$;

-- ---------- Départs : seul changement, les phases du Petit bac renvoient aussi au salon ----------
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

  if r.status in ('question_select', 'answering', 'judging', 'ranking', 'clue', 'guessing',
                  'naming', 'writing', 'voting', 'reveal') then
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

-- ---------- Minuteurs : jouer à la place des absents ----------
-- Petit bac : une catégorie classique est proposée pour lui ; au bout des 2 min d'écriture
-- (+ 3 s pour laisser arriver les dernières frappes), les grilles sont
-- ramassées telles quelles ; un vote oublié vaut 👍.
create or replace function public.reap_idle(p_code text, p_token uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; pl record; n integer; aid integer; aid2 integer; sid uuid; delai interval;
begin
  me := public._player(p_code, p_token);
  if me.id is null then return; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.id is null then return; end if;
  delai := case when r.status = 'reveal' then interval '5 seconds'
                when r.status = 'writing' then interval '123 seconds'
                else interval '120 seconds' end;
  if now() - r.phase_at < delai then return; end if;

  if r.status = 'question_select' then
    -- la première carte proposée, dans l'ordre où le lecteur les voit
    if cardinality(r.question_choices) > 0 then
      perform public.select_question(r.code, (select token from public.players where id = r.reader_id),
                                     r.question_choices[1]);
    end if;

  elsif r.status = 'answering' then
    select coalesce(blanks, 1) into n from public.questions where id = r.question_id;
    n := coalesce(n, 1);
    -- les premières cartes de la main, dans l'ordre où elle s'affiche
    for pl in
      select p.id, p.token from public.players p
      where p.room_id = r.id and p.active and p.id <> r.reader_id
        and not exists (select 1 from public.submissions s where s.room_id = r.id and s.round = r.round and s.player_id = p.id)
      order by p.seat
    loop
      select h.answer_id into aid from public.hands h join public.answers a on a.id = h.answer_id
        where h.player_id = pl.id order by a.text, a.id limit 1;
      aid2 := null;
      if n = 2 then
        select h.answer_id into aid2 from public.hands h join public.answers a on a.id = h.answer_id
          where h.player_id = pl.id and h.answer_id <> aid order by a.text, a.id limit 1;
      end if;
      if aid is not null and (n = 1 or aid2 is not null) then
        perform public.submit_answer(r.code, pl.token, aid, aid2);
      end if;
    end loop;

  elsif r.status = 'judging' then
    -- la première réponse lue par le lecteur gagne le point
    select s.id into sid from public.submissions s
      join public.players p on p.id = s.player_id and p.active
      where s.room_id = r.id and s.round = r.round order by s.sort_key limit 1;
    if sid is not null then
      perform public.pick_winner(r.code, (select token from public.players where id = r.reader_id), sid);
    end if;

  elsif r.status = 'ranking' then
    for pl in
      select p.token from public.players p
      where p.room_id = r.id and p.active
        and not exists (select 1 from public.rankings k where k.room_id = r.id and k.round = r.round and k.player_id = p.id)
      order by p.seat
    loop
      perform public.submit_ranking(r.code, pl.token,
        (select array_agg(x order by random()) from unnest(r.rank_cards) x));
    end loop;

  elsif r.status = 'clue' then
    perform public.submit_clue(r.code, (select token from public.players where id = r.reader_id), 'Sans texte');

  elsif r.status = 'guessing' then
    for pl in
      select p.token from public.players p
      where p.room_id = r.id and p.active and p.id <> r.reader_id
        and not exists (select 1 from public.wave_guesses g where g.room_id = r.id and g.round = r.round and g.player_id = p.id)
      order by p.seat
    loop
      perform public.submit_guess(r.code, pl.token, 50);
    end loop;

  elsif r.status = 'naming' then
    if exists (select 1 from public.players where id = r.reader_id and active) then
      perform public.bac_category(r.code, (select token from public.players where id = r.reader_id),
                                  public._bac_default_category(r.id));
    end if;

  elsif r.status = 'writing' then
    perform public._bac_start_vote(r.id);

  elsif r.status = 'voting' then
    for pl in
      select p.token from public.players p
      where p.room_id = r.id and p.active
        and exists (select 1 from public.bac_answers b
                    join public.players o on o.id = b.player_id and o.active
                    where b.room_id = r.id and b.round = r.round and b.player_id <> p.id
                      and b.points[r.bac_step + 1] is null)
      order by p.seat
    loop
      perform public.bac_vote(r.code, pl.token, 2);
    end loop;

  elsif r.status = 'reveal' then
    perform public._begin_round(r.id, public._next_reader(r.id, r.reader_id), r.round + 1);
  end if;
end $function$;

-- ---------- Bots : catégorie classique, grille « X comme bot », votes surtout 👍 ----------
create or replace function public.bot_step(p_code text, p_token uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms; b public.players; aid integer; aid2 integer; sid uuid; qid integer; n int; sc int; rd uuid;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;

  if r.status = 'question_select' then
    select * into b from public.players where id = r.reader_id and active and is_bot;
    if b.id is not null then
      select x into qid from unnest(r.question_choices) x order by random() limit 1;
      update public.rooms set question_id = qid, used_questions = used_questions || qid,
        question_choices = '{}', status = 'answering', phase_at = now(), updated_at = now() where id = r.id;
    end if;

  elsif r.status = 'answering' then
    select blanks into n from public.questions where id = r.question_id;
    n := coalesce(n, 1);
    for b in select * from public.players p where p.room_id = r.id and p.active and p.is_bot and p.id <> r.reader_id
             and not exists(select 1 from public.submissions s where s.room_id = r.id and s.round = r.round and s.player_id = p.id) loop
      aid := null; aid2 := null;
      select h.answer_id into aid from public.hands h where h.player_id = b.id order by random() limit 1;
      if n = 2 then
        select h.answer_id into aid2 from public.hands h where h.player_id = b.id and h.answer_id <> aid order by random() limit 1;
      end if;
      if aid is not null and (n = 1 or aid2 is not null) then
        insert into public.submissions(room_id, round, player_id, answer_id, answer_id2)
        values (r.id, r.round, b.id, aid, aid2) on conflict do nothing;
        delete from public.hands where player_id = b.id and answer_id in (aid, aid2);
      end if;
    end loop;
    perform public._deal(r.id);
    perform public._maybe_judge(r.id);
    update public.rooms set updated_at = now() where id = r.id;

  elsif r.status = 'ranking' then
    for b in select * from public.players p where p.room_id = r.id and p.active and p.is_bot
             and not exists(select 1 from public.rankings k where k.room_id = r.id and k.round = r.round and k.player_id = p.id) loop
      insert into public.rankings(room_id, round, player_id, cards)
      values (r.id, r.round, b.id, (select array_agg(x order by random()) from unnest(r.rank_cards) x))
      on conflict do nothing;
    end loop;
    perform public._maybe_score(r.id);
    update public.rooms set updated_at = now() where id = r.id;

  elsif r.status = 'clue' then
    if exists(select 1 from public.players where id = r.reader_id and active and is_bot) then
      update public.rooms set wave_clue = 'Indice de bot (vers ' || r.wave_target || ')',
        status = 'guessing', phase_at = now(), updated_at = now() where id = r.id;
    end if;

  elsif r.status = 'guessing' then
    for b in select * from public.players p where p.room_id = r.id and p.active and p.is_bot and p.id <> r.reader_id
             and not exists(select 1 from public.wave_guesses g where g.room_id = r.id and g.round = r.round and g.player_id = p.id) loop
      insert into public.wave_guesses(room_id, round, player_id, value)
      values (r.id, r.round, b.id, greatest(0, least(100, r.wave_target - 20 + floor(random() * 41)::integer)))
      on conflict do nothing;
    end loop;
    perform public._maybe_wave_score(r.id);
    update public.rooms set updated_at = now() where id = r.id;

  elsif r.status = 'naming' then
    select * into b from public.players where id = r.reader_id and active and is_bot;
    if b.id is not null then
      perform public.bac_category(r.code, b.token, public._bac_default_category(r.id));
    end if;

  elsif r.status = 'writing' then
    -- une case sur cinq reste vide, pour voir le 0 d'office
    for b in select * from public.players p where p.room_id = r.id and p.active and p.is_bot
             and not exists(select 1 from public.bac_answers x where x.room_id = r.id and x.round = r.round and x.player_id = p.id and x.done) loop
      perform public.bac_save(r.code, b.token,
        (select array_agg(case when random() < .2 then '' else r.bac_letter || ' comme bot' end) from generate_series(1, 6)),
        true);
    end loop;

  elsif r.status = 'voting' then
    for b in select * from public.players p where p.room_id = r.id and p.active and p.is_bot
             and exists(select 1 from public.bac_answers x where x.room_id = r.id and x.round = r.round
                        and x.player_id <> p.id and x.points[r.bac_step + 1] is null) loop
      perform public.bac_vote(r.code, b.token,
        (select case when v < .6 then 2 when v < .8 then 1 else 0 end from (select random() as v) t));
    end loop;

  elsif r.status = 'judging' and exists(select 1 from public.players where id = r.reader_id and active and is_bot) then
    select s.id, s.player_id into sid, b.id from public.submissions s
      join public.players p on p.id = s.player_id and p.active
      where s.room_id = r.id and s.round = r.round order by random() limit 1;
    if sid is not null then
      update public.players set score = score + 1 where id = b.id returning score into sc;
      update public.rooms set status = case when sc >= r.target_score then 'finished' else 'reveal' end,
        winner_id = b.id, winning_submission_id = sid, phase_at = now(), updated_at = now() where id = r.id;
    end if;

  elsif r.status = 'reveal' then
    update public.players set next_ack_round = r.round
      where room_id = r.id and active and is_bot and next_ack_round <> r.round;
    if not exists(select 1 from public.players where room_id = r.id and active and next_ack_round <> r.round) then
      rd := public._random_reader(r.id, r.reader_id);
      perform public._begin_round(r.id, rd, r.round + 1);
    else
      update public.rooms set updated_at = now() where id = r.id;
    end if;

  elsif r.status = 'finished' then
    update public.players set continue_requested = true
      where room_id = r.id and active and is_bot and not continue_requested;
    if not exists(select 1 from public.players where room_id = r.id and active and not continue_requested) then
      update public.players set ready = false, score = 0, discard_round = 0, next_ack_round = 0, continue_requested = false
        where room_id = r.id and active;
      delete from public.hands where room_id = r.id;
      delete from public.used_answers where room_id = r.id;
      delete from public.submissions where room_id = r.id;
      update public.rooms set status = 'lobby', round = 0, reader_id = null, previous_reader_id = null,
        question_id = null, question_choices = '{}', winner_id = null, winning_submission_id = null,
        used_questions = '{}', phase_at = now(), updated_at = now() where id = r.id;
    else
      update public.rooms set updated_at = now() where id = r.id;
    end if;
  end if;
end $function$;

-- ---------- État : catégories, lettre, ma grille ; au vote, les réponses jusqu'à la catégorie en cours ----------
-- Pendant le vote, le verdict sur la catégorie en cours reste caché tant que
-- les deux n'ont pas voté : pas de vote de représailles.
create or replace function public.get_state(p_code text, p_token uuid)
 returns json language plpgsql security definer set search_path to '' as $function$
declare me public.players; r public.rooms;
begin
 me:=public._player(p_code,p_token); if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 if me.last_seen<now()-interval '5 minutes' then update public.players set last_seen=now() where id=me.id; end if;
 select * into r from public.rooms where id=me.room_id;
 return json_build_object(
 'room',json_build_object('code',r.code,'status',r.status,'round',r.round,'target',r.target_score,'mode',r.mode,'turns',r.judge_turns,'host_id',r.host_id,'reader_id',r.reader_id,'winner_id',r.winner_id,'winning_submission_id',r.winning_submission_id,'updated_at',r.updated_at,'phase_at',r.phase_at,'submission_count',(select count(*) from public.submissions s where s.room_id=r.id and s.round=r.round)),
 'me',json_build_object('id',me.id,'name',me.name,'ready',me.ready,'next_ack',me.next_ack_round,'continue_requested',me.continue_requested,'can_discard',r.status='answering' and r.reader_id<>me.id and me.discard_round<>r.round and not exists(select 1 from public.submissions s where s.room_id=r.id and s.round=r.round and s.player_id=me.id)),
 'question',(select q.text from public.questions q where q.id=r.question_id),
 'blanks',coalesce((select q.blanks from public.questions q where q.id=r.question_id),1),
 'question_choices',case when r.status='question_select' and r.reader_id=me.id then (select coalesce(json_agg(json_build_object('id',q.id,'text',q.text) order by array_position(r.question_choices,q.id)),'[]'::json) from public.questions q where q.id=any(r.question_choices)) else '[]'::json end,
 'players',(select coalesce(json_agg(json_build_object('id',p.id,'name',p.name,'score',p.score,'active',p.active,'ready',p.ready,'is_bot',p.is_bot,'next_ack',p.next_ack_round,'continue_requested',p.continue_requested,'judge_count',p.judge_count,
    'submitted',exists(select 1 from public.submissions s where s.room_id=r.id and s.round=r.round and s.player_id=p.id),
    'ranked',exists(select 1 from public.rankings k where k.room_id=r.id and k.round=r.round and k.player_id=p.id),
    'guessed',exists(select 1 from public.wave_guesses g where g.room_id=r.id and g.round=r.round and g.player_id=p.id),
    'bac_done',exists(select 1 from public.bac_answers b where b.room_id=r.id and b.round=r.round and b.player_id=p.id and b.done)) order by p.seat),'[]'::json)
   from public.players p where p.room_id=r.id and (p.active or (r.status in('reveal','finished') and p.id=r.winner_id))),
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
    where s.room_id=r.id and s.round=r.round) else '[]'::json end,
 'rank_cards',case when r.mode='priorites' and r.status in('ranking','reveal','finished') then
   (select coalesce(json_agg(json_build_object('id',a.id,'text',a.text,'kind',a.kind) order by x.i),'[]'::json)
    from unnest(r.rank_cards) with ordinality as x(aid,i) join public._rank_pool(true) a on a.id=x.aid) else '[]'::json end,
 'my_ranking',(select k.cards from public.rankings k where k.room_id=r.id and k.round=r.round and k.player_id=me.id),
 'rankings',case when r.mode='priorites' and r.status in('reveal','finished') then
   (select coalesce(json_agg(json_build_object('player_id',k.player_id,'cards',k.cards,'points',k.points)),'[]'::json)
    from public.rankings k where k.room_id=r.id and k.round=r.round) else '[]'::json end,
 'wave',case when r.mode='ondes' and r.status in('clue','guessing','reveal','finished') and r.wave_card is not null then
   json_build_object(
     'left',(select c.left_text from public.wave_cards c where c.id=r.wave_card),
     'right',(select c.right_text from public.wave_cards c where c.id=r.wave_card),
     'clue',r.wave_clue,
     'target',case when r.reader_id=me.id or r.status in('reveal','finished') then r.wave_target end,
     'my_guess',(select g.value from public.wave_guesses g where g.room_id=r.id and g.round=r.round and g.player_id=me.id and g.player_id<>r.reader_id),
     'guesses',case when r.status in('reveal','finished') then
       (select coalesce(json_agg(json_build_object('player_id',g.player_id,'value',g.value,'points',g.points)),'[]'::json)
        from public.wave_guesses g where g.room_id=r.id and g.round=r.round) else '[]'::json end)
   end,
 'bac',case when r.mode='bac' and r.status in('naming','writing','voting','reveal') then
   json_build_object(
     'categories',r.bac_categories,
     'letter',case when r.status<>'naming' then r.bac_letter end,
     'step',r.bac_step,
     'mine',(select b.answers from public.bac_answers b where b.room_id=r.id and b.round=r.round and b.player_id=me.id),
     'done',coalesce((select b.done from public.bac_answers b where b.room_id=r.id and b.round=r.round and b.player_id=me.id),false),
     'rows',case when r.status in('voting','reveal') then
       (select coalesce(json_agg(json_build_object('player_id',b.player_id,
          'answers',case when r.status='voting' then b.answers[1:r.bac_step+1] else b.answers end,
          'points',case when r.status='voting' then b.points[1:r.bac_step] else b.points end,
          'pending',r.status='voting' and b.points[r.bac_step+1] is null) order by p.seat),'[]'::json)
        from public.bac_answers b join public.players p on p.id=b.player_id and p.active
        where b.room_id=r.id and b.round=r.round) else '[]'::json end)
   end);
end $function$;

-- ---------- Droits ----------
revoke all on function public._min_players(text) from public, anon, authenticated;
revoke all on function public._max_players(text) from public, anon, authenticated;
revoke all on function public._begin_bac_round(uuid, integer) from public, anon, authenticated;
revoke all on function public._bac_advance(uuid) from public, anon, authenticated;
revoke all on function public._bac_start_vote(uuid) from public, anon, authenticated;
revoke all on function public._begin_round(uuid, uuid, integer) from public, anon, authenticated;
revoke all on function public._remove_player(uuid) from public, anon, authenticated;
revoke all on function public._bac_default_category(uuid) from public, anon, authenticated;
revoke all on function public.bac_category(text, uuid, text) from public, anon, authenticated;
grant execute on function public.bac_category(text, uuid, text) to anon;
revoke all on function public.bac_save(text, uuid, text[], boolean) from public, anon, authenticated;
grant execute on function public.bac_save(text, uuid, text[], boolean) to anon;
revoke all on function public.bac_vote(text, uuid, integer) from public, anon, authenticated;
grant execute on function public.bac_vote(text, uuid, integer) to anon;
revoke all on function public.create_room(text, integer, text, integer) from public, anon, authenticated;
grant execute on function public.create_room(text, integer, text, integer) to anon;
revoke all on function public.set_room_options(text, uuid, text, integer, integer) from public, anon, authenticated;
grant execute on function public.set_room_options(text, uuid, text, integer, integer) to anon;
revoke all on function public.join_room(text, text) from public, anon, authenticated;
grant execute on function public.join_room(text, text) to anon;
revoke all on function public.add_bot(text, uuid) from public, anon, authenticated;
grant execute on function public.add_bot(text, uuid) to anon;
revoke all on function public.start_game(text, uuid) from public, anon, authenticated;
grant execute on function public.start_game(text, uuid) to anon;
revoke all on function public.reap_idle(text, uuid) from public, anon, authenticated;
grant execute on function public.reap_idle(text, uuid) to anon;
revoke all on function public.bot_step(text, uuid) from public, anon, authenticated;
grant execute on function public.bot_step(text, uuid) to anon;
revoke all on function public.get_state(text, uuid) from public, anon, authenticated;
grant execute on function public.get_state(text, uuid) to anon;

notify pgrst, 'reload schema';
