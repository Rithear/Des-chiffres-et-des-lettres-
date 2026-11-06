-- ============================================================================
-- Des chiffres et des lettres v08 : partie personnalisée en multijoueur
-- À coller en entier dans Supabase > SQL Editor > New query, puis Run.
-- Autorise le nouveau mode « p » (partie personnalisée) dans les résultats multijoueur.
-- Ne touche à aucun résultat déjà enregistré. On peut le relancer sans risque.
-- ============================================================================

-- mode : o = Jeu original, q = Partie rapide, p = Partie personnalisée
alter table public.multi_results drop constraint if exists multi_results_mode_check;
alter table public.multi_results add constraint multi_results_mode_check
  check (mode in ('o','q','p'));

-- game : n/q = partie complète/courte ; l/c/w = jeu de la partie rapide ; p = partie personnalisée
alter table public.multi_results drop constraint if exists multi_results_game_check;
alter table public.multi_results add constraint multi_results_game_check
  check (game in ('n','q','l','c','w','p'));
