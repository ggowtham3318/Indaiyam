create or replace function app.guard_profile_moderation_fields() returns trigger
language plpgsql security definer
set search_path = app, pg_catalog, pg_temp as $$
begin
  if (select auth.role()) <> 'service_role' and not app.is_staff() then
    if tg_op = 'INSERT' and new.status <> 'draft' then
      raise exception 'PROFILE_REVIEW_FIELDS_FORBIDDEN' using errcode = 'P0001';
    end if;
    if tg_op = 'UPDATE' then
      if new.status in ('approved', 'suspended', 'deleted')
         and new.status is distinct from old.status then
        raise exception 'PROFILE_REVIEW_FIELDS_FORBIDDEN' using errcode = 'P0001';
      end if;
      if new.reviewed_at is distinct from old.reviewed_at
         or new.reviewed_by is distinct from old.reviewed_by
         or new.deleted_at is distinct from old.deleted_at then
        raise exception 'PROFILE_REVIEW_FIELDS_FORBIDDEN' using errcode = 'P0001';
      end if;
    end if;
  end if;
  return new;
end $$;

create trigger profiles_moderation_guard
before insert or update on app.profiles
for each row execute function app.guard_profile_moderation_fields();
