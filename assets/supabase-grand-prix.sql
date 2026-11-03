-- Des chiffres et des lettres — v17 : Grand Prix
-- À lancer une seule fois dans Supabase : SQL Editor > New query > coller ce texte > Run.
-- Autorise l'enregistrement des résultats du Grand Prix (mode 'g') dans les statistiques multijoueur.
alter table public.multi_results drop constraint if exists multi_results_mode_check;
alter table public.multi_results add constraint multi_results_mode_check check (mode in ('o','q','p','g'));
