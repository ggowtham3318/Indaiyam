-- Remove the paid product and expose contact data only after an accepted interest.
drop policy if exists package_public_read on app.packages;
drop policy if exists package_staff_write on app.packages;
drop policy if exists package_quota_public_read on app.package_quotas;
drop policy if exists package_quota_staff_write on app.package_quotas;
drop policy if exists subscription_owner_read on app.subscriptions;
drop policy if exists subscription_staff_write on app.subscriptions;
drop policy if exists subscriptions_staff_read on app.subscriptions;
drop policy if exists quota_owner_read on app.subscription_quotas;
drop policy if exists quotas_staff_read on app.subscription_quotas;
drop policy if exists payments_owner_read on app.payments;
drop policy if exists payments_staff_write on app.payments;
drop policy if exists payments_staff_read on app.payments;
drop policy if exists payments_staff_read_only on app.payments;
drop policy if exists payment_events_staff_read on app.payment_events;
drop policy if exists refunds_staff_read on app.refunds;
drop policy if exists refunds_admin_insert on app.refunds;
drop policy if exists refunds_staff_write on app.refunds;
drop policy if exists contacts_owner_read on app.user_contact_details;
drop policy if exists contacts_owner_read_only on app.user_contact_details;
drop policy if exists contacts_owner_write on app.user_contact_details;
drop policy if exists contacts_owner_write_only on app.user_contact_details;
drop policy if exists contacts_owner_update_only on app.user_contact_details;
drop policy if exists contacts_owner_delete_only on app.user_contact_details;

drop function if exists app.activate_due_subscriptions();
drop function if exists app.apply_subscription(uuid, uuid, text, text, bigint);
drop function if exists app.unlock_contact(uuid);

drop trigger if exists packages_updated_at on app.packages;
drop trigger if exists subscriptions_updated_at on app.subscriptions;
drop trigger if exists payments_updated_at on app.payments;
drop trigger if exists payments_immutable_update on app.payments;
drop trigger if exists payment_events_immutable_update on app.payment_events;

drop table if exists app.refunds cascade;
drop table if exists app.payment_events cascade;
drop table if exists app.payment_orders cascade;
drop table if exists app.payments cascade;
drop table if exists app.subscription_quotas cascade;
drop table if exists app.subscriptions cascade;
drop table if exists app.package_quotas cascade;
drop table if exists app.packages cascade;
drop table if exists app.contact_unlocks cascade;
drop function if exists app.prevent_ledger_mutation();

drop type if exists app.payment_status;
drop type if exists app.subscription_status;

revoke update (user_id, status, reviewed_by, reviewed_at, rejection_reason, deleted_at) on app.profiles from authenticated;
create policy contacts_owner_read_self on app.user_contact_details
for select to authenticated using (user_id = (select auth.uid()) or app.is_staff());
create policy contacts_owner_write on app.user_contact_details
for insert to authenticated with check (user_id = (select auth.uid()));
create policy contacts_owner_update on app.user_contact_details
for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy contacts_owner_delete on app.user_contact_details
for delete to authenticated using (user_id = (select auth.uid()));

create table if not exists app.contact_messages (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 1 and 120),
  email text not null check (char_length(trim(email)) between 3 and 320),
  message text not null check (char_length(trim(message)) between 1 and 5000),
  created_at timestamptz not null default now()
);
alter table app.contact_messages enable row level security;
alter table app.contact_messages force row level security;
revoke all on app.contact_messages from anon, authenticated;
create policy contact_messages_anon_insert on app.contact_messages
for insert to anon, authenticated with check (true);
create policy contact_messages_staff_read on app.contact_messages
for select to authenticated using (app.is_staff());
grant select on app.profiles to service_role;
grant select, insert on app.user_roles to service_role;
grant insert on app.user_contact_details to service_role;

-- Return one public profile; callers receive only approved, non-deleted rows.
create or replace function app.get_profile_detail(p_profile_id uuid)
returns app.public_profiles
language sql stable security definer
set search_path = ''
as $$
  select pp
  from app.public_profiles pp
  where pp.id = p_profile_id
$$;

