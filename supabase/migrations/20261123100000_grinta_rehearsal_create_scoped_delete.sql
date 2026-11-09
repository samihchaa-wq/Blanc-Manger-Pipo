-- Fix creation error: the database safety layer forbids unscoped DELETE.
-- The delete is limited to rehearsal participants and the isolated rate-limit table.
-- No statements touch asgq_private (the real one-night quiz).
create or replace function public.asgq_rehearsal_create(
 p_password text, p_name text, p_bots integer default 0
) returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  invite_secret text;
  joined jsonb;
  public_code text;
  i integer;
begin
  if not public._is_admin_plus(p_password) then raise exception 'Mot de passe Admin+ incorrect.'; end if;
  if p_bots is null or p_bots < 0 or p_bots > 20 then raise exception 'Nombre de bots non autorisé.'; end if;
  select * into ev from asgq_rehearsal_private.event where id=1 for update;
  if not found then raise exception 'Répétition indisponible.'; end if;
  if ev.phase not in ('lobby','finished') then raise exception 'Une répétition est en cours.'; end if;
  delete from asgq_rehearsal_private.players where event_id=1;
  delete from asgq_rehearsal_private.join_attempts where client_hash is not null;
  public_code := asgq_rehearsal_private.new_room_code();
  update asgq_rehearsal_private.event
    set created=true,armed=true,room_code=public_code,
        phase='lobby',phase_started_at=null,phase_until=null,starts_at=null,
        current_position=0,manual_started=false,host_token_hash=null,
        intro_seconds=7, question_seconds=25, reveal_seconds=9, halftime_seconds=40
    where id=1;
  select plaintext_code into invite_secret from asgq_rehearsal_private.invitation where event_id=1;
  if invite_secret is null then raise exception 'Partie indisponible.'; end if;
  joined := public.asgq_rehearsal_join(invite_secret,p_name,null);
  update asgq_rehearsal_private.event set host_token_hash =
    pg_catalog.encode(extensions.digest('asgq-token:'||(joined->>'token'),'sha256'),'hex')
    where id=1;
  for i in 1..p_bots loop
    insert into asgq_rehearsal_private.players(event_id,name,token_hash,bot_order)
    values (1,'Bot '||pg_catalog.lpad(i::text,2,'0'),
      pg_catalog.encode(extensions.digest('asgq-rehearsal-bot:'||pg_catalog.gen_random_uuid()::text,'sha256'),'hex'),i);
  end loop;
  return joined || pg_catalog.jsonb_build_object('code',public_code);
end $fn$;

-- Keep the old two-argument overload inaccessible. The client always sends p_bots=0.
revoke execute on function public.asgq_rehearsal_create(text,text) from public, anon, authenticated;
revoke execute on function public.asgq_rehearsal_create(text,text,integer) from public, anon, authenticated;
grant execute on function public.asgq_rehearsal_create(text,text,integer) to anon, authenticated;
