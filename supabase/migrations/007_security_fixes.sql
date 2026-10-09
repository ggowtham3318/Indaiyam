-- A1: Make interaction, report, shortlist, contact, consent, and photo writes RPC-only or owner-only.
drop policy if exists interests_sender_insert on app.interests;
drop policy if exists interests_participant_update on app.interests;
drop policy if exists reports_owner_insert on app.reports;
drop policy if exists photos_owner_update on app.profile_photos;
drop policy if exists profiles_owner_insert on app.profiles;
drop policy if exists shortlist_owner on app.shortlists;
drop policy if exists contacts_owner_read on app.user_contact_details;
drop policy if exists contacts_owner_write on app.user_contact_details;
drop policy if exists consent_owner on app.consent_records;
drop policy if exists photos_owner_insert on app.profile_photos;

create policy interests_rpc_insert_only on app.interests
for insert to authenticated with check (false);
create policy interests_rpc_update_only on app.interests
for update to authenticated using (false) with check (false);
create policy reports_rpc_insert_only on app.reports
for insert to authenticated with check (false);
create policy photos_rpc_insert_only on app.profile_photos
for insert to authenticated with check (false);
create policy photos_rpc_update_only on app.profile_photos
for update to authenticated using (false) with check (false);
drop policy if exists photos_owner_or_approved on app.profile_photos;
create policy photos_owner_or_approved on app.profile_photos
for select to authenticated using (
  (uploaded_by = (select auth.uid()) and status = 'pending')
  or app.is_staff()
  or (status = 'approved' and storage_bucket = 'photos-approved')
);
create policy shortlist_owner_read on app.shortlists
for select to authenticated using (user_id = (select auth.uid()));
create policy shortlist_rpc_write_only on app.shortlists
for insert to authenticated with check (false);
create policy shortlist_rpc_delete_only on app.shortlists
for delete to authenticated using (false);
create policy contacts_owner_read_only on app.user_contact_details
for select to authenticated using (user_id = (select auth.uid()) or exists (
  select 1 from app.contact_unlocks u
  where u.viewer_user_id = (select auth.uid())
    and u.profile_user_id = user_id
    and u.expires_at > now()
));
create policy contacts_owner_write_only on app.user_contact_details
for insert to authenticated with check (user_id = (select auth.uid()));
create policy contacts_owner_update_only on app.user_contact_details
for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy contacts_owner_delete_only on app.user_contact_details
for delete to authenticated using (user_id = (select auth.uid()));
create policy consent_owner_read on app.consent_records
for select to authenticated using (user_id = (select auth.uid()) or app.is_staff());
create policy consent_owner_insert on app.consent_records
for insert to authenticated with check (user_id = (select auth.uid()));

-- A1: Column privileges prevent owner updates to identity, moderation, and verification fields.
revoke update (user_id, status, reviewed_by, reviewed_at, rejection_reason, deleted_at) on app.profiles from authenticated;

-- A2/A3/B10/B12: Replace the exposed view with safe fields and expose search only through the guarded definer RPC.
revoke all on app.public_profiles from anon, authenticated;
drop function if exists app.search_profiles(app.gender, integer, integer, uuid, uuid, text, text, uuid, timestamptz, uuid, integer);
drop view app.public_profiles;
create view app.public_profiles
with (security_barrier = true)
as
select
  p.id,
  p.gender,
  extract(year from age(current_date, p.date_of_birth))::integer as age,
  p.profile_for,
  p.display_name,
  p.mother_tongue,
  p.religion_id,
  r.name as religion_name,
  p.caste_id,
  c.name as caste_name,
  p.marital_status_id,
  ms.name as marital_status_name,
  p.height_cm,
  p.state,
  p.city,
  p.education_id,
  e.name as education_name,
  p.occupation_category_id,
  oc.name as occupation_category_name,
  p.occupation,
  p.created_at
from app.profiles p
left join app.lookup_religions r on r.id = p.religion_id
left join app.lookup_castes c on c.id = p.caste_id
left join app.lookup_marital_statuses ms on ms.id = p.marital_status_id
left join app.lookup_education e on e.id = p.education_id
left join app.lookup_occupation_categories oc on oc.id = p.occupation_category_id
where p.status = 'approved' and p.deleted_at is null;

create table if not exists app.search_rate_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  window_started_at timestamptz not null default now(),
  request_count integer not null default 0 check (request_count >= 0)
);
alter table app.search_rate_limits enable row level security;
alter table app.search_rate_limits force row level security;
revoke all on app.search_rate_limits from anon, authenticated;

