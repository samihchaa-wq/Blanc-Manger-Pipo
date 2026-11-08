-- Vérifie la fermeture des 26 fonctions, sans fermer les API utilisées.
begin;
do $audit$
declare n integer;
begin
  select count(*) into n from pg_proc p
  where p.pronamespace='public'::regnamespace
    and p.proname in ('admin_add_card','admin_add_mime_card','admin_add_wave_card','admin_add_white_word','admin_check','admin_delete_card','admin_delete_mime_card','admin_delete_white_word','admin_list_cards','admin_list_mime_cards','admin_list_white_words','admin_set_card_form','admin_update_card','admin_white_add','admin_white_delete','admin_white_list','card_counts','force_judging','punish_add','punish_remove','punish_set','punish_start','set_ready','start_game','white_clue','white_guess')
    and has_function_privilege('anon',p.oid,'EXECUTE');
  if n<>0 then raise exception 'RPC obsolètes encore anonymes : %',n; end if;
  if not has_function_privilege('anon','public.create_room(text,integer,text,integer)','EXECUTE') then
    raise exception 'La création de salon est devenue inaccessible';
  end if;
  if not has_function_privilege('anon','public.join_room(text,text)','EXECUTE') then
    raise exception 'Le salon est devenu inaccessible';
  end if;
end $audit$;
rollback;
