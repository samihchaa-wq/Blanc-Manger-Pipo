-- Grand Quiz AS Grinta: Admin+-verified recovery of the EXISTING official host.
-- No new participant, no event reset, no change to questions, scores or phase.
-- A successful recovery rotates the host's bearer token: the old phone loses control.
-- This RPC is intentionally NOT a "join" route for invited players.

create table if not exists asgq_private.host_recovery_attempts (
  client_hash text primary key,
  window_started_at timestamptz not null default clock_timestamp(),
  attempts integer not null default 0
);
alter table asgq_private.host_recovery_attempts enable row level security;
revoke all on asgq_private.host_recovery_attempts from public, anon, authenticated;

create or replace function public.asgq_recover_host(p_password text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  v_client_hash text;
  v_attempts integer;
  ev asgq_private.event%rowtype;
  host_player asgq_private.players%rowtype;
  v_token uuid;
  v_token_hash text;
begin
  -- Rate limit before checking Admin+, fail closed if a client cannot be identified.
  v_client_hash:=public._client_hash();
  if v_client_hash is null or length(v_client_hash)=0 then
    return pg_catalog.jsonb_build_object('error','Récupération indisponible sur cette connexion.');
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('asgq-recover-host:'||v_client_hash,0));
  insert into asgq_private.host_recovery_attempts(client_hash,window_started_at,attempts)
  values(v_client_hash,clock_timestamp(),1)
  on conflict (client_hash) do update
    set attempts=case when asgq_private.host_recovery_attempts.window_started_at
          < clock_timestamp()-interval '10 minutes'
          then 1 else asgq_private.host_recovery_attempts.attempts+1 end,
        window_started_at=case when asgq_private.host_recovery_attempts.window_started_at
          < clock_timestamp()-interval '10 minutes'
          then clock_timestamp() else asgq_private.host_recovery_attempts.window_started_at end
  returning attempts into v_attempts;
  if v_attempts>5 then
    return pg_catalog.jsonb_build_object(
      'error','Trop de tentatives. Réessaie dans dix minutes.');
  end if;
  if not public._is_admin_plus(p_password) then
    perform pg_catalog.pg_sleep(0.2);
    return pg_catalog.jsonb_build_object('error','Mot de passe Admin+ incorrect.');
  end if;

  select * into ev from asgq_private.event where id=1 for update;
  if ev.id is null or not ev.created or ev.host_token_hash is null then
    return pg_catalog.jsonb_build_object('error','Aucune émission officielle à reprendre.');
  end if;

  select * into host_player from asgq_private.players
    where event_id=1 and token_hash=ev.host_token_hash for update;
  if host_player.id is null then
    return pg_catalog.jsonb_build_object('error','Animateur introuvable. Contacte l’administrateur.');
  end if;

  v_token:=pg_catalog.gen_random_uuid();
  v_token_hash:=pg_catalog.encode(
    extensions.digest('asgq-token:'||v_token::text,'sha256'),'hex');
  update asgq_private.players set token_hash=v_token_hash,last_seen_at=clock_timestamp()
    where id=host_player.id;
  update asgq_private.event set host_token_hash=v_token_hash where id=1;

  return pg_catalog.jsonb_build_object(
    'token',v_token,'name',host_player.name,'code',ev.room_code);
end $fn$;

revoke execute on function public.asgq_recover_host(text) from public, anon, authenticated;
grant execute on function public.asgq_recover_host(text) to anon, authenticated;
