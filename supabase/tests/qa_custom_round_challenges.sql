-- Exécuté dans une base PostgreSQL dédiée, jamais dans le projet utilisateur.
BEGIN;
INSERT INTO public.rooms(id,code,round,mode,status,reader_id,host_id,question_choices,wave_target)
VALUES ('10000000-0000-4000-8000-000000000001','TEST1234',1,'phrases','question_select',
        '20000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000002',
        ARRAY[1,2,3,4,5],46);
INSERT INTO public.players(id,room_id,token,seat) VALUES
('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',
 '30000000-0000-4000-8000-000000000001',1),
('20000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001',
 '30000000-0000-4000-8000-000000000002',2);
DO $qa$
DECLARE r public.rooms; s json;
BEGIN
  -- Un autre joueur ne peut pas écrire la phrase.
  BEGIN
    PERFORM public.choose_custom_question('TEST1234',
      '30000000-0000-4000-8000-000000000002','Je veux ____');
    RAISE EXCEPTION 'QA_FAIL : un non-meneur peut modifier le défi';
  EXCEPTION WHEN others THEN
    IF sqlerrm LIKE 'QA_FAIL%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.choose_custom_question('TEST1234',
      '30000000-0000-4000-8000-000000000001','Sans aucun trou');
    RAISE EXCEPTION 'QA_FAIL : une phrase sans trou est acceptée';
  EXCEPTION WHEN others THEN
    IF sqlerrm LIKE 'QA_FAIL%' THEN RAISE; END IF;
  END;
  PERFORM public.choose_custom_question('TEST1234',
    '30000000-0000-4000-8000-000000000001','____ rencontre ____');
  SELECT * INTO r FROM public.rooms WHERE code='TEST1234';
  IF r.status <> 'answering' OR r.custom_blanks <> 2 OR r.question_id IS NOT NULL
     OR cardinality(r.question_choices) <> 0 THEN
    RAISE EXCEPTION 'QA_FAIL : phrase 2 trous ou transition invalide';
  END IF;
  s:=public.get_state('TEST1234','30000000-0000-4000-8000-000000000002');
  IF s->>'question' <> '____ rencontre ____' OR (s->>'blanks')::integer <> 2
    THEN RAISE EXCEPTION 'QA_FAIL : phrase non transmise à tous les joueurs'; END IF;
  -- Nouveau tour : le contenu éphémère est réellement effacé.
  UPDATE public.rooms SET round=2,status='clue',mode='ondes' WHERE code='TEST1234';
  SELECT * INTO r FROM public.rooms WHERE code='TEST1234';
  IF r.custom_question IS NOT NULL OR r.custom_blanks IS NOT NULL OR r.custom_round IS NOT NULL
    THEN RAISE EXCEPTION 'QA_FAIL : phrase conservée au tour suivant'; END IF;
  -- Baromètre : extrêmes, mais la cible 46 ne peut pas changer.
  PERFORM public.choose_custom_wave('TEST1234',
    '30000000-0000-4000-8000-000000000001','Nul au foot','Génie du ballon');
  SELECT * INTO r FROM public.rooms WHERE code='TEST1234';
  IF r.wave_target <> 46 OR r.custom_wave_left <> 'Nul au foot'
     OR r.custom_wave_right <> 'Génie du ballon'
    THEN RAISE EXCEPTION 'QA_FAIL : Baromètre ou cible altérés'; END IF;
  s:=public.get_state('TEST1234','30000000-0000-4000-8000-000000000002');
  IF s->'wave'->>'left'<>'Nul au foot' OR s->'wave'->>'right'<>'Génie du ballon'
    THEN RAISE EXCEPTION 'QA_FAIL : extrêmes non synchronisés'; END IF;
  UPDATE public.rooms SET round=3,mode='mimes',status='mime_play',
    mime_card=7,mime_index=0 WHERE code='TEST1234';
  SELECT * INTO r FROM public.rooms WHERE code='TEST1234';
  IF r.mime_ready OR r.custom_wave_left IS NOT NULL
    THEN RAISE EXCEPTION 'QA_FAIL : préparation Mimes / nettoyage'; END IF;
  s:=public.get_state('TEST1234','30000000-0000-4000-8000-000000000002');
  IF (s->'mime'->>'ready')::boolean OR s->'mime'->>'action' IS NOT NULL
    THEN RAISE EXCEPTION 'QA_FAIL : mime révélé avant le choix du juge'; END IF;
  BEGIN
    PERFORM public.choose_mime_challenge('TEST1234',
      '30000000-0000-4000-8000-000000000002',true,
      'Manger un citron','Délicieux','Acide');
    RAISE EXCEPTION 'QA_FAIL : mime modifiable par un non-juge';
  EXCEPTION WHEN others THEN
    IF sqlerrm LIKE 'QA_FAIL%' THEN RAISE; END IF;
  END;
  PERFORM public.choose_mime_challenge('TEST1234',
    '30000000-0000-4000-8000-000000000001',true,
    'Manger un citron','Délicieux','Acide');
  SELECT * INTO r FROM public.rooms WHERE code='TEST1234';
  IF NOT r.mime_ready OR r.custom_mime_action <> 'Manger un citron'
    THEN RAISE EXCEPTION 'QA_FAIL : mime personnalisé non validé'; END IF;
  s:=public.get_state('TEST1234','30000000-0000-4000-8000-000000000002');
  IF s->'mime'->>'action' <> 'Manger un citron'
    THEN RAISE EXCEPTION 'QA_FAIL : mime personnalisé non visible'; END IF;
  UPDATE public.rooms SET round=4,mode='mimes',status='mime_play' WHERE code='TEST1234';
  SELECT * INTO r FROM public.rooms WHERE code='TEST1234';
  IF r.mime_ready OR r.custom_mime_action IS NOT NULL
    THEN RAISE EXCEPTION 'QA_FAIL : mime non nettoyé'; END IF;
  PERFORM public.choose_mime_challenge('TEST1234',
    '30000000-0000-4000-8000-000000000001',false,NULL,NULL,NULL);
  SELECT * INTO r FROM public.rooms WHERE code='TEST1234';
  IF NOT r.mime_ready OR r.custom_mime_action IS NOT NULL
    THEN RAISE EXCEPTION 'QA_FAIL : mime classique'; END IF;
  RAISE NOTICE 'QA PASS : 3 jeux, droits meneur, cibles préservées, partage et nettoyage par manche';
END $qa$;
ROLLBACK;
