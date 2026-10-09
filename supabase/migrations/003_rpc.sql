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
language plpgsql stable security invoker
set search_path = app, public, pg_temp as $$
declare v_gender app.gender;
begin
  if p_limit < 1 or p_limit > 100 then raise exception 'SEARCH_INVALID_LIMIT' using errcode = 'P0001'; end if;
  if p_age_min is not null and (p_age_min < 18 or p_age_min > 100) then raise exception 'SEARCH_INVALID_AGE' using errcode = 'P0001'; end if;
  if p_age_max is not null and (p_age_max < 18 or p_age_max > 100) then raise exception 'SEARCH_INVALID_AGE' using errcode = 'P0001'; end if;
  if p_age_min is not null and p_age_max is not null and p_age_min > p_age_max then raise exception 'SEARCH_INVALID_RANGE' using errcode = 'P0001'; end if;
  select case when gender = 'male' then 'female'::app.gender when gender = 'female' then 'male'::app.gender else null end
    into v_gender from app.profiles where user_id = (select auth.uid()) and status <> 'deleted';
  return query
  select pp.*
  from app.public_profiles pp
  where (p_gender is not null and pp.gender = p_gender or p_gender is null and (v_gender is null or pp.gender = v_gender))
    and (p_age_min is null or pp.age >= p_age_min)
    and (p_age_max is null or pp.age <= p_age_max)
    and (p_religion_id is null or pp.religion_id = p_religion_id)
    and (p_caste_id is null or pp.caste_id = p_caste_id)
    and (p_state is null or lower(pp.state) = lower(p_state))
    and (p_city is null or lower(pp.city) = lower(p_city))
    and (p_marital_status_id is null or pp.marital_status_id = p_marital_status_id)
    and (p_cursor_created_at is null or (pp.created_at, pp.id) < (p_cursor_created_at, p_cursor_id))
    and not exists (select 1 from app.blocks b where b.blocker_user_id = (select auth.uid()) and b.blocked_user_id = pp.user_id)
    and not exists (select 1 from app.blocks b where b.blocker_user_id = pp.user_id and b.blocked_user_id = (select auth.uid()))
  order by pp.created_at desc, pp.id desc
  limit p_limit;
end $$;

create or replace function app.send_interest(p_receiver_user_id uuid, p_message text default null)
returns app.interests
language plpgsql security definer
set search_path = app, public, pg_temp as $$
declare v_interest app.interests; v_quota app.subscription_quotas; v_sub app.subscriptions;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = 'P0001'; end if;
  if p_receiver_user_id = auth.uid() then raise exception 'INTEREST_SELF' using errcode = 'P0001'; end if;
  if exists (select 1 from app.blocks where blocker_user_id = auth.uid() and blocked_user_id = p_receiver_user_id or blocker_user_id = p_receiver_user_id and blocked_user_id = auth.uid()) then raise exception 'INTEREST_BLOCKED' using errcode = 'P0001'; end if;
  if exists (select 1 from app.interests where sender_user_id = auth.uid() and created_at >= current_date and status in ('pending','accepted')) then
    if (select count(*) from app.interests where sender_user_id = auth.uid() and created_at >= current_date) >= 50 then raise exception 'INTEREST_DAILY_LIMIT' using errcode = 'P0001'; end if;
  end if;
  select * into v_sub from app.subscriptions where user_id = auth.uid() and status = 'active' and starts_at <= now() and ends_at > now() order by ends_at desc limit 1;
  if not found then raise exception 'SUBSCRIPTION_REQUIRED' using errcode = 'P0001'; end if;
  select * into v_quota from app.subscription_quotas where subscription_id = v_sub.id for update;
  if not v_quota.unlimited_interests and v_quota.interests_remaining <= 0 then raise exception 'INTEREST_QUOTA_EXHAUSTED' using errcode = 'P0001'; end if;
  if exists (select 1 from app.interests where sender_user_id = auth.uid() and receiver_user_id = p_receiver_user_id and status in ('pending','accepted')) then
    raise exception 'INTEREST_ALREADY_EXISTS' using errcode = 'P0001';
  end if;
  if not v_quota.unlimited_interests then update app.subscription_quotas set interests_remaining = interests_remaining - 1 where id = v_quota.id; end if;
  insert into app.interests(sender_user_id, receiver_user_id, message) values (auth.uid(), p_receiver_user_id, nullif(trim(p_message), '')) returning * into v_interest;
  insert into app.notifications(user_id, notification_type, title, body, data) values (p_receiver_user_id, 'interest_received', 'New interest', 'Someone sent you an interest.', jsonb_build_object('interest_id', v_interest.id));
  return v_interest;
