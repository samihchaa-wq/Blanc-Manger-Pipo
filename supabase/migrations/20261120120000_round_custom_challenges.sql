-- Défis uniques par manche (Mimes, Baromètre normal, Phrases à trou).
-- Consulter les tests et déployer la migration AVANT le client.

-- Défis éphémères pour la MANCHE courante, jamais ajoutés aux catalogues.
ALTER TABLE public.rooms
  ADD COLUMN IF NOT EXISTS custom_round integer,
  ADD COLUMN IF NOT EXISTS custom_question text,
  ADD COLUMN IF NOT EXISTS custom_blanks smallint,
  ADD COLUMN IF NOT EXISTS custom_wave_left text,
  ADD COLUMN IF NOT EXISTS custom_wave_right text,
  ADD COLUMN IF NOT EXISTS custom_mime_action text,
  ADD COLUMN IF NOT EXISTS custom_mime_low text,
  ADD COLUMN IF NOT EXISTS custom_mime_high text,
  ADD COLUMN IF NOT EXISTS mime_ready boolean NOT NULL DEFAULT true;

-- Activation différée : la préparation Mimes n'est utilisée qu'une fois
-- l'interface nouvelle effectivement publiée (migration d'activation séparée).
CREATE OR REPLACE FUNCTION public._custom_round_enabled()
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path TO '' AS $fn$
  SELECT false
$fn$;
REVOKE ALL ON FUNCTION public._custom_round_enabled() FROM PUBLIC, anon, authenticated;

-- Nettoyage systématique lors de chaque changement de manche (ou retour au salon).
CREATE OR REPLACE FUNCTION public._clear_round_custom_challenge()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path TO '' AS $fn$
BEGIN
  IF NEW.round IS DISTINCT FROM OLD.round THEN
    NEW.custom_round := NULL;
    NEW.custom_question := NULL;
    NEW.custom_blanks := NULL;
    NEW.custom_wave_left := NULL;
    NEW.custom_wave_right := NULL;
    NEW.custom_mime_action := NULL;
    NEW.custom_mime_low := NULL;
    NEW.custom_mime_high := NULL;
    NEW.mime_ready := NOT (NEW.mode = 'mimes' AND NEW.status = 'mime_play' AND public._custom_round_enabled());
  END IF;
  RETURN NEW;
END $fn$;
DROP TRIGGER IF EXISTS clear_round_custom_challenge ON public.rooms;
CREATE TRIGGER clear_round_custom_challenge
BEFORE UPDATE OF round ON public.rooms
FOR EACH ROW EXECUTE FUNCTION public._clear_round_custom_challenge();
REVOKE ALL ON FUNCTION public._clear_round_custom_challenge() FROM PUBLIC, anon, authenticated;