create index if not exists profiles_status_gender_dob_idx
on app.profiles (status, gender, date_of_birth);
create index if not exists profiles_religion_caste_idx
on app.profiles (religion_id, caste_id);
create index if not exists profiles_lower_state_city_idx
on app.profiles (lower(state), lower(city))
where status = 'approved' and deleted_at is null;

-- A2: Logged-out landing pages receive only safe teaser columns and never more than twelve rows.
create or replace function app.public_teaser_profiles()
returns table (profile_id uuid, display_name text, age integer, gender app.gender, state text)
language sql stable security definer
set search_path = app, pg_temp
as $$
  select p.id, p.display_name,
    extract(year from age(current_date, p.date_of_birth))::integer,
    p.gender, p.state
  from app.profiles p
  where p.status = 'approved' and p.deleted_at is null
  order by p.created_at desc, p.id desc
  limit 12
$$;

-- A2/A3/B10/B12: Search requires an approved caller, excludes self and both block directions, and rate-limits pages.
create or replace function app.search_profiles(
  p_gender app.gender default null,
  p_age_min integer default null,
  p_age_max integer default null,
  p_religion_id uuid default null,
  p_caste_id uuid default null,
  p_state text default null,
  p_city text default null,
  p_marital_status_id uuid default null,
  p_cursor_created_at timestamptz default null,
  p_cursor_id uuid default null,
  p_limit integer default 20
) returns setof app.public_profiles
language plpgsql security definer
set search_path = app, pg_temp
as $$
declare
  v_caller app.profiles;
  v_gender app.gender;
  v_rate app.search_rate_limits;
  v_min_dob date;
  v_max_dob date;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;
  if p_limit < 1 or p_limit > 100 then raise exception 'SEARCH_INVALID_LIMIT' using errcode = 'P0001'; end if;
  if p_age_min is not null and (p_age_min < 18 or p_age_min > 100) then raise exception 'SEARCH_INVALID_AGE' using errcode = 'P0001'; end if;
  if p_age_max is not null and (p_age_max < 18 or p_age_max > 100) then raise exception 'SEARCH_INVALID_AGE' using errcode = 'P0001'; end if;
  if p_age_min is not null and p_age_max is not null and p_age_min > p_age_max then raise exception 'SEARCH_INVALID_RANGE' using errcode = 'P0001'; end if;
  select * into v_caller from app.profiles where user_id = auth.uid() and status = 'approved' and deleted_at is null;
  if not found then raise exception 'APPROVED_PROFILE_REQUIRED' using errcode = 'P0001'; end if;

  insert into app.search_rate_limits(user_id, window_started_at, request_count)
  values (auth.uid(), now(), 0)
  on conflict (user_id) do nothing;
  select * into v_rate from app.search_rate_limits where user_id = auth.uid() for update;
  if v_rate.window_started_at < now() - interval '1 minute' then
    update app.search_rate_limits set window_started_at = now(), request_count = 1 where user_id = auth.uid()
    returning * into v_rate;
  elsif v_rate.request_count >= 60 then
    raise exception 'SEARCH_RATE_LIMIT' using errcode = 'P0001';
  else
    update app.search_rate_limits set request_count = request_count + 1 where user_id = auth.uid()
    returning * into v_rate;
  end if;

  v_min_dob := case when p_age_max is null then null else (current_date - make_interval(years => p_age_max))::date end;
  v_max_dob := case when p_age_min is null then null else (current_date - make_interval(years => p_age_min) - interval '1 day')::date end;
  select case when v_caller.gender = 'male' then 'female'::app.gender when v_caller.gender = 'female' then 'male'::app.gender else null end into v_gender;
  return query
  select pp.*
  from app.public_profiles pp
  join app.profiles target on target.id = pp.id
  where target.user_id <> auth.uid()
    and (p_gender is not null and pp.gender = p_gender or p_gender is null and (v_gender is null or pp.gender = v_gender))
    and (v_min_dob is null or target.date_of_birth >= v_min_dob)
    and (v_max_dob is null or target.date_of_birth <= v_max_dob)
    and (p_religion_id is null or pp.religion_id = p_religion_id)
    and (p_caste_id is null or pp.caste_id = p_caste_id)
    and (p_state is null or lower(pp.state) = lower(p_state))
    and (p_city is null or lower(pp.city) = lower(p_city))
    and (p_marital_status_id is null or pp.marital_status_id = p_marital_status_id)
    and (p_cursor_created_at is null or (pp.created_at, pp.id) < (p_cursor_created_at, p_cursor_id))
    and not exists (select 1 from app.blocks b where b.blocker_user_id = auth.uid() and b.blocked_user_id = target.user_id)
    and not exists (select 1 from app.blocks b where b.blocker_user_id = target.user_id and b.blocked_user_id = auth.uid())
  order by pp.created_at desc, pp.id desc
  limit p_limit;