end $$;

create or replace function app.respond_interest(p_interest_id uuid, p_status app.interest_status)
returns app.interests
language plpgsql security definer
set search_path = app, public, pg_temp as $$
declare v_interest app.interests;
begin
  if p_status not in ('accepted','declined') then raise exception 'INTEREST_INVALID_RESPONSE' using errcode = 'P0001'; end if;
  update app.interests set status = p_status, responded_at = now()
  where id = p_interest_id and receiver_user_id = auth.uid() and status = 'pending'
  returning * into v_interest;
  if not found then raise exception 'INTEREST_NOT_FOUND' using errcode = 'P0001'; end if;
  insert into app.notifications(user_id, notification_type, title, body, data)
  values (v_interest.sender_user_id, 'interest_response', 'Interest updated', 'Your interest received a response.', jsonb_build_object('interest_id', p_interest_id, 'status', p_status));
  return v_interest;
end $$;

create or replace function app.toggle_shortlist(p_profile_id uuid)
returns boolean
language plpgsql security definer
set search_path = app, public, pg_temp as $$
begin
  if not exists (select 1 from app.profiles where id = p_profile_id and status = 'approved' and deleted_at is null) then raise exception 'PROFILE_NOT_FOUND' using errcode = 'P0001'; end if;
  if exists (select 1 from app.blocks b join app.profiles p on p.user_id = b.blocked_user_id where b.blocker_user_id = auth.uid() and p.id = p_profile_id) then raise exception 'PROFILE_BLOCKED' using errcode = 'P0001'; end if;
  if exists (select 1 from app.shortlists where user_id = auth.uid() and shortlisted_profile_id = p_profile_id) then
    delete from app.shortlists where user_id = auth.uid() and shortlisted_profile_id = p_profile_id; return false;
  end if;
  insert into app.shortlists(user_id, shortlisted_profile_id) values (auth.uid(), p_profile_id); return true;
end $$;

create or replace function app.unlock_contact(p_profile_user_id uuid)
returns app.user_contact_details
language plpgsql security definer
set search_path = app, public, pg_temp as $$
declare v_contact app.user_contact_details; v_sub app.subscriptions; v_quota app.subscription_quotas; v_profile app.profiles;
begin
  if p_profile_user_id = auth.uid() then raise exception 'CONTACT_SELF' using errcode = 'P0001'; end if;
  select * into v_contact from app.user_contact_details where user_id = p_profile_user_id;
  if not found then raise exception 'CONTACT_NOT_FOUND' using errcode = 'P0001'; end if;
  if exists (select 1 from app.contact_unlocks where viewer_user_id = auth.uid() and profile_user_id = p_profile_user_id and expires_at > now()) then return v_contact; end if;
  if exists (select 1 from app.blocks where blocker_user_id = auth.uid() and blocked_user_id = p_profile_user_id or blocker_user_id = p_profile_user_id and blocked_user_id = auth.uid()) then raise exception 'CONTACT_BLOCKED' using errcode = 'P0001'; end if;
  select * into v_profile from app.profiles where user_id = p_profile_user_id and status = 'approved' and deleted_at is null;
  if not found then raise exception 'PROFILE_NOT_FOUND' using errcode = 'P0001'; end if;
  select * into v_sub from app.subscriptions where user_id = auth.uid() and status = 'active' and starts_at <= now() and ends_at > now() order by ends_at desc limit 1;
  if not found then raise exception 'SUBSCRIPTION_REQUIRED' using errcode = 'P0001'; end if;
  select * into v_quota from app.subscription_quotas where subscription_id = v_sub.id for update;
  if not v_quota.unlimited_contact_views and v_quota.contact_views_remaining <= 0 then raise exception 'CONTACT_QUOTA_EXHAUSTED' using errcode = 'P0001'; end if;
  if not v_quota.unlimited_contact_views then update app.subscription_quotas set contact_views_remaining = contact_views_remaining - 1 where id = v_quota.id; end if;
  insert into app.contact_unlocks(viewer_user_id, profile_user_id, subscription_id, expires_at)
  values (auth.uid(), p_profile_user_id, v_sub.id, v_sub.ends_at)
  on conflict (viewer_user_id, profile_user_id) do update set expires_at = excluded.expires_at;
  return v_contact;
