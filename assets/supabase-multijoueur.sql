-- ============================================================================
-- Des chiffres et des lettres v06 : résultats du multijoueur en direct
-- À coller en entier dans Supabase > SQL Editor > New query, puis Run.
-- Ne touche à rien d'existant (comptes, amis, classements du jour). On peut le relancer sans risque.
-- Les salons eux-mêmes n'ont besoin d'aucune table : ils passent par Supabase Realtime.
-- ============================================================================

create table if not exists public.multi_results (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  gid text not null check (char_length(gid) between 6 and 40),       -- identifiant de la partie
  mode text not null check (mode in ('o','q')),                      -- o = Jeu original, q = Partie rapide
  game text not null check (game in ('n','q','l','c','w')),          -- n/q = partie complète/courte ; l/c/w = jeu de la partie rapide
  dict text check (dict in ('fr','en')),
  rank integer not null check (rank between 1 and 64),
  players integer not null check (players between 1 and 64),
  points integer not null check (points between 0 and 9999),
  detail text check (char_length(detail) <= 20),
  created_at timestamptz not null default now(),
  unique (user_id, gid)
);
create index if not exists multi_results_user_idx on public.multi_results (user_id, created_at desc);
alter table public.multi_results enable row level security;
revoke all on public.multi_results from anon, authenticated;

-- Enregistrer mon résultat à la fin d'une partie (compte connecté uniquement)
create or replace function public.submit_multi(p_gid text, p_mode text, p_game text, p_dict text,
  p_rank integer, p_players integer, p_points integer, p_detail text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'NOT_LOGGED'; end if;
  insert into public.multi_results (user_id, gid, mode, game, dict, rank, players, points, detail)
  values (uid, p_gid, p_mode, p_game, p_dict, p_rank, greatest(p_players, p_rank), p_points, left(coalesce(p_detail, ''), 20))
  on conflict (user_id, gid) do nothing;
  return true;
end $$;

-- Mes 30 dernières parties multijoueur (menu Records)
create or replace function public.my_multi()
returns table (created_at timestamptz, mode text, game text, dict text, rank integer, players integer, points integer, detail text)
language sql security definer set search_path = '' stable as $$
  select m.created_at, m.mode, m.game, m.dict, m.rank, m.players, m.points, m.detail
  from public.multi_results m
  where m.user_id = auth.uid()
  order by m.created_at desc
  limit 30
$$;

grant execute on function public.submit_multi(text, text, text, text, integer, integer, integer, text) to authenticated;
grant execute on function public.my_multi() to authenticated;
