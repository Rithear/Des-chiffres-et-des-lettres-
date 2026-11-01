-- La partie du jour : table des classements (à coller dans Supabase > SQL Editor > Run)
create table if not exists public.daily_scores (
  id bigint generated always as identity primary key,
  day date not null,
  game text not null check (game in ('lf','le','c','wf','we')),
  player_id text not null check (char_length(player_id) between 4 and 40),
  pseudo text not null check (char_length(pseudo) between 1 and 12),
  result integer not null check (result between 0 and 9999),
  detail text check (char_length(detail) <= 20),
  time_cs integer not null check (time_cs between 0 and 12100),
  created_at timestamptz not null default now(),
  unique (day, game, player_id)
);

alter table public.daily_scores enable row level security;

-- Tout le monde peut lire les classements
create policy "Lecture pour tous" on public.daily_scores
  for select using (true);

-- On ne peut ajouter qu'un résultat du jour (ou de la veille), jamais modifier ni supprimer
create policy "Ajout du jour" on public.daily_scores
  for insert with check (
    day between (now() at time zone 'Europe/Paris')::date - 1
            and (now() at time zone 'Europe/Paris')::date
  );

grant select, insert on public.daily_scores to anon;
