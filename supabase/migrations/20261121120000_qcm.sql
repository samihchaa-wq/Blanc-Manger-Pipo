-- QCM : le quiz personnalisé. L'animateur écrit son quiz à l'avance (ses
-- questions, 2 à 4 réponses, la bonne, 1 à 3 points, un commentaire montré
-- avec la réponse), puis tout le monde répond à la même question en même temps.
--
-- Le quiz vit hors des salons : un salon est effacé après un jour sans
-- activité, un quiz se prépare des semaines avant la soirée. Il est protégé
-- par un code secret de 12 caractères (seule son empreinte est stockée) :
-- connaître le code, c'est pouvoir lire et modifier le quiz, réponses comprises.
--
-- Déroulé d'une partie (mode 'qcm') :
--   lancement : le quiz choisi est recopié dans le salon (qcm_room_questions),
--     l'hôte devient l'animateur (reader_id) et ne répond pas ;
--   qcm_question : la question n°round est posée à tous, chacun touche une
--     réponse et peut en changer tant que la question est ouverte ;
--   reveal : quand tout le monde a répondu, à la fin du temps, ou quand
--     l'animateur le décide : bonne réponse, qui a répondu quoi, points ;
--   l'animateur passe à la question suivante ; après la dernière : finished.
-- Points : ceux de la question pour une bonne réponse. Mode Rapidité : la
-- première bonne réponse rapporte 1 point de plus.
--
-- Les fonctions partagées (_begin_round, get_full_state, create_room,
-- set_room_options, _min_players, _max_players, _time_phase_seconds,
-- reap_idle, _remove_player, lancer_partie, _punish_loser) sont reprises
-- telles qu'elles tournent en production (relues le 2026-11-09), avec la
-- seule branche du QCM en plus.
--
-- À coller tel quel dans l'éditeur SQL de Supabase : tout passe dans une seule
-- transaction (une erreur n'applique rien) et la migration s'inscrit dans
-- l'historique supabase_migrations.
begin;

-- ---------------------------------------------------------------- Schéma
alter table public.rooms drop constraint if exists rooms_mode_check;
alter table public.rooms add constraint rooms_mode_check
  check (mode in ('phrases','priorites','ondes','bac','white','mimes','dico','dilemme','qcm'));
alter table public.rooms drop constraint if exists rooms_status_check;
alter table public.rooms add constraint rooms_status_check check (status in (
  'lobby','question_select','answering','judging','ranking','clue','guessing','naming','writing','voting',
  'reveal','finished','white_clue','white_vote','white_guess','white_elimination','mime_play',
  'dico_pick','dico_write','dico_vote','dilemme_pick','dilemme_write','dilemme_vote','qcm_question'));

-- Les quiz : un par code secret.
create table if not exists public.qcm_quizzes (
  id uuid primary key default gen_random_uuid(),
  key_hash text not null unique,
  title text not null,
  created_by_hash text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  used_at timestamptz
);
create index if not exists qcm_quizzes_created_by on public.qcm_quizzes(created_by_hash, created_at);

-- Les questions d'un quiz, dans l'ordre. correct : position de la bonne
-- réponse dans choices, en partant de 0.
create table if not exists public.qcm_questions (
  quiz_id uuid not null references public.qcm_quizzes(id) on delete cascade,
  position integer not null check (position between 1 and 100),
  text text not null,
  choices text[] not null check (cardinality(choices) between 2 and 4),
  correct smallint not null,
  points smallint not null default 1 check (points between 1 and 3),
  note text,
  primary key (quiz_id, position),
  check (correct >= 0 and correct < cardinality(choices))
);

alter table public.rooms add column if not exists qcm_quiz_id uuid references public.qcm_quizzes(id) on delete set null;
alter table public.rooms add column if not exists qcm_variant text not null default 'classique';
alter table public.rooms drop constraint if exists rooms_qcm_variant_check;
alter table public.rooms add constraint rooms_qcm_variant_check check (qcm_variant in ('classique','rapidite'));
create index if not exists rooms_qcm_quiz_id on public.rooms(qcm_quiz_id) where qcm_quiz_id is not null;

-- Copie du quiz faite au lancement : modifier ou supprimer le quiz pendant la
-- partie ne la dérange pas.
create table if not exists public.qcm_room_questions (
  room_id uuid not null references public.rooms(id) on delete cascade,
  position integer not null,
  text text not null,
  choices text[] not null,
  correct smallint not null,
  points smallint not null,
  note text,
  primary key (room_id, position)
);

-- Une réponse par joueur et par question. answered_at départage le mode Rapidité.
create table if not exists public.qcm_answers (
  room_id uuid not null references public.rooms(id) on delete cascade,
  round integer not null,
  player_id uuid not null references public.players(id) on delete cascade,
  choice smallint not null,
  answered_at timestamptz not null default clock_timestamp(),
  points integer not null default 0,
  bonus boolean not null default false,
  primary key (room_id, round, player_id)
);
create index if not exists qcm_answers_player on public.qcm_answers(player_id);

alter table public.qcm_quizzes enable row level security;
alter table public.qcm_questions enable row level security;
alter table public.qcm_room_questions enable row level security;
alter table public.qcm_answers enable row level security;
revoke all on public.qcm_quizzes, public.qcm_questions, public.qcm_room_questions, public.qcm_answers
  from public, anon, authenticated;

-- ---------------------------------------------------------------- Outils
-- Le code d'un quiz : 12 caractères sans ambiguïté (ni 0/O, ni 1/I/L),
-- affichés par groupes de 4. Tirets, espaces et minuscules sont tolérés.
create or replace function public._qcm_norm_key(p_key text)
returns text language sql immutable set search_path to '' as $fn$
  select upper(regexp_replace(coalesce(p_key, ''), '[^A-Za-z0-9]', '', 'g'))
$fn$;

create or replace function public._qcm_fmt_key(p_key text)
returns text language sql immutable set search_path to '' as $fn$
  select substr(k, 1, 4) || '-' || substr(k, 5, 4) || '-' || substr(k, 9, 4)
  from (select public._qcm_norm_key(p_key) as k) x
$fn$;

create or replace function public._qcm_key_hash(p_key text)
returns text language sql stable set search_path to '' as $fn$
  select encode(extensions.digest('qcm:' || public._qcm_norm_key(p_key), 'sha256'), 'hex')
$fn$;

create or replace function public._qcm_new_key()
returns text language plpgsql volatile set search_path to '' as $fn$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  b bytea := extensions.gen_random_bytes(12);
  k text := '';
  i integer;
begin
  for i in 0..11 loop
    k := k || substr(alphabet, 1 + (get_byte(b, i) % 31), 1);
  end loop;
  return public._qcm_fmt_key(k);
end $fn$;

-- Un texte saisi : espaces resserrés, longueur bornée.
create or replace function public._qcm_text(p_text text, p_max integer)
returns text language sql immutable set search_path to '' as $fn$
  select btrim(left(btrim(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g')), p_max))
$fn$;

create or replace function public._qcm_find(p_key text)
returns public.qcm_quizzes language plpgsql stable security definer set search_path to '' as $fn$
declare q public.qcm_quizzes;
begin
  if length(public._qcm_norm_key(p_key)) <> 12 then return null; end if;
  select * into q from public.qcm_quizzes where key_hash = public._qcm_key_hash(p_key);
  return q;
end $fn$;

-- Le quiz complet, réponses comprises : seulement pour qui a son code.
create or replace function public._qcm_quiz_json(p_quiz uuid, p_key text)
returns json language sql stable security definer set search_path to '' as $fn$
  select json_build_object(
    'id', q.id,
    'key', public._qcm_fmt_key(p_key),
    'title', q.title,
    'updated_at', q.updated_at,
    'questions', coalesce((select json_agg(json_build_object(
        'text', x.text, 'choices', x.choices, 'correct', x.correct, 'points', x.points, 'note', x.note)
        order by x.position) from public.qcm_questions x where x.quiz_id = q.id), '[]'::json))
  from public.qcm_quizzes q where q.id = p_quiz
$fn$;

-- L'animateur : l'hôte du salon.
create or replace function public._qcm_animator(p_room uuid)
returns uuid language sql stable security definer set search_path to '' as $fn$
  select coalesce(
    (select r.host_id from public.rooms r join public.players p on p.id = r.host_id and p.active where r.id = p_room),
    (select p.id from public.players p where p.room_id = p_room and p.active order by p.seat limit 1))
$fn$;

-- ---------------------------------------------------------------- Préparer un quiz
create or replace function public.qcm_quiz_create(p_title text)
returns json language plpgsql security definer set search_path to '' as $fn$
declare
  t text := public._qcm_text(p_title, 60);
  h text := public._client_hash();
  k text;
  q public.qcm_quizzes;
begin
  if t = '' then t := 'Mon quiz'; end if;
  if h is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('bmp-qcm:' || h, 0));
    if (select count(*) from public.qcm_quizzes x
        where x.created_by_hash = h and x.created_at > now() - interval '1 hour') >= 10 then
      raise exception 'Trop de quiz créés récemment. Réessaie dans un moment.';
    end if;
  end if;
  -- Ménage : un quiz ni modifié ni joué depuis un an disparaît.
  delete from public.qcm_quizzes
    where greatest(updated_at, coalesce(used_at, updated_at)) < now() - interval '1 year';
  k := public._qcm_new_key();
  insert into public.qcm_quizzes(key_hash, title, created_by_hash)
    values (public._qcm_key_hash(k), t, h) returning * into q;
  return public._qcm_quiz_json(q.id, k);
end $fn$;

create or replace function public.qcm_quiz_get(p_key text)
returns json language plpgsql security definer set search_path to '' as $fn$
declare q public.qcm_quizzes;
begin
  q := public._qcm_find(p_key);
  if q.id is null then
    perform pg_catalog.pg_sleep(0.15);
    raise exception 'Code de quiz inconnu.';
  end if;
  return public._qcm_quiz_json(q.id, p_key);
end $fn$;

-- Enregistre le quiz entier : titre et questions, dans l'ordre. Chaque question :
-- { text, choices: [2 à 4 textes], correct: 0..n-1, points: 1..3, note }.
create or replace function public.qcm_quiz_save(p_key text, p_title text, p_questions jsonb)
returns json language plpgsql security definer set search_path to '' as $fn$
declare
  q public.qcm_quizzes;
  t text := public._qcm_text(p_title, 60);
  item jsonb;
  i integer := 0;
  qt text; ch text[]; c text; co integer; pts integer; nt text;
begin
  q := public._qcm_find(p_key);
  if q.id is null then
    perform pg_catalog.pg_sleep(0.15);
    raise exception 'Code de quiz inconnu.';
  end if;
  select * into q from public.qcm_quizzes where id = q.id for update;
  if t = '' then raise exception 'Donne un titre au quiz.'; end if;
  if p_questions is null or jsonb_typeof(p_questions) <> 'array' then raise exception 'Questions invalides.'; end if;
  if jsonb_array_length(p_questions) > 100 then raise exception 'Un quiz compte 100 questions au maximum.'; end if;
  delete from public.qcm_questions where quiz_id = q.id;
  for item in select e.value from jsonb_array_elements(p_questions) as e(value) loop
    i := i + 1;
    if jsonb_typeof(item) <> 'object' then raise exception 'Question % : invalide.', i; end if;
    qt := public._qcm_text(item->>'text', 200);
    if length(qt) < 3 then raise exception 'Question % : écris la question.', i; end if;
    if coalesce(jsonb_typeof(item->'choices'), '') <> 'array' then raise exception 'Question % : réponses invalides.', i; end if;
    select coalesce(array_agg(public._qcm_text(x.v, 80) order by x.o), '{}') into ch
      from jsonb_array_elements_text(item->'choices') with ordinality as x(v, o);
    if cardinality(ch) not between 2 and 4 then raise exception 'Question % : il faut 2 à 4 réponses.', i; end if;
    foreach c in array ch loop
      if c = '' then raise exception 'Question % : une réponse est vide.', i; end if;
    end loop;
    if (select count(distinct lower(x)) from unnest(ch) x) < cardinality(ch) then
      raise exception 'Question % : deux réponses sont identiques.', i;
    end if;
    if coalesce(jsonb_typeof(item->'correct'), '') <> 'number'
       or (item->>'correct')::numeric <> trunc((item->>'correct')::numeric)
       or (item->>'correct')::numeric not between 0 and cardinality(ch) - 1 then
      raise exception 'Question % : choisis la bonne réponse.', i;
    end if;
    co := (item->>'correct')::integer;
    if item->'points' is null or jsonb_typeof(item->'points') = 'null' then pts := 1;
    elsif jsonb_typeof(item->'points') <> 'number'
       or (item->>'points')::numeric not in (1, 2, 3) then
      raise exception 'Question % : 1, 2 ou 3 points.', i;
    else pts := (item->>'points')::integer;
    end if;
    nt := nullif(public._qcm_text(item->>'note', 200), '');
    insert into public.qcm_questions(quiz_id, position, text, choices, correct, points, note)
      values (q.id, i, qt, ch, co, pts, nt);
  end loop;
  update public.qcm_quizzes set title = t, updated_at = now() where id = q.id;
  return public._qcm_quiz_json(q.id, p_key);
end $fn$;

create or replace function public.qcm_quiz_delete(p_key text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare q public.qcm_quizzes;
begin
  q := public._qcm_find(p_key);
  if q.id is null then
    perform pg_catalog.pg_sleep(0.15);
    raise exception 'Code de quiz inconnu.';
  end if;
  delete from public.qcm_quizzes where id = q.id;
end $fn$;

-- ---------------------------------------------------------------- Salon
-- L'hôte choisit le quiz de la partie avec son code. Les autres joueurs n'en
-- voient que le titre et le nombre de questions.
create or replace function public.qcm_select(p_code text, p_token uuid, p_key text)
returns json language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; q public.qcm_quizzes;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception 'Seul l’hôte choisit le quiz.'; end if;
  if r.status <> 'lobby' or r.punish_phase then raise exception 'Le quiz se choisit depuis le salon.'; end if;
  if r.mode <> 'qcm' then raise exception 'Choisis d’abord le jeu QCM.'; end if;
  q := public._qcm_find(p_key);
  if q.id is null then
    perform pg_catalog.pg_sleep(0.15);
    raise exception 'Code de quiz inconnu.';
  end if;
  update public.rooms set qcm_quiz_id = q.id, updated_at = now() where id = r.id;
  return json_build_object('id', q.id, 'title', q.title,
    'count', (select count(*) from public.qcm_questions x where x.quiz_id = q.id));
end $fn$;

create or replace function public.set_qcm_variant(p_code text, p_token uuid, p_variant text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id <> me.id or r.status <> 'lobby' then raise exception 'Seul l’hôte choisit le mode avant la partie.'; end if;
  if p_variant is null or p_variant not in ('classique','rapidite') then raise exception 'Mode inconnu.'; end if;
  update public.rooms set qcm_variant = p_variant, updated_at = now() where id = r.id;
end $fn$;

-- ---------------------------------------------------------------- Questions
-- Question suivante. Au lancement (manche 1), le quiz est recopié dans le salon.
create or replace function public._begin_qcm_round(p_room uuid, p_next_round integer)
returns void language plpgsql security definer set search_path to '' as $fn$
declare r public.rooms; n integer; a uuid; w uuid;
begin
  select * into r from public.rooms where id = p_room for update;
  if p_next_round = 1 then
    delete from public.qcm_answers where room_id = p_room;
    delete from public.qcm_room_questions where room_id = p_room;
    insert into public.qcm_room_questions(room_id, position, text, choices, correct, points, note)
      select p_room, row_number() over (order by q.position), q.text, q.choices, q.correct, q.points, q.note
      from public.qcm_questions q where q.quiz_id = r.qcm_quiz_id;
    if not found then raise exception 'Choisis un quiz avec au moins une question avant de lancer.'; end if;
    update public.qcm_quizzes set used_at = now() where id = r.qcm_quiz_id;
  end if;
  a := public._qcm_animator(p_room);
  select count(*) into n from public.qcm_room_questions where room_id = p_room;
  if p_next_round > n then
    -- Fin du quiz : l'animateur ne compte pas dans le classement.
    select p.id into w from public.players p
      where p.room_id = p_room and p.active and p.id is distinct from a
      order by p.score desc, p.seat limit 1;
    update public.rooms set status = 'finished', reader_id = a, winner_id = w, winning_submission_id = null,
      phase_at = now(), updated_at = now() where id = p_room;
    return;
  end if;
  update public.players set next_ack_round = 0 where room_id = p_room and active;
  delete from public.qcm_answers where room_id = p_room and round = p_next_round;
  update public.rooms set
    status = 'qcm_question', round = p_next_round,
    previous_reader_id = reader_id, reader_id = a,
    question_id = null, question_choices = '{}',
    winner_id = null, winning_submission_id = null,
    phase_at = now(), updated_at = now()
  where id = p_room;
end $fn$;

-- Ferme la question : points, bonus de rapidité, puis révélation.
create or replace function public._qcm_close(p_room uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare r public.rooms; q public.qcm_room_questions; first_id uuid;
begin
  select * into r from public.rooms where id = p_room for update;
  if r.mode <> 'qcm' or r.status <> 'qcm_question' then return; end if;
  select * into q from public.qcm_room_questions where room_id = r.id and position = r.round;
  update public.qcm_answers a
    set points = case when a.choice = q.correct and a.player_id is distinct from r.reader_id then q.points else 0 end,
        bonus = false
    where a.room_id = r.id and a.round = r.round;
  if r.qcm_variant = 'rapidite' then
    select a.player_id into first_id from public.qcm_answers a
      join public.players p on p.id = a.player_id and p.active
      where a.room_id = r.id and a.round = r.round and a.choice = q.correct
        and a.player_id is distinct from r.reader_id
      order by a.answered_at, p.seat limit 1;
    if first_id is not null then
      update public.qcm_answers set points = points + 1, bonus = true
        where room_id = r.id and round = r.round and player_id = first_id;
    end if;
  end if;
  update public.players p set score = p.score + a.points
    from public.qcm_answers a
    where a.room_id = r.id and a.round = r.round and a.player_id = p.id
      and p.active and a.points > 0;
  update public.rooms set status = 'reveal', phase_at = now(), updated_at = now() where id = r.id;
end $fn$;

-- Tout le monde (sauf l'animateur) a répondu : on révèle.
create or replace function public._qcm_maybe_close(p_room uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare r public.rooms; attendus integer; faits integer;
begin
  select * into r from public.rooms where id = p_room for update;
  if r.mode <> 'qcm' or r.status <> 'qcm_question' then return; end if;
  select count(*) into attendus from public.players p
    where p.room_id = r.id and p.active and p.id is distinct from r.reader_id;
  select count(*) into faits from public.qcm_answers a
    join public.players p on p.id = a.player_id and p.active
    where a.room_id = r.id and a.round = r.round and a.player_id is distinct from r.reader_id;
  if attendus > 0 and faits >= attendus then perform public._qcm_close(r.id); end if;
end $fn$;

-- Un joueur touche une réponse ; il peut en changer tant que la question est
-- ouverte (son heure de réponse suit alors son dernier choix).
create or replace function public.qcm_answer(p_code text, p_token uuid, p_choice integer)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; n integer;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.mode <> 'qcm' or r.status <> 'qcm_question' then raise exception 'Les réponses sont fermées pour cette question.'; end if;
  if r.reader_id = me.id then raise exception 'Tu animes le quiz : tu ne réponds pas.'; end if;
  if public._time_expired(r) then raise exception 'Le temps est écoulé.'; end if;
  select cardinality(x.choices) into n from public.qcm_room_questions x where x.room_id = r.id and x.position = r.round;
  if p_choice is null or p_choice < 0 or p_choice >= coalesce(n, 0) then raise exception 'Réponse invalide.'; end if;
  insert into public.qcm_answers(room_id, round, player_id, choice)
    values (r.id, r.round, me.id, p_choice)
  on conflict (room_id, round, player_id) do update
    set choice = excluded.choice, answered_at = clock_timestamp()
    where public.qcm_answers.choice is distinct from excluded.choice;
  update public.rooms set updated_at = now() where id = r.id;
  perform public._qcm_maybe_close(r.id);
end $fn$;

-- L'animateur révèle la réponse sans attendre les retardataires.
create or replace function public.qcm_reveal(p_code text, p_token uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.mode <> 'qcm' or r.status <> 'qcm_question' then raise exception 'La réponse est déjà révélée.'; end if;
  if r.reader_id <> me.id then raise exception 'Seul l’animateur révèle la réponse.'; end if;
  perform public._qcm_close(r.id);
end $fn$;

-- L'animateur passe à la question suivante (ou au classement après la dernière).
create or replace function public.qcm_next(p_code text, p_token uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.mode <> 'qcm' or r.status <> 'reveal' then raise exception 'Ce n’est pas le moment de passer à la suite.'; end if;
  if r.reader_id <> me.id then raise exception 'Seul l’animateur passe à la question suivante.'; end if;
  perform public._begin_round(r.id, null, r.round + 1);
end $fn$;

-- Bots, pilotés par le téléphone de l'hôte : une bonne réponse sur deux.
create or replace function public.qcm_bot_step(p_code text, p_token uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; q public.qcm_room_questions;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception 'Seul l’hôte pilote les bots.'; end if;
  if r.mode <> 'qcm' or r.status <> 'qcm_question' then return; end if;
  select * into q from public.qcm_room_questions where room_id = r.id and position = r.round;
  if q.room_id is null then return; end if;
  insert into public.qcm_answers(room_id, round, player_id, choice)
    select r.id, r.round, p.id,
      case when random() < .5 then q.correct else floor(random() * cardinality(q.choices))::integer end
    from public.players p
    where p.room_id = r.id and p.active and p.is_bot and p.id is distinct from r.reader_id
  on conflict do nothing;
  perform public._qcm_maybe_close(r.id);
end $fn$;

-- L'état du QCM pour un joueur. La bonne réponse et le commentaire restent
-- cachés jusqu'à la révélation, sauf pour l'animateur ; les choix des autres
-- aussi (pendant la question, on ne sait que qui a déjà répondu). L'hôte
-- reçoit en plus l'identifiant du quiz, pour retrouver son code sur son
-- téléphone (l'identifiant seul n'ouvre rien).
create or replace function public.qcm_state(p_code text, p_token uuid)
returns json language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; q public.qcm_room_questions; total integer; anim boolean; fin boolean;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id;
  if r.mode <> 'qcm' then return null; end if;
  if r.status = 'lobby' or r.round = 0 then
    return json_build_object('variant', r.qcm_variant,
      'quiz', (select json_build_object('title', z.title,
                 'count', (select count(*) from public.qcm_questions x where x.quiz_id = z.id),
                 'id', case when r.host_id = me.id then z.id end)
               from public.qcm_quizzes z where z.id = r.qcm_quiz_id));
  end if;
  anim := r.reader_id = me.id;
  fin := r.status in ('reveal', 'finished');
  select count(*) into total from public.qcm_room_questions where room_id = r.id;
  select * into q from public.qcm_room_questions where room_id = r.id and position = r.round;
  return json_build_object(
    'variant', r.qcm_variant,
    'quiz', (select json_build_object('title', z.title, 'count', total,
               'id', case when r.host_id = me.id then z.id end)
             from public.qcm_quizzes z where z.id = r.qcm_quiz_id),
    'position', r.round, 'total', total,
    'text', q.text, 'choices', q.choices, 'points', q.points,
    'correct', case when fin or anim then q.correct end,
    'note', case when fin or anim then q.note end,
    'my_choice', (select a.choice from public.qcm_answers a
                   where a.room_id = r.id and a.round = r.round and a.player_id = me.id),
    'answered', (select coalesce(json_agg(a.player_id order by a.answered_at), '[]'::json) from public.qcm_answers a
                  join public.players p on p.id = a.player_id and p.active
                  where a.room_id = r.id and a.round = r.round and a.player_id is distinct from r.reader_id),
    'answers', case when fin then
      (select coalesce(json_agg(json_build_object('player_id', a.player_id, 'choice', a.choice,
          'points', a.points, 'bonus', a.bonus) order by a.answered_at), '[]'::json)
       from public.qcm_answers a join public.players p on p.id = a.player_id and p.active
       where a.room_id = r.id and a.round = r.round and a.player_id is distinct from r.reader_id) end);
end $fn$;

-- ---------------------------------------------------------------- Fonctions partagées
-- Une seule lecture par rafraîchissement : l'état du QCM rejoint celui du salon.
create or replace function public.get_full_state(p_code text, p_token uuid)
returns json language plpgsql security definer set search_path to '' as $fn$
declare s json; w json := null; pu json := null; q json := null; st text;
begin
  s := public.get_state(p_code, p_token);
  st := s->'room'->>'status';

  if st in ('lobby', 'finished') then
    begin
      pu := public.punish_state(p_code, p_token);
    exception when others then
      pu := null;
    end;
    -- phase absente, null ou false : la saisie n'est pas (ou plus) ouverte
    if st = 'lobby' and coalesce(pu->>'phase', '') in ('', 'false') then
      s := public.get_state(p_code, p_token);
      st := s->'room'->>'status';
      if st not in ('lobby', 'finished') then pu := null; end if;
    end if;
  end if;

  if s->'room'->>'mode' = 'white' and st <> 'lobby' then
    w := public.white_state(p_code, p_token);
  end if;

  if s->'room'->>'mode' = 'qcm' then
    q := public.qcm_state(p_code, p_token);
  end if;

  return json_build_object('state', s, 'white', w, 'pun', pu, 'qcm', q);
end $fn$;

create or replace function public._begin_round(p_room uuid, p_reader uuid, p_next_round integer)
returns void language plpgsql security definer set search_path to '' as $fn$
declare choices integer[]; m text;
begin
  select mode into m from public.rooms where id = p_room;
  if m = 'priorites' then perform public._begin_rank_round(p_room, p_next_round); return; end if;
  if m = 'ondes' then perform public._begin_wave_round(p_room, p_next_round); return; end if;
  if m = 'bac' then perform public._begin_bac_round(p_room, p_next_round); return; end if;
  if m = 'white' then perform public._begin_white_round(p_room, p_next_round); return; end if;
  if m = 'mimes' then perform public._begin_mime_round(p_room, p_next_round); return; end if;
  if m = 'dico' then perform public._begin_dico_round(p_room, p_next_round); return; end if;
  if m = 'dilemme' then perform public._begin_dilemme_round(p_room, p_next_round); return; end if;
  if m = 'qcm' then perform public._begin_qcm_round(p_room, p_next_round); return; end if;
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
end $fn$;

-- La validation de base ne connaît ni Mimes, ni le Dico, ni le Dilemme, ni le
-- QCM : on crée en Priorités puis on bascule le mode.
create or replace function public.create_room(p_name text, p_target integer default 5,
  p_mode text default 'phrases', p_turns integer default 2)
returns json language plpgsql security definer set search_path to '' as $fn$
declare res json;
begin
 if p_mode in ('mimes','dico','dilemme','qcm') then
   res:=public._create_room_base(p_name,p_target,'priorites',p_turns);
   update public.rooms set mode=p_mode where code=res->>'code';
 else
   res:=public._create_room_base(p_name,p_target,p_mode,p_turns);
 end if;
 update public.rooms set time_mode=case when p_mode in ('bac','white','mimes')
     then 'unlimited' else 'medium' end where code=res->>'code';
 return res;
end $fn$;

-- Le QCM accueille 30 joueurs : la validation de base, bornée à 12, ne
-- s'applique pas à lui. Un salon de plus de 12 qui quitte le QCM reçoit un
-- message juste (la base parlait du Petit bac).
create or replace function public.set_room_options(p_code text, p_token uuid, p_mode text, p_target integer, p_turns integer)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; nb integer;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception 'Seul l’hôte choisit le jeu.'; end if;
  if r.status <> 'lobby' then raise exception 'Le jeu se choisit depuis le salon.'; end if;
  select count(*) into nb from public.players where room_id = r.id and active;
  if p_mode = 'qcm' then
    if p_target is null or p_target not between 1 and 20 then raise exception 'Le nombre de manches doit être entre 1 et 20.'; end if;
    if p_turns is null or p_turns not between 1 and 5 then raise exception 'Le nombre de tours doit être entre 1 et 5.'; end if;
    if nb > public._max_players(p_mode) then raise exception 'Trop de joueurs pour le QCM (% au maximum).', public._max_players(p_mode); end if;
    update public.rooms set mode = p_mode, target_score = p_target, judge_turns = p_turns, updated_at = now()
      where id = r.id;
    return;
  end if;
  if p_mode is not null and p_mode <> 'bac' and nb > public._max_players(p_mode) then
    raise exception 'Trop de joueurs pour ce jeu (% au maximum).', public._max_players(p_mode);
  end if;
  if p_mode in ('mimes','dico','dilemme') then
    perform public._set_room_options_base(p_code, p_token, 'priorites', p_target, p_turns);
    update public.rooms set mode = p_mode where id = me.room_id;
    return;
  end if;
  perform public._set_room_options_base(p_code, p_token, p_mode, p_target, p_turns);
end $fn$;

-- QCM : l'animateur et un joueur suffisent ; 30 joueurs au plus.
create or replace function public._min_players(p_mode text)
returns integer language sql immutable set search_path to '' as $fn$
  select case when p_mode in ('priorites','ondes','bac','mimes','qcm') then 2 else 3 end
$fn$;

create or replace function public._max_players(p_mode text)
returns integer language sql immutable set search_path to '' as $fn$
  select case when p_mode = 'bac' then 2 when p_mode = 'qcm' then 30 else 12 end
$fn$;

-- ---------------------------------------------------------------- Minuteurs
create or replace function public._time_phase_seconds(p_room public.rooms)
returns integer language plpgsql stable set search_path to '' as $fn$
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
  -- Le Dico : écrire une définition, puis lire toutes les propositions et voter
  when p_room.mode='dico' and p_room.status='dico_write'
    then case pace when 'slow' then 150 when 'fast' then 60 else 100 end
  when p_room.mode='dico' and p_room.status='dico_vote'
    then case pace when 'slow' then 150 when 'fast' then 60 else 100 end
  -- Dilemme parfait : écrire son « mais », puis répondre Oui/Non aux autres
  when p_room.mode='dilemme' and p_room.status='dilemme_write'
    then case pace when 'slow' then 120 when 'fast' then 45 else 75 end
  when p_room.mode='dilemme' and p_room.status='dilemme_vote'
    then case pace when 'slow' then 120 when 'fast' then 45 else 75 end
  -- QCM : le temps de répondre à une question
  when p_room.mode='qcm' and p_room.status='qcm_question'
    then case pace when 'slow' then 60 when 'fast' then 15 else 30 end
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
end $fn$;

create or replace function public.reap_idle(p_code text, p_token uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; jc integer[]; submitted integer; rd uuid;
begin
 me:=public._player(p_code,p_token);
 if me.id is null then return; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.id is null or not public._time_expired(r) then return; end if;
 if r.status='answering' and r.mode='phrases' then
   select count(*) into submitted from public.submissions s
     join public.players p on p.id=s.player_id and p.active
     where s.room_id=r.id and s.round=r.round;
   if submitted>0 then
     update public.rooms set status='judging',phase_at=now(),updated_at=now() where id=r.id;
   else
     rd:=public._next_reader(r.id,r.reader_id);
     perform public._begin_round(r.id,rd,r.round+1);
   end if;
 elsif r.status='ranking' and r.mode='priorites' then
   select cards into jc from public.rankings
    where room_id=r.id and round=r.round and player_id=r.reader_id;
   if jc is null then
     perform public._begin_round(r.id,null,r.round+1);
   else
     update public.rankings k set points =
      (select coalesce(sum(case abs(i - array_position(jc,k.cards[i]))
           when 0 then 2 when 1 then 1 else 0 end),0)
        from generate_subscripts(k.cards,1) i)
      + case when k.cards=jc then 2 else 0 end
      where k.room_id=r.id and k.round=r.round and k.player_id<>r.reader_id;
     update public.rankings set points=
       (select count(*) from public.rankings k where k.room_id=r.id and k.round=r.round
         and k.player_id<>r.reader_id and k.points>=5)
       where room_id=r.id and round=r.round and player_id=r.reader_id;
     update public.players p set score=p.score+k.points
      from public.rankings k
      where k.room_id=r.id and k.round=r.round and k.player_id=p.id and p.active;
     update public.rooms set status='reveal',phase_at=now(),updated_at=now() where id=r.id;
   end if;
 elsif r.status='clue' and r.mode='ondes' then
   -- Pas d'indice : on saute la manche, aucun joueur ne marque de points.
   perform public._begin_round(r.id,null,r.round+1);
 elsif r.status='guessing' and r.mode='ondes' then
   update public.wave_guesses g set points=
     case when abs(g.value-r.wave_target)<=3 then 4
          when abs(g.value-r.wave_target)<=9 then 3
          when abs(g.value-r.wave_target)<=15 then 2 else 0 end
    where g.room_id=r.id and g.round=r.round;
   insert into public.wave_guesses(room_id,round,player_id,value,points)
    select r.id,r.round,r.reader_id,r.wave_target,
      coalesce((select round(avg(g.points))::integer from public.wave_guesses g
        where g.room_id=r.id and g.round=r.round and g.player_id<>r.reader_id),0)
    on conflict (room_id,round,player_id) do update set value=excluded.value,points=excluded.points;
   update public.players p set score=p.score+g.points from public.wave_guesses g
    where g.room_id=r.id and g.round=r.round and g.player_id=p.id and p.active;
   update public.rooms set status='reveal',phase_at=now(),updated_at=now() where id=r.id;
 elsif r.status='naming' and r.mode='bac' then
   -- Expiration : appliquer directement une catégorie non utilisée.
   -- bac_category refuse à juste titre les validations humaines hors délai.
   if cardinality(coalesce(r.bac_categories,'{}'::text[]))<5 then
     update public.rooms set
       bac_categories=coalesce(r.bac_categories,'{}'::text[]) || public._bac_default_category(r.id),
       reader_id=public._next_reader(r.id,r.reader_id),
       phase_at=now(),updated_at=now() where id=r.id;
   else
     update public.rooms set
       bac_categories=coalesce(r.bac_categories,'{}'::text[]) || public._bac_default_category(r.id)
       where id=r.id;
     perform public._begin_bac_round(r.id,r.round);
   end if;
 elsif r.status='writing' and r.mode='bac' then
   perform public._bac_start_vote(r.id);
 elsif r.status='white_vote' and r.mode='white' then
   perform public._white_resolve_vote(r.id);
 elsif r.status='dico_write' and r.mode='dico' then
   -- Au moins une définition de joueur : on vote ; sinon la manche est sautée.
   if exists (select 1 from public.dico_defs d join public.players p on p.id=d.player_id and p.active
              where d.room_id=r.id and d.round=r.round and not d.is_true) then
     perform public._dico_open_vote(r.id);
   else
     perform public._begin_round(r.id,null,r.round+1);
   end if;
 elsif r.status='dico_vote' and r.mode='dico' then
   perform public._dico_score(r.id);
 elsif r.status='dilemme_write' and r.mode='dilemme' then
   -- Au moins deux propositions : on vote ; sinon la manche est sautée.
   if (select count(*) from public.dilemme_buts b join public.players p on p.id=b.player_id and p.active
        where b.room_id=r.id and b.round=r.round) >= 2 then
     perform public._dilemme_open_vote(r.id);
   else
     perform public._begin_round(r.id,null,r.round+1);
   end if;
 elsif r.status='dilemme_vote' and r.mode='dilemme' then
   perform public._dilemme_score(r.id);
 elsif r.status='qcm_question' and r.mode='qcm' then
   -- Temps écoulé : la question se ferme, les absents ne marquent rien.
   perform public._qcm_close(r.id);
 end if;
end $fn$;

-- ---------------------------------------------------------------- Départs
create or replace function public._remove_player(p_player uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare pl public.players; r public.rooms;
begin
  select * into pl from public.players where id = p_player;
  if pl.id is null or not pl.active then return; end if;
  select * into r from public.rooms where id = pl.room_id for update;
  perform public._remove_player_base(p_player);
  if r.mode = 'mimes' and r.status = 'mime_play' then
    if (select count(*) from public.players where room_id = r.id and active) < public._min_players(r.mode) then
      update public.rooms set status = 'lobby', phase_at = now(), updated_at = now() where id = r.id;
    elsif r.reader_id = p_player then
      perform public._begin_round(r.id, null, r.round + 1);
    end if;
  end if;
  if r.mode = 'dico' and r.status in ('dico_pick','dico_write','dico_vote') then
    if (select count(*) from public.players where room_id = r.id and active) < public._min_players(r.mode) then
      update public.rooms set status = 'lobby', phase_at = now(), updated_at = now() where id = r.id;
    elsif r.reader_id = p_player then
      perform public._begin_round(r.id, null, r.round + 1);
    else
      perform public._dico_advance(r.id);
    end if;
  end if;
  -- Dilemme : le meneur ne compte que pendant le choix du début ; ensuite sa
  -- proposition disparaît avec lui et la manche continue.
  if r.mode = 'dilemme' and r.status in ('dilemme_pick','dilemme_write','dilemme_vote') then
    if (select count(*) from public.players where room_id = r.id and active) < public._min_players(r.mode) then
      update public.rooms set status = 'lobby', phase_at = now(), updated_at = now() where id = r.id;
    elsif r.status = 'dilemme_pick' and r.reader_id = p_player then
      perform public._begin_round(r.id, null, r.round + 1);
    else
      perform public._dilemme_advance(r.id);
    end if;
  end if;
  -- QCM : l'animateur parti, le nouvel hôte reprend l'animation (sa réponse à
  -- la question en cours est retirée) ; un joueur parti n'est plus attendu.
  -- Pendant la révélation, la base enchaîne déjà sur la question suivante.
  if r.mode = 'qcm' and r.status = 'qcm_question' then
    if (select count(*) from public.players where room_id = r.id and active) < public._min_players(r.mode) then
      update public.rooms set status = 'lobby', phase_at = now(), updated_at = now() where id = r.id;
    else
      if r.reader_id = p_player then
        update public.rooms set reader_id = public._qcm_animator(r.id), updated_at = now() where id = r.id;
        delete from public.qcm_answers a using public.rooms x
          where x.id = r.id and a.room_id = r.id and a.round = r.round and a.player_id = x.reader_id;
      end if;
      perform public._qcm_maybe_close(r.id);
    end if;
  end if;
end $fn$;

-- ---------------------------------------------------------------- Lancement et punitions
create or replace function public.lancer_partie(p_code text, p_token uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id;
  if r.host_id <> me.id then raise exception 'Seul l’hôte peut lancer la partie.'; end if;
  if r.status <> 'lobby' then raise exception 'La partie est déjà en cours.'; end if;
  -- QCM : pas de partie sans quiz (avant même l'écran des punitions).
  if r.mode = 'qcm' and not exists (select 1 from public.qcm_questions q where q.quiz_id = r.qcm_quiz_id) then
    raise exception 'Choisis un quiz avec au moins une question avant de lancer.';
  end if;
  update public.players set ready = true where room_id = r.id and active and not ready;
  if r.punish then perform public.punish_start(p_code, p_token);
  else perform public.start_game(p_code, p_token); end if;
end $fn$;

-- Le perdant tire la punition. Au QCM, l'animateur n'a joué aucune question :
-- il n'est jamais désigné.
create or replace function public._punish_loser(p_room uuid)
returns uuid language plpgsql security definer set search_path to '' as $fn$
declare r public.rooms; l uuid;
begin
  select * into r from public.rooms where id = p_room for update;
  if r.status <> 'finished' or not r.punish then return null; end if;
  if r.punish_loser is not null then return r.punish_loser; end if;
  select p.id into l from public.players p
    where p.room_id = p_room and p.active
      and not (r.mode = 'qcm' and p.id is not distinct from r.reader_id)
    order by p.score asc, random() limit 1;
  update public.rooms set punish_loser = l where id = p_room;
  return l;
end $fn$;

-- ---------------------------------------------------------------- Droits
revoke execute on function
  public._qcm_norm_key(text),
  public._qcm_fmt_key(text),
  public._qcm_key_hash(text),
  public._qcm_new_key(),
  public._qcm_text(text, integer),
  public._qcm_find(text),
  public._qcm_quiz_json(uuid, text),
  public._qcm_animator(uuid),
  public._begin_qcm_round(uuid, integer),
  public._qcm_close(uuid),
  public._qcm_maybe_close(uuid)
from public, anon, authenticated;

revoke execute on function
  public.qcm_quiz_create(text),
  public.qcm_quiz_get(text),
  public.qcm_quiz_save(text, text, jsonb),
  public.qcm_quiz_delete(text),
  public.qcm_select(text, uuid, text),
  public.set_qcm_variant(text, uuid, text),
  public.qcm_answer(text, uuid, integer),
  public.qcm_reveal(text, uuid),
  public.qcm_next(text, uuid),
  public.qcm_bot_step(text, uuid),
  public.qcm_state(text, uuid)
from public;
grant execute on function
  public.qcm_quiz_create(text),
  public.qcm_quiz_get(text),
  public.qcm_quiz_save(text, text, jsonb),
  public.qcm_quiz_delete(text),
  public.qcm_select(text, uuid, text),
  public.set_qcm_variant(text, uuid, text),
  public.qcm_answer(text, uuid, integer),
  public.qcm_reveal(text, uuid),
  public.qcm_next(text, uuid),
  public.qcm_bot_step(text, uuid),
  public.qcm_state(text, uuid)
to anon, authenticated;

-- Inscription dans l'historique des migrations (absente d'une base locale de test).
do $hist$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    if not exists (select 1 from supabase_migrations.schema_migrations where version = '20261121120000') then
      insert into supabase_migrations.schema_migrations(version, name) values ('20261121120000', 'qcm');
    end if;
  end if;
end $hist$;

commit;

select 'Le QCM est installé.' as resultat;
