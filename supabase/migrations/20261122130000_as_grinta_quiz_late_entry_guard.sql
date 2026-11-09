-- Follow-up: reject any new player after the scheduled kickoff, even if all phones were offline.
create or replace function public.asgq_join(p_code text, p_name text, p_token uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  ev asgq_private.event%rowtype;
  player_row asgq_private.players%rowtype;
  clean_name text;
  generated_token uuid;
  normalized_code text;
begin
  select * into ev from asgq_private.event where id=1 for update;
  if not found then raise exception 'Événement indisponible.'; end if;

  if p_token is not null then
    player_row := asgq_private.player_for(p_token);
    if player_row.id is null then raise exception 'Session inconnue.'; end if;
    update asgq_private.players set last_seen_at=clock_timestamp() where id=player_row.id;
    perform asgq_private.tick();
    return jsonb_build_object('token',p_token,'name',player_row.name);
  end if;

  normalized_code := upper(regexp_replace(coalesce(p_code,''), '[^A-Za-z0-9]', '', 'g'));
  if encode(extensions.digest('asgq:' || normalized_code, 'sha256'),'hex') <> ev.code_hash then
    raise exception 'Code d’entrée incorrect.';
  end if;
  if ev.phase <> 'lobby' or (ev.starts_at is not null and clock_timestamp() >= ev.starts_at) then
    raise exception 'Le quiz a déjà commencé.';
  end if;
  if (select count(*) from asgq_private.players)>=ev.max_players then raise exception 'Le vestiaire est complet.'; end if;
  clean_name := btrim(regexp_replace(coalesce(p_name,''),'\s+',' ','g'));
  if char_length(clean_name) < 2 or char_length(clean_name) > 22 then raise exception 'Prénom : entre 2 et 22 caractères.'; end if;
  if exists(select 1 from asgq_private.players where lower(name)=lower(clean_name)) then
    raise exception 'Ce prénom est déjà pris dans le vestiaire.';
  end if;
  generated_token := gen_random_uuid();
  insert into asgq_private.players(event_id,name,token_hash)
    values (1,clean_name,encode(extensions.digest('asgq-token:' || generated_token::text,'sha256'),'hex'));
  perform asgq_private.tick();
  return jsonb_build_object('token', generated_token, 'name', clean_name);
end $fn$;