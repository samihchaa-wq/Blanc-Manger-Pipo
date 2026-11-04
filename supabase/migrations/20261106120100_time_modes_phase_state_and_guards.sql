-- Fonctions métier : le serveur renvoie une échéance unique à tous les téléphones.
CREATE OR REPLACE FUNCTION public.get_state(p_code text, p_token uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms; base jsonb; extra jsonb := '{}'::jsonb;
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
  return (base || extra)::json;
end $function$;

CREATE OR REPLACE FUNCTION public._white_resolve_vote(p_room uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.rooms; out_id uuid; out_role text; nmax integer; ties integer; out_name text;
begin
  select * into r from public.rooms where id=p_room for update;
  if r.status<>'white_vote' then return; end if;
  if exists(select 1 from public.white_roles wr join public.players p on p.id=wr.player_id and p.active
      where wr.room_id=p_room and wr.round=r.round and not wr.eliminated and
      not exists(select 1 from public.white_votes v where v.room_id=p_room and v.round=r.round and
        v.cycle=r.white_cycle and v.player_id=wr.player_id)) and not public._time_expired(r) then return; end if;
  select max(n) into nmax from (select count(*) n from public.white_votes v
    where v.room_id=p_room and v.round=r.round and v.cycle=r.white_cycle group by target_id) z;
  select count(*) into ties from (select target_id,count(*) n from public.white_votes
    where room_id=p_room and round=r.round and cycle=r.white_cycle group by target_id) z where n=nmax;
  if nmax is null or ties<>1 then
    update public.rooms set status='white_elimination',white_note='Égalité : personne n’est éliminé.',
      phase_at=now(),updated_at=now() where id=p_room;
    return;
  end if;
  select v.target_id into out_id from public.white_votes v
    where v.room_id=p_room and v.round=r.round and v.cycle=r.white_cycle
    group by v.target_id order by count(*) desc limit 1;
  update public.white_roles set eliminated=true,eliminated_cycle=r.white_cycle
    where room_id=p_room and round=r.round and player_id=out_id returning role into out_role;
  select name into out_name from public.players where id=out_id;
  update public.white_rounds set last_eliminated=out_id where room_id=p_room and round=r.round;
  update public.rooms set white_note=out_name||' est éliminé ('||
    case out_role when 'civil' then 'Civil' when 'undercover' then 'Undercover' else 'Mr White' end||').',
    updated_at=now() where id=p_room;
  if out_role='white' then
    update public.rooms set status='white_guess',phase_at=now(),updated_at=now() where id=p_room;
  else perform public._white_check_end(p_room); end if;
end $function$;

CREATE OR REPLACE FUNCTION public._begin_mime_round(p_room uuid, p_next_round integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    mime_index = 0, mime_started_at = null,
    previous_reader_id = reader_id, reader_id = j,
    mime_card = c, used_mimes = (select used_mimes from public.rooms where id = p_room) || c,
    question_id = null, question_choices = '{}',
    winner_id = null, winning_submission_id = null,
    phase_at = now(), updated_at = now()
  where id = p_room;
end $function$;

CREATE OR REPLACE FUNCTION public.submit_answer(p_code text, p_token uuid, p_answer_id integer, p_answer_id2 integer DEFAULT NULL::integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms; n int;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if public._time_expired(r) then raise exception 'Le temps est écoulé.'; end if;
  if r.status <> 'answering' then raise exception 'Les réponses sont fermées pour ce tour.'; end if;
  if r.reader_id = me.id then raise exception 'Tu lis la question ce tour-ci.'; end if;
  if exists(select 1 from public.submissions where room_id = r.id and round = r.round and player_id = me.id)
    then raise exception 'Tu as déjà joué une carte.'; end if;

  select blanks into n from public.questions where id = r.question_id;
  n := coalesce(n, 1);
  if n = 1 and p_answer_id2 is not null then raise exception 'Cette phrase n''a qu''un trou.'; end if;
  if n = 2 and p_answer_id2 is null then raise exception 'Cette phrase a deux trous : choisis deux cartes.'; end if;
  if p_answer_id2 = p_answer_id then raise exception 'Choisis deux cartes différentes.'; end if;

  if not exists(select 1 from public.hands where player_id = me.id and answer_id = p_answer_id)
    then raise exception 'Cette carte n''est pas dans ta main.'; end if;
  if p_answer_id2 is not null
     and not exists(select 1 from public.hands where player_id = me.id and answer_id = p_answer_id2)
    then raise exception 'Cette carte n''est pas dans ta main.'; end if;

  insert into public.submissions(room_id, round, player_id, answer_id, answer_id2)
  values (r.id, r.round, me.id, p_answer_id, p_answer_id2);
  delete from public.hands where player_id = me.id and answer_id in (p_answer_id, p_answer_id2);

  perform public._deal(r.id);
  perform public._maybe_judge(r.id);
  update public.rooms set updated_at = now() where id = r.id;
end
$function$;

CREATE OR REPLACE FUNCTION public.submit_ranking(p_code text, p_token uuid, p_cards integer[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if public._time_expired(r) then raise exception 'Le temps est écoulé.'; end if;
  if r.status <> 'ranking' then raise exception 'Ce n’est pas le moment de classer.'; end if;
  if p_cards is null or cardinality(p_cards) <> cardinality(r.rank_cards)
     or (select count(distinct x) from unnest(p_cards) x) <> cardinality(r.rank_cards)
     or not (p_cards <@ r.rank_cards) then
    raise exception 'Classe les 5 cartes, chacune une seule fois.';
  end if;
  insert into public.rankings(room_id, round, player_id, cards)
  values (r.id, r.round, me.id, p_cards) on conflict do nothing;
  if not found then raise exception 'Ton classement est déjà envoyé.'; end if;
  perform public._maybe_score(r.id);
  update public.rooms set updated_at = now() where id = r.id;
end $function$;

CREATE OR REPLACE FUNCTION public.submit_guess(p_code text, p_token uuid, p_value integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if public._time_expired(r) then raise exception 'Le temps est écoulé.'; end if;
  if r.status <> 'guessing' then raise exception 'Ce n’est pas le moment de viser.'; end if;
  if r.reader_id = me.id then raise exception 'Le médium ne vise pas.'; end if;
  if p_value is null or p_value < 0 or p_value > 100 then raise exception 'Position invalide.'; end if;
  insert into public.wave_guesses(room_id, round, player_id, value)
  values (r.id, r.round, me.id, p_value) on conflict do nothing;
  if not found then raise exception 'Ta réponse est déjà envoyée.'; end if;
  perform public._maybe_wave_score(r.id);
  update public.rooms set updated_at = now() where id = r.id;
end $function$;

CREATE OR REPLACE FUNCTION public.submit_clue(p_code text, p_token uuid, p_clue text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms; t text := regexp_replace(trim(coalesce(p_clue, '')), '\s+', ' ', 'g');
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if public._time_expired(r) then raise exception 'Le temps est écoulé.'; end if;
  if r.status <> 'clue' then raise exception 'Ce n’est pas le moment de donner l’indice.'; end if;
  if r.reader_id <> me.id then raise exception 'Seul le médium donne l’indice.'; end if;
  if r.wave_variant = 'inverse' and r.wave_theme is null then raise exception 'Attends le thème.'; end if;
  if t = '' then raise exception 'Écris un indice.'; end if;
  if char_length(t) > 60 then raise exception 'L’indice fait 60 caractères au maximum.'; end if;
  update public.rooms set wave_clue = t, status = 'guessing', phase_at = now(), updated_at = now() where id = r.id;
end $function$;

CREATE OR REPLACE FUNCTION public.submit_theme(p_code text, p_token uuid, p_theme text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms; t text := regexp_replace(trim(coalesce(p_theme, '')), '\s+', ' ', 'g');
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if public._time_expired(r) then raise exception 'Le temps est écoulé.'; end if;
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
end $function$;

CREATE OR REPLACE FUNCTION public.bac_save(p_code text, p_token uuid, p_answers text[], p_done boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms; a text[];
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if public._time_expired(r) then raise exception 'Le temps est écoulé.'; end if;
  if r.status <> 'writing' then raise exception 'Le temps est écoulé.'; end if;
  if cardinality(coalesce(p_answers, '{}')) > 6 then raise exception 'Six réponses au maximum.'; end if;
  select array_agg(left(btrim(regexp_replace(coalesce(p_answers[i], ''), '\s+', ' ', 'g')), 120) order by i)
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

CREATE OR REPLACE FUNCTION public.bac_category(p_code text, p_token uuid, p_name text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms;
  t text := regexp_replace(btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')), '[.]+$', '');
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if public._time_expired(r) then raise exception 'Le temps est écoulé.'; end if;
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

CREATE OR REPLACE FUNCTION public.white_vote(p_code text, p_token uuid, p_target uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms;
begin
  me:=public._player(p_code,p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id=me.room_id for update;
  if public._time_expired(r) then raise exception 'Le temps est écoulé.'; end if;
  if r.mode<>'white' or r.status<>'white_vote' then raise exception 'Le vote est fermé.'; end if;
  if not exists(select 1 from public.white_roles where room_id=r.id and round=r.round and player_id=me.id and not eliminated)
  then raise exception 'Tu es éliminé.'; end if;
  if p_target=me.id or not exists(select 1 from public.white_roles wr join public.players p on p.id=wr.player_id and p.active
        where wr.room_id=r.id and wr.round=r.round and wr.player_id=p_target and not wr.eliminated)
  then raise exception 'Cible de vote invalide.'; end if;
  insert into public.white_votes(room_id,round,cycle,player_id,target_id) values(r.id,r.round,r.white_cycle,me.id,p_target);
  perform public._white_resolve_vote(r.id);
  update public.rooms set updated_at=now() where id=r.id;
end $function$;