end
$$;

-- A4: Direct audit inserts are forbidden; SECURITY DEFINER code supplies the actor from auth.uid().
drop policy if exists audit_insert_server on app.audit_logs;
revoke insert on app.audit_logs from public, anon, authenticated, service_role;
revoke update, delete on app.audit_logs from public, anon, authenticated, service_role;
revoke all on app.user_roles from authenticated, anon;

-- A4: Even service_role cannot mutate the audit history; only the definer writer can append rows.
drop trigger if exists audit_logs_immutable_update on app.audit_logs;
create or replace function app.prevent_audit_mutation() returns trigger
language plpgsql security definer
set search_path = app, pg_temp
as $$
begin
  raise exception 'IMMUTABLE_AUDIT_LOG' using errcode = 'P0001';
  return old;
end
$$;
create trigger audit_logs_immutable_update
before update or delete on app.audit_logs
for each row execute function app.prevent_audit_mutation();
create or replace function app.write_audit(
  p_action text, p_target_table text, p_target_id uuid, p_before jsonb, p_after jsonb, p_actor_role app.user_role default null
) returns void
language plpgsql security definer
set search_path = app, pg_temp
as $$
begin
  insert into app.audit_logs(actor_user_id, actor_role, action, target_table, target_id, before_data, after_data)
  values (auth.uid(), coalesce(p_actor_role, case when auth.uid() is null then null::app.user_role when app.is_admin() then 'admin'::app.user_role else 'moderator'::app.user_role end), p_action, p_target_table, p_target_id, p_before, p_after);
end
$$;

-- A5/A6: Store the server-authoritative order facts used by webhook processing.
create table if not exists app.payment_orders (
  id uuid primary key default gen_random_uuid(),
  provider text not null default 'razorpay',
  provider_order_id text not null unique,
  user_id uuid not null references auth.users(id),
  package_id uuid not null references app.packages(id),
  amount_paise bigint not null check (amount_paise >= 0),
  currency char(3) not null default 'INR',
  status text not null default 'created' check (status in ('created','captured','failed','cancelled')),
  provider_payment_id text unique,
  created_at timestamptz not null default now(),
  captured_at timestamptz
);
alter table app.payment_orders enable row level security;
alter table app.payment_orders force row level security;
revoke all on app.payment_orders from anon, authenticated;

-- A5: Financial tables are readable by staff but writable only by service_role.
drop policy if exists subscription_staff_write on app.subscriptions;
drop policy if exists payments_staff_read_only on app.payments;
drop policy if exists refunds_admin_insert on app.refunds;
create policy subscriptions_staff_read on app.subscriptions for select to authenticated using (app.is_staff());
create policy quotas_staff_read on app.subscription_quotas for select to authenticated using (app.is_staff());
create policy payments_staff_read on app.payments for select to authenticated using (app.is_staff());
drop policy if exists refunds_staff_read on app.refunds;
create policy refunds_staff_read on app.refunds for select to authenticated using (app.is_staff());
revoke insert, update, delete on app.subscriptions, app.subscription_quotas, app.payments, app.payment_events, app.refunds from authenticated, anon;

-- A6: Queue renewals/upgrades after the current plan; do not expire unused entitlements.
create or replace function app.apply_subscription(
  p_user_id uuid, p_package_id uuid, p_order_id text, p_payment_id text, p_amount_paise bigint
) returns app.subscriptions
language plpgsql security definer
set search_path = app, pg_temp
as $$
declare
  v_order app.payment_orders;
  v_package app.packages;
  v_sub app.subscriptions;
  v_quota app.package_quotas;
  v_current app.subscriptions;
  v_start timestamptz;
  v_status app.subscription_status;
