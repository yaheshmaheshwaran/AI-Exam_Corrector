-- Empties every Marklume table and deletes every account, for starting over
-- with test data. Tables, rules and the storage bucket are kept. Cannot be
-- undone. Uploaded answer sheets are not removed: Supabase blocks deleting
-- them from SQL, so empty the answer-sheets bucket from Storage instead.
begin;

truncate public.correction_requests, public.results, public.paper_defaults,
         public.profiles, public.colleges, private.login_lookups
  restart identity cascade;

-- Accounts; their sessions and identities go with them.
delete from auth.users;

commit;
