-- Only for the disposable plain-PostgreSQL test container, never a Supabase migration.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin noinherit bypassrls;
create schema auth;
create schema extensions;
-- New Supabase projects normally already have pgcrypto here.
create extension pgcrypto with schema extensions;
-- Exercise the grants Supabase supplies for new public tables/functions.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
create table auth.users(id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
grant usage on schema public, auth, extensions to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;
