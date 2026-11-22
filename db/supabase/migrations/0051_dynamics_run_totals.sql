-- =============================================================================
-- 0051  A feed's last result is the whole run, not its last batch
--
-- Found on staging, 31 October: the Worker sends a view in batches of 400 rows,
-- and each batch overwrote the feed's last_result, so training showed "29
-- rows" after reading 4,029. Now each batch of the same run adds to it, and a
-- new run starts afresh. The total carries the run's id.
--
-- Safe to run twice.
-- =============================================================================

create or replace function app.dynamics_add_result(p_old jsonb, p_run uuid, p_new jsonb) returns jsonb
language sql immutable set search_path = ''
as $$
  select case
    when p_old is null or p_old ->> 'run' is distinct from p_run::text
      then p_new || jsonb_build_object('run', p_run)
    else jsonb_build_object(
      'run', p_run,
      'read', coalesce((p_old ->> 'read')::int, 0) + coalesce((p_new ->> 'read')::int, 0),
      'unreadable', coalesce((p_old ->> 'unreadable')::int, 0) + coalesce((p_new ->> 'unreadable')::int, 0),
      'decided', coalesce((
        select jsonb_object_agg(k, n) from (
          select k, sum(v::int) as n
            from (select key as k, value as v from jsonb_each_text(coalesce(p_old -> 'decided', '{}'))
                  union all
                  select key, value from jsonb_each_text(coalesce(p_new -> 'decided', '{}'))) u
           group by k) t), '{}'::jsonb))
      || case when p_new ? 'waiting' then jsonb_build_object('waiting', p_new -> 'waiting') else '{}'::jsonb end
  end;
$$;

create or replace function app.dynamics_feed_result() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_run uuid;
begin
  -- Only one run is ever running (dynamics_run_begin sees to it), so a batch
  -- written while one runs belongs to it, and is added to what that run has
  -- already written. dynamics_record itself is left exactly as 0049 has it.
  if new.last_result is not distinct from old.last_result or new.last_result ? 'run' then
    return new;
  end if;
  select id into v_run from public.dynamics_runs where status = 'running' order by started_at desc limit 1;
  if v_run is not null then
    new.last_result := app.dynamics_add_result(old.last_result, v_run, new.last_result);
  end if;
  return new;
end;
$$;
revoke all on function app.dynamics_feed_result() from public;

drop trigger if exists dynamics_feed_result on public.dynamics_feeds;
create trigger dynamics_feed_result before update of last_result on public.dynamics_feeds
  for each row execute function app.dynamics_feed_result();
