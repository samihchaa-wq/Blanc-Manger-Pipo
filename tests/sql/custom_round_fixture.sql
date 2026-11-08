-- PostgreSQL isolé : petite base temporaire pour tester la migration des défis.
DO $roles$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN; END IF;
END $roles$;
CREATE TABLE public.rooms(
  id uuid PRIMARY KEY,
  code text NOT NULL UNIQUE,
  round integer NOT NULL DEFAULT 0,
  mode text NOT NULL,
  status text NOT NULL,
  reader_id uuid,
  host_id uuid,
  wave_variant text NOT NULL DEFAULT 'normal',
  wave_clue text,
  wave_theme text,
  wave_asker uuid,
  wave_target integer,
  mime_index integer NOT NULL DEFAULT 0,
  mime_started_at timestamptz,
  mime_card integer,
  question_id integer,
  question_choices integer[] NOT NULL DEFAULT '{}',
  time_mode text NOT NULL DEFAULT 'medium',
  dilemme_variant text NOT NULL DEFAULT 'aleatoire',
  phrases_variant text NOT NULL DEFAULT 'normal',
  phase_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
CREATE TABLE public.players(
  id uuid PRIMARY KEY,
  room_id uuid NOT NULL,
  token uuid NOT NULL UNIQUE,
  active boolean NOT NULL DEFAULT true,
  seat integer NOT NULL
);
CREATE TABLE public.mime_cards(
  id integer PRIMARY KEY,
  action text,
  low_text text,
  high_text text
);
CREATE TABLE public.mime_parts(
  room_id uuid,round integer,player_id uuid,intensity integer,
  guess integer,points integer
);
CREATE OR REPLACE FUNCTION public._player(p_code text,p_token uuid)
RETURNS public.players LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT p.* FROM public.players p JOIN public.rooms r ON r.id=p.room_id
  WHERE r.code=p_code AND p.token=p_token AND p.active;
$$;
CREATE OR REPLACE FUNCTION public._maybe_judge(p_room uuid)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN END $$;
CREATE OR REPLACE FUNCTION public._time_phase_seconds(r public.rooms)
RETURNS integer LANGUAGE sql STABLE AS $$ SELECT NULL::integer $$;
CREATE OR REPLACE FUNCTION public._get_state_base(p_code text,p_token uuid)
RETURNS json LANGUAGE sql STABLE AS $$
  SELECT json_build_object(
    'room',json_build_object('status',r.status,'round',r.round,'reader_id',r.reader_id),
    'question',NULL,'blanks',1,
    'wave',json_build_object('left','Froid','right','Chaud','target',r.wave_target),
    'mime',json_build_object('action','Action normale'))
  FROM public.rooms r WHERE r.code=p_code;
$$;
