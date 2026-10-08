-- Priorités : un prénom seul ne se classe pas, « Le prénom Dylan » si.
update public.priority_cards
set text = 'Le prénom ' || text
where theme = 'prénom' and text not ilike 'le prénom %';
