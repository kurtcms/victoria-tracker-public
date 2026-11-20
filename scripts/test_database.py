#!/usr/bin/env python3
"""Real PostgreSQL migration/RLS/idempotency tests in a disposable, isolated Docker container."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import subprocess
import time
import uuid

root = Path(__file__).resolve().parents[1]
name = "victoria-db-test-" + uuid.uuid4().hex[:10]
image = "postgres:15-alpine"
def docker(*args, **kwargs):
    return subprocess.run(["docker", *args], check=True, text=True, **kwargs)
def sql(source, capture=False):
    return docker("exec", "-i", name, "psql", "-h", "127.0.0.1", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "postgres", input=source, capture_output=capture)

try:
    docker("run", "--rm", "-d", "--network", "none", "--name", name, "-e", "POSTGRES_HOST_AUTH_METHOD=trust", image)
    for attempt in range(100):
        # The entrypoint's temporary initialization server accepts Unix sockets
        # before restarting. TCP readiness identifies the final server instead.
        ready = subprocess.run(["docker", "exec", name, "pg_isready", "-h", "127.0.0.1", "-U", "postgres"], capture_output=True)
        if ready.returncode == 0: break
        time.sleep(0.2)
    else: raise RuntimeError("PostgreSQL did not become ready")
    sql((root / "supabase/tests/bootstrap.sql").read_text())
    preflight = (root / "supabase/preflight.sql").read_text().strip().rstrip(";")
    sql("do $$ begin if exists(select 1 from (" + preflight + ") checks where not checks.ok) then raise exception 'Fresh project preflight failed'; end if; end $$;")
    print("PASS: read-only preflight accepts a fresh Supabase-like project")
    first_migration = next(iter(sorted((root / "supabase/migrations").glob("*.sql"))))
    sql("alter extension pgcrypto set schema public;")
    wrong_extension = subprocess.run(["docker", "exec", "-i", name, "psql", "-h", "127.0.0.1", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "postgres"],
                                    input=first_migration.read_text(), text=True, capture_output=True)
    if wrong_extension.returncode == 0:
        raise RuntimeError("Migration accepted pgcrypto in an unexpected schema")
    sql("""do $$ begin if to_regclass('public.families') is not null then
      raise exception 'Rejected migration created app objects'; end if; end $$;
      alter extension pgcrypto set schema extensions;""")
    print("PASS: unexpected extension namespace is rejected before app schema changes")
    # The hosted CLI records migration history; reproduce that catalog locally
    # so the same read-only postflight can be verified against the full schema.
    sql("create schema supabase_migrations; create table supabase_migrations.schema_migrations(version text primary key);")
    for migration in sorted((root / "supabase/migrations").glob("*.sql")):
        sql(migration.read_text())
        version = migration.name.split("_", 1)[0]
        assert version.isdigit()
        sql(f"insert into supabase_migrations.schema_migrations(version) values('{version}');")
    verification = (root / "supabase/verify_deployment.sql").read_text().strip().rstrip(";")
    sql("do $$ begin if exists(select 1 from (" + verification + ") checks where not checks.ok) then raise exception 'Post-migration privilege verification failed'; end if; end $$;")
    print("PASS: hosted read-only postflight covers the complete current schema and grants")
    sql("do $$ begin if not exists(select 1 from (" + preflight + ") checks where not checks.ok) then raise exception 'Preflight missed an occupied app schema'; end if; end $$;")
    print("PASS: read-only preflight detects an already occupied project")
    sql((root / "supabase/tests/security.sql").read_text())
    sql((root / "supabase/tests/expanded.sql").read_text())
    sql((root / "supabase/tests/voice_pronouns.sql").read_text())
    sql((root / "supabase/tests/conversation.sql").read_text())
    sql((root / "supabase/tests/care_queries.sql").read_text())
    sql((root / "supabase/tests/read_snapshot.sql").read_text())
    # A migration is a one-time operation. An accidental repeat must roll back,
    # leaving all original objects and rows intact, not partially reconfigure access.
    repeat = subprocess.run(["docker", "exec", "-i", name, "psql", "-h", "127.0.0.1", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "postgres"],
                            input=first_migration.read_text(), text=True, capture_output=True)
    if repeat.returncode == 0:
        raise RuntimeError("Unexpectedly reapplied an initial migration")
    sql("""do $$ begin if (select count(*) from public.events) <> 0
      or to_regprocedure('public.create_family(text)') is null then
      raise exception 'Failed migration changed original state'; end if; end $$;""")
    print("PASS: accidental migration repeat fails without changing the original schema/data")
    # Two separate database sessions race the same write, exercising the advisory lock.
    sql("""insert into auth.users values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','race@example.invalid');
      set role authenticated;
      select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',false);
      select public.create_family('UTC');""")
    instant = datetime.now(timezone.utc).isoformat()
    racing = f"""begin; set local role authenticated;
      select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',true);
      select public.record_event((select id from public.children limit 1),
        'dddddddd-dddd-4ddd-8ddd-dddddddddddd',repeat('a',64),'feeding','{instant}','siri',160,null,null); commit;"""
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(sql, racing, True) for _ in range(2)]
        for f in futures: f.result()
    sql("""do $$ begin if (select count(*) from public.events) <> 1 then
      raise exception 'Concurrent retries duplicated a record'; end if; end $$;""")
    print("PASS: concurrent retries persist exactly one event")
    # New commands serialize per baby even with different parent/request UUIDs.
    common = "begin; set local role authenticated; select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',true); "
    sleep_race = common + "select public.execute_care_command((select id from public.children limit 1),gen_random_uuid(),repeat('b',64),'sleep_start',now(),'manual',jsonb_build_object('occurred_at',now()-interval '1 hour'),'UTC'); commit;"
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures=[pool.submit(sql,sleep_race,True) for _ in range(2)]
        for f in futures:f.result()
    sql("do $$ begin if (select count(*) from public.sleep_sessions)<>1 then raise exception 'Concurrent starts duplicated sleep';end if;end $$;")
    print("PASS: two concurrent starts create exactly one shared sleep")
    wake_race=common+"select public.execute_care_command((select id from public.children limit 1),gen_random_uuid(),repeat('c',64),'sleep_end',now(),'manual',jsonb_build_object('occurred_at',now()),'UTC'); commit;"
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures=[pool.submit(sql,wake_race,True) for _ in range(2)]
        for f in futures:f.result()
    sql("do $$ begin if (select count(*) from public.sleep_sessions where ended_at is not null)<>1 or (select count(*) from public.care_revisions where target_type='sleep')<>1 then raise exception 'Concurrent wakes changed sleep twice';end if;end $$;")
    print("PASS: two concurrent wakes close the session exactly once")
    sql(common+"select public.execute_care_command((select id from public.children limit 1),gen_random_uuid(),repeat('d',64),'propose_feeding',now(),'manual','{\"correction_kind\":\"total\",\"amount_ml\":150}','UTC'); select public.execute_care_command((select id from public.children limit 1),gen_random_uuid(),repeat('e',64),'propose_feeding',now(),'manual','{\"correction_kind\":\"total\",\"amount_ml\":140}','UTC'); commit;",True)
    def confirm_race(value):
        return sql(common+f"select public.execute_care_command((select id from public.children limit 1),gen_random_uuid(),repeat('f',64),'confirm',now(),'manual',jsonb_build_object('proposal_id',(select id from public.care_proposals where changes->>'volume_ml'='{value}')),'UTC'); commit;",True)
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures=[pool.submit(confirm_race,value) for value in (140,150)]
        for f in futures:f.result()
    sql("do $$ begin if (select revision from public.events limit 1)<>2 or (select count(*) from public.care_revisions where target_type='feeding')<>1 then raise exception 'Concurrent confirmations overwrote each other';end if;end $$;")
    print("PASS: competing confirmations apply one revision; the other is stale")
    print("Database migration and security tests passed.")
finally:
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)
