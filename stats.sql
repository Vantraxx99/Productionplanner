-- Production Planner: statistiche live per l'amministratore del servizio
-- Da eseguire dopo schema.sql. Si può rieseguire.

-- chi vede le statistiche di tutto (e può aprire ogni piano in sola lettura)
create or replace function public.is_super() returns boolean
language sql stable security definer set search_path = public as $$
  select lower(coalesce(auth.jwt()->>'email','')) in ('roca.filippo1999@gmail.com');
$$;
grant execute on function public.is_super() to authenticated;

-- ruolo: proprietario, poi membro, poi "super" (sola lettura su tutto)
create or replace function public.ruolo(p uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from piani where id = p and owner = auth.uid()) then 'owner'
    else coalesce(
      (select ruolo from membri where piano_id = p and email = lower(auth.jwt()->>'email')),
      case when public.is_super() then 'super' end)
  end;
$$;

-- data di creazione delle voci (per le statistiche)
alter table public.voci add column if not exists created_at timestamptz not null default now();

-- registro di ogni modifica
create table if not exists public.registro (
  id        bigserial primary key,
  piano_id  uuid,                     -- niente vincolo: il registro resta anche se il piano viene eliminato
  email     text not null default '',
  azione    text not null,            -- nuova / modifica / eliminata / task / piano
  oggetto   text not null default '',
  at        timestamptz not null default now()
);
create index if not exists registro_at on public.registro(at desc);
alter table public.registro enable row level security;
drop policy if exists registro_sel on public.registro;
create policy registro_sel on public.registro for select to authenticated using (public.is_super());

create or replace function public.registra() returns trigger
language plpgsql security definer set search_path = public as $$
declare em text := lower(coalesce(auth.jwt()->>'email',''));
begin
  if TG_TABLE_NAME = 'voci' then
    if TG_OP = 'INSERT' then insert into registro(piano_id,email,azione,oggetto) values (new.piano_id,em,'nuova',new.attivita);
    elsif TG_OP = 'UPDATE' then insert into registro(piano_id,email,azione,oggetto) values (new.piano_id,em,'modifica',new.attivita);
    else insert into registro(piano_id,email,azione,oggetto) values (old.piano_id,em,'eliminata',old.attivita); end if;
  elsif TG_TABLE_NAME = 'task' then
    if TG_OP = 'DELETE' then insert into registro(piano_id,email,azione,oggetto) values (old.piano_id,em,'task',old.testo);
    else insert into registro(piano_id,email,azione,oggetto) values (new.piano_id,em,'task',new.testo); end if;
  elsif TG_TABLE_NAME = 'piani' then
    if TG_OP = 'INSERT' then insert into registro(piano_id,email,azione,oggetto) values (new.id,em,'piano creato',new.nome);
    elsif TG_OP = 'UPDATE' then insert into registro(piano_id,email,azione,oggetto) values (new.id,em,'impostazioni',new.nome); end if;
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists trg_reg_voci on public.voci;
create trigger trg_reg_voci after insert or update or delete on public.voci for each row execute function public.registra();
drop trigger if exists trg_reg_task on public.task;
create trigger trg_reg_task after insert or update or delete on public.task for each row execute function public.registra();
drop trigger if exists trg_reg_piani on public.piani;
create trigger trg_reg_piani after insert or update on public.piani for each row execute function public.registra();

do $$ begin
  begin alter publication supabase_realtime add table public.registro; exception when duplicate_object then null; end;
end $$;

-- tutte le statistiche in una chiamata (solo per is_super)
create or replace function public.statistiche() returns json
language plpgsql stable security definer set search_path = public as $$
declare r json;
begin
  if not public.is_super() then raise exception 'Non autorizzato'; end if;
  select json_build_object(
    'ora', now(),
    'utenti', (select count(*) from auth.users),
    'utenti_confermati', (select count(*) from auth.users where email_confirmed_at is not null),
    'attivi_24h', (select count(*) from auth.users where last_sign_in_at > now() - interval '24 hours'),
    'attivi_7g', (select count(distinct email) from registro where at > now() - interval '7 days' and email <> ''),
    'piani', (select count(*) from piani),
    'voci', (select count(*) from voci),
    'task', (select count(*) from task),
    'task_fatte', (select count(*) from task where fatto),
    'membri', (select count(*) from membri),
    'materiali', (select count(*) from voci where materiali <> ''),
    'materiali_ok', (select count(*) from voci where materiali <> '' and materiali_ok),
    'modifiche_oggi', (select count(*) from registro where at > date_trunc('day', now())),
    'modifiche_7g', (select count(*) from registro where at > now() - interval '7 days'),
    'giorni', (select coalesce(json_agg(json_build_object('g', g::date, 'n', coalesce(n,0)) order by g), '[]'::json)
               from generate_series(date_trunc('day', now()) - interval '29 days', date_trunc('day', now()), interval '1 day') g
               left join (select date_trunc('day', at) d, count(*) n from registro where at > now() - interval '30 days' group by 1) x on x.d = g),
    'stati', (select coalesce(json_object_agg(s, n), '{}'::json) from (select coalesce(nullif(stato,''),'—') s, count(*) n from voci group by 1) x),
    'piani_elenco', (select coalesce(json_agg(row_to_json(x) order by x.ultima desc nulls last), '[]'::json) from (
        select p.id, p.nome, p.cliente, p.colore, p.created_at, u.email as proprietario,
               (select min(e->>'d') from jsonb_array_elements(p.giorni) e) as dal,
               (select max(e->>'d') from jsonb_array_elements(p.giorni) e) as al,
               (select count(*) from voci v where v.piano_id = p.id) as voci,
               (select count(*) from task t where t.piano_id = p.id) as task,
               (select count(*) from membri m where m.piano_id = p.id) as persone,
               (select max(at) from registro g where g.piano_id = p.id) as ultima
        from piani p left join auth.users u on u.id = p.owner) x),
    'utenti_elenco', (select coalesce(json_agg(row_to_json(x) order by x.ultimo_accesso desc nulls last), '[]'::json) from (
        select u.email, u.created_at, u.last_sign_in_at as ultimo_accesso, (u.email_confirmed_at is not null) as confermato,
               (select count(*) from piani p where p.owner = u.id) as piani_creati,
               (select count(*) from membri m where m.email = lower(u.email)) as inviti,
               (select count(*) from registro g where g.email = lower(u.email)) as modifiche
        from auth.users u) x),
    'ultime', (select coalesce(json_agg(row_to_json(x)), '[]'::json) from (
        select g.at, g.email, g.azione, g.oggetto, p.nome as piano, p.colore
        from registro g left join piani p on p.id = g.piano_id order by g.at desc limit 40) x)
  ) into r;
  return r;
end $$;
grant execute on function public.statistiche() to authenticated;
