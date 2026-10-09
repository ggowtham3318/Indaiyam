drop policy if exists audit_insert_server on app.audit_logs;
drop policy if exists payments_staff_write on app.payments;

create policy payments_staff_read_only on app.payments
for select to authenticated using (app.is_staff());

create policy refunds_admin_insert on app.refunds
for insert to authenticated with check (app.is_admin());

drop policy if exists refunds_staff_write on app.refunds;

create or replace function app.prevent_ledger_mutation() returns trigger
language plpgsql security definer
set search_path = app, pg_catalog, pg_temp as $$
begin
  if (select auth.role()) <> 'service_role' then
    raise exception 'IMMUTABLE_LEDGER' using errcode = 'P0001';
  end if;
  return new;
end $$;

create trigger payments_immutable_update
before update or delete on app.payments
for each row execute function app.prevent_ledger_mutation();

create trigger payment_events_immutable_update
before update or delete on app.payment_events
for each row execute function app.prevent_ledger_mutation();

create trigger audit_logs_immutable_update
before update or delete on app.audit_logs
for each row execute function app.prevent_ledger_mutation();
