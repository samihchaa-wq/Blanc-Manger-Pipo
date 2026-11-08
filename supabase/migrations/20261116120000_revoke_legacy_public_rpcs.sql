-- Exposition minimale : ces 26 anciens RPC SECURITY DEFINER ne sont plus
-- appelés par l'application. Le propriétaire postgres conserve EXECUTE, donc
-- les appels internes depuis les fonctions serveur continuent de fonctionner.
-- Une API non utilisée ne doit pas rester publiquement invocable.
begin;

revoke execute on function public.admin_add_card(text, text, text) from PUBLIC, anon, authenticated;
revoke execute on function public.admin_add_mime_card(text, text, text, text) from PUBLIC, anon, authenticated;
revoke execute on function public.admin_add_wave_card(text, text, text) from PUBLIC, anon, authenticated;
revoke execute on function public.admin_add_white_word(text, text, text) from PUBLIC, anon, authenticated;
revoke execute on function public.admin_check(text) from PUBLIC, anon, authenticated;
revoke execute on function public.admin_delete_card(text, text, integer) from PUBLIC, anon, authenticated;
revoke execute on function public.admin_delete_mime_card(text, integer) from PUBLIC, anon, authenticated;
revoke execute on function public.admin_delete_white_word(text, integer) from PUBLIC, anon, authenticated;
revoke execute on function public.admin_list_cards(text, text, text, integer) from PUBLIC, anon, authenticated;
revoke execute on function public.admin_list_mime_cards(text, text, integer) from PUBLIC, anon, authenticated;
revoke execute on function public.admin_list_white_words(text, text, integer) from PUBLIC, anon, authenticated;
revoke execute on function public.admin_set_card_form(text, integer, text) from PUBLIC, anon, authenticated;
revoke execute on function public.admin_update_card(text, text, integer, text) from PUBLIC, anon, authenticated;
revoke execute on function public.admin_white_add(text, text, text) from PUBLIC, anon, authenticated;
revoke execute on function public.admin_white_delete(text, integer) from PUBLIC, anon, authenticated;
revoke execute on function public.admin_white_list(text, text, integer) from PUBLIC, anon, authenticated;
revoke execute on function public.card_counts() from PUBLIC, anon, authenticated;
revoke execute on function public.force_judging(text, uuid) from PUBLIC, anon, authenticated;
revoke execute on function public.punish_add(text, uuid, text) from PUBLIC, anon, authenticated;
revoke execute on function public.punish_remove(text, uuid, bigint) from PUBLIC, anon, authenticated;
revoke execute on function public.punish_set(text, uuid, boolean) from PUBLIC, anon, authenticated;
revoke execute on function public.punish_start(text, uuid) from PUBLIC, anon, authenticated;
revoke execute on function public.set_ready(text, uuid, boolean) from PUBLIC, anon, authenticated;
revoke execute on function public.start_game(text, uuid) from PUBLIC, anon, authenticated;
revoke execute on function public.white_clue(text, uuid, text) from PUBLIC, anon, authenticated;
revoke execute on function public.white_guess(text, uuid, text) from PUBLIC, anon, authenticated;

commit;
