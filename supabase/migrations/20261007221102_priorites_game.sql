-- Deuxième jeu : « Priorités ».
-- Un juge par manche, à tour de rôle (1, 2 ou 3 tours chacun). Tout le monde
-- reçoit les mêmes 5 cartes « Réponses » : le juge les classe pour lui-même,
-- les autres classent ce qu'ils pensent qu'il a mis.
-- Points : 1 par carte au bon rang, +2 pour un sans-faute (5/5) ; le juge
-- marque 1 point par joueur qui a trouvé au moins 3 cartes.
-- Le mode « phrases » (jeu d'origine) ne change pas : _begin_round aiguille
-- simplement vers _begin_rank_round quand la salle est en mode « priorites ».

alter table public.rooms
  add column if not exists mode text not null default 'phrases',
  add column if not exists judge_turns integer not null default 2,
  add column if not exists rank_cards integer[] not null default '{}';
alter table public.rooms drop constraint if exists rooms_mode_check;
alter table public.rooms add constraint rooms_mode_check check (mode in ('phrases', 'priorites'));
alter table public.rooms drop constraint if exists rooms_judge_turns_check;
alter table public.rooms add constraint rooms_judge_turns_check check (judge_turns in (1, 2, 3));
alter table public.rooms drop constraint if exists rooms_status_check;
alter table public.rooms add constraint rooms_status_check
  check (status in ('lobby', 'question_select', 'answering', 'judging', 'ranking', 'reveal', 'finished'));

alter table public.players add column if not exists judge_count integer not null default 0;

create table if not exists public.rankings (
  room_id uuid not null references public.rooms(id) on delete cascade,
  round integer not null,
  player_id uuid not null references public.players(id) on delete cascade,
  cards integer[] not null,
  points integer,
  primary key (room_id, round, player_id)
);
alter table public.rankings enable row level security;
revoke all on table public.rankings from public, anon, authenticated;