-- Search approved profiles with offset pagination; callers must be approved.
drop function if exists app.search_profiles(app.gender, integer, integer, uuid, uuid, text, text, uuid, timestamptz, uuid, integer);
create or replace function app.search_profiles(
  p_gender app.gender default null,
  p_age_min integer default null,
  p_age_max integer default null,
  p_religion_id uuid default null,
  p_caste_id uuid default null,
  p_state text default null,
  p_city text default null,
  p_education_id uuid default null,
  p_limit integer default 20,
  p_offset integer default 0
) returns setof app.public_profiles
language plpgsql security definer
set search_path = ''
as $$
declare
  v_caller app.profiles;
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;
  if p_limit < 1 or p_limit > 100 or p_offset < 0 then raise exception 'SEARCH_INVALID_PAGING' using errcode = 'P0001'; end if;
  if p_age_min is not null and (p_age_min < 18 or p_age_min > 100)
     or p_age_max is not null and (p_age_max < 18 or p_age_max > 100)
     or p_age_min is not null and p_age_max is not null and p_age_min > p_age_max then
    raise exception 'SEARCH_INVALID_AGE' using errcode = 'P0001';
  end if;
  select * into v_caller from app.profiles
  where user_id = (select auth.uid()) and status = 'approved' and deleted_at is null;
  if not found then raise exception 'APPROVED_PROFILE_REQUIRED' using errcode = 'P0001'; end if;
  return query
  select pp.* from app.public_profiles pp
  where (p_gender is null or pp.gender = p_gender)
    and (p_age_min is null or pp.age >= p_age_min)
    and (p_age_max is null or pp.age <= p_age_max)
    and (p_religion_id is null or pp.religion_id = p_religion_id)
    and (p_caste_id is null or pp.caste_id = p_caste_id)
    and (p_state is null or lower(pp.state) = lower(p_state))
    and (p_city is null or lower(pp.city) = lower(p_city))
    and (p_education_id is null or pp.education_id = p_education_id)
    and pp.id <> v_caller.id
  order by pp.created_at desc, pp.id desc
  limit p_limit offset p_offset;
end
$$;

-- Return contact data only to staff or approved users with an accepted interest.
create or replace function app.get_contact_details(p_target_user_id uuid)
returns app.user_contact_details
language plpgsql security definer
set search_path = ''
as $$
declare
  v_contact app.user_contact_details;
  v_caller_status app.profile_status;
  v_target_status app.profile_status;
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;
  select status into v_caller_status from app.profiles
  where user_id = (select auth.uid()) and deleted_at is null;
  select status into v_target_status from app.profiles
  where user_id = p_target_user_id and deleted_at is null;
  if app.is_staff() then null;
  elsif v_caller_status <> 'approved' or v_target_status <> 'approved'
     or not exists (
       select 1 from app.interests i
       where i.status = 'accepted'
         and ((i.sender_user_id = (select auth.uid()) and i.receiver_user_id = p_target_user_id)
           or (i.sender_user_id = p_target_user_id and i.receiver_user_id = (select auth.uid())))
     ) then
    raise exception 'CONTACT_NOT_AVAILABLE' using errcode = 'P0001';
  end if;
  select * into v_contact from app.user_contact_details where user_id = p_target_user_id;
  if not found then raise exception 'CONTACT_NOT_FOUND' using errcode = 'P0001'; end if;
  return v_contact;
end
$$;

-- Send an interest as the authenticated user; no subscription or quota is required.
create or replace function app.send_interest(p_receiver_user_id uuid, p_message text default null)
returns app.interests
language plpgsql security definer
set search_path = ''
as $$
declare v_interest app.interests;
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;
  if p_receiver_user_id = (select auth.uid()) then raise exception 'INTEREST_SELF' using errcode = 'P0001'; end if;
  if not exists (select 1 from app.profiles where user_id = (select auth.uid()) and status = 'approved' and deleted_at is null)
     or not exists (select 1 from app.profiles where user_id = p_receiver_user_id and status = 'approved' and deleted_at is null) then
    raise exception 'APPROVED_PROFILE_REQUIRED' using errcode = 'P0001';
  end if;
  if exists (select 1 from app.interests where sender_user_id = (select auth.uid()) and receiver_user_id = p_receiver_user_id and status in ('pending','accepted')) then
    raise exception 'INTEREST_ALREADY_EXISTS' using errcode = 'P0001';
  end if;
  insert into app.interests(sender_user_id, receiver_user_id, message)
  values ((select auth.uid()), p_receiver_user_id, nullif(trim(p_message), ''))
  returning * into v_interest;
  return v_interest;
end
$$;

-- Accept or decline a pending interest; only its receiver may respond.
create or replace function app.respond_interest(p_interest_id uuid, p_status app.interest_status)
returns app.interests
language plpgsql security definer
set search_path = ''
as $$
declare v_interest app.interests;
begin
  if p_status not in ('accepted','declined') then raise exception 'INTEREST_INVALID_RESPONSE' using errcode = 'P0001'; end if;
  update app.interests set status = p_status, responded_at = now()
  where id = p_interest_id and receiver_user_id = (select auth.uid()) and status = 'pending'
  returning * into v_interest;
  if not found then raise exception 'INTEREST_NOT_FOUND' using errcode = 'P0001'; end if;
  return v_interest;
end
$$;

-- Remove a pending or accepted interest owned by the authenticated sender.
create or replace function app.withdraw_interest(p_interest_id uuid)
returns app.interests
language plpgsql security definer
set search_path = ''
as $$
declare v_interest app.interests;
begin
  update app.interests set status = 'withdrawn'
  where id = p_interest_id and sender_user_id = (select auth.uid()) and status in ('pending','accepted')
  returning * into v_interest;
  if not found then raise exception 'INTEREST_NOT_FOUND' using errcode = 'P0001'; end if;
  return v_interest;
end
$$;