end $$;

create or replace function app.block_user(p_blocked_user_id uuid, p_reason text default null)
returns void
language plpgsql security definer
set search_path = app, public, pg_temp as $$
begin
  if p_blocked_user_id = auth.uid() then raise exception 'BLOCK_SELF' using errcode = 'P0001'; end if;
  insert into app.blocks(blocker_user_id, blocked_user_id, reason) values (auth.uid(), p_blocked_user_id, p_reason) on conflict do nothing;
  update app.interests set status = 'declined', responded_at = now()
  where (sender_user_id = auth.uid() and receiver_user_id = p_blocked_user_id or sender_user_id = p_blocked_user_id and receiver_user_id = auth.uid()) and status in ('pending','accepted');
end $$;

create or replace function app.report_user(p_reported_user_id uuid, p_category text, p_description text)
returns app.reports
language plpgsql security definer
set search_path = app, public, pg_temp as $$
declare v_report app.reports;
begin
  if p_reported_user_id = auth.uid() then raise exception 'REPORT_SELF' using errcode = 'P0001'; end if;
  if (select count(*) from app.reports where reporter_user_id = auth.uid() and created_at >= current_date) >= 10 then raise exception 'REPORT_DAILY_LIMIT' using errcode = 'P0001'; end if;
  if exists (select 1 from app.reports where reporter_user_id = auth.uid() and reported_user_id = p_reported_user_id and status in ('open','reviewing')) then raise exception 'REPORT_ALREADY_OPEN' using errcode = 'P0001'; end if;
  insert into app.reports(reporter_user_id, reported_user_id, category, description) values (auth.uid(), p_reported_user_id, p_category, p_description) returning * into v_report;
  return v_report;
end $$;

create or replace function app.submit_profile_for_review(p_profile_id uuid)
returns app.profiles
language plpgsql security definer
set search_path = app, public, pg_temp as $$
declare v_profile app.profiles;
begin
  update app.profiles set status = 'pending_review', submitted_at = now(), rejection_reason = null
  where id = p_profile_id and user_id = auth.uid() and status in ('draft','rejected')
  returning * into v_profile;
  if not found then raise exception 'PROFILE_NOT_EDITABLE' using errcode = 'P0001'; end if;
  return v_profile;
end $$;

create or replace function app.admin_review_profile(p_profile_id uuid, p_status app.profile_status, p_reason text default null)
returns app.profiles
language plpgsql security definer
set search_path = app, public, pg_temp as $$
declare v_profile app.profiles;
begin
  if not app.is_staff() then raise exception 'STAFF_REQUIRED' using errcode = 'P0001'; end if;
  if p_status not in ('approved','rejected','suspended','deleted') then raise exception 'PROFILE_INVALID_REVIEW_STATUS' using errcode = 'P0001'; end if;
  update app.profiles set status = p_status, reviewed_at = now(), reviewed_by = auth.uid(), rejection_reason = p_reason, deleted_at = case when p_status = 'deleted' then now() else null end
  where id = p_profile_id and status <> 'deleted' returning * into v_profile;
  if not found then raise exception 'PROFILE_NOT_FOUND' using errcode = 'P0001'; end if;
  insert into app.audit_logs(actor_user_id, actor_role, action, target_table, target_id, after_data) values (auth.uid(), case when app.is_admin() then 'admin' else 'moderator' end, 'review_profile', 'profiles', p_profile_id, to_jsonb(v_profile));
  return v_profile;
end $$;

create or replace function app.admin_review_photo(p_photo_id uuid, p_status app.photo_status, p_reason text default null)
returns app.profile_photos
language plpgsql security definer
set search_path = app, public, pg_temp as $$
declare v_photo app.profile_photos;
begin
  if not app.is_staff() then raise exception 'STAFF_REQUIRED' using errcode = 'P0001'; end if;
  if p_status not in ('approved','rejected','removed') then raise exception 'PHOTO_INVALID_STATUS' using errcode = 'P0001'; end if;
  update app.profile_photos set status = p_status, storage_bucket = case when p_status = 'approved' then 'photos-approved' else storage_bucket end, reviewed_at = now(), reviewed_by = auth.uid(), rejection_reason = p_reason
  where id = p_photo_id returning * into v_photo;
  if not found then raise exception 'PHOTO_NOT_FOUND' using errcode = 'P0001'; end if;
  insert into app.audit_logs(actor_user_id, actor_role, action, target_table, target_id, after_data) values (auth.uid(), case when app.is_admin() then 'admin' else 'moderator' end, 'review_photo', 'profile_photos', p_photo_id, to_jsonb(v_photo));
  return v_photo;
