# Production Planner

Sito: https://vantraxx99.github.io/Productionplanner/

- `index.html` — landing: accesso/registrazione, elenco piani, creazione e impostazioni di un piano (giorni, location, categorie, team e staff, accessi).
- `app.html?p=<id>` — l'app del singolo piano (agenda, timeline, location, task, materiali, export PDF/CSV).
- `config.js` — URL e chiave pubblica (publishable) del progetto Supabase.
- `schema.sql` — tabelle e permessi da eseguire una volta nel SQL Editor di Supabase.
- `sw.js` — funzionamento offline; a ogni rilascio cambia `VERSION` qui e `APP_V` in `app.html`.

Ruoli per piano: proprietario (chi lo crea), admin, solo alcuni campi, sola lettura.

## Statistiche
`stats.sql` (da eseguire dopo `schema.sql`) aggiunge il registro delle modifiche e la pagina Statistiche live,
visibile solo all'account indicato in `is_super()` (roca.filippo1999@gmail.com), che può anche aprire ogni piano in sola lettura.
