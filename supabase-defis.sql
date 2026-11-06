-- ============================================================================
-- Des chiffres et des lettres v09 : les défis en multijoueur
-- À coller en entier dans Supabase > SQL Editor > New query, puis Run.
-- Autorise les nouveaux jeux dans les résultats multijoueur (Partie rapide) :
--   t = Défi thème, k = Défi calcul mental (u et s sont réservés au lot 2 :
--   l'un dans l'autre et orthographe, pour ne pas avoir à relancer de script).
-- Ne touche à aucun résultat déjà enregistré. On peut le relancer sans risque.
-- ============================================================================

-- game : n/q = partie complète/courte ; l/c/w = jeu de la partie rapide ; p = partie personnalisée ;
--        t/k = défis thème / calcul mental ; u/s = défis du lot 2
alter table public.multi_results drop constraint if exists multi_results_game_check;
alter table public.multi_results add constraint multi_results_game_check
  check (game in ('n','q','l','c','w','p','t','k','u','s'));