begin
  perform pg_advisory_xact_lock(hashtext(p_order_id));
  if auth.role() <> 'service_role' and not app.is_admin() then raise exception 'SERVICE_REQUIRED' using errcode = 'P0001'; end if;
  select * into v_order from app.payment_orders where provider_order_id = p_order_id for update;
  if not found then raise exception 'PAYMENT_ORDER_NOT_FOUND' using errcode = 'P0001'; end if;
  if v_order.user_id <> p_user_id or v_order.package_id <> p_package_id or v_order.amount_paise <> p_amount_paise then raise exception 'PAYMENT_ORDER_MISMATCH' using errcode = 'P0001'; end if;
  if exists (select 1 from app.payments where provider_order_id = p_order_id and status = 'captured') then
    select * into v_sub from app.subscriptions where razorpay_order_id = p_order_id;
    return v_sub;
  end if;
  select * into v_package from app.packages where id = v_order.package_id and is_active;
  if not found then raise exception 'PACKAGE_NOT_FOUND' using errcode = 'P0001'; end if;
  select * into v_quota from app.package_quotas where package_id = v_package.id;
  if not found then raise exception 'PACKAGE_QUOTA_NOT_FOUND' using errcode = 'P0001'; end if;
  select * into v_current from app.subscriptions where user_id = v_order.user_id and status in ('active','pending') order by ends_at desc nulls last for update limit 1;
  v_start := greatest(now(), coalesce(v_current.ends_at, now()));
  v_status := case when v_start <= now() then 'active' else 'pending' end;
  insert into app.subscriptions(user_id, package_id, status, starts_at, ends_at, razorpay_order_id, razorpay_payment_id)
  values (v_order.user_id, v_package.id, v_status, v_start, v_start + make_interval(days => v_package.validity_days), p_order_id, p_payment_id)
  returning * into v_sub;
  insert into app.subscription_quotas(subscription_id, contact_views_remaining, interests_remaining, photo_slots_remaining, unlimited_contact_views, unlimited_interests, unlimited_photo_slots)
  values (v_sub.id, v_quota.contact_views, v_quota.interests_sent, v_quota.photo_slots, v_quota.unlimited_contact_views, v_quota.unlimited_interests, v_quota.unlimited_photo_slots);
  insert into app.payments(user_id, subscription_id, provider_order_id, provider_payment_id, amount_paise, status, paid_at)
  values (v_order.user_id, v_sub.id, p_order_id, p_payment_id, p_amount_paise, 'captured', now());
  update app.payment_orders set status = 'captured', provider_payment_id = p_payment_id, captured_at = now() where id = v_order.id;
  perform app.write_audit('apply_subscription', 'subscriptions', v_sub.id, null, to_jsonb(v_sub), null);
  return v_sub;
end
$$;

-- A6: Promote queued plans only when their start time arrives.
create or replace function app.activate_due_subscriptions()
returns void
language plpgsql security definer
set search_path = app, pg_temp
as $$
begin
  update app.subscriptions set status = 'expired' where status = 'active' and ends_at <= now();
  update app.subscriptions set status = 'active'
  where status = 'pending' and starts_at <= now()
    and not exists (select 1 from app.subscriptions a where a.user_id = subscriptions.user_id and a.status = 'active' and a.ends_at > now());
end
$$;

-- A7/B12: Rebuild contact unlocking with block-first ordering, approved caller, row lock, and post-lock idempotency.
create or replace function app.unlock_contact(p_profile_user_id uuid)
returns app.user_contact_details
language plpgsql security definer
set search_path = app, pg_temp
as $$
declare
  v_contact app.user_contact_details;
  v_sub app.subscriptions;
  v_quota app.subscription_quotas;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;
  if p_profile_user_id = auth.uid() then raise exception 'CONTACT_SELF' using errcode = 'P0001'; end if;
  if exists (select 1 from app.blocks where (blocker_user_id = auth.uid() and blocked_user_id = p_profile_user_id) or (blocker_user_id = p_profile_user_id and blocked_user_id = auth.uid())) then raise exception 'CONTACT_BLOCKED' using errcode = 'P0001'; end if;
  if not exists (select 1 from app.profiles where user_id = p_profile_user_id and status = 'approved' and deleted_at is null) then raise exception 'PROFILE_NOT_FOUND' using errcode = 'P0001'; end if;
  if not exists (select 1 from app.profiles where user_id = auth.uid() and status = 'approved' and deleted_at is null) then raise exception 'APPROVED_PROFILE_REQUIRED' using errcode = 'P0001'; end if;
  perform app.activate_due_subscriptions();
  select * into v_sub from app.subscriptions where user_id = auth.uid() and status = 'active' and starts_at <= now() and ends_at > now() order by ends_at desc limit 1;
  if not found then raise exception 'SUBSCRIPTION_REQUIRED' using errcode = 'P0001'; end if;
  select * into v_quota from app.subscription_quotas where subscription_id = v_sub.id for update;
  if not found then raise exception 'QUOTA_NOT_FOUND' using errcode = 'P0001'; end if;
  if exists (select 1 from app.contact_unlocks where viewer_user_id = auth.uid() and profile_user_id = p_profile_user_id and expires_at > now()) then
    select * into v_contact from app.user_contact_details where user_id = p_profile_user_id;
    if not found then raise exception 'CONTACT_NOT_FOUND' using errcode = 'P0001'; end if;
    return v_contact;
  end if;
  if not v_quota.unlimited_contact_views and v_quota.contact_views_remaining <= 0 then raise exception 'CONTACT_QUOTA_EXHAUSTED' using errcode = 'P0001'; end if;
  if not v_quota.unlimited_contact_views then update app.subscription_quotas set contact_views_remaining = contact_views_remaining - 1 where id = v_quota.id; end if;
  insert into app.contact_unlocks(viewer_user_id, profile_user_id, subscription_id, expires_at) values (auth.uid(), p_profile_user_id, v_sub.id, v_sub.ends_at)
  on conflict (viewer_user_id, profile_user_id) do update set expires_at = excluded.expires_at;
  select * into v_contact from app.user_contact_details where user_id = p_profile_user_id;
  if not found then raise exception 'CONTACT_NOT_FOUND' using errcode = 'P0001'; end if;
  return v_contact;
