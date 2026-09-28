-- Marklume: accounts, colleges and published results on Supabase.
--
-- Run this once in your project's SQL editor (Dashboard → SQL Editor → New
-- query → paste → Run). It can be run again safely: it only adds what is
-- missing and replaces the functions and rules with these.
--
-- Security: the app holds only the public (anon) key. Everything anyone may
-- see or change is decided here — by row level security on every table and
-- by the functions below, which check who is asking. Role, college and status
-- are written by the server when an account is made and are never read from
-- anything the user can edit.

create schema if not exists private;

do $$ begin
  create type public.member_role as enum ('admin', 'teacher', 'student');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.member_status as enum ('pending', 'active', 'rejected', 'removed');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Colleges and their members
-- ---------------------------------------------------------------------------

create table if not exists public.colleges (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z0-9-]{3,20}$'),
  name text not null check (length(btrim(name)) between 2 and 120),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  college_id uuid not null references public.colleges (id) on delete cascade,
  role public.member_role not null,
  status public.member_status not null,
  username text not null check (username ~ '^[a-z0-9_.]{3,30}$'),
  email text not null,
  full_name text not null check (length(btrim(full_name)) between 1 and 120),
  roll_no text,
  staff_id text,
  decided_by uuid references public.profiles (id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  check ((role = 'student') = (roll_no is not null)),
  check ((role <> 'student') = (staff_id is not null))
);
create unique index if not exists profiles_username on public.profiles (lower(username));
create unique index if not exists profiles_roll on public.profiles (college_id, roll_no) where role = 'student';
create unique index if not exists profiles_staff on public.profiles (college_id, staff_id) where role <> 'student';

-- Username look-ups, counted to slow down guessing.
create table if not exists private.login_lookups (
  username text not null,
  at timestamptz not null default now()
);
create index if not exists login_lookups_recent on private.login_lookups (username, at);

-- A roll number as the app stores it: upper case, no spaces.
create or replace function private.normalise_roll(p text) returns text
language sql immutable set search_path = '' as $$
  select upper(regexp_replace(coalesce(p, ''), '\s+', '', 'g'))
$$;

-- Who is asking. Each looks at the caller's own profile and counts only an
-- active one, so removing someone takes effect on their very next request.
create or replace function public.my_college() returns uuid
language sql stable security definer set search_path = '' as $$
  select college_id from public.profiles where id = auth.uid() and status = 'active'
$$;

-- The caller's college whatever their status: a teacher still waiting for
-- approval may read their college's name.
create or replace function public.my_college_any() returns uuid
language sql stable security definer set search_path = '' as $$
  select college_id from public.profiles where id = auth.uid()
$$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and status = 'active' and role in ('admin', 'teacher')
  )
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles where id = auth.uid() and status = 'active' and role = 'admin'
  )
$$;

create or replace function public.my_roll() returns text
language sql stable security definer set search_path = '' as $$
  select roll_no from public.profiles where id = auth.uid() and status = 'active' and role = 'student'
$$;

-- The version of this setup, which the app's "Test connection" asks for.
create or replace function public.marklume_schema() returns int
language sql immutable set search_path = '' as $$ select 1 $$;

-- A college's name from its college ID, for "Joining: …" while signing up.
create or replace function public.college_name(p_code text) returns text
language sql stable security definer set search_path = '' as $$
  select name from public.colleges where code = private.normalise_roll(p_code)
$$;