end $$;

create or replace function app.admin_dashboard_stats()
returns jsonb
language plpgsql stable security definer
set search_path = app, public, pg_temp as $$
begin
  if not app.is_staff() then raise exception 'STAFF_REQUIRED' using errcode = 'P0001'; end if;
  return jsonb_build_object(
    'total_profiles', (select count(*) from app.profiles where status <> 'deleted'),
    'pending_profiles', (select count(*) from app.profiles where status = 'pending_review'),
    'pending_photos', (select count(*) from app.profile_photos where status = 'pending'),
    'open_reports', (select count(*) from app.reports where status in ('open','reviewing')),
    'active_subscriptions', (select count(*) from app.subscriptions where status = 'active' and ends_at > now()),
    'revenue_paise', (select coalesce(sum(amount_paise),0) from app.payments where status = 'captured')
  );
end $$;

create or replace function app.apply_subscription(
  p_user_id uuid, p_package_id uuid, p_order_id text, p_payment_id text, p_amount_paise bigint
) returns app.subscriptions
language plpgsql security definer
set search_path = app, public, pg_temp as $$
declare v_package app.packages; v_sub app.subscriptions; v_quota app.package_quotas; v_old app.subscriptions;
begin
  if (select auth.role()) <> 'service_role' and not app.is_admin() then raise exception 'SERVICE_REQUIRED' using errcode = 'P0001'; end if;
  select * into v_package from app.packages where id = p_package_id and is_active;
  if not found or v_package.price_paise <> p_amount_paise then raise exception 'PAYMENT_AMOUNT_MISMATCH' using errcode = 'P0001'; end if;
  if exists (select 1 from app.payments where provider_order_id = p_order_id and status in ('captured','authorized')) then
    select * into v_sub from app.subscriptions where razorpay_order_id = p_order_id; return v_sub;
  end if;
  select * into v_quota from app.package_quotas where package_id = p_package_id;
  update app.subscriptions set status = 'expired' where user_id = p_user_id and status = 'active';
  insert into app.subscriptions(user_id, package_id, status, starts_at, ends_at, razorpay_order_id, razorpay_payment_id)
  values (p_user_id, p_package_id, 'active', now(), now() + make_interval(days => v_package.validity_days), p_order_id, p_payment_id) returning * into v_sub;
  insert into app.subscription_quotas(subscription_id, contact_views_remaining, interests_remaining, photo_slots_remaining, unlimited_contact_views, unlimited_interests, unlimited_photo_slots)
  values (v_sub.id, v_quota.contact_views, v_quota.interests_sent, v_quota.photo_slots, v_quota.unlimited_contact_views, v_quota.unlimited_interests, v_quota.unlimited_photo_slots);
  insert into app.payments(user_id, subscription_id, provider_order_id, provider_payment_id, amount_paise, status, paid_at)
  values (p_user_id, v_sub.id, p_order_id, p_payment_id, p_amount_paise, 'captured', now())
  on conflict (provider_order_id) do update set status = 'captured', provider_payment_id = excluded.provider_payment_id, subscription_id = excluded.subscription_id, paid_at = excluded.paid_at;
  return v_sub;
end $$;

revoke all on function app.search_profiles from public;
revoke all on function app.send_interest from public;
revoke all on function app.respond_interest from public;
revoke all on function app.toggle_shortlist from public;
revoke all on function app.unlock_contact from public;
revoke all on function app.block_user from public;
revoke all on function app.report_user from public;
revoke all on function app.submit_profile_for_review from public;
revoke all on function app.admin_review_profile from public;
revoke all on function app.admin_review_photo from public;
revoke all on function app.admin_dashboard_stats from public;
revoke all on function app.apply_subscription from public;
grant execute on all functions in schema app to authenticated;