end
$$;

-- B1/B2/B12: Interest sending requires two approved profiles, a locked quota, one daily count, and a bounded message.
create or replace function app.send_interest(p_receiver_user_id uuid, p_message text default null)
returns app.interests
language plpgsql security definer
set search_path = app, pg_temp
as $$
declare
  v_interest app.interests;
  v_sub app.subscriptions;
  v_quota app.subscription_quotas;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;
  if p_receiver_user_id = auth.uid() then raise exception 'INTEREST_SELF' using errcode = 'P0001'; end if;
  if p_message is not null and char_length(p_message) > 500 then raise exception 'INTEREST_MESSAGE_TOO_LONG' using errcode = 'P0001'; end if;
  if not exists (select 1 from app.profiles where user_id = auth.uid() and status = 'approved' and deleted_at is null) then raise exception 'APPROVED_PROFILE_REQUIRED' using errcode = 'P0001'; end if;
  if not exists (select 1 from app.profiles where user_id = p_receiver_user_id and status = 'approved' and deleted_at is null) then raise exception 'RECEIVER_PROFILE_NOT_FOUND' using errcode = 'P0001'; end if;
  if exists (select 1 from app.blocks where (blocker_user_id = auth.uid() and blocked_user_id = p_receiver_user_id) or (blocker_user_id = p_receiver_user_id and blocked_user_id = auth.uid())) then raise exception 'INTEREST_BLOCKED' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtext('interest:' || auth.uid()::text));
  perform app.activate_due_subscriptions();
  select * into v_sub from app.subscriptions where user_id = auth.uid() and status = 'active' and starts_at <= now() and ends_at > now() order by ends_at desc limit 1;
  if not found then raise exception 'SUBSCRIPTION_REQUIRED' using errcode = 'P0001'; end if;
  select * into v_quota from app.subscription_quotas where subscription_id = v_sub.id for update;
  if not found then raise exception 'QUOTA_NOT_FOUND' using errcode = 'P0001'; end if;
  if (select count(*) from app.interests where sender_user_id = auth.uid() and created_at >= current_date) >= 50 then raise exception 'INTEREST_DAILY_LIMIT' using errcode = 'P0001'; end if;
  if not v_quota.unlimited_interests and v_quota.interests_remaining <= 0 then raise exception 'INTEREST_QUOTA_EXHAUSTED' using errcode = 'P0001'; end if;
  if exists (select 1 from app.interests where sender_user_id = auth.uid() and receiver_user_id = p_receiver_user_id and status in ('pending','accepted')) then raise exception 'INTEREST_ALREADY_EXISTS' using errcode = 'P0001'; end if;
  if not v_quota.unlimited_interests then update app.subscription_quotas set interests_remaining = interests_remaining - 1 where id = v_quota.id; end if;
  insert into app.interests(sender_user_id, receiver_user_id, message) values (auth.uid(), p_receiver_user_id, nullif(trim(p_message), '')) returning * into v_interest;
  insert into app.notifications(user_id, notification_type, title, body, data) values (p_receiver_user_id, 'interest_received', 'New interest', 'Someone sent you an interest.', jsonb_build_object('interest_id', v_interest.id));
  return v_interest;
end
$$;