-- Everything that can be checked before an account is made, said plainly:
-- the server hides why a sign-up failed once it has started.
create or replace function public.check_signup(
  p_role text, p_college_code text, p_username text, p_member_id text
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_code text := private.normalise_roll(p_college_code);
  v_college public.colleges;
  v_member text;
begin
  if p_role is null or p_role not in ('admin', 'teacher', 'student') then
    return jsonb_build_object('status', 'not_allowed');
  end if;
  select * into v_college from public.colleges c where c.code = v_code;
  if p_role = 'admin' and v_college.id is not null then
    return jsonb_build_object('status', 'college_code_taken');
  end if;
  if p_role <> 'admin' and v_college.id is null then
    return jsonb_build_object('status', 'college_not_found');
  end if;
  if exists (select 1 from public.profiles p where lower(p.username) = lower(btrim(p_username))) then
    return jsonb_build_object('status', 'username_taken');
  end if;
  v_member := case when p_role = 'student' then private.normalise_roll(p_member_id) else upper(btrim(p_member_id)) end;
  if v_college.id is not null and exists (
    select 1 from public.profiles p
    where p.college_id = v_college.id
      and ((p_role = 'student' and p.role = 'student' and p.roll_no = v_member)
        or (p_role <> 'student' and p.role <> 'student' and p.staff_id = v_member))
  ) then
    return jsonb_build_object('status', 'member_taken');
  end if;
  return jsonb_build_object('status', 'ok', 'college_name', v_college.name);
end $$;

-- A username's email, so people can sign in with either. Throttled per
-- username; an unknown one returns nothing, and the app answers it exactly
-- as it answers a wrong password.
create or replace function public.email_for_login(p_login text) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_login text := lower(btrim(coalesce(p_login, '')));
  v_recent int;
begin
  if position('@' in v_login) > 0 then return btrim(p_login); end if;
  delete from private.login_lookups where at < now() - interval '1 day';
  select count(*) into v_recent from private.login_lookups
    where username = v_login and at > now() - interval '10 minutes';
  if v_recent >= 10 then raise exception 'too_many_attempts'; end if;
  insert into private.login_lookups (username) values (v_login);
  return (
    select p.email from public.profiles p
    where lower(p.username) = v_login and p.status in ('active', 'pending')
  );
end $$;

-- A new account's profile, from what was filled in at sign-up. An admin's
-- sign-up registers the college; everyone else joins one by its college ID.
-- Teachers wait for the admin; students and the admin are in at once.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_role text := m ->> 'role';
  v_code text := private.normalise_roll(m ->> 'college_code');
  v_college uuid;
begin
  -- Accounts made in the dashboard have no role; they get no profile.
  if v_role is null then return new; end if;
  if v_role not in ('admin', 'teacher', 'student') then raise exception 'not_allowed'; end if;
  if v_role = 'admin' then
    insert into public.colleges (code, name, created_by)
    values (v_code, btrim(m ->> 'college_name'), new.id)
    returning id into v_college;
  else
    select c.id into v_college from public.colleges c where c.code = v_code;
    if v_college is null then raise exception 'college_not_found'; end if;
  end if;
  insert into public.profiles (id, college_id, role, status, username, email, full_name, roll_no, staff_id)
  values (
    new.id,
    v_college,
    v_role::public.member_role,
    (case when v_role = 'teacher' then 'pending' else 'active' end)::public.member_status,
    lower(btrim(m ->> 'username')),
    new.email,
    btrim(m ->> 'full_name'),
    case when v_role = 'student' then private.normalise_roll(m ->> 'member_id') end,
    case when v_role <> 'student' then upper(btrim(m ->> 'member_id')) end
  );
  return new;
end $$;

drop trigger if exists marklume_on_auth_user_created on auth.users;
create trigger marklume_on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- The admin approves, turns down, removes or restores a teacher.
create or replace function public.set_teacher_status(p_member uuid, p_status public.member_status) returns void
language plpgsql security definer set search_path = '' as $$
declare v public.profiles;
begin
  if not public.is_admin() then raise exception 'not_allowed'; end if;
  if p_status = 'pending' then raise exception 'not_allowed'; end if;
  select * into v from public.profiles where id = p_member;
  if v.id is null or v.college_id <> public.my_college() then raise exception 'not_in_college'; end if;
  if v.role <> 'teacher' then raise exception 'not_allowed'; end if;
  update public.profiles
    set status = p_status, decided_by = auth.uid(), decided_at = now()
    where id = p_member;
end $$;

-- A teacher or the admin removes or restores a student.
create or replace function public.set_student_status(p_member uuid, p_status public.member_status) returns void
language plpgsql security definer set search_path = '' as $$
declare v public.profiles;
begin
  if not public.is_staff() then raise exception 'not_allowed'; end if;
  if p_status not in ('active', 'removed') then raise exception 'not_allowed'; end if;
  select * into v from public.profiles where id = p_member;
  if v.id is null or v.college_id <> public.my_college() then raise exception 'not_in_college'; end if;
  if v.role <> 'student' then raise exception 'not_allowed'; end if;
  update public.profiles
    set status = p_status, decided_by = auth.uid(), decided_at = now()
    where id = p_member;
end $$;

-- ---------------------------------------------------------------------------
-- Published results
-- ---------------------------------------------------------------------------

create table if not exists public.results (
  id bigint generated always as identity primary key,
  college_id uuid not null default public.my_college() references public.colleges (id) on delete cascade,
  roll_no text not null,
  subject_code text not null,
  exam text not null default '',
  student_name text not null default '',
  paper_hash text not null default '',
  script_hash text not null default '',
  total numeric not null,
  maximum numeric not null,
  percentage numeric not null,
  -- The result as the app builds it: questions, sections, explanations.
  payload jsonb not null,
  -- The answer sheet: [{number, width, height, object}], `object` being its
  -- path in the answer-sheets bucket.
  pages jsonb not null default '[]'::jsonb,
  published_by uuid default auth.uid() references public.profiles (id) on delete set null,
  published_at timestamptz not null,
  updated_at timestamptz not null default now(),
  first_seen_at timestamptz,
  last_seen_at timestamptz,
  seen_count int not null default 0,
  verified_at timestamptz,
  unique (college_id, roll_no, subject_code, exam)
);
create index if not exists results_student on public.results (college_id, roll_no, subject_code);

create table if not exists public.correction_requests (
  id bigint generated always as identity primary key,
  college_id uuid not null references public.colleges (id) on delete cascade,
  result_id bigint not null references public.results (id) on delete cascade,
  question_id text not null,
  roll_no text not null,
  subject_code text not null,
  student_id uuid references public.profiles (id) on delete set null,
  message text not null check (length(btrim(message)) between 1 and 2000),
  status text not null default 'open' check (status in ('open', 'accepted', 'declined')),
  reply text not null default '',
  old_marks numeric,
  new_marks numeric,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references public.profiles (id) on delete set null
);
create unique index if not exists one_open_request
  on public.correction_requests (result_id, question_id) where status = 'open';

-- What each teacher last published a paper under, to fill the form in.
create table if not exists public.paper_defaults (
  owner uuid not null default auth.uid() references auth.users (id) on delete cascade,
  paper_hash text not null,
  subject_code text not null,
  exam text not null,
  primary key (owner, paper_hash)
);

-- A question's current mark in a result's JSON.
create or replace function private.question_marks(p_payload jsonb, p_question text) returns numeric
language sql immutable set search_path = '' as $$
  select (q ->> 'marks')::numeric
  from jsonb_array_elements(coalesce(p_payload -> 'questions', '[]'::jsonb)) q
  where q ->> 'questionId' = p_question
  limit 1
$$;

-- Requests with what the teacher needs beside them: the question's number,
-- mark and explanation. The caller's own rules still apply.
create or replace view public.request_details with (security_invoker = true) as
  select c.*, r.exam, r.student_name,
         j.q ->> 'number' as number,
         (j.q ->> 'marks')::numeric as marks,
         (j.q ->> 'maximum')::numeric as maximum,
         coalesce(j.q ->> 'explanation', '') as explanation
  from public.correction_requests c
  join public.results r on r.id = c.result_id
  left join lateral (
    select x as q from jsonb_array_elements(coalesce(r.payload -> 'questions', '[]'::jsonb)) x
    where x ->> 'questionId' = c.question_id
    limit 1
  ) j on true;

-- Where every student stands, for the teacher's table.
create or replace view public.result_overview with (security_invoker = true) as
  select r.id, r.roll_no, r.student_name, r.subject_code, r.exam, r.total, r.maximum, r.percentage,
         r.published_at, r.first_seen_at, r.last_seen_at, r.seen_count, r.verified_at,
         (select count(*) from public.correction_requests c where c.result_id = r.id and c.status = 'open') as open_requests,
         (select count(*) from public.correction_requests c where c.result_id = r.id and c.status = 'accepted') as accepted_requests,
         (select count(*) from public.correction_requests c where c.result_id = r.id and c.status = 'declined') as declined_requests,
         (select count(*) from jsonb_array_elements(coalesce(r.payload -> 'questions', '[]'::jsonb)) x
            where coalesce((x ->> 'counted')::boolean, true) and coalesce(x ->> 'badge', 'none') <> 'none') as badges
  from public.results r;

-- A student's own result, or nothing.
create or replace function private.own_result(p_result bigint) returns public.results
language sql stable security definer set search_path = '' as $$
  select r.* from public.results r
  where r.id = p_result and r.college_id = public.my_college() and r.roll_no = public.my_roll()
$$;

-- The student opened a result: the first time is kept, each view counted.
create or replace function public.mark_seen(p_result bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (private.own_result(p_result)).id is null then raise exception 'not_found'; end if;
  update public.results
    set first_seen_at = coalesce(first_seen_at, now()), last_seen_at = now(), seen_count = seen_count + 1
    where id = p_result;
end $$;

-- The student agrees with the marks.
create or replace function public.verify_result(p_result bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.results := private.own_result(p_result);
begin
  if r.id is null then raise exception 'not_found'; end if;
  if r.verified_at is not null then raise exception 'already_verified'; end if;
  if r.first_seen_at is null then raise exception 'not_seen'; end if;
  if exists (select 1 from public.correction_requests c where c.result_id = r.id and c.status = 'open') then
    raise exception 'request_open';
  end if;
  update public.results set verified_at = now() where id = r.id;
end $$;

-- The student asks the teacher to look again at one question.
create or replace function public.request_correction(p_result bigint, p_question text, p_message text) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  r public.results := private.own_result(p_result);
  v_id bigint;
begin
  if r.id is null then raise exception 'not_found'; end if;
  if r.verified_at is not null then raise exception 'verified'; end if;
  if private.question_marks(r.payload, p_question) is null then raise exception 'no_such_question'; end if;
  if exists (
    select 1 from public.correction_requests c
    where c.result_id = r.id and c.question_id = p_question and c.status = 'open'
  ) then
    raise exception 'already_requested';
  end if;
  insert into public.correction_requests (college_id, result_id, question_id, roll_no, subject_code, student_id, message)
  values (r.college_id, r.id, p_question, r.roll_no, r.subject_code, auth.uid(), btrim(p_message))
  returning id into v_id;
  return v_id;
end $$;

-- A teacher accepts a request. The new totals are worked out in the app, by
-- the same rules as every mark, and stored here with the answer in one go.
create or replace function public.accept_request(
  p_request bigint, p_marks numeric, p_reply text, p_payload jsonb, p_total numeric, p_percentage numeric
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  c public.correction_requests;
  r public.results;
begin
  if not public.is_staff() then raise exception 'not_allowed'; end if;
  select * into c from public.correction_requests where id = p_request and college_id = public.my_college();
  if c.id is null then raise exception 'request_not_found'; end if;
  if c.status <> 'open' then raise exception 'request_answered'; end if;
  select * into r from public.results where id = c.result_id;
  update public.results
    set payload = p_payload, total = p_total, percentage = p_percentage, updated_at = now(), verified_at = null
    where id = c.result_id;
  update public.correction_requests
    set status = 'accepted', reply = coalesce(btrim(p_reply), ''),
        old_marks = private.question_marks(r.payload, c.question_id), new_marks = p_marks,
        resolved_at = now(), resolved_by = auth.uid()
    where id = c.id;
end $$;

create or replace function public.decline_request(p_request bigint, p_reply text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  c public.correction_requests;
  r public.results;
begin
  if not public.is_staff() then raise exception 'not_allowed'; end if;
  select * into c from public.correction_requests where id = p_request and college_id = public.my_college();
  if c.id is null then raise exception 'request_not_found'; end if;
  if c.status <> 'open' then raise exception 'request_answered'; end if;
  select * into r from public.results where id = c.result_id;
  update public.correction_requests
    set status = 'declined', reply = btrim(p_reply), old_marks = private.question_marks(r.payload, c.question_id),
        resolved_at = now(), resolved_by = auth.uid()
    where id = c.id;
end $$;

-- ---------------------------------------------------------------------------
-- Row level security: who may read and change what
-- ---------------------------------------------------------------------------

alter table public.colleges enable row level security;
alter table public.profiles enable row level security;
alter table public.results enable row level security;
alter table public.correction_requests enable row level security;
alter table public.paper_defaults enable row level security;
alter table private.login_lookups enable row level security;

drop policy if exists "members read their college" on public.colleges;
create policy "members read their college" on public.colleges
  for select to authenticated using (id = public.my_college_any());

-- One's own profile, and — for teachers and the admin — everyone in the
-- college. Nobody writes profiles directly: the functions above do.
drop policy if exists "read own or college profiles" on public.profiles;
create policy "read own or college profiles" on public.profiles
  for select to authenticated
  using (id = auth.uid() or (college_id = public.my_college() and public.is_staff()));

drop policy if exists "read college or own results" on public.results;
create policy "read college or own results" on public.results
  for select to authenticated
  using (college_id = public.my_college() and (public.is_staff() or roll_no = public.my_roll()));

drop policy if exists "staff publish results" on public.results;
create policy "staff publish results" on public.results
  for insert to authenticated
  with check (college_id = public.my_college() and public.is_staff());

drop policy if exists "staff update results" on public.results;
create policy "staff update results" on public.results
  for update to authenticated
  using (college_id = public.my_college() and public.is_staff())
  with check (college_id = public.my_college() and public.is_staff());

drop policy if exists "staff unpublish results" on public.results;
create policy "staff unpublish results" on public.results
  for delete to authenticated
  using (college_id = public.my_college() and public.is_staff());

drop policy if exists "read college or own requests" on public.correction_requests;
create policy "read college or own requests" on public.correction_requests
  for select to authenticated
  using (college_id = public.my_college() and (public.is_staff() or roll_no = public.my_roll()));

drop policy if exists "own paper defaults" on public.paper_defaults;
create policy "own paper defaults" on public.paper_defaults
  for all to authenticated
  using (owner = auth.uid() and public.is_staff())
  with check (owner = auth.uid() and public.is_staff());

revoke all on public.colleges, public.profiles, public.results, public.correction_requests,
  public.paper_defaults, public.request_details, public.result_overview from anon;
grant select on public.colleges, public.profiles, public.request_details, public.result_overview to authenticated;
grant select, insert, update, delete on public.results, public.paper_defaults to authenticated;
grant select on public.correction_requests to authenticated;

-- ---------------------------------------------------------------------------
-- Answer sheets: images in a private bucket, <college>/<result>/page_N.ext
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('answer-sheets', 'answer-sheets', false, 10485760, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do nothing;

drop policy if exists "marklume staff manage answer sheets" on storage.objects;
create policy "marklume staff manage answer sheets" on storage.objects
  for all to authenticated
  using (bucket_id = 'answer-sheets' and (storage.foldername(name))[1] = public.my_college()::text and public.is_staff())
  with check (bucket_id = 'answer-sheets' and (storage.foldername(name))[1] = public.my_college()::text and public.is_staff());

drop policy if exists "marklume students read own answer sheets" on storage.objects;
create policy "marklume students read own answer sheets" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'answer-sheets'
    and exists (
      select 1 from public.results r
      where r.id::text = (storage.foldername(name))[2]
        and r.college_id = public.my_college()
        and r.roll_no = public.my_roll()
    )
  );

-- ---------------------------------------------------------------------------
-- Who may call which function
-- ---------------------------------------------------------------------------

revoke all on schema private from public, anon, authenticated;

-- Run only by the sign-up trigger, never called directly.
revoke execute on function public.handle_new_user() from public, anon, authenticated;

revoke execute on function
  public.my_college(), public.my_college_any(), public.is_staff(), public.is_admin(), public.my_roll(),
  public.marklume_schema(), public.college_name(text), public.check_signup(text, text, text, text),
  public.email_for_login(text), public.set_teacher_status(uuid, public.member_status),
  public.set_student_status(uuid, public.member_status), public.mark_seen(bigint), public.verify_result(bigint),
  public.request_correction(bigint, text, text),
  public.accept_request(bigint, numeric, text, jsonb, numeric, numeric), public.decline_request(bigint, text)
from public, anon;

-- Before signing in: only these.
grant execute on function
  public.marklume_schema(), public.college_name(text), public.check_signup(text, text, text, text),
  public.email_for_login(text)
to anon, authenticated;

-- Signed in: the rest, each checking who is asking.
grant execute on function
  public.my_college(), public.my_college_any(), public.is_staff(), public.is_admin(), public.my_roll(),
  public.set_teacher_status(uuid, public.member_status), public.set_student_status(uuid, public.member_status),
  public.mark_seen(bigint), public.verify_result(bigint), public.request_correction(bigint, text, text),
  public.accept_request(bigint, numeric, text, jsonb, numeric, numeric), public.decline_request(bigint, text)
to authenticated;
