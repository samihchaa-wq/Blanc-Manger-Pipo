-- Re-use the smallest available bot number when bots are removed.
-- Prevents a full squad with multiple bot replacements from hitting a false limit.
create or replace function public.asgq_rehearsal_add_bot(p_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  player_row asgq_rehearsal_private.players%rowtype;
  next_number integer;
  bot_name text;
begin
  select * into ev from asgq_rehearsal_private.event where id=1 for update;
  player_row := asgq_rehearsal_private.player_for(p_token);
  if player_row.id is null or ev.host_token_hash is distinct from player_row.token_hash
    then raise exception 'Seul le créateur peut ajouter des bots.'; end if;
  if ev.phase<>'lobby' or ev.manual_started then raise exception 'La partie a déjà commencé.'; end if;
  if (select count(*) from asgq_rehearsal_private.players)>=ev.max_players
    then raise exception 'Le salon est complet.'; end if;
  select min(slot.n) into next_number
    from pg_catalog.generate_series(1,20) as slot(n)
    where not exists (
      select 1 from asgq_rehearsal_private.players p where p.bot_order=slot.n
    );
  if next_number is null then raise exception 'Maximum 20 bots pour cette répétition.'; end if;
  bot_name := 'Bot '||pg_catalog.lpad(next_number::text,2,'0');
  if exists(select 1 from asgq_rehearsal_private.players where lower(name)=lower(bot_name))
    then raise exception 'Ce nom de bot est déjà utilisé.'; end if;
  insert into asgq_rehearsal_private.players(event_id,name,token_hash,bot_order)
    values(1,bot_name,
      pg_catalog.encode(extensions.digest('asgq-rehearsal-bot:'||pg_catalog.gen_random_uuid()::text,'sha256'),'hex'),
      next_number);
  return pg_catalog.jsonb_build_object('name',bot_name,'bots',(select count(*) from asgq_rehearsal_private.players where bot_order is not null));
end $fn$;

revoke execute on function public.asgq_rehearsal_add_bot(uuid) from public,anon,authenticated;
grant execute on function public.asgq_rehearsal_add_bot(uuid) to anon,authenticated;