-- Add a pending photo for the owner; storage enforces bucket, path, size, and MIME rules.
create or replace function app.add_profile_photo(
  p_profile_id uuid,
  p_storage_path text,
  p_is_primary boolean default false,
  p_is_blurred boolean default false,
  p_is_private boolean default false
)
returns app.profile_photos
language plpgsql security definer
set search_path = ''
as $$
declare v_photo app.profile_photos;
begin
  if not exists (
    select 1 from app.profiles
    where id = p_profile_id and user_id = (select auth.uid())
      and status in ('draft','pending_review','approved') and deleted_at is null
  ) then raise exception 'PROFILE_NOT_FOUND' using errcode = 'P0001'; end if;
  insert into app.profile_photos(
    profile_id, uploaded_by, storage_bucket, storage_path,
    is_primary, is_blurred, is_private
  ) values (
    p_profile_id, (select auth.uid()), 'photos-pending', p_storage_path,
    p_is_primary, p_is_blurred, p_is_private
  ) returning * into v_photo;
  return v_photo;
end
$$;

-- Return staff dashboard counts without payment or subscription data.
create or replace function app.admin_dashboard_stats()
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
begin
  if not app.is_staff() then raise exception 'STAFF_REQUIRED' using errcode = 'P0001'; end if;
  return jsonb_build_object(
    'total_profiles', (select count(*) from app.profiles where status <> 'deleted'),
    'pending_profiles', (select count(*) from app.profiles where status = 'pending_review'),
    'pending_photos', (select count(*) from app.profile_photos where status = 'pending'),
    'open_reports', (select count(*) from app.reports where status in ('open','reviewing'))
  );
end
$$;

create or replace function app.admin_list_pending_profiles()
returns setof app.profiles language sql security definer set search_path = '' as $$
  select p from app.profiles p where p.status = 'pending_review' and app.is_staff()
$$;

create or replace function app.admin_list_pending_photos()
returns setof app.profile_photos language sql security definer set search_path = '' as $$
  select p from app.profile_photos p where p.status = 'pending' and app.is_staff()
$$;

create or replace function app.admin_list_users()
returns table (user_id uuid, email text, status app.profile_status, created_at timestamptz)
language sql security definer set search_path = '' as $$
  select p.user_id, u.email, p.status, p.created_at
  from app.profiles p join auth.users u on u.id = p.user_id
  where app.is_staff()
  order by p.created_at desc
$$;

create or replace function app.admin_set_profile_status(p_profile_id uuid, p_status app.profile_status, p_reason text default null)
returns app.profiles language plpgsql security definer set search_path = '' as $$
declare v_profile app.profiles;
begin
  if not app.is_staff() then raise exception 'STAFF_REQUIRED' using errcode = 'P0001'; end if;
  if p_status not in ('approved','rejected','suspended','deleted') then raise exception 'PROFILE_INVALID_STATUS' using errcode = 'P0001'; end if;
  update app.profiles set status = p_status, reviewed_at = now(), reviewed_by = (select auth.uid()),
    rejection_reason = p_reason, deleted_at = case when p_status = 'deleted' then now() else null end
  where id = p_profile_id returning * into v_profile;
  if not found then raise exception 'PROFILE_NOT_FOUND' using errcode = 'P0001'; end if;
  return v_profile;
end
$$;

revoke all on function app.admin_get_contact(uuid, text) from public, anon, authenticated;
revoke all on function app.admin_dashboard_stats() from public, anon, authenticated;
revoke all on function app.add_profile_photo(uuid, text, boolean, boolean, boolean) from public, anon, authenticated;
revoke all on function app.search_profiles(app.gender, integer, integer, uuid, uuid, text, text, uuid, integer, integer) from public, anon, authenticated;
grant execute on function app.search_profiles(app.gender, integer, integer, uuid, uuid, text, text, uuid, integer, integer) to authenticated;
grant execute on function app.get_profile_detail(uuid) to anon, authenticated;
grant execute on function app.get_contact_details(uuid) to authenticated;
grant execute on function app.send_interest(uuid, text) to authenticated;
grant execute on function app.respond_interest(uuid, app.interest_status) to authenticated;
grant execute on function app.withdraw_interest(uuid) to authenticated;
grant execute on function app.add_profile_photo(uuid, text, boolean, boolean, boolean) to authenticated;
grant execute on function app.admin_dashboard_stats() to authenticated;
grant execute on function app.admin_list_pending_profiles() to authenticated;
grant execute on function app.admin_list_pending_photos() to authenticated;
grant execute on function app.admin_list_users() to authenticated;
grant execute on function app.admin_set_profile_status(uuid, app.profile_status, text) to authenticated;
alter function app.get_profile_detail(uuid) set search_path = '';
alter function app.get_contact_details(uuid) set search_path = '';
alter function app.send_interest(uuid, text) set search_path = '';
alter function app.respond_interest(uuid, app.interest_status) set search_path = '';
alter function app.withdraw_interest(uuid) set search_path = '';
alter function app.add_profile_photo(uuid, text, boolean, boolean, boolean) set search_path = '';
alter function app.admin_dashboard_stats() set search_path = '';
alter function app.search_profiles(app.gender, integer, integer, uuid, uuid, text, text, uuid, integer, integer) set search_path = '';
