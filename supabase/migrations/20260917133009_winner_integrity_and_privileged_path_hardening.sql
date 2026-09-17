-- Applied to production on 2026-09-17.
-- Prevents selecting a departed player as winner and removes pseudo-based privilege assumptions.

create or replace function public.pick_winner(p_code text, p_token uuid, p_submission_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare me public.players; r public.rooms; w uuid; sc integer;
begin
  me := public._player(p_code, p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id = me.room_id for update;
  if r.reader_id <> me.id then raise exception 'Seul le lecteur choisit la gagnante.'; end if;
  if r.status <> 'judging' then raise exception 'Ce n''est pas le moment de voter.'; end if;
  select s.player_id into w from public.submissions s join public.players p on p.id=s.player_id and p.active
    where s.id=p_submission_id and s.room_id=r.id and s.round=r.round;
  if w is null then raise exception 'Réponse introuvable ou joueur parti.'; end if;
  update public.players set score=score+1 where id=w and active returning score into sc;
  if sc is null then raise exception 'Le joueur n''est plus actif.'; end if;
  update public.rooms set status=case when sc >= r.target_score then 'finished' else 'reveal' end,
    winner_id=w, winning_submission_id=p_submission_id, updated_at=now() where id=r.id;
end $$;

create or replace function public.add_reward_card(p_code text, p_token uuid, p_kind text, p_text text)
returns json language plpgsql security definer set search_path = '' as $$
declare me public.players; r public.rooms; res json;
begin
  me := public._player(p_code,p_token);
  if me.id is null then raise exception 'Session expirée. Rejoins la partie à nouveau.'; end if;
  select * into r from public.rooms where id=me.room_id for update;
  if r.status <> 'finished' or r.winner_id <> me.id then raise exception 'Seul le gagnant peut créer la carte bonus.'; end if;
  if r.reward_used then raise exception 'La carte bonus a déjà été créée.'; end if;
  if p_kind='q' then res := public.add_question(p_text,me.name);
  elsif p_kind='a' then res := public.add_answer(p_text,me.name);
  else raise exception 'Type de carte inconnu.'; end if;
  update public.rooms set reward_used=true,reward_kind=p_kind,reward_text=res->>'text',updated_at=now() where id=r.id;
  return res;
end $$;
