-- ═══════════════════════════════════════════
-- PROPINAS CAFÉ — Schema de Supabase
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ═══════════════════════════════════════════

-- ── Cafés ──────────────────────────────────
create table public.cafes (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  owner_id     uuid references auth.users(id) on delete cascade,
  split_count  int  not null default 3,
  invite_code  text unique default upper(substr(md5(random()::text), 1, 6)),
  created_at   timestamptz default now()
);

-- ── Perfiles (extiende auth.users) ─────────
create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text not null default '',
  role       text not null default 'employee' check (role in ('owner','employee')),
  cafe_id    uuid references public.cafes(id) on delete set null,
  created_at timestamptz default now()
);

-- ── Turnos ─────────────────────────────────
create table public.shifts (
  id          uuid primary key default gen_random_uuid(),
  cafe_id     uuid not null references public.cafes(id) on delete cascade,
  employee_id uuid not null references public.profiles(id) on delete cascade,
  date        date not null,
  type        text not null check (type in ('mañana','tarde')),
  created_at  timestamptz default now(),
  unique(employee_id, date)
);

-- ── Propinas ───────────────────────────────
create table public.tips (
  id          uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.profiles(id) on delete cascade,
  cafe_id     uuid not null references public.cafes(id) on delete cascade,
  date        date not null,
  total       int,
  my_share    int  not null,
  note        text default '',
  split_mode  boolean default true,
  split_count int     default 3,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now(),
  unique(employee_id, date)
);

-- ── RLS ────────────────────────────────────
alter table public.cafes    enable row level security;
alter table public.profiles enable row level security;
alter table public.shifts   enable row level security;
alter table public.tips     enable row level security;

-- Cafes: dueño gestiona el suyo, empleados lo ven
create policy "owner manages cafe" on public.cafes
  for all using (owner_id = auth.uid());
create policy "employee views cafe" on public.cafes
  for select using (
    id in (select cafe_id from public.profiles where id = auth.uid())
  );

-- Profiles: cualquiera del mismo café puede ver, solo uno edita el suyo
create policy "anyone reads profiles" on public.profiles
  for select using (
    cafe_id in (select cafe_id from public.profiles where id = auth.uid())
    or id = auth.uid()
  );
create policy "user manages own profile" on public.profiles
  for all using (id = auth.uid());

-- Shifts: miembros del café ven, dueño gestiona todos
create policy "cafe members view shifts" on public.shifts
  for select using (
    cafe_id in (select cafe_id from public.profiles where id = auth.uid())
  );
create policy "owner manages shifts" on public.shifts
  for all using (
    cafe_id in (select id from public.cafes where owner_id = auth.uid())
  );

-- Tips: empleado gestiona los suyos, dueño ve todos del café
create policy "employee manages own tips" on public.tips
  for all using (employee_id = auth.uid());
create policy "owner reads cafe tips" on public.tips
  for select using (
    cafe_id in (select id from public.cafes where owner_id = auth.uid())
  );

-- ── Storage: PDFs de horario ───────────────
insert into storage.buckets (id, name, public)
  values ('schedules', 'schedules', false)
  on conflict do nothing;

create policy "cafe members read schedules" on storage.objects
  for select using (
    bucket_id = 'schedules' and auth.uid() is not null
  );
create policy "owners upload schedules" on storage.objects
  for insert with check (
    bucket_id = 'schedules' and auth.uid() is not null
  );
create policy "owners update schedules" on storage.objects
  for update using (
    bucket_id = 'schedules' and auth.uid() is not null
  );
create policy "owners delete schedules" on storage.objects
  for delete using (
    bucket_id = 'schedules' and auth.uid() is not null
  );

-- ── Trigger: crear perfil al registrarse ───
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  insert into public.profiles (id, name)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', ''));
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ── Trigger: updated_at en tips ────────────
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

create trigger tips_updated_at
  before update on public.tips
  for each row execute procedure public.set_updated_at();