-- B2/B12: Blocks and reports validate targets, lengths, and allowed categories before writing.
create or replace function app.block_user(p_blocked_user_id uuid, p_reason text default null)
returns void
language plpgsql security definer
set search_path = app, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;
  if p_blocked_user_id = auth.uid() then raise exception 'BLOCK_SELF' using errcode = 'P0001'; end if;
  if not exists (select 1 from auth.users where id = p_blocked_user_id) then raise exception 'TARGET_USER_NOT_FOUND' using errcode = 'P0001'; end if;
  if p_reason is not null and char_length(p_reason) > 1000 then raise exception 'BLOCK_REASON_TOO_LONG' using errcode = 'P0001'; end if;
  insert into app.blocks(blocker_user_id, blocked_user_id, reason) values (auth.uid(), p_blocked_user_id, p_reason) on conflict do nothing;
end
$$;

create or replace function app.report_user(p_reported_user_id uuid, p_category text, p_description text)
returns app.reports
language plpgsql security definer
set search_path = app, pg_temp
as $$
declare v_report app.reports;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;
  if p_reported_user_id = auth.uid() then raise exception 'REPORT_SELF' using errcode = 'P0001'; end if;
  if not exists (select 1 from auth.users where id = p_reported_user_id) then raise exception 'TARGET_USER_NOT_FOUND' using errcode = 'P0001'; end if;
  if p_category not in ('fake_profile','harassment','scam','inappropriate_content','underage','other') then raise exception 'REPORT_INVALID_CATEGORY' using errcode = 'P0001'; end if;
  if char_length(p_description) > 1000 then raise exception 'REPORT_DESCRIPTION_TOO_LONG' using errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtext('report:' || auth.uid()::text));
  if (select count(*) from app.reports where reporter_user_id = auth.uid() and created_at >= current_date) >= 10 then raise exception 'REPORT_DAILY_LIMIT' using errcode = 'P0001'; end if;
  insert into app.reports(reporter_user_id, reported_user_id, category, description) values (auth.uid(), p_reported_user_id, p_category, p_description) returning * into v_report;
  return v_report;
end
$$;

-- B3: Approval uses copy-before-commit through review-photo; this RPC accepts approval only after the approved object exists.
drop function if exists app.admin_review_photo(uuid, app.photo_status, text);
create or replace function app.admin_review_photo(p_photo_id uuid, p_status app.photo_status, p_reason text default null, p_approved_storage_path text default null)
returns app.profile_photos
language plpgsql security definer
set search_path = app, pg_temp
as $$
declare v_photo app.profile_photos; v_before jsonb;
begin
  if not app.is_staff() then raise exception 'STAFF_REQUIRED' using errcode = 'P0001'; end if;
  if p_status not in ('approved','rejected','removed') then raise exception 'PHOTO_INVALID_STATUS' using errcode = 'P0001'; end if;
  if p_reason is not null and char_length(p_reason) > 1000 then raise exception 'PHOTO_REASON_TOO_LONG' using errcode = 'P0001'; end if;
  select ph.* into v_photo from app.profile_photos ph where ph.id = p_photo_id for update;
  if not found then raise exception 'PHOTO_NOT_FOUND' using errcode = 'P0001'; end if;
  v_before := to_jsonb(v_photo);
  if p_status = 'approved' then
    if p_approved_storage_path is null or not exists (select 1 from storage.objects where bucket_id = 'photos-approved' and name = p_approved_storage_path) then raise exception 'APPROVED_OBJECT_REQUIRED' using errcode = 'P0001'; end if;
    update app.profile_photos set status = 'approved', storage_bucket = 'photos-approved', storage_path = p_approved_storage_path, reviewed_at = now(), reviewed_by = auth.uid(), rejection_reason = null where id = p_photo_id returning * into v_photo;
  else
    update app.profile_photos set status = p_status, reviewed_at = now(), reviewed_by = auth.uid(), rejection_reason = p_reason where id = p_photo_id returning * into v_photo;
  end if;
  perform app.write_audit('review_photo', 'profile_photos', p_photo_id, v_before, to_jsonb(v_photo), null);
  return v_photo;
end
$$;

