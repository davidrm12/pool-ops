-- =====================================================================
-- Cloro Diego · Scheduling (run ONCE in the Supabase SQL Editor, after
-- deploying the `reports` Edge Function). Replace the two values marked ⟨…⟩.
-- =====================================================================
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- 1) Where the Edge Function lives, and the shared secret it checks.
--    ⟨PROJECT_URL⟩ = Project Settings → API → Project URL (https://xxxx.supabase.co)
--    ⟨CRON_SECRET⟩ = any long random string; set the SAME value as the
--                    CRON_SECRET secret of the Edge Function.
select vault.create_secret('⟨PROJECT_URL⟩', 'project_url');
select vault.create_secret('⟨CRON_SECRET⟩', 'cron_secret');

-- 2) Jobs. pg_cron runs in UTC: 13:00 UTC = 7:00 a.m. in Torreón (UTC−6, no daylight saving).
select cron.schedule('cloro-daily',  '0 13 * * *', $$ select automation_daily(); $$);   -- every day 7:00
select cron.schedule('cloro-weekly', '5 13 * * 1', $$ select send_report('weekly'); $$); -- Mondays 7:05

-- Useful checks:
--   select * from cron.job;                                         -- scheduled jobs
--   select * from cron.job_run_details order by start_time desc limit 10;
--   select * from automation_runs order by ran_at desc limit 20;    -- what each run did
--   select automation_daily();                                      -- run the daily job now
-- To stop a job:  select cron.unschedule('cloro-daily');
