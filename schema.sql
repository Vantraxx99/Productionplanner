-- Production Planner: schema per più piani di produzione
-- Da eseguire una volta nel SQL Editor del progetto Supabase.

create extension if not exists pgcrypto;

-- ---------- piani ----------
create table if not exists public.piani (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  cliente     text not null default '',
  sottotitolo text not null default '',
  colore      text not null default '#2E7BE6',
  giorni      jsonb not null default '[]'::jsonb,   -- [{"d":"2026-10-24","lbl":"Opening","ph":"pre|ev|post"}]
  categorie   jsonb not null default '[]'::jsonb,   -- [["Entertainment","#2E7BE6"], ...]
  teams       jsonb not null default '[]'::jsonb,   -- ["Service","Produzione", ...]
  staff       jsonb not null default '{}'::jsonb,   -- {"Produzione":["Nome Cognome", ...]}
  locations   jsonb not null default '[]'::jsonb,   -- ["Teatro","Sala A", ...]
  taglio      int  not null default 360,            -- fine della giornata operativa, in minuti (360 = 06:00)
  archiviato  boolean not null default false,
  owner       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---------- persone con accesso a un piano ----------
create table if not exists public.membri (
  piano_id uuid not null references public.piani(id) on delete cascade,
  email    text not null,
  ruolo    text not null default 'lettura' check (ruolo in ('admin','campi','lettura')),
  nome     text not null default '',
  primary key (piano_id, email)
);
create or replace function public.membri_lower() returns trigger language plpgsql as $$
begin new.email := lower(trim(new.email)); return new; end $$;
drop trigger if exists trg_membri_lower on public.membri;
create trigger trg_membri_lower before insert or update on public.membri for each row execute function public.membri_lower();

-- ---------- voci del piano ----------
create table if not exists public.voci (
  id           uuid primary key default gen_random_uuid(),
  piano_id     uuid not null references public.piani(id) on delete cascade,
  giorno       date,
  inizio       text not null default '',
  fine         text not null default '',
  area         text not null default '',
  team         text not null default '',
  categoria    text not null default '',
  location     text not null default '',
  attivita     text not null default '',
  responsabile text not null default '',
  fornitore    text not null default '',
  materiali    text not null default '',
  materiali_ok boolean not null default false,
  lingua       text not null default '',
  stato        text not null default 'Da confermare',
  note         text not null default '',
  updated_at   timestamptz not null default now(),
  updated_by   text not null default ''
);
create index if not exists voci_piano on public.voci(piano_id, giorno);

-- ---------- daily task ----------
create table if not exists public.task (
  id         uuid primary key default gen_random_uuid(),
  piano_id   uuid not null references public.piani(id) on delete cascade,
  giorno     date not null,
  testo      text not null,
  chi        text not null default '',
  fatto      boolean not null default false,
  ordine     int not null default 0,
  created_at timestamptz not null default now(),
  updated_by text not null default ''
);
create index if not exists task_piano on public.task(piano_id, giorno);

-- ---------- ruolo dell'utente collegato su un piano ----------
-- owner = chi ha creato il piano; poi admin / campi / lettura dalla tabella membri; null = nessun accesso
create or replace function public.ruolo(p uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from piani where id = p and owner = auth.uid()) then 'owner'
    else (select ruolo from membri where piano_id = p and email = lower(auth.jwt()->>'email'))
  end;
$$;
grant execute on function public.ruolo(uuid) to authenticated;

-- aggiorna updated_at
create or replace function public.tocca() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists trg_piani_tocca on public.piani;
create trigger trg_piani_tocca before update on public.piani for each row execute function public.tocca();
drop trigger if exists trg_voci_tocca on public.voci;
create trigger trg_voci_tocca before update on public.voci for each row execute function public.tocca();

-- chi ha ruolo "campi" non può cambiare titolo, giorno, orari, location, categoria, team, lingua, stato;
-- nessuno può spostare una voce o un task in un altro piano
create or replace function public.blocca_campi() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.piano_id is distinct from old.piano_id then
    raise exception 'Non si può spostare in un altro piano';
  end if;
  if public.ruolo(new.piano_id) = 'campi' and (
     new.attivita is distinct from old.attivita or new.giorno is distinct from old.giorno or
     new.inizio is distinct from old.inizio or new.fine is distinct from old.fine or
     new.location is distinct from old.location or new.area is distinct from old.area or
     new.team is distinct from old.team or new.lingua is distinct from old.lingua or
     new.stato is distinct from old.stato) then
    raise exception 'Con il tuo accesso puoi modificare solo staff, responsabile, materiali e note';
  end if;
  return new;
end $$;
drop trigger if exists trg_voci_campi on public.voci;
create trigger trg_voci_campi before update on public.voci for each row execute function public.blocca_campi();

create or replace function public.blocca_task() returns trigger language plpgsql as $$
begin
  if new.piano_id is distinct from old.piano_id then raise exception 'Non si può spostare in un altro piano'; end if;
  return new;
end $$;
drop trigger if exists trg_task_piano on public.task;
create trigger trg_task_piano before update on public.task for each row execute function public.blocca_task();

-- l'owner non si può cambiare
create or replace function public.blocca_owner() returns trigger language plpgsql as $$
begin
  if new.owner is distinct from old.owner then raise exception 'Il proprietario del piano non si può cambiare'; end if;
  return new;
end $$;
drop trigger if exists trg_piani_owner on public.piani;
create trigger trg_piani_owner before update on public.piani for each row execute function public.blocca_owner();

-- ---------- permessi (RLS) ----------
alter table public.piani  enable row level security;
alter table public.membri enable row level security;
alter table public.voci   enable row level security;
alter table public.task   enable row level security;

drop policy if exists piani_sel on public.piani;
drop policy if exists piani_ins on public.piani;
drop policy if exists piani_upd on public.piani;
drop policy if exists piani_del on public.piani;
create policy piani_sel on public.piani for select to authenticated using (owner = auth.uid() or public.ruolo(id) is not null);
create policy piani_ins on public.piani for insert to authenticated with check (owner = auth.uid());
create policy piani_upd on public.piani for update to authenticated using (public.ruolo(id) in ('owner','admin')) with check (public.ruolo(id) in ('owner','admin'));
create policy piani_del on public.piani for delete to authenticated using (owner = auth.uid());

drop policy if exists membri_sel on public.membri;
drop policy if exists membri_ins on public.membri;
drop policy if exists membri_upd on public.membri;
drop policy if exists membri_del on public.membri;
create policy membri_sel on public.membri for select to authenticated using (public.ruolo(piano_id) is not null);
create policy membri_ins on public.membri for insert to authenticated with check (public.ruolo(piano_id) in ('owner','admin'));
create policy membri_upd on public.membri for update to authenticated using (public.ruolo(piano_id) in ('owner','admin')) with check (public.ruolo(piano_id) in ('owner','admin'));
create policy membri_del on public.membri for delete to authenticated using (public.ruolo(piano_id) in ('owner','admin'));

drop policy if exists voci_sel on public.voci;
drop policy if exists voci_ins on public.voci;
drop policy if exists voci_upd on public.voci;
drop policy if exists voci_del on public.voci;
create policy voci_sel on public.voci for select to authenticated using (public.ruolo(piano_id) is not null);
create policy voci_ins on public.voci for insert to authenticated with check (public.ruolo(piano_id) in ('owner','admin'));
create policy voci_upd on public.voci for update to authenticated using (public.ruolo(piano_id) in ('owner','admin','campi')) with check (public.ruolo(piano_id) in ('owner','admin','campi'));
create policy voci_del on public.voci for delete to authenticated using (public.ruolo(piano_id) in ('owner','admin'));

drop policy if exists task_sel on public.task;
drop policy if exists task_ins on public.task;
drop policy if exists task_upd on public.task;
drop policy if exists task_del on public.task;
create policy task_sel on public.task for select to authenticated using (public.ruolo(piano_id) is not null);
create policy task_ins on public.task for insert to authenticated with check (public.ruolo(piano_id) in ('owner','admin','campi'));
create policy task_upd on public.task for update to authenticated using (public.ruolo(piano_id) in ('owner','admin','campi')) with check (public.ruolo(piano_id) in ('owner','admin','campi'));
create policy task_del on public.task for delete to authenticated using (public.ruolo(piano_id) in ('owner','admin','campi'));

-- ---------- tempo reale ----------
do $$ begin
  begin alter publication supabase_realtime add table public.voci; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.task; exception when duplicate_object then null; end;
end $$;
alter table public.voci replica identity full;
alter table public.task replica identity full;