-- B4/B12: Users register photos only through this RPC, which locks and consumes photo slots atomically.
create or replace function app.add_profile_photo(p_profile_id uuid, p_storage_path text, p_is_primary boolean default false, p_is_blurred boolean default false, p_is_private boolean default false)
returns app.profile_photos
language plpgsql security definer
set search_path = app, pg_temp
as $$
declare v_profile app.profiles; v_sub app.subscriptions; v_quota app.subscription_quotas; v_photo app.profile_photos;
begin
  select * into v_profile from app.profiles where id = p_profile_id and user_id = auth.uid() and status in ('draft','pending_review','approved') and deleted_at is null;
  if not found then raise exception 'PROFILE_NOT_UPLOADABLE' using errcode = 'P0001'; end if;
  if p_storage_path is null or split_part(p_storage_path, '/', 1) <> auth.uid()::text then raise exception 'PHOTO_PATH_INVALID' using errcode = 'P0001'; end if;
  if not exists (select 1 from storage.objects where bucket_id = 'photos-pending' and name = p_storage_path) then raise exception 'PHOTO_OBJECT_NOT_FOUND' using errcode = 'P0001'; end if;
  perform app.activate_due_subscriptions();
  select * into v_sub from app.subscriptions where user_id = auth.uid() and status = 'active' and starts_at <= now() and ends_at > now() order by ends_at desc limit 1;
  if not found then raise exception 'SUBSCRIPTION_REQUIRED' using errcode = 'P0001'; end if;
  select * into v_quota from app.subscription_quotas where subscription_id = v_sub.id for update;
  if not found then raise exception 'QUOTA_NOT_FOUND' using errcode = 'P0001'; end if;
  if not v_quota.unlimited_photo_slots and v_quota.photo_slots_remaining <= 0 then raise exception 'PHOTO_QUOTA_EXHAUSTED' using errcode = 'P0001'; end if;
  if not v_quota.unlimited_photo_slots then update app.subscription_quotas set photo_slots_remaining = photo_slots_remaining - 1 where id = v_quota.id; end if;
  insert into app.profile_photos(profile_id, uploaded_by, storage_bucket, storage_path, is_primary, is_blurred, is_private)
  values (p_profile_id, auth.uid(), 'photos-pending', p_storage_path, p_is_primary, p_is_blurred, p_is_private) returning * into v_photo;
  return v_photo;
end
$$;

-- B11/B12: Only admins may retrieve another user's contact data, and every retrieval is audited.
create or replace function app.admin_get_contact(p_user_id uuid, p_reason text)
returns app.user_contact_details
language plpgsql security definer
set search_path = app, pg_temp
as $$
declare v_contact app.user_contact_details;
begin
  if not app.is_admin() then raise exception 'ADMIN_REQUIRED' using errcode = 'P0001'; end if;
  if p_reason is null or char_length(trim(p_reason)) < 5 or char_length(p_reason) > 500 then raise exception 'ADMIN_REASON_INVALID' using errcode = 'P0001'; end if;
  select * into v_contact from app.user_contact_details where user_id = p_user_id;
  if not found then raise exception 'CONTACT_NOT_FOUND' using errcode = 'P0001'; end if;
  perform app.write_audit('read_contact', 'user_contact_details', p_user_id, null, jsonb_build_object('reason', p_reason), 'admin');
  return v_contact;
end
$$;

-- A8/B8: Keep settings private by default and expose only explicitly prefixed public settings.
create table if not exists app.site_settings_public (
  key text primary key check (key like 'public\_%' escape '\'),
  value jsonb not null,
  updated_at timestamptz not null default now()
);
alter table app.site_settings_public enable row level security;
alter table app.site_settings_public force row level security;
drop policy if exists settings_public_read on app.site_settings;
revoke select on app.site_settings from anon, authenticated;
create policy public_settings_read on app.site_settings_public for select to anon, authenticated using (true);
create policy public_settings_admin_write on app.site_settings_public for all to authenticated using (app.is_admin()) with check (app.is_admin());
grant select on app.site_settings_public to anon, authenticated;
grant select on app.cms_pages, app.cms_banners, app.cms_faqs, app.cms_testimonials, app.cms_success_stories, app.packages, app.package_quotas to anon;

-- B12: A suspended, rejected, or deleted profile cannot upload into the pending bucket.
drop policy if exists photos_pending_owner_upload on storage.objects;
create policy photos_pending_owner_upload
on storage.objects for insert to authenticated
with check (
  bucket_id = 'photos-pending'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and exists (
    select 1 from app.profiles p
    where p.user_id = (select auth.uid())
      and p.status in ('draft','pending_review','approved')
      and p.deleted_at is null
  )
);
drop policy if exists photos_pending_owner_read on storage.objects;
create policy photos_pending_owner_read
on storage.objects for select to authenticated
using (
  bucket_id = 'photos-pending'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and exists (
    select 1 from app.profile_photos ph
    where ph.storage_bucket = 'photos-pending'
      and ph.storage_path = name
      and ph.uploaded_by = (select auth.uid())
      and ph.status = 'pending'
  )
);

-- B7: This assertion is callable by CI and fails loudly if any app table lacks forced RLS.
create or replace function app.assert_all_tables_rls()
returns void
language plpgsql security definer
set search_path = app, pg_temp
as $$
begin
  if exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'app' and c.relkind = 'r' and (not c.relrowsecurity or not c.relforcerowsecurity)
  ) then raise exception 'RLS_CATALOG_CHECK_FAILED' using errcode = 'P0001'; end if;
