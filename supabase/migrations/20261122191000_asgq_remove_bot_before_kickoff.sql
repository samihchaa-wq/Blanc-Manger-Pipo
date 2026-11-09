-- Same as other Soulieteur lobbies: the host may remove an added bot before kickoff.
create or replace function public.asgq_rehearsal_remove_bot(p_token uuid,p_bot_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_rehearsal_private.event%rowtype;
  host_player asgq_rehearsal_private.players%rowtype;
  bot_player asgq_rehearsal_private.players%rowtype;
begin
  select * into ev from asgq_rehearsal_private.event where id=1 for update;
  host_player:=asgq_rehearsal_private.player_for(p_token);
  if host_player.id is null or ev.host_token_hash is distinct from host_player.token_hash then
    raise exception 'Seul le créateur peut retirer les bots.';
  end if;
  if ev.phase<>'lobby' or ev.manual_started then
    raise exception 'La partie a déjà commencé.';
  end if;
  select * into bot_player from asgq_rehearsal_private.players where id=p_bot_id for update;
  if bot_player.id is null or bot_player.bot_order is null then
    raise exception 'Ce joueur n’est pas un bot.';
  end if;
  delete from asgq_rehearsal_private.players where id=p_bot_id;
  return pg_catalog.jsonb_build_object('removed',bot_player.id,'name',bot_player.name);
end $fn$;
revoke execute on function public.asgq_rehearsal_remove_bot(uuid,uuid) from public,anon,authenticated;
grant execute on function public.asgq_rehearsal_remove_bot(uuid,uuid) to anon,authenticated;