-- Seul le lecteur de la question active peut écrire une question de 1 ou 2 trous.
CREATE OR REPLACE FUNCTION public.choose_custom_question(p_code text,p_token uuid,p_text text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $fn$
DECLARE me public.players; r public.rooms; t text; n integer;
BEGIN
  me := public._player(p_code,p_token);
  IF me.id IS NULL THEN RAISE EXCEPTION 'Session expirée.'; END IF;
  SELECT * INTO r FROM public.rooms WHERE id=me.room_id FOR UPDATE;
  IF r.mode <> 'phrases' OR r.status <> 'question_select' OR r.reader_id IS DISTINCT FROM me.id
  THEN RAISE EXCEPTION 'Seul le lecteur peut inventer la question à cette étape.'; END IF;
  t := btrim(coalesce(p_text,''));
  n := (length(t)-length(replace(t,'____',''))) / 4;
  IF length(t) < 5 OR length(t) > 150 OR n NOT IN (1,2)
  THEN RAISE EXCEPTION 'Écris une phrase de 150 caractères maximum avec 1 ou 2 trous (____).'; END IF;
  UPDATE public.rooms SET custom_round=r.round, custom_question=t,custom_blanks=n,
    question_id=NULL,question_choices='{}',status='answering',phase_at=now(),updated_at=now()
  WHERE id=r.id;
  PERFORM public._maybe_judge(r.id);
END $fn$;

-- Le médium invente les deux extrêmes, mais jamais la cible secrète.
CREATE OR REPLACE FUNCTION public.choose_custom_wave(p_code text,p_token uuid,p_left text,p_right text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $fn$
DECLARE me public.players; r public.rooms; l text; rr text;
BEGIN
  me := public._player(p_code,p_token);
  IF me.id IS NULL THEN RAISE EXCEPTION 'Session expirée.'; END IF;
  SELECT * INTO r FROM public.rooms WHERE id=me.room_id FOR UPDATE;
  IF r.mode <> 'ondes' OR r.wave_variant <> 'normal' OR r.status <> 'clue'
     OR r.reader_id IS DISTINCT FROM me.id OR r.wave_clue IS NOT NULL
  THEN RAISE EXCEPTION 'Tu ne peux plus modifier ce Baromètre.'; END IF;
  l := btrim(coalesce(p_left,'')); rr := btrim(coalesce(p_right,''));
  IF length(l) < 2 OR length(rr) < 2 OR length(l) > 40 OR length(rr) > 40
     OR lower(l)=lower(rr)
  THEN RAISE EXCEPTION 'Définis deux extrêmes différents (2 à 40 caractères chacun).'; END IF;
  UPDATE public.rooms SET custom_round=r.round, custom_wave_left=l,custom_wave_right=rr,
    phase_at=now(),updated_at=now() WHERE id=r.id;
END $fn$;

-- Pour Mimes : le juge valide la carte normale OU une création à trois champs.
-- Les intensités secrètes sont celles tirées avant cette étape, jamais modifiées.
CREATE OR REPLACE FUNCTION public.choose_mime_challenge(p_code text,p_token uuid,
  p_custom boolean,p_action text,p_low text,p_high text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $fn$
DECLARE me public.players; r public.rooms; a text; l text; h text;
BEGIN
  me := public._player(p_code,p_token);
  IF me.id IS NULL THEN RAISE EXCEPTION 'Session expirée.'; END IF;
  SELECT * INTO r FROM public.rooms WHERE id=me.room_id FOR UPDATE;
  IF r.mode <> 'mimes' OR r.status <> 'mime_play' OR r.reader_id IS DISTINCT FROM me.id
     OR r.mime_ready OR r.mime_index <> 0
  THEN RAISE EXCEPTION 'Ce mime a déjà commencé, ou tu n’es pas le juge.'; END IF;
  IF coalesce(p_custom,false) THEN
    a:=btrim(coalesce(p_action,'')); l:=btrim(coalesce(p_low,'')); h:=btrim(coalesce(p_high,''));
    IF length(a)<3 OR length(a)>80 OR length(l)<2 OR length(l)>60
       OR length(h)<2 OR length(h)>60
    THEN RAISE EXCEPTION 'Décris l’action (3 à 80 caractères) et les deux intensités (2 à 60).'; END IF;
    UPDATE public.rooms SET custom_round=r.round, custom_mime_action=a,
      custom_mime_low=l,custom_mime_high=h,mime_ready=true,
      phase_at=now(),updated_at=now() WHERE id=r.id;
  ELSE
    UPDATE public.rooms SET mime_ready=true,phase_at=now(),updated_at=now() WHERE id=r.id;
  END IF;
END $fn$;
REVOKE ALL ON FUNCTION public.choose_custom_question(text,uuid,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.choose_custom_wave(text,uuid,text,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.choose_mime_challenge(text,uuid,boolean,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.choose_custom_question(text,uuid,text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.choose_custom_wave(text,uuid,text,text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.choose_mime_challenge(text,uuid,boolean,text,text,text) TO anon, authenticated, service_role;

-- Conservons les flux actuels, avec seulement les adaptations ciblées.

CREATE OR REPLACE FUNCTION public.get_state(p_code text, p_token uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  base := jsonb_set(base, '{room,dilemme_variant}', to_jsonb(r.dilemme_variant));
  base := jsonb_set(base, '{room,phrases_variant}', to_jsonb(r.phrases_variant));
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
      -- sa propre cible, connue de lui seul jusqu'à la révélation
      'my_target', (select jsonb_build_object('pct', t.target, 'yes', t.target_yes, 'voters', t.voters)
                     from public.dilemme_cibles t where t.room_id = r.id and t.round = r.round and t.player_id = me.id),
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
            'target', case when fin then (select jsonb_build_object('pct', t.target, 'yes', t.target_yes, 'voters', t.voters)
                        from public.dilemme_cibles t
                        where t.room_id = r.id and t.round = r.round and t.player_id = b.player_id) end,
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
  base := base || extra;
  if r.mode = 'phrases' and r.custom_round = r.round and r.custom_question is not null
     and r.status in ('answering','judging','reveal','finished') then
    base := jsonb_set(base, '{question}', to_jsonb(r.custom_question));
    base := jsonb_set(base, '{blanks}', to_jsonb(r.custom_blanks));
    base := jsonb_set(base, '{custom_question}', 'true'::jsonb);
  end if;
  if r.mode = 'ondes' and r.wave_variant = 'normal' and r.custom_round = r.round
     and r.custom_wave_left is not null and jsonb_typeof(base->'wave')='object' then
    base := jsonb_set(base, '{wave,left}', to_jsonb(r.custom_wave_left));
    base := jsonb_set(base, '{wave,right}', to_jsonb(r.custom_wave_right));
    base := jsonb_set(base, '{wave,custom}', 'true'::jsonb);
  end if;
  if r.mode = 'mimes' and jsonb_typeof(base->'mime') = 'object' then
    base := jsonb_set(base, '{mime,ready}', to_jsonb(r.mime_ready));
    if r.custom_round = r.round and r.custom_mime_action is not null then
      base := jsonb_set(base, '{mime,action}', to_jsonb(r.custom_mime_action));
      base := jsonb_set(base, '{mime,low}', to_jsonb(r.custom_mime_low));
      base := jsonb_set(base, '{mime,high}', to_jsonb(r.custom_mime_high));
    end if;
    if not r.mime_ready and r.reader_id is distinct from me.id then
      base := jsonb_set(base, '{mime,action}', 'null'::jsonb);
      base := jsonb_set(base, '{mime,low}', 'null'::jsonb);
      base := jsonb_set(base, '{mime,high}', 'null'::jsonb);
      base := jsonb_set(base, '{mime,mine}', 'null'::jsonb);
    end if;
  end if;
  return base::json;
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

  if r.custom_round = r.round and r.custom_question is not null then
    n := r.custom_blanks;
  else
    select blanks into n from public.questions where id = r.question_id;
  end if;
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


CREATE OR REPLACE FUNCTION public.bot_step(p_code text, p_token uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms; b public.players; aid integer; aid2 integer; sid uuid; qid integer; n int; sc int; rd uuid;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id is distinct from me.id then raise exception 'Seul l’hôte pilote les bots.'; end if;

  if r.status = 'question_select' then
    select * into b from public.players where id = r.reader_id and active and is_bot;
    if b.id is not null then
      select x into qid from unnest(r.question_choices) x order by random() limit 1;
      update public.rooms set question_id = qid, used_questions = used_questions || qid,
        question_choices = '{}', status = 'answering', phase_at = now(), updated_at = now() where id = r.id;
    end if;

  elsif r.status = 'answering' then
    if r.custom_round = r.round and r.custom_question is not null then
      n := r.custom_blanks;
    else
      select blanks into n from public.questions where id = r.question_id;
    end if;
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


CREATE OR REPLACE FUNCTION public.mime_bot_step(p_code text, p_token uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms; ids uuid[]; notes integer[];
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.host_id <> me.id then raise exception 'Seul l’hôte pilote les bots.'; end if;
  if r.mode <> 'mimes' or r.status <> 'mime_play' then return; end if;
  if not exists (select 1 from public.players where id = r.reader_id and active and is_bot) then return; end if;
  if not r.mime_ready then
    update public.rooms set mime_ready=true, phase_at=now(),updated_at=now() where id=r.id;
  end if;
  select array_agg(m.player_id), array_agg(greatest(1, least(10, m.intensity - 2 + floor(random() * 5)::integer)))
    into ids, notes
    from public.mime_parts m where m.room_id = r.id and m.round = r.round and m.intensity is not null;
  perform public._mime_score(r.id, coalesce(ids, '{}'), coalesce(notes, '{}'));
end $function$;


CREATE OR REPLACE FUNCTION public.mime_rate(p_code text, p_token uuid, p_players uuid[], p_notes integer[])
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
  if r.mode <> 'mimes' or r.status <> 'mime_play' then raise exception 'Ce n’est pas le moment de noter.'; end if;
  if r.reader_id <> me.id then raise exception 'Seul le juge note les mimes.'; end if;
  if not r.mime_ready then raise exception 'Prépare le mime avant de noter.'; end if;
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
end $function$;


CREATE OR REPLACE FUNCTION public.mime_progress(p_code text, p_token uuid, p_action text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.players; r public.rooms; n integer;
begin
 me:=public._player(p_code,p_token);
 if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
 select * into r from public.rooms where id=me.room_id for update;
 if r.mode<>'mimes' or r.status<>'mime_play' or r.reader_id<>me.id then
   raise exception 'Seul le juge peut diriger les prestations.';
 end if;
 if not r.mime_ready then raise exception 'Prépare le mime avant de commencer.'; end if;
 if p_action<>'next' then raise exception 'Action invalide.'; end if;
 select count(*) into n from public.mime_parts m
  join public.players p on p.id=m.player_id and p.active
  where m.room_id=r.id and m.round=r.round;
 if r.mime_index>=n then raise exception 'Tous les mimes sont passés.'; end if;
 update public.rooms set mime_index=r.mime_index+1,mime_started_at=now(),updated_at=now() where id=r.id;
end $function$;


-- Les signatures existantes conservent leurs grants; les nouvelles ont des grants explicites.
