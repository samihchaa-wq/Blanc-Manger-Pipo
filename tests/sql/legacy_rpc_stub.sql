-- Banc d'essai PostgreSQL seulement : signatures des anciens RPC.
-- Ne jamais appliquer ce fichier à la base Supabase réelle.
create function public.admin_add_card(text, text, text) returns integer language sql as $$ select 1 $$;
create function public.admin_add_mime_card(text, text, text, text) returns integer language sql as $$ select 1 $$;
create function public.admin_add_wave_card(text, text, text) returns integer language sql as $$ select 1 $$;
create function public.admin_add_white_word(text, text, text) returns integer language sql as $$ select 1 $$;
create function public.admin_check(text) returns integer language sql as $$ select 1 $$;
create function public.admin_delete_card(text, text, integer) returns integer language sql as $$ select 1 $$;
create function public.admin_delete_mime_card(text, integer) returns integer language sql as $$ select 1 $$;
create function public.admin_delete_white_word(text, integer) returns integer language sql as $$ select 1 $$;
create function public.admin_list_cards(text, text, text, integer) returns integer language sql as $$ select 1 $$;
create function public.admin_list_mime_cards(text, text, integer) returns integer language sql as $$ select 1 $$;
create function public.admin_list_white_words(text, text, integer) returns integer language sql as $$ select 1 $$;
create function public.admin_set_card_form(text, integer, text) returns integer language sql as $$ select 1 $$;
create function public.admin_update_card(text, text, integer, text) returns integer language sql as $$ select 1 $$;
create function public.admin_white_add(text, text, text) returns integer language sql as $$ select 1 $$;
create function public.admin_white_delete(text, integer) returns integer language sql as $$ select 1 $$;
create function public.admin_white_list(text, text, integer) returns integer language sql as $$ select 1 $$;
create function public.card_counts() returns integer language sql as $$ select 1 $$;
create function public.force_judging(text, uuid) returns integer language sql as $$ select 1 $$;
create function public.punish_add(text, uuid, text) returns integer language sql as $$ select 1 $$;
create function public.punish_remove(text, uuid, bigint) returns integer language sql as $$ select 1 $$;
create function public.punish_set(text, uuid, boolean) returns integer language sql as $$ select 1 $$;
create function public.punish_start(text, uuid) returns integer language sql as $$ select 1 $$;
create function public.set_ready(text, uuid, boolean) returns integer language sql as $$ select 1 $$;
create function public.start_game(text, uuid) returns integer language sql as $$ select 1 $$;
create function public.white_clue(text, uuid, text) returns integer language sql as $$ select 1 $$;
create function public.white_guess(text, uuid, text) returns integer language sql as $$ select 1 $$;
