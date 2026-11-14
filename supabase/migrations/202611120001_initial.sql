begin;

-- Fail before changing a project with an incompatible or occupied namespace.
do $$
begin
  if current_setting('server_version_num')::integer < 150000 then
    raise exception 'Victoria Tracker requires PostgreSQL 15 or later';
  end if;
  if to_regprocedure('auth.uid()') is null or to_regclass('auth.users') is null
    or not exists(select 1 from pg_roles where rolname = 'anon')
    or not exists(select 1 from pg_roles where rolname = 'authenticated') then
    raise exception 'Expected Supabase Auth schema and roles';
  end if;
  if exists(select 1 from pg_extension e join pg_namespace n on n.oid = e.extnamespace
    where e.extname = 'pgcrypto' and n.nspname <> 'extensions') then
    raise exception 'pgcrypto must be installed in extensions; review the project before migrating';
  end if;
  if exists(select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'private')
    or exists(select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'private') then
    raise exception 'The private schema is occupied; this migration is intended for a new project';
  end if;
end;
$$;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create extension if not exists pgcrypto with schema extensions;

create type public.event_type as enum ('feeding', 'diaper', 'weight');
create type public.diaper_kind as enum ('wet', 'dirty', 'mixed');
create type public.input_source as enum ('siri', 'text', 'manual');

create table public.families (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(name) between 1 and 80),
  created_at timestamptz not null default now()
);
create table public.family_members (
  family_id uuid not null references public.families(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'parent')),
  created_at timestamptz not null default now(),
  primary key (family_id, user_id),
  unique (user_id) -- Phase 1: one family per account.
);
create table public.children (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  name text not null check (length(name) between 1 and 80),
  time_zone text not null default 'America/Vancouver',
  date_of_birth date,
  growth_reference_sex text check (growth_reference_sex in ('female', 'male')),
  created_at timestamptz not null default now()
);
create index children_family_idx on public.children(family_id);

-- One event row makes metadata, idempotency, and timeline reads atomic.
-- Typed, RLS-respecting views below expose the three record categories.
create table public.events (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children(id),
  event_type public.event_type not null,
  occurred_at timestamptz not null,
  recorded_by uuid not null references auth.users(id),
  input_source public.input_source not null,
  created_at timestamptz not null default now(),
  volume_ml numeric(7,2),
  diaper_kind public.diaper_kind,
  weight_kg numeric(6,3),
  request_id uuid not null,
  request_hash text not null check (request_hash ~ '^[a-f0-9]{64}$'),
  unique(recorded_by, request_id),
  constraint event_payload check (
    (event_type = 'feeding' and volume_ml > 0 and volume_ml <= 2000 and diaper_kind is null and weight_kg is null)
    or (event_type = 'diaper' and diaper_kind is not null and volume_ml is null and weight_kg is null)
    or (event_type = 'weight' and weight_kg > 0 and weight_kg <= 100 and volume_ml is null and diaper_kind is null)
  ),
  constraint payload_required check (
    (event_type <> 'feeding' or volume_ml is not null)
    and (event_type <> 'weight' or weight_kg is not null)
  )
);
create index events_child_time_idx on public.events(child_id, occurred_at desc, id);

create table private.family_invites (
  token_hash bytea primary key,
  family_id uuid not null references public.families(id) on delete cascade,
  expires_at timestamptz not null default now() + interval '24 hours'
);
create table private.event_budgets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  window_start timestamptz not null,
  count integer not null
);
revoke all on private.family_invites, private.event_budgets from public, anon, authenticated;

create function private.is_family_member(p_family_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.family_members
    where family_id = p_family_id and user_id = (select auth.uid()));
$$;
grant usage on schema private to authenticated;
grant execute on function private.is_family_member(uuid) to authenticated;

alter table public.families enable row level security;
alter table public.family_members enable row level security;
alter table public.children enable row level security;
alter table public.events enable row level security;
alter table private.family_invites enable row level security;
alter table private.event_budgets enable row level security;

create policy family_read on public.families for select to authenticated
  using (private.is_family_member(id));
create policy members_read on public.family_members for select to authenticated
  using (private.is_family_member(family_id));
create policy children_read on public.children for select to authenticated
  using (private.is_family_member(family_id));
create policy events_read on public.events for select to authenticated
  using (exists(select 1 from public.children c where c.id = child_id and private.is_family_member(c.family_id)));

revoke all on public.families, public.family_members, public.children, public.events from public, anon, authenticated;
grant select on public.families, public.family_members, public.children, public.events to authenticated;

create view public.feeding_events with (security_invoker = true) as
  select * from public.events where event_type = 'feeding';
create view public.diaper_events with (security_invoker = true) as
  select * from public.events where event_type = 'diaper';
create view public.weight_measurements with (security_invoker = true) as
  select * from public.events where event_type = 'weight';
revoke all on public.feeding_events, public.diaper_events, public.weight_measurements from public, anon, authenticated;
grant select on public.feeding_events, public.diaper_events, public.weight_measurements to authenticated;

create function public.create_family(p_time_zone text) returns public.children
language plpgsql security definer set search_path = '' as $$
declare f uuid; c public.children;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text, 0));
  if exists(select 1 from public.family_members where user_id = auth.uid()) then
    raise exception 'Already in a family' using errcode = '22023';
  end if;
  if not exists(select 1 from pg_timezone_names where name = p_time_zone) then
    raise exception 'Invalid time zone' using errcode = '22023';
  end if;
  insert into public.families(name) values ('Victoria’s family') returning id into f;
  insert into public.family_members(family_id, user_id, role) values(f, auth.uid(), 'owner');
  insert into public.children(family_id, name, time_zone, growth_reference_sex)
    values(f, 'Victoria', p_time_zone, 'female') returning * into c;
  return c;
