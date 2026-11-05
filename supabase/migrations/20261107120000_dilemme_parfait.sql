-- Dilemme parfait : le meneur pose le début d'un dilemme (« Tu gagnes un
-- million d'euros… »), chaque joueur écrit la suite après « mais… ». Toutes
-- les propositions sont mélangées et chacun répond Oui ou Non à celles des
-- autres (« Tu acceptes ? »). Le but : couper la table pile en deux.
--
-- Points d'une proposition (votants = tous sauf l'auteur) :
--   round(3 × (1 − |oui − non| / votants)) : 3 pour un 50/50 parfait,
--   0 pour l'unanimité, entre les deux selon l'écart.
--
-- Phases : dilemme_pick (le meneur choisit le début) → dilemme_write (chacun,
-- meneur compris, écrit son « mais ») → dilemme_vote (Oui/Non sur les
-- propositions des autres, envoyés d'un coup) → reveal → manche suivante.
-- Chaque joueur est meneur autant de fois que « Tours » (judge_turns), comme
-- dans Le Dico.
--
-- Les fonctions partagées (_begin_round, get_state, reap_idle,
-- _time_phase_seconds, _remove_player, create_room, set_room_options) sont
-- reprises telles qu'elles tournent en production (relues le 2026-11-05),
-- avec la seule branche du Dilemme en plus.

-- À coller tel quel dans l'éditeur SQL de Supabase : tout passe dans une seule
-- transaction (une erreur n'applique rien) et la migration s'inscrit dans
-- l'historique supabase_migrations.
begin;

-- ---------------------------------------------------------------- Schéma
alter table public.rooms drop constraint if exists rooms_mode_check;
alter table public.rooms add constraint rooms_mode_check
  check (mode in ('phrases','priorites','ondes','bac','white','mimes','dico','dilemme'));
alter table public.rooms drop constraint if exists rooms_status_check;
alter table public.rooms add constraint rooms_status_check check (status in (
  'lobby','question_select','answering','judging','ranking','clue','guessing','naming','writing','voting',
  'reveal','finished','white_clue','white_vote','white_guess','white_elimination','mime_play',
  'dico_pick','dico_write','dico_vote','dilemme_pick','dilemme_write','dilemme_vote'));

alter table public.rooms add column if not exists dilemme_start text;

-- Une ligne par proposition (« mais… ») de la manche.
create table if not exists public.dilemme_buts (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  round integer not null,
  player_id uuid not null references public.players(id) on delete cascade,
  text text not null,
  sort_key double precision not null default random(),
  created_at timestamptz not null default now(),
  unique (room_id, round, player_id)
);
create index if not exists dilemme_buts_room_round on public.dilemme_buts(room_id, round);

create table if not exists public.dilemme_votes (
  room_id uuid not null references public.rooms(id) on delete cascade,
  round integer not null,
  voter_id uuid not null references public.players(id) on delete cascade,
  but_id uuid not null references public.dilemme_buts(id) on delete cascade,
  yes boolean not null,
  primary key (room_id, round, voter_id, but_id)
);

create table if not exists public.dilemme_points (
  room_id uuid not null references public.rooms(id) on delete cascade,
  round integer not null,
  player_id uuid not null references public.players(id) on delete cascade,
  points integer not null default 0,
  primary key (room_id, round, player_id)
);

alter table public.dilemme_buts enable row level security;
alter table public.dilemme_votes enable row level security;
alter table public.dilemme_points enable row level security;
revoke all on public.dilemme_buts, public.dilemme_votes, public.dilemme_points from public, anon, authenticated;

-- ---------------------------------------------------------------- Création et réglages
-- La validation de base ne connaît ni Mimes, ni le Dico, ni le Dilemme : on
-- crée en Priorités puis on bascule le mode.
create or replace function public.create_room(p_name text, p_target integer default 5,
  p_mode text default 'phrases', p_turns integer default 2)
returns json language plpgsql security definer set search_path to '' as $fn$
declare res json;
begin
 if p_mode in ('mimes','dico','dilemme') then
   res:=public._create_room_base(p_name,p_target,'priorites',p_turns);
   update public.rooms set mode=p_mode where code=res->>'code';
 else
   res:=public._create_room_base(p_name,p_target,p_mode,p_turns);
 end if;
 update public.rooms set time_mode=case when p_mode in ('bac','white','mimes')
     then 'unlimited' else 'medium' end where code=res->>'code';
 return res;
end $fn$;

create or replace function public.set_room_options(p_code text, p_token uuid, p_mode text, p_target integer, p_turns integer)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players;
begin
  if p_mode in ('mimes','dico','dilemme') then
    perform public._set_room_options_base(p_code, p_token, 'priorites', p_target, p_turns);
    me := public._player(p_code, p_token);
    update public.rooms set mode = p_mode where id = me.room_id;
    return;
  end if;
  perform public._set_room_options_base(p_code, p_token, p_mode, p_target, p_turns);
end $fn$;

-- ---------------------------------------------------------------- Manches
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

-- Le moins souvent meneur passe en premier (à égalité, l'ordre d'arrivée).
-- Quand chacun l'a été « Tours » fois, la partie est finie.
create or replace function public._begin_dilemme_round(p_room uuid, p_next_round integer)
returns void language plpgsql security definer set search_path to '' as $fn$
declare r public.rooms; j uuid; w uuid;
begin
  select * into r from public.rooms where id = p_room for update;
  if p_next_round = 1 then
    delete from public.dilemme_votes where room_id = p_room;
    delete from public.dilemme_points where room_id = p_room;
    delete from public.dilemme_buts where room_id = p_room;
  end if;
  select id into j from public.players
    where room_id = p_room and active and judge_count < r.judge_turns
    order by judge_count, seat limit 1;
  if j is null then
    select id into w from public.players where room_id = p_room and active order by score desc, seat limit 1;
    update public.rooms set status = 'finished', winner_id = w, winning_submission_id = null,
      phase_at = now(), updated_at = now() where id = p_room;
    return;
  end if;
  update public.players set judge_count = judge_count + 1 where id = j;
  update public.players set next_ack_round = 0 where room_id = p_room and active;
  delete from public.dilemme_votes where room_id = p_room and round = p_next_round;
  delete from public.dilemme_points where room_id = p_room and round = p_next_round;
  delete from public.dilemme_buts where room_id = p_room and round = p_next_round;
  update public.rooms set
    status = 'dilemme_pick', round = p_next_round,
    previous_reader_id = reader_id, reader_id = j,
    dilemme_start = null,
    question_id = null, question_choices = '{}',
    winner_id = null, winning_submission_id = null,
    phase_at = now(), updated_at = now()
  where id = p_room;
end $fn$;

-- Le meneur a posé le début du dilemme : la rédaction commence.
create or replace function public._dilemme_set_start(p_room uuid, p_start text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare r public.rooms;
  s text := left(regexp_replace(trim(coalesce(p_start, '')), '\s+', ' ', 'g'), 140);
begin
  select * into r from public.rooms where id = p_room for update;
  if r.status <> 'dilemme_pick' then raise exception 'Le dilemme est déjà posé.'; end if;
  -- « mais » final et points de suspension : l'appli les ajoute elle-même
  s := trim(regexp_replace(s, '[\s,.…]*(mais)?[\s,.…]*$', '', 'i'));
  if length(s) < 5 then raise exception 'Écris le début du dilemme.'; end if;
  update public.rooms set dilemme_start = s, status = 'dilemme_write',
    phase_at = now(), updated_at = now() where id = r.id;
end $fn$;

create or replace function public.dilemme_pick(p_code text, p_token uuid, p_start text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.mode <> 'dilemme' or r.status <> 'dilemme_pick' then raise exception 'Ce n’est pas le moment de poser le dilemme.'; end if;
  if r.reader_id <> me.id then raise exception 'Seul le meneur pose le dilemme.'; end if;
  perform public._dilemme_set_start(r.id, p_start);
end $fn$;

-- Ouvre le vote : les propositions sont mélangées à nouveau.
create or replace function public._dilemme_open_vote(p_room uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare r public.rooms;
begin
  select * into r from public.rooms where id = p_room for update;
  if r.status <> 'dilemme_write' then return; end if;
  update public.dilemme_buts set sort_key = random() where room_id = r.id and round = r.round;
  update public.rooms set status = 'dilemme_vote', phase_at = now(), updated_at = now() where id = r.id;
end $fn$;

-- Joueurs actifs qui ont répondu à toutes les propositions des autres joueurs actifs.
create or replace function public._dilemme_voters_done(p_room uuid, p_round integer)
returns uuid[] language sql stable security definer set search_path to '' as $fn$
  select coalesce(array_agg(p.id), '{}') from public.players p
  where p.room_id = p_room and p.active
    and (select count(*) from public.dilemme_votes v
           join public.dilemme_buts b on b.id = v.but_id
           join public.players a on a.id = b.player_id and a.active
          where v.room_id = p_room and v.round = p_round and v.voter_id = p.id and b.player_id <> p.id)
     >= (select count(*) from public.dilemme_buts b
           join public.players a on a.id = b.player_id and a.active
          where b.room_id = p_room and b.round = p_round and b.player_id <> p.id)
$fn$;

create or replace function public._dilemme_score(p_room uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare r public.rooms;
begin
  select * into r from public.rooms where id = p_room for update;
  if r.status <> 'dilemme_vote' then return; end if;
  delete from public.dilemme_points where room_id = r.id and round = r.round;
  -- 3 pour un 50/50 parfait, 0 pour l'unanimité
  insert into public.dilemme_points(room_id, round, player_id, points)
  select r.id, r.round, p.id, coalesce((
    select case when t.n = 0 then 0
                else round(3 * (1 - abs(2 * t.y - t.n)::numeric / t.n))::integer end
    from (select count(v.voter_id) as n, count(v.voter_id) filter (where v.yes) as y
            from public.dilemme_buts b
            left join public.dilemme_votes v on v.but_id = b.id
              and exists (select 1 from public.players q where q.id = v.voter_id and q.active)
           where b.room_id = r.id and b.round = r.round and b.player_id = p.id) t), 0)
  from public.players p where p.room_id = r.id and p.active;
  update public.players p set score = p.score + d.points from public.dilemme_points d
    where d.room_id = r.id and d.round = r.round and d.player_id = p.id and p.active;
  update public.rooms set status = 'reveal', phase_at = now(), updated_at = now() where id = r.id;
end $fn$;

-- Passe à la phase suivante quand tout le monde a écrit, ou a voté.
create or replace function public._dilemme_advance(p_room uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare r public.rooms; attendus integer; faits integer;
begin
  select * into r from public.rooms where id = p_room for update;
  if r.mode <> 'dilemme' then return; end if;
  select count(*) into attendus from public.players where room_id = r.id and active;
  if attendus = 0 then return; end if;
  if r.status = 'dilemme_write' then
    select count(*) into faits from public.dilemme_buts b join public.players p on p.id = b.player_id and p.active
      where b.room_id = r.id and b.round = r.round;
    if faits >= attendus then perform public._dilemme_open_vote(r.id); end if;
  elsif r.status = 'dilemme_vote' then
    faits := cardinality(public._dilemme_voters_done(r.id, r.round));
    if faits >= attendus then perform public._dilemme_score(r.id); end if;
  end if;
end $fn$;

create or replace function public.dilemme_write(p_code text, p_token uuid, p_text text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms;
  t text := left(regexp_replace(trim(coalesce(p_text, '')), '\s+', ' ', 'g'), 140);
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.mode <> 'dilemme' or r.status <> 'dilemme_write' then raise exception 'Ce n’est plus le moment d’écrire.'; end if;
  -- « mais » recopié en tête : l'appli l'affiche déjà
  t := trim(regexp_replace(t, '^[\s.…]*mais[\s,.…]+', '', 'i'));
  if length(t) < 3 then raise exception 'Écris la suite du dilemme.'; end if;
  insert into public.dilemme_buts(room_id, round, player_id, text) values (r.id, r.round, me.id, t)
    on conflict (room_id, round, player_id) do update set text = excluded.text;
  perform public._dilemme_advance(r.id);
end $fn$;

-- Les réponses Oui/Non d'un joueur, envoyées d'un coup : une par proposition
-- des autres joueurs. Renvoyer remplace les réponses précédentes.
create or replace function public.dilemme_vote(p_code text, p_token uuid, p_buts uuid[], p_yes boolean[])
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; attendus integer; recus integer;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.mode <> 'dilemme' or r.status <> 'dilemme_vote' then raise exception 'Ce n’est pas le moment de voter.'; end if;
  if coalesce(cardinality(p_buts), 0) <> coalesce(cardinality(p_yes), 0) then raise exception 'Votes incomplets.'; end if;
  if exists (select 1 from unnest(p_yes) y where y is null) then raise exception 'Réponds Oui ou Non à chaque proposition.'; end if;
  if exists (select 1 from unnest(p_buts) x left join public.dilemme_buts b on b.id = x and b.room_id = r.id and b.round = r.round
             where b.id is null) then raise exception 'Proposition inconnue.'; end if;
  if exists (select 1 from public.dilemme_buts b where b.id = any(p_buts) and b.player_id = me.id) then
    raise exception 'Tu ne votes pas pour ta propre proposition.'; end if;
  select count(*) into attendus from public.dilemme_buts b join public.players a on a.id = b.player_id and a.active
    where b.room_id = r.id and b.round = r.round and b.player_id <> me.id;
  select count(distinct x) into recus from unnest(p_buts) x
    join public.dilemme_buts b on b.id = x join public.players a on a.id = b.player_id and a.active;
  if recus < attendus then raise exception 'Réponds Oui ou Non à chaque proposition.'; end if;
  delete from public.dilemme_votes where room_id = r.id and round = r.round and voter_id = me.id;
  insert into public.dilemme_votes(room_id, round, voter_id, but_id, yes)
  select distinct on (x.b) r.id, r.round, me.id, x.b, x.y from unnest(p_buts, p_yes) as x(b, y);
  perform public._dilemme_advance(r.id);
end $fn$;

-- Bots, pilotés par le téléphone de l'hôte, qui leur envoie des débuts de
-- dilemme et des « mais » tirés au hasard. Meneur bot : il prend le premier
-- début. Bots qui écrivent : un « mais » chacun. Bots qui votent : au hasard.
create or replace function public.dilemme_bot_step(p_code text, p_token uuid, p_starts text[], p_buts text[])
returns void language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; b public.players; k integer := 0; n integer := coalesce(cardinality(p_buts), 0);
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception 'Seul l’hôte pilote les bots.'; end if;
  if r.mode <> 'dilemme' then return; end if;
  if r.status = 'dilemme_pick' then
    if exists (select 1 from public.players where id = r.reader_id and active and is_bot) then
      perform public._dilemme_set_start(r.id, coalesce(nullif(trim(p_starts[1]), ''), 'Tu gagnes un million d’euros'));
    end if;
  elsif r.status = 'dilemme_write' then
    for b in select * from public.players p where p.room_id = r.id and p.active and p.is_bot
             and not exists (select 1 from public.dilemme_buts d where d.room_id = r.id and d.round = r.round and d.player_id = p.id) loop
      k := k + 1;
      insert into public.dilemme_buts(room_id, round, player_id, text)
      values (r.id, r.round, b.id, coalesce(nullif(left(trim(p_buts[((k - 1) % greatest(n, 1)) + 1]), 140), ''), 'tu dois chanter à chaque fois que tu parles'))
      on conflict do nothing;
    end loop;
    perform public._dilemme_advance(r.id);
  elsif r.status = 'dilemme_vote' then
    for b in select * from public.players p where p.room_id = r.id and p.active and p.is_bot
             and not (p.id = any(public._dilemme_voters_done(r.id, r.round))) loop
      delete from public.dilemme_votes where room_id = r.id and round = r.round and voter_id = b.id;
      insert into public.dilemme_votes(room_id, round, voter_id, but_id, yes)
      select r.id, r.round, b.id, d.id, random() < .5 from public.dilemme_buts d
        where d.room_id = r.id and d.round = r.round and d.player_id <> b.id;
    end loop;
    perform public._dilemme_advance(r.id);
  end if;
end $fn$;

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
end $fn$;

-- ---------------------------------------------------------------- État envoyé à chaque joueur
-- Jusqu'à la révélation, ni les auteurs ni les votes des autres ne sont envoyés.
create or replace function public.get_state(p_code text, p_token uuid)
returns json language plpgsql security definer set search_path to '' as $fn$
declare me public.players; r public.rooms; base jsonb; extra jsonb := '{}'::jsonb; fin boolean;
begin
  base := public._get_state_base(p_code, p_token)::jsonb;
  me := public._player(p_code, p_token);
  select * into r from public.rooms where id = me.room_id;
  base := jsonb_set(base, '{room,time_mode}', to_jsonb(r.time_mode));
  base := jsonb_set(base, '{room,mime_index}', to_jsonb(r.mime_index));
  base := jsonb_set(base, '{room,mime_started_at}', coalesce(to_jsonb(r.mime_started_at), 'null'::jsonb));
  base := jsonb_set(base, '{room,phase_seconds}', coalesce(to_jsonb(public._time_phase_seconds(r)), 'null'::jsonb));
  base := jsonb_set(base, '{room,phase_deadline}', coalesce(to_jsonb(
    case when r.status = 'mime_play' then
      case when r.mime_index between 1 and (select count(*) from public.mime_parts where room_id=r.id and round=r.round)
        and r.mime_started_at is not null and public._time_phase_seconds(r) is not null
        then r.mime_started_at + make_interval(secs => public._time_phase_seconds(r)) end
    else
      case when public._time_phase_seconds(r) is not null
        then r.phase_at + make_interval(secs => public._time_phase_seconds(r)) end
    end), 'null'::jsonb));
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
  if r.mode = 'dico' and r.status in ('dico_pick','dico_write','dico_vote','reveal','finished') and r.round > 0 then
    fin := r.status in ('reveal','finished');
    extra := extra || jsonb_build_object('dico', jsonb_build_object(
      'word', r.dico_word, 'nature', r.dico_nature,
      'definition', case when fin or r.reader_id = me.id then r.dico_def end,
      'mine', (select d.text from public.dico_defs d where d.room_id = r.id and d.round = r.round and d.player_id = me.id),
      'written', (select coalesce(jsonb_agg(d.player_id), '[]'::jsonb) from public.dico_defs d
                   join public.players p on p.id = d.player_id and p.active
                   where d.room_id = r.id and d.round = r.round and not d.is_true),
      'voted', (select coalesce(jsonb_agg(v.voter_id), '[]'::jsonb) from public.dico_votes v
                 join public.players p on p.id = v.voter_id and p.active
                 where v.room_id = r.id and v.round = r.round),
      'my_vote', (select v.def_id from public.dico_votes v where v.room_id = r.id and v.round = r.round and v.voter_id = me.id),
      'defs', case when r.status in ('dico_vote','reveal','finished') then
        (select coalesce(jsonb_agg(jsonb_build_object(
            'id', d.id, 'text', d.text, 'mine', d.player_id = me.id,
            'is_true', case when fin then d.is_true end,
            'author_id', case when fin then d.player_id end,
            'voters', case when fin then (select coalesce(jsonb_agg(v.voter_id), '[]'::jsonb) from public.dico_votes v
                                           where v.def_id = d.id) end)
          order by d.sort_key), '[]'::jsonb)
         from public.dico_defs d left join public.players p on p.id = d.player_id
         where d.room_id = r.id and d.round = r.round and (d.player_id is null or p.active)) end,
      'points', case when fin then
        (select coalesce(jsonb_agg(jsonb_build_object('player_id', x.player_id, 'points', x.points)), '[]'::jsonb)
         from public.dico_points x where x.room_id = r.id and x.round = r.round) end));
  end if;
  if r.mode = 'dilemme' and r.status in ('dilemme_pick','dilemme_write','dilemme_vote','reveal','finished') and r.round > 0 then
    fin := r.status in ('reveal','finished');
    extra := extra || jsonb_build_object('dilemme', jsonb_build_object(
      'start', r.dilemme_start,
      'mine', (select b.text from public.dilemme_buts b where b.room_id = r.id and b.round = r.round and b.player_id = me.id),
      'written', (select coalesce(jsonb_agg(b.player_id), '[]'::jsonb) from public.dilemme_buts b
                   join public.players p on p.id = b.player_id and p.active
                   where b.room_id = r.id and b.round = r.round),
      'voted', case when r.status = 'dilemme_vote' then to_jsonb(public._dilemme_voters_done(r.id, r.round)) else '[]'::jsonb end,
      'buts', case when r.status in ('dilemme_vote','reveal','finished') then
        (select coalesce(jsonb_agg(jsonb_build_object(
            'id', b.id, 'text', b.text, 'mine', b.player_id = me.id,
            'my_vote', (select v.yes from public.dilemme_votes v where v.but_id = b.id and v.voter_id = me.id),
            'author_id', case when fin then b.player_id end,
            'yes', case when fin then (select coalesce(jsonb_agg(v.voter_id), '[]'::jsonb) from public.dilemme_votes v
                     join public.players q on q.id = v.voter_id and q.active where v.but_id = b.id and v.yes) end,
            'no', case when fin then (select coalesce(jsonb_agg(v.voter_id), '[]'::jsonb) from public.dilemme_votes v
                    join public.players q on q.id = v.voter_id and q.active where v.but_id = b.id and not v.yes) end,
            'points', case when fin then (select x.points from public.dilemme_points x
                        where x.room_id = r.id and x.round = r.round and x.player_id = b.player_id) end)
          order by b.sort_key), '[]'::jsonb)
         from public.dilemme_buts b join public.players p on p.id = b.player_id and p.active
         where b.room_id = r.id and b.round = r.round) end,
      'points', case when fin then
        (select coalesce(jsonb_agg(jsonb_build_object('player_id', x.player_id, 'points', x.points)), '[]'::jsonb)
         from public.dilemme_points x where x.room_id = r.id and x.round = r.round) end));
  end if;
  return (base || extra)::json;
end $fn$;

-- ---------------------------------------------------------------- Droits
revoke execute on function
  public._begin_dilemme_round(uuid,integer),
  public._dilemme_set_start(uuid,text),
  public._dilemme_open_vote(uuid),
  public._dilemme_voters_done(uuid,integer),
  public._dilemme_score(uuid),
  public._dilemme_advance(uuid)
from public, anon, authenticated;

revoke execute on function
  public.dilemme_pick(text,uuid,text),
  public.dilemme_write(text,uuid,text),
  public.dilemme_vote(text,uuid,uuid[],boolean[]),
  public.dilemme_bot_step(text,uuid,text[],text[])
from public;
grant execute on function
  public.dilemme_pick(text,uuid,text),
  public.dilemme_write(text,uuid,text),
  public.dilemme_vote(text,uuid,uuid[],boolean[]),
  public.dilemme_bot_step(text,uuid,text[],text[])
to anon, authenticated;

-- Inscription dans l'historique des migrations (absente d'une base locale de test).
do $hist$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    if not exists (select 1 from supabase_migrations.schema_migrations where version = '20261107120000') then
      insert into supabase_migrations.schema_migrations(version, name) values ('20261107120000', 'dilemme_parfait');
    end if;
  end if;
end $hist$;

commit;

select 'Dilemme parfait est installé.' as resultat;
