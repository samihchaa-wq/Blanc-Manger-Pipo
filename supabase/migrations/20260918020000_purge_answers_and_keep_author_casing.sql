-- 1. La casse d'origine des réponses n'est plus écrasée.
--
-- _clean_card forçait une majuscule initiale sur chaque réponse, ce qui
-- détruisait l'information : à l'affichage, le front devait deviner s'il
-- fallait la retirer pour insérer la réponse en milieu de phrase, et il se
-- trompait sur les noms propres (« Jean-Michel » devenait « jean-Michel »)
-- comme sur les sigles accentués. Les réponses sont désormais stockées telles
-- que tapées, prêtes à s'insérer dans la phrase ; c'est l'affichage qui met la
-- majuscule quand le trou ouvre la phrase.
create or replace function public._clean_card(p_kind text, p_text text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare t text; n int;
begin
  t := regexp_replace(trim(coalesce(p_text, '')), '\s+', ' ', 'g');
  if p_kind = 'q' then
    t := regexp_replace(t, '_{2,}', '____', 'g');
    if length(t) < 5 then raise exception 'La question est trop courte.'; end if;
    if length(t) > 150 then raise exception 'La question dépasse 150 caractères.'; end if;
    n := (length(t) - length(replace(t, '____', ''))) / 4;
    if n = 0 then raise exception 'Ajoute un trou « ____ » à l''endroit de la réponse.'; end if;
    if n > 1 then raise exception 'Une question ne peut contenir qu''un seul trou.'; end if;
  else
    t := regexp_replace(t, '[.]+$', '');
    if length(t) < 1 then raise exception 'La réponse est vide.'; end if;
    if length(t) > 80 then raise exception 'La réponse dépasse 80 caractères.'; end if;
    if position('____' in t) > 0 then raise exception 'Une réponse ne contient pas de trou.'; end if;
  end if;
  return t;
end
$$;
revoke all on function public._clean_card(text, text) from public, anon, authenticated;

-- 2. Suppression réelle de toutes les réponses.
--
-- Pas de deleted_at : les lignes partent de la table. Les parties en cours
-- deviendraient injouables avec des mains vides, elles retournent donc au
-- salon d'attente. Les clés étrangères de hands, submissions et used_answers
-- sont en NO ACTION, l'ordre de suppression compte.
update public.rooms set
  status = 'lobby', round = 0, reader_id = null, previous_reader_id = null,
  question_id = null, question_choices = '{}', winner_id = null,
  winning_submission_id = null, used_questions = '{}', skips_used = 0,
  reward_used = false, reward_kind = null, reward_text = null, updated_at = now();

update public.players set
  ready = is_bot, score = 0, discard_round = 0, next_ack_round = 0, continue_requested = false;

delete from public.submissions;
delete from public.hands;
delete from public.used_answers;
delete from public.answers;

-- L'identifiant repart de 1 : sans cela les nouvelles réponses hériteraient
-- des numéros de celles qu'on vient d'effacer.
select setval(pg_get_serial_sequence('public.answers', 'id'), 1, false);