end;
$$;

create function public.create_family_invite() returns text
language plpgsql security definer set search_path = '' as $$
declare f uuid; token text;
begin
  select family_id into f from public.family_members where user_id = auth.uid() and role = 'owner';
  if f is null then raise exception 'Only a family owner may invite' using errcode = '42501'; end if;
  perform 1 from public.families where id = f for update;
  if (select count(*) from public.family_members where family_id = f) >= 2 then
    raise exception 'Both parents have already joined' using errcode = '22023';
  end if;
  delete from private.family_invites where family_id = f;
  token := encode(extensions.gen_random_bytes(24), 'hex');
  insert into private.family_invites(token_hash, family_id) values(extensions.digest(token, 'sha256'), f);
  return token;
end;
$$;

create function public.join_family(p_token text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare f uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text, 0));
  if exists(select 1 from public.family_members where user_id = auth.uid()) then
    raise exception 'Already in a family' using errcode = '22023';
  end if;
  select family_id into f from private.family_invites
    where token_hash = extensions.digest(p_token, 'sha256') and expires_at > now();
  if f is null then raise exception 'Invalid or expired invite' using errcode = '22023'; end if;
  perform 1 from public.families where id = f for update;
  -- Recheck under the family lock to serialize invite consumption.
  delete from private.family_invites where token_hash = extensions.digest(p_token, 'sha256')
    and expires_at > now() returning family_id into f;
  if f is null then raise exception 'Invalid or expired invite' using errcode = '22023'; end if;
  if (select count(*) from public.family_members where family_id = f) >= 2 then
    raise exception 'Family is full' using errcode = '22023';
  end if;
  insert into public.family_members(family_id, user_id, role) values(f, auth.uid(), 'parent');
  return f;
end;
$$;

create function public.consume_event_budget() returns boolean
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  insert into private.event_budgets(user_id, window_start, count) values(auth.uid(), now(), 1)
  on conflict(user_id) do update set
    count = case when private.event_budgets.window_start < now() - interval '1 minute' then 1 else private.event_budgets.count + 1 end,
    window_start = case when private.event_budgets.window_start < now() - interval '1 minute' then now() else private.event_budgets.window_start end
  returning count into n;
  return n <= 30;
end;
$$;

create function public.record_event(
  p_child_id uuid, p_request_id uuid, p_request_hash text,
  p_event_type public.event_type, p_occurred_at timestamptz, p_input_source public.input_source,
  p_volume_ml numeric default null, p_diaper_kind public.diaper_kind default null, p_weight_kg numeric default null
) returns public.events
language plpgsql security definer set search_path = '' as $$
declare e public.events;
begin
  if auth.uid() is null or not exists(
    select 1 from public.children c join public.family_members m on m.family_id = c.family_id
    where c.id = p_child_id and m.user_id = auth.uid()
  ) then raise exception 'Child not accessible' using errcode = '42501'; end if;
  if p_request_id is null or p_request_hash is null or p_request_hash !~ '^[a-f0-9]{64}$'
    or p_event_type is null or p_input_source is null then
    raise exception 'Invalid recording metadata' using errcode = '22023';
  end if;
  -- Serialize retries for this parent/request; conflicting reuse never changes a saved event.
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || p_request_id::text, 1));
  select * into e from public.events where recorded_by = auth.uid() and request_id = p_request_id;
  if found then
    if e.request_hash <> p_request_hash or e.child_id <> p_child_id then
      raise exception 'Idempotency conflict' using errcode = '23505';
    end if;
    return e;
  end if;
  if p_occurred_at is null or not isfinite(p_occurred_at)
    or p_occurred_at > now() + interval '5 minutes' or p_occurred_at < now() - interval '366 days' then
    raise exception 'Event timestamp out of range' using errcode = '22023';
  end if;
  -- Numeric column coercion rounds values before CHECK constraints see them.
  -- Validate RPC precision first so direct callers cannot silently round data.
  if (p_volume_ml is not null and p_volume_ml <> round(p_volume_ml, 2))
    or (p_weight_kg is not null and p_weight_kg <> round(p_weight_kg, 3)) then
    raise exception 'Too many decimal places' using errcode = '22023';
  end if;
  insert into public.events(child_id, event_type, occurred_at, recorded_by, input_source,
    request_id, request_hash, volume_ml, diaper_kind, weight_kg)
  values(p_child_id, p_event_type, p_occurred_at, auth.uid(), p_input_source,
    p_request_id, p_request_hash, p_volume_ml, p_diaper_kind, p_weight_kg) returning * into e;
  return e;
end;
$$;

revoke all on function private.is_family_member(uuid) from public, anon;
revoke all on function public.create_family(text), public.create_family_invite(), public.join_family(text),
  public.consume_event_budget(), public.record_event(uuid, uuid, text, public.event_type, timestamptz, public.input_source, numeric, public.diaper_kind, numeric) from public, anon;
grant execute on function public.create_family(text), public.create_family_invite(), public.join_family(text),
  public.consume_event_budget(), public.record_event(uuid, uuid, text, public.event_type, timestamptz, public.input_source, numeric, public.diaper_kind, numeric) to authenticated;

commit;
