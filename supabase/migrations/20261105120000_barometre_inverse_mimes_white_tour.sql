-- Trois évolutions, toutes additives (le client en ligne continue de marcher) :
--  1. Mr White : le premier à parler est tiré au sort à la 1re manche, puis la
--     main tourne d'un joueur à chaque tour d'indices et à chaque manche.
--     white_state expose ce premier joueur (starter_id).
--  2. Baromètre « Inversé » : un joueur écrit un thème (« un salaire que
--     j'aimerais toucher »), le médium voit la cible et répond (« 100 000 € »),
--     les autres placent l'aiguille d'après sa réponse. Barème inchangé.
--  3. Nouveau jeu « Mimes » : un juge lit une action à intensité (1 à 10),
--     chaque autre joueur reçoit une intensité secrète et mime. Le juge devine
--     l'intensité de chacun.
--
-- Les grosses fonctions existantes (get_state, white_state, _remove_player,
-- create_room, set_room_options, _begin_wave_round, _begin_white_round,
-- white_resume) sont renommées en *_base et enveloppées : leur code reste
-- intact et l'enveloppe ajoute seulement le comportement nouveau.

-- ---------------------------------------------------------------- Schéma
alter table public.rooms drop constraint if exists rooms_mode_check;
alter table public.rooms add constraint rooms_mode_check
  check (mode in ('phrases','priorites','ondes','bac','white','mimes'));

alter table public.rooms drop constraint if exists rooms_status_check;
alter table public.rooms add constraint rooms_status_check check (status in (
  'lobby','question_select','answering','judging','ranking','clue','guessing',
  'naming','writing','voting','reveal','finished','white_clue','white_vote',
  'white_guess','white_elimination','mime_play'
));

alter table public.rooms add column if not exists wave_variant text not null default 'normal';
alter table public.rooms drop constraint if exists rooms_wave_variant_check;
alter table public.rooms add constraint rooms_wave_variant_check check (wave_variant in ('normal','inverse'));
alter table public.rooms add column if not exists wave_theme text;
alter table public.rooms add column if not exists wave_asker uuid;
alter table public.rooms add column if not exists mime_card integer;
alter table public.rooms add column if not exists used_mimes integer[] not null default '{}';

create table if not exists public.mime_cards (
  id serial primary key,
  action text not null,
  low_text text not null,
  high_text text not null,
  added_by text,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create table if not exists public.mime_parts (
  room_id uuid not null references public.rooms(id) on delete cascade,
  round integer not null,
  player_id uuid not null references public.players(id) on delete cascade,
  intensity integer check (intensity between 1 and 10),   -- null pour le juge
  guess integer check (guess between 1 and 10),
  points integer,
  primary key (room_id, round, player_id)
);
create index if not exists mime_parts_player_idx on public.mime_parts(player_id);
alter table public.mime_cards enable row level security;
alter table public.mime_parts enable row level security;
revoke all on public.mime_cards, public.mime_parts from public, anon, authenticated;
revoke all on sequence public.mime_cards_id_seq from public, anon, authenticated;

insert into public.mime_cards(action, low_text, high_text, added_by)
select v.a, v.l, v.h, 'seed' from (values
  ('Imite un chien qui aboie', 'il est gentil', 'il est le plus méchant possible'),
  ('Mange un citron', 'c’est sucré', 'c’est atrocement acide'),
  ('Rentre dans une piscine', 'l’eau est tiède', 'l’eau est glaciale'),
  ('Ouvre un cadeau', 'tu es déçu', 'c’est le plus beau jour de ta vie'),
  ('Marche sous la pluie', 'quelques gouttes', 'une tempête apocalyptique'),
  ('Soulève une valise', 'elle est vide', 'elle pèse une tonne'),
  ('Regarde un film d’horreur', 'tu t’ennuies', 'tu es terrorisé'),
  ('Attends le bus', 'tu es patient', 'tu es à bout de nerfs'),
  ('Goûte un plat épicé', 'c’est doux', 'ta bouche prend feu'),
  ('Danse à un mariage', 'tu es timide', 'tu mets le feu à la piste'),
  ('Te réveilles le matin', 'tu es en pleine forme', 'tu es un zombie'),
  ('Imite un chat qui demande à manger', 'il est poli', 'il est insupportable'),
  ('Marche pieds nus sur des Lego', 'ça chatouille', 'c’est la pire douleur du monde'),
  ('Écoutes une blague', 'elle est nulle', 'tu meurs de rire'),
  ('Fais un câlin à quelqu’un', 'c’est gênant', 'c’est ton grand amour'),
  ('Croises ton ex dans la rue', 'tu t’en fiches', 'c’est la panique totale'),
  ('Sens une odeur', 'ça sent bon', 'ça pue horriblement'),
  ('Conduis une voiture', 'tu es très prudent', 'tu es un pilote de rallye'),
  ('Reçois un compliment', 'tu restes de marbre', 'tu fonds de bonheur'),
  ('Fais du sport', 'tu t’échauffes', 'tu es au bord de l’évanouissement'),
  ('Tiens un bébé', 'tu es à l’aise', 'tu as peur de le casser'),
  ('Découvres ta note d’examen', 'c’est une catastrophe', 'c’est la note parfaite'),
  ('Imite un lion', 'un chaton', 'le roi de la savane en colère'),
  ('Bois un café', 'il est tiède', 'il est brûlant'),
  ('Cherches tes clés', 'tu es détendu', 'tu es en retard et paniqué'),
  ('Fais un discours', 'tu es timide', 'tu es un tribun enflammé'),
  ('Vois une araignée', 'elle est mignonne', 'c’est ta pire phobie'),
  ('Joues de la guitare', 'tu débutes', 'tu es une rock star'),
  ('Attends des nouvelles importantes', 'tu es serein', 'tu es rongé par l’angoisse'),
  ('Fais la queue à la boulangerie', 'tu as tout ton temps', 'tu meurs de faim'),
  ('Imite un fantôme', 'il est sympa', 'il est terrifiant'),
  ('Termines un marathon', 'tu es frais', 'tu rampes jusqu’à l’arrivée'),
  ('Reçois une facture', 'elle est minuscule', 'elle te ruine'),
  ('Embrasses quelqu’un', 'c’est timide', 'c’est passionné'),
  ('Supportes ton équipe au stade', 'tu es calme', 'tu es en transe'),
  ('Entends un bruit la nuit', 'tu te rendors', 'tu es certain qu’il y a un monstre'),
  ('Imite un pirate', 'il est gentil', 'il est le plus cruel des sept mers'),
  ('Porte un pull qui gratte', 'ça va', 'c’est une torture'),
  ('Fais un selfie', 'tu es naturel', 'tu es une star égocentrique'),
  ('Marches dans le désert', 'il fait bon', 'tu meurs de soif')
) as v(a, l, h)
where not exists (select 1 from public.mime_cards);

-- ---------------------------------------------------------------- Bornes
create or replace function public._min_players(p_mode text)
returns integer language sql immutable set search_path to '' as $fn$
  select case when p_mode in ('priorites','ondes','bac','mimes') then 2 else 3 end
$fn$;

-- create_room et set_room_options valident la liste des jeux dans leur code :
-- pour « mimes » on passe par un jeu équivalent (même plafond de 12) puis on
-- corrige le mode.
alter function public.create_room(text,integer,text,integer) rename to _create_room_base;
create or replace function public.create_room(p_name text, p_target integer default 5,
  p_mode text default 'phrases', p_turns integer default 2)
returns json language plpgsql security definer set search_path to '' as $fn$
declare res json;
begin
  if p_mode = 'mimes' then
    res := public._create_room_base(p_name, p_target, 'priorites', p_turns);
    update public.rooms set mode = 'mimes' where code = res->>'code';
    return res;
  end if;
  return public._create_room_base(p_name, p_target, p_mode, p_turns);
end $fn$;

alter function public.set_room_options(text,uuid,text,integer,integer) rename to _set_room_options_base;
create or replace function public.set_room_options(p_code text, p_token uuid, p_mode text, p_target integer, p_turns integer)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players;
begin
  if p_mode = 'mimes' then
    perform public._set_room_options_base(p_code, p_token, 'priorites', p_target, p_turns);
    me := public._player(p_code, p_token);
    update public.rooms set mode = 'mimes' where id = me.room_id;
    return;
  end if;
  perform public._set_room_options_base(p_code, p_token, p_mode, p_target, p_turns);
end $fn$;

-- ---------------------------------------------------------------- Aiguillage des manches
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

-- ================================================================ 1. Mr White
-- Premier joueur encore en lice à partir de reader_id, dans l'ordre des sièges.
create or replace function public._white_starter(p_room uuid)
returns uuid language sql stable security definer set search_path to '' as $fn$
  select p.id from public.rooms r
  join public.players p on p.room_id = r.id and p.active
  join public.white_roles wr on wr.room_id = r.id and wr.round = r.round and wr.player_id = p.id and not wr.eliminated
  join public.players origin on origin.id = r.reader_id
  where r.id = p_room
  order by (p.seat - origin.seat + 10000) % 10000 limit 1
$fn$;

-- Manche 1 : tirage au sort (fait par la base). Ensuite : le joueur suivant.
alter function public._begin_white_round(uuid,integer) rename to _begin_white_round_base;
create or replace function public._begin_white_round(p_room uuid, p_next_round integer)
returns void language plpgsql security definer set search_path to '' as $fn$
begin
  perform public._begin_white_round_base(p_room, p_next_round);
  if p_next_round > 1 then
    update public.rooms set reader_id = public._next_reader(p_room, previous_reader_id)
      where id = p_room and status = 'white_clue' and round = p_next_round and previous_reader_id is not null;
  end if;
end $fn$;

-- Nouveau tour d'indices : la main passe au joueur encore en lice suivant.
alter function public.white_resume(text,uuid) rename to _white_resume_base;
create or replace function public.white_resume(p_code text, p_token uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; nxt uuid;
begin
  perform public._white_resume_base(p_code, p_token);
  me := public._player(p_code, p_token);
  select * into r from public.rooms where id = me.room_id for update;
  if r.status <> 'white_clue' then return; end if;
  select p.id into nxt from public.players p
    join public.white_roles wr on wr.room_id = r.id and wr.round = r.round and wr.player_id = p.id and not wr.eliminated
    join public.players origin on origin.id = r.reader_id
    where p.room_id = r.id and p.active
    order by (p.seat - origin.seat - 1 + 10000) % 10000 limit 1;
  if nxt is not null then update public.rooms set reader_id = nxt where id = r.id; end if;
end $fn$;

alter function public.white_state(text,uuid) rename to _white_state_base;
create or replace function public.white_state(p_code text, p_token uuid)
returns json language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; base json;
begin
  base := public._white_state_base(p_code, p_token);
  me := public._player(p_code, p_token);
  select * into r from public.rooms where id = me.room_id;
  return (base::jsonb || jsonb_build_object('starter_id',
    case when r.status = 'white_clue' then public._white_starter(r.id) end))::json;
end $fn$;

-- ================================================================ 2. Baromètre inversé
create or replace function public.set_wave_variant(p_code text, p_token uuid, p_variant text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception 'Seul l’hôte choisit le mode.'; end if;
  if r.status <> 'lobby' then raise exception 'Le mode se choisit depuis le salon.'; end if;
  if r.mode <> 'ondes' then raise exception 'Ce réglage est propre au Baromètre.'; end if;
  if p_variant is null or p_variant not in ('normal','inverse') then raise exception 'Mode inconnu.'; end if;
  update public.rooms set wave_variant = p_variant, updated_at = now() where id = r.id;
end $fn$;

-- Le joueur assis après le médium écrit le thème.
alter function public._begin_wave_round(uuid,integer) rename to _begin_wave_round_base;
create or replace function public._begin_wave_round(p_room uuid, p_next_round integer)
returns void language plpgsql security definer set search_path to '' as $fn$
begin
  perform public._begin_wave_round_base(p_room, p_next_round);
  update public.rooms set wave_theme = null,
    wave_asker = case when wave_variant = 'inverse' then public._next_reader(p_room, reader_id) end
    where id = p_room and status = 'clue';
end $fn$;

-- Si l'auteur désigné est parti, n'importe quel autre joueur peut écrire le thème.
create or replace function public.submit_theme(p_code text, p_token uuid, p_theme text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; t text := regexp_replace(trim(coalesce(p_theme, '')), '\s+', ' ', 'g');
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.mode <> 'ondes' or r.wave_variant <> 'inverse' or r.status <> 'clue' or r.wave_theme is not null then
    raise exception 'Ce n’est pas le moment d’écrire le thème.';
  end if;
  if r.reader_id = me.id then raise exception 'Le médium ne choisit pas le thème.'; end if;
  if r.wave_asker is distinct from me.id
     and exists (select 1 from public.players where id = r.wave_asker and active) then
    raise exception 'Un autre joueur écrit le thème.';
  end if;
  if t = '' then raise exception 'Écris un thème.'; end if;
  if char_length(t) > 80 then raise exception 'Le thème fait 80 caractères au maximum.'; end if;
  update public.rooms set wave_theme = t, wave_asker = me.id, phase_at = now(), updated_at = now() where id = r.id;
end $fn$;

create or replace function public.submit_clue(p_code text, p_token uuid, p_clue text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; t text := regexp_replace(trim(coalesce(p_clue, '')), '\s+', ' ', 'g');
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.status <> 'clue' then raise exception 'Ce n’est pas le moment de donner l’indice.'; end if;
  if r.reader_id <> me.id then raise exception 'Seul le médium donne l’indice.'; end if;
  if r.wave_variant = 'inverse' and r.wave_theme is null then raise exception 'Attends le thème.'; end if;
  if t = '' then raise exception 'Écris un indice.'; end if;
  if char_length(t) > 60 then raise exception 'L’indice fait 60 caractères au maximum.'; end if;
  update public.rooms set wave_clue = t, status = 'guessing', phase_at = now(), updated_at = now() where id = r.id;
end $fn$;

-- Bots du mode inversé (phase « clue ») ; le reste passe par bot_step.
create or replace function public.wave_bot_step(p_code text, p_token uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; asker uuid;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception 'Seul l’hôte pilote les bots.'; end if;
  if r.mode <> 'ondes' or r.status <> 'clue' or r.wave_variant <> 'inverse' then return; end if;
  if r.wave_theme is null then
    select id into asker from public.players where id = r.wave_asker and active and is_bot;
    if asker is not null then
      update public.rooms set
        wave_theme = (array['Un salaire que j’aimerais toucher','Une star que je trouve canon',
          'Un plat que j’adore','Un endroit où partir en vacances','Un film qui fait peur',
          'Un métier que je pourrais faire'])[1 + floor(random() * 6)::integer],
        phase_at = now(), updated_at = now() where id = r.id;
    end if;
  elsif exists (select 1 from public.players where id = r.reader_id and active and is_bot) then
    update public.rooms set wave_clue = 'Réponse de bot (vers ' || r.wave_target || ')',
      status = 'guessing', phase_at = now(), updated_at = now() where id = r.id;
  end if;
end $fn$;

-- reap_idle : Mimes n'a pas de minuteur ; un thème qui ne vient pas au bout de
-- 2 min est remplacé.
create or replace function public.reap_idle(p_code text, p_token uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then return; end if;
  select * into r from public.rooms where id = me.room_id;
  if r.mode in ('bac','mimes') then return; end if;
  if r.mode = 'ondes' and r.status = 'clue' and r.wave_variant = 'inverse' and r.wave_theme is null then
    if now() - r.phase_at >= interval '120 seconds' then
      update public.rooms set wave_theme = 'Sans thème', phase_at = now(), updated_at = now()
        where id = r.id and status = 'clue' and wave_theme is null;
    end if;
    return;
  end if;
  perform public._reap_idle_timed(p_code, p_token);
end $fn$;

-- ================================================================ 3. Mimes
create or replace function public._begin_mime_round(p_room uuid, p_next_round integer)
returns void language plpgsql security definer set search_path to '' as $fn$
declare r public.rooms; j uuid; w uuid; c integer;
begin
  select * into r from public.rooms where id = p_room for update;
  if p_next_round = 1 then
    update public.rooms set used_mimes = '{}' where id = p_room;
    r.used_mimes := '{}';
  end if;
  -- le moins souvent juge passe en premier, à égalité l'ordre d'arrivée
  select id into j from public.players
    where room_id = p_room and active and judge_count < r.judge_turns
    order by judge_count, seat limit 1;
  if j is null then
    select id into w from public.players where room_id = p_room and active order by score desc, seat limit 1;
    update public.rooms set status = 'finished', winner_id = w, winning_submission_id = null,
      phase_at = now(), updated_at = now() where id = p_room;
    return;
  end if;

  select id into c from public.mime_cards
    where deleted_at is null and not (id = any(r.used_mimes)) order by random() limit 1;
  if c is null then
    update public.rooms set used_mimes = '{}' where id = p_room;
    select id into c from public.mime_cards where deleted_at is null order by random() limit 1;
  end if;
  if c is null then raise exception 'Aucune carte Mimes disponible.'; end if;

  update public.players set judge_count = judge_count + 1 where id = j;
  update public.players set next_ack_round = 0 where room_id = p_room and active;
  delete from public.mime_parts where room_id = p_room and round = p_next_round;
  -- intensités tirées sans remise de 1 à 10 (au-delà de 10 mimes, on reboucle)
  insert into public.mime_parts(room_id, round, player_id, intensity)
  select p_room, p_next_round, m.id, n.v
  from (select id, row_number() over (order by random()) k from public.players
        where room_id = p_room and active and id <> j) m
  join (select v, row_number() over (order by random()) k from generate_series(1, 10) v) n
    on n.k = ((m.k - 1) % 10) + 1;

  update public.rooms set
    status = 'mime_play', round = p_next_round,
    previous_reader_id = reader_id, reader_id = j,
    mime_card = c, used_mimes = (select used_mimes from public.rooms where id = p_room) || c,
    question_id = null, question_choices = '{}',
    winner_id = null, winning_submission_id = null,
    phase_at = now(), updated_at = now()
  where id = p_room;
end $fn$;

-- Barème : écart 0 → 3 pts, 1 → 2 pts, 2 → 1 pt, au-delà 0 (pour le mime).
-- Le juge marque la moyenne arrondie des points des mimes, comme le médium du Baromètre.
create or replace function public._mime_score(p_room uuid, p_players uuid[], p_notes integer[])
returns void language plpgsql security definer set search_path to '' as $fn$
declare r public.rooms;
begin
  select * into r from public.rooms where id = p_room for update;
  if r.status <> 'mime_play' then return; end if;
  update public.mime_parts m set guess = x.v,
    points = case abs(x.v - m.intensity) when 0 then 3 when 1 then 2 when 2 then 1 else 0 end
    from unnest(p_players, p_notes) as x(pid, v)
    where m.room_id = p_room and m.round = r.round and m.player_id = x.pid and m.intensity is not null;
  insert into public.mime_parts(room_id, round, player_id, intensity, points)
  select p_room, r.round, r.reader_id, null,
    coalesce((select round(avg(m.points))::integer from public.mime_parts m
              join public.players p on p.id = m.player_id and p.active
              where m.room_id = p_room and m.round = r.round and m.intensity is not null and m.points is not null), 0)
  on conflict (room_id, round, player_id) do update set points = excluded.points;
  update public.players p set score = p.score + m.points
    from public.mime_parts m
    where m.room_id = p_room and m.round = r.round and m.player_id = p.id and p.active and m.points is not null;
  update public.rooms set status = 'reveal', phase_at = now(), updated_at = now() where id = p_room;
end $fn$;

create or replace function public.mime_rate(p_code text, p_token uuid, p_players uuid[], p_notes integer[])
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.mode <> 'mimes' or r.status <> 'mime_play' then raise exception 'Ce n’est pas le moment de noter.'; end if;
  if r.reader_id <> me.id then raise exception 'Seul le juge note les mimes.'; end if;
  if p_players is null or p_notes is null or cardinality(p_players) <> cardinality(p_notes) then
    raise exception 'Notes invalides.';
  end if;
  if exists (select 1 from unnest(p_notes) v where v is null or v < 1 or v > 10) then
    raise exception 'Chaque note va de 1 à 10.';
  end if;
  if exists (select 1 from public.mime_parts m join public.players p on p.id = m.player_id and p.active
             where m.room_id = r.id and m.round = r.round and m.intensity is not null
               and not (m.player_id = any(p_players))) then
    raise exception 'Note chaque joueur.';
  end if;
  perform public._mime_score(r.id, p_players, p_notes);
end $fn$;

create or replace function public.mime_bot_step(p_code text, p_token uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; ids uuid[]; notes integer[];
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception 'Seul l’hôte pilote les bots.'; end if;
  if r.mode <> 'mimes' or r.status <> 'mime_play' then return; end if;
  if not exists (select 1 from public.players where id = r.reader_id and active and is_bot) then return; end if;
  select array_agg(m.player_id), array_agg(greatest(1, least(10, m.intensity - 2 + floor(random() * 5)::integer)))
    into ids, notes
    from public.mime_parts m where m.room_id = r.id and m.round = r.round and m.intensity is not null;
  perform public._mime_score(r.id, coalesce(ids, '{}'), coalesce(notes, '{}'));
end $fn$;

-- Départ pendant le jeu : sous le minimum → salon ; départ du juge → manche suivante.
alter function public._remove_player(uuid) rename to _remove_player_base;
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
end $fn$;

-- get_state : l'état existant, plus le mode du Baromètre et la carte Mimes.
alter function public.get_state(text,uuid) rename to _get_state_base;
create or replace function public.get_state(p_code text, p_token uuid)
returns json language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; base jsonb; extra jsonb := '{}'::jsonb;
begin
  base := public._get_state_base(p_code, p_token)::jsonb;
  me := public._player(p_code, p_token);
  select * into r from public.rooms where id = me.room_id;
  base := jsonb_set(base, '{room,wave_variant}', to_jsonb(r.wave_variant));
  if base->'wave' is not null and jsonb_typeof(base->'wave') = 'object' then
    base := jsonb_set(base, '{wave}', (base->'wave') || jsonb_build_object(
      'variant', r.wave_variant, 'theme', r.wave_theme, 'asker_id', r.wave_asker));
  end if;
  if r.mode = 'mimes' and r.status in ('mime_play','reveal','finished') and r.mime_card is not null then
    extra := jsonb_build_object('mime', jsonb_build_object(
      'action', (select c.action from public.mime_cards c where c.id = r.mime_card),
      'low', (select c.low_text from public.mime_cards c where c.id = r.mime_card),
      'high', (select c.high_text from public.mime_cards c where c.id = r.mime_card),
      'mine', (select m.intensity from public.mime_parts m where m.room_id = r.id and m.round = r.round and m.player_id = me.id),
      -- ordre de passage : les sièges à partir du juge (le juge en tête, sans intensité)
      'parts', (select coalesce(jsonb_agg(jsonb_build_object('player_id', m.player_id,
          'intensity', case when r.status in ('reveal','finished') then m.intensity end,
          'guess', case when r.status in ('reveal','finished') then m.guess end,
          'points', case when r.status in ('reveal','finished') then m.points end)
          order by (p.seat - coalesce(jp.seat, 0) + 10000) % 10000), '[]'::jsonb)
        from public.mime_parts m
        join public.players p on p.id = m.player_id and p.active
        left join public.players jp on jp.id = r.reader_id
        where m.room_id = r.id and m.round = r.round)));
  end if;
  return (base || extra)::json;
end $fn$;

-- ---------------------------------------------------------------- Droits
revoke execute on function
  public._create_room_base(text,integer,text,integer),
  public._set_room_options_base(text,uuid,text,integer,integer),
  public._white_starter(uuid),
  public._begin_white_round_base(uuid,integer),
  public._begin_white_round(uuid,integer),
  public._white_resume_base(text,uuid),
  public._white_state_base(text,uuid),
  public._begin_wave_round_base(uuid,integer),
  public._begin_wave_round(uuid,integer),
  public._begin_round(uuid,uuid,integer),
  public._begin_mime_round(uuid,integer),
  public._mime_score(uuid,uuid[],integer[]),
  public._remove_player_base(uuid),
  public._remove_player(uuid),
  public._get_state_base(text,uuid)
from public, anon, authenticated;

grant execute on function
  public.create_room(text,integer,text,integer),
  public.set_room_options(text,uuid,text,integer,integer),
  public.white_resume(text,uuid),
  public.white_state(text,uuid),
  public.set_wave_variant(text,uuid,text),
  public.submit_theme(text,uuid,text),
  public.submit_clue(text,uuid,text),
  public.wave_bot_step(text,uuid),
  public.reap_idle(text,uuid),
  public.mime_rate(text,uuid,uuid[],integer[]),
  public.mime_bot_step(text,uuid),
  public.get_state(text,uuid)
to anon, authenticated;
