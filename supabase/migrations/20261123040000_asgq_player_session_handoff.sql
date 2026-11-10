-- AS Grinta Grand Quiz: secure one-time transfer of an EXISTING player's session.
-- The host issues an ephemeral eight-digit handoff code to a selected player.
-- Reclaiming requires the room code, that player's name AND the host-issued code.
-- No guest can recover by knowing only a publicly shared room code and name.
-- This migration does not reset the official game, scores, phases or questions.

create table if not exists asgq_private.player_handoffs (
  player_id uuid primary key references asgq_private.players(id) on delete cascade,
  code_hash text not null,
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null
);
alter table asgq_private.player_handoffs enable row level security;
revoke all on asgq_private.player_handoffs from public, anon, authenticated;

create table if not exists asgq_private.player_handoff_attempts (
  client_hash text primary key,
  window_started_at timestamptz not null default clock_timestamp(),
  attempts integer not null default 0,
  failures integer not null default 0
);
alter table asgq_private.player_handoff_attempts enable row level security;
revoke all on asgq_private.player_handoff_attempts from public, anon, authenticated;

create or replace function public.asgq_issue_player_handoff(p_host_token uuid,p_player_id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_private.event%rowtype;
  host_player asgq_private.players%rowtype;
  target_player asgq_private.players%rowtype;
  v_code text;
  v_hash text;
begin
  host_player:=asgq_private.player_for(p_host_token);
  select * into ev from asgq_private.event where id=1 for update;
  if host_player.id is null or ev.host_token_hash is distinct from host_player.token_hash then
    raise exception 'Accès réservé à l’animateur.';
  end if;
  select * into target_player from asgq_private.players
    where id=p_player_id and event_id=1
      and token_hash is distinct from ev.host_token_hash for update;
  if target_player.id is null then
    raise exception 'Joueur introuvable.';
  end if;
  v_code:=asgq_private.new_room_code();
  v_hash:=pg_catalog.encode(
    extensions.digest('asgq-handoff:'||target_player.id::text||':'||v_code,'sha256'),'hex');
  insert into asgq_private.player_handoffs(player_id,code_hash,created_at,expires_at)
    values(target_player.id,v_hash,clock_timestamp(),clock_timestamp()+interval '10 minutes')
    on conflict (player_id) do update
      set code_hash=excluded.code_hash,created_at=excluded.created_at,
          expires_at=excluded.expires_at;
  return pg_catalog.jsonb_build_object(
    'name',target_player.name,'code',v_code,'minutes',10);
end $fn$;

create or replace function public.asgq_claim_player_handoff(
  p_room_code text,p_player_name text,p_handoff_code text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_private.event%rowtype;
  target_player asgq_private.players%rowtype;
  ticket asgq_private.player_handoffs%rowtype;
  v_room_code text;
  v_handoff_code text;
  v_name text;
  v_client_hash text;
  v_requests integer;
  v_failures integer;
  v_hash text;
  v_token uuid;
begin
  v_client_hash:=public._client_hash();
  if v_client_hash is null or length(v_client_hash)=0 then
    return pg_catalog.jsonb_build_object('error','Récupération indisponible sur cette connexion.');
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('asgq-handoff-claim:'||v_client_hash,0));
  insert into asgq_private.player_handoff_attempts(
    client_hash,window_started_at,attempts,failures)
    values(v_client_hash,clock_timestamp(),1,0)
    on conflict (client_hash) do update
      set attempts=case
          when asgq_private.player_handoff_attempts.window_started_at
                < clock_timestamp()-interval '10 minutes'
          then 1 else asgq_private.player_handoff_attempts.attempts+1 end,
          failures=case
          when asgq_private.player_handoff_attempts.window_started_at
                < clock_timestamp()-interval '10 minutes'
          then 0 else asgq_private.player_handoff_attempts.failures end,
          window_started_at=case
          when asgq_private.player_handoff_attempts.window_started_at
                < clock_timestamp()-interval '10 minutes'
          then clock_timestamp() else asgq_private.player_handoff_attempts.window_started_at end
    returning attempts,failures into v_requests,v_failures;
  if v_requests>60 or v_failures>=15 then
    return pg_catalog.jsonb_build_object(
      'error','Trop de tentatives. Réessaie dans quelques minutes.');
  end if;

  v_room_code:=pg_catalog.regexp_replace(coalesce(p_room_code,''),'[^0-9]','','g');
  v_handoff_code:=pg_catalog.regexp_replace(coalesce(p_handoff_code,''),'[^0-9]','','g');
  v_name:=pg_catalog.btrim(coalesce(p_player_name,''));

  select * into ev from asgq_private.event where id=1;
  if ev.created and ev.room_code=v_room_code
     and v_room_code ~ '^[0-9]{8}$' and v_handoff_code ~ '^[0-9]{8}$'
     and pg_catalog.char_length(v_name) between 2 and 22 then
    select * into target_player from asgq_private.players
      where event_id=1 and lower(name)=lower(v_name)
        and token_hash is distinct from ev.host_token_hash for update;
    if target_player.id is not null then
      select * into ticket from asgq_private.player_handoffs
        where player_id=target_player.id for update;
      v_hash:=pg_catalog.encode(
        extensions.digest('asgq-handoff:'||target_player.id::text||':'||v_handoff_code,
          'sha256'),'hex');
      if ticket.player_id is not null and ticket.expires_at>clock_timestamp()
          and ticket.code_hash=v_hash then
        v_token:=pg_catalog.gen_random_uuid();
        update asgq_private.players
          set token_hash=pg_catalog.encode(
            extensions.digest('asgq-token:'||v_token::text,'sha256'),'hex'),
            last_seen_at=clock_timestamp()
          where id=target_player.id;
        delete from asgq_private.player_handoffs where player_id=target_player.id;
        return pg_catalog.jsonb_build_object(
          'token',v_token,'name',target_player.name,'code',ev.room_code);
      end if;
    end if;
  end if;

  update asgq_private.player_handoff_attempts set failures=failures+1
    where client_hash=v_client_hash;
  perform pg_catalog.pg_sleep(0.15);
  return pg_catalog.jsonb_build_object(
    'error','Code de récupération incorrect ou expiré. Demande un nouveau code à l’animateur.');
end $fn$;

revoke execute on function public.asgq_issue_player_handoff(uuid,uuid) from public, anon, authenticated;
revoke execute on function public.asgq_claim_player_handoff(text,text,text) from public, anon, authenticated;
grant execute on function public.asgq_issue_player_handoff(uuid,uuid) to anon, authenticated;
grant execute on function public.asgq_claim_player_handoff(text,text,text) to anon, authenticated;
