-- Corrective follow-up: join attempts are shared by multiple players on the same Wi-Fi.
-- Match the existing Soulieteur thresholds: 48 requests or 8 failures / 10 minutes.
-- Also avoid ambiguous PL/pgSQL variable / column names in ON CONFLICT.
alter table asgq_private.join_attempts
  add column if not exists failures integer not null default 0;

create or replace function public.asgq_join_room(p_code text, p_name text)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_private.event%rowtype;
  normalized_code text;
  private_code text;
  v_client_hash text;
  v_requests integer;
  v_failures integer;
  joined jsonb;
begin
  normalized_code := regexp_replace(coalesce(p_code,''),'[^0-9]','','g');
  v_client_hash := public._client_hash();
  if v_client_hash is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('asgq-join:'||v_client_hash,0));
    insert into asgq_private.join_attempts(client_hash,window_started_at,attempts,failures)
      values(v_client_hash,clock_timestamp(),1,0)
      on conflict on constraint join_attempts_pkey do update
        set attempts=case when asgq_private.join_attempts.window_started_at < clock_timestamp() - interval '10 minutes'
                          then 1 else asgq_private.join_attempts.attempts+1 end,
            failures=case when asgq_private.join_attempts.window_started_at < clock_timestamp() - interval '10 minutes'
                          then 0 else asgq_private.join_attempts.failures end,
            window_started_at=case when asgq_private.join_attempts.window_started_at < clock_timestamp() - interval '10 minutes'
                          then clock_timestamp() else asgq_private.join_attempts.window_started_at end
      returning attempts, failures into v_requests,v_failures;
    if v_requests>48 or v_failures>=8 then
      return pg_catalog.jsonb_build_object('error','Trop de tentatives. Réessaie dans quelques minutes.');
    end if;
  end if;

  select * into ev from asgq_private.event where id=1;
  if ev.id is null or not ev.created then
    return pg_catalog.jsonb_build_object('error','La partie AS Grinta n’a pas encore été créée.');
  end if;
  if length(normalized_code)<>8 or normalized_code <> ev.room_code then
    if v_client_hash is not null then
      update asgq_private.join_attempts set failures=failures+1
      where join_attempts.client_hash=v_client_hash;
    end if;
    perform pg_catalog.pg_sleep(0.15);
    return pg_catalog.jsonb_build_object('error','Code de partie incorrect.');
  end if;
  select plaintext_code into private_code from asgq_private.invitation where event_id=1;
  if private_code is null then raise exception 'Événement non configuré.'; end if;
  joined := public.asgq_join(private_code,p_name,null);
  return joined || pg_catalog.jsonb_build_object('code',ev.room_code);
end $fn$;

revoke execute on function public.asgq_join_room(text,text) from public, anon, authenticated;
grant execute on function public.asgq_join_room(text,text) to anon, authenticated;