end
$$;

-- B5/B6/B9: Remove broad exposure and grant only the documented client/API functions.
revoke all on all functions in schema app from public, anon, authenticated;
alter default privileges in schema app revoke execute on functions from public;
alter default privileges in schema app revoke execute on functions from anon;
alter default privileges in schema app revoke execute on functions from authenticated;
grant execute on function app.is_admin() to anon, authenticated;
grant execute on function app.is_staff() to anon, authenticated;
grant execute on function app.public_teaser_profiles() to anon, authenticated;
grant execute on function app.search_profiles(app.gender, integer, integer, uuid, uuid, text, text, uuid, timestamptz, uuid, integer) to authenticated;
grant execute on function app.send_interest(uuid, text) to authenticated;
grant execute on function app.respond_interest(uuid, app.interest_status) to authenticated;
grant execute on function app.toggle_shortlist(uuid) to authenticated;
grant execute on function app.unlock_contact(uuid) to authenticated;
grant execute on function app.block_user(uuid, text) to authenticated;
grant execute on function app.report_user(uuid, text, text) to authenticated;
grant execute on function app.submit_profile_for_review(uuid) to authenticated;
grant execute on function app.admin_review_profile(uuid, app.profile_status, text) to authenticated;
grant execute on function app.admin_review_photo(uuid, app.photo_status, text, text) to authenticated;
grant execute on function app.admin_dashboard_stats() to authenticated;
grant execute on function app.add_profile_photo(uuid, text, boolean, boolean, boolean) to authenticated;
grant execute on function app.admin_get_contact(uuid, text) to authenticated;
grant execute on function app.apply_subscription(uuid, uuid, text, text, bigint) to service_role;
grant usage on schema app to service_role;
grant select on app.packages to service_role;
grant insert, select on app.payment_orders to service_role;
grant insert, update on app.payments to service_role;
grant insert on app.payment_events to service_role;
grant select on app.notifications to service_role;

-- B9: Tighten every existing helper/RPC search path without changing older migration files.
alter function app.touch_updated_at() set search_path = app, pg_temp;
alter function app.set_updated_at() set search_path = app, pg_temp;
alter function app.handle_new_user() set search_path = app, pg_temp;
alter function app.is_admin() set search_path = app, pg_temp;
alter function app.is_staff() set search_path = app, pg_temp;
alter function app.guard_profile_moderation_fields() set search_path = app, pg_temp;
alter function app.prevent_ledger_mutation() set search_path = app, pg_temp;
alter function app.prevent_audit_mutation() set search_path = app, pg_temp;
alter function app.public_teaser_profiles() set search_path = app, pg_temp;
alter function app.search_profiles(app.gender, integer, integer, uuid, uuid, text, text, uuid, timestamptz, uuid, integer) set search_path = app, pg_temp;
alter function app.send_interest(uuid, text) set search_path = app, pg_temp;
alter function app.respond_interest(uuid, app.interest_status) set search_path = app, pg_temp;
alter function app.toggle_shortlist(uuid) set search_path = app, pg_temp;
alter function app.unlock_contact(uuid) set search_path = app, pg_temp;
alter function app.block_user(uuid, text) set search_path = app, pg_temp;
alter function app.report_user(uuid, text, text) set search_path = app, pg_temp;
alter function app.submit_profile_for_review(uuid) set search_path = app, pg_temp;
alter function app.admin_review_profile(uuid, app.profile_status, text) set search_path = app, pg_temp;
alter function app.admin_review_photo(uuid, app.photo_status, text, text) set search_path = app, pg_temp;
alter function app.admin_dashboard_stats() set search_path = app, pg_temp;
alter function app.activate_due_subscriptions() set search_path = app, pg_temp;
alter function app.add_profile_photo(uuid, text, boolean, boolean, boolean) set search_path = app, pg_temp;
alter function app.admin_get_contact(uuid, text) set search_path = app, pg_temp;
alter function app.write_audit(text, text, uuid, jsonb, jsonb, app.user_role) set search_path = app, pg_temp;
alter function app.assert_all_tables_rls() set search_path = app, pg_temp;
