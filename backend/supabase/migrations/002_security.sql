create or replace function app.is_admin() returns boolean
language sql stable security definer
set search_path = app, pg_catalog, pg_temp
as $$
  select exists (
    select 1 from app.user_roles
    where user_id = (select auth.uid()) and role = 'admin'
  );
$$;

create or replace function app.is_staff() returns boolean
language sql stable security definer
set search_path = app, pg_catalog, pg_temp
as $$
  select exists (
    select 1 from app.user_roles
    where user_id = (select auth.uid()) and role in ('admin', 'moderator')
  );
$$;

revoke all on function app.is_admin() from public;
revoke all on function app.is_staff() from public;
grant execute on function app.is_admin() to authenticated;
grant execute on function app.is_staff() to authenticated;

grant usage on schema app to anon, authenticated;
grant select, insert, update, delete on all tables in schema app to authenticated;
grant select on all tables in schema app to anon;
alter default privileges in schema app grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema app grant select on tables to anon;

do $$
declare r record;
begin
  for r in select table_name from information_schema.tables where table_schema = 'app' and table_type = 'BASE TABLE' loop
    execute format('alter table app.%I enable row level security', r.table_name);
    execute format('alter table app.%I force row level security', r.table_name);
  end loop;
end $$;

-- Reference data is public-read, but writes remain staff-only.
create policy lookup_public_read on app.lookup_religions for select to anon, authenticated using (is_active);
create policy lookup_staff_write on app.lookup_religions for all to authenticated using (app.is_staff()) with check (app.is_staff());
create policy lookup_public_read on app.lookup_castes for select to anon, authenticated using (is_active);
create policy lookup_staff_write on app.lookup_castes for all to authenticated using (app.is_staff()) with check (app.is_staff());
create policy lookup_public_read on app.lookup_sub_castes for select to anon, authenticated using (is_active);
create policy lookup_staff_write on app.lookup_sub_castes for all to authenticated using (app.is_staff()) with check (app.is_staff());
create policy lookup_public_read on app.lookup_education for select to anon, authenticated using (is_active);
create policy lookup_staff_write on app.lookup_education for all to authenticated using (app.is_staff()) with check (app.is_staff());
create policy lookup_public_read on app.lookup_rasis for select to anon, authenticated using (is_active);
create policy lookup_staff_write on app.lookup_rasis for all to authenticated using (app.is_staff()) with check (app.is_staff());
create policy lookup_public_read on app.lookup_nakshatras for select to anon, authenticated using (is_active);
create policy lookup_staff_write on app.lookup_nakshatras for all to authenticated using (app.is_staff()) with check (app.is_staff());
create policy lookup_public_read on app.lookup_marital_statuses for select to anon, authenticated using (is_active);
create policy lookup_staff_write on app.lookup_marital_statuses for all to authenticated using (app.is_staff()) with check (app.is_staff());
create policy lookup_public_read on app.lookup_body_types for select to anon, authenticated using (is_active);
create policy lookup_staff_write on app.lookup_body_types for all to authenticated using (app.is_staff()) with check (app.is_staff());
create policy lookup_public_read on app.lookup_complexions for select to anon, authenticated using (is_active);
create policy lookup_staff_write on app.lookup_complexions for all to authenticated using (app.is_staff()) with check (app.is_staff());
create policy lookup_public_read on app.lookup_diets for select to anon, authenticated using (is_active);
create policy lookup_staff_write on app.lookup_diets for all to authenticated using (app.is_staff()) with check (app.is_staff());
create policy lookup_public_read on app.lookup_occupation_categories for select to anon, authenticated using (is_active);
create policy lookup_staff_write on app.lookup_occupation_categories for all to authenticated using (app.is_staff()) with check (app.is_staff());
create policy lookup_public_read on app.lookup_income_ranges for select to anon, authenticated using (is_active);
create policy lookup_staff_write on app.lookup_income_ranges for all to authenticated using (app.is_staff()) with check (app.is_staff());

create policy profiles_owner_read on app.profiles for select to authenticated using (user_id = (select auth.uid()) or app.is_staff());
create policy profiles_owner_insert on app.profiles for insert to authenticated with check (user_id = (select auth.uid()));
create policy profiles_owner_update on app.profiles for update to authenticated using (user_id = (select auth.uid()) or app.is_staff()) with check (user_id = (select auth.uid()) or app.is_staff());
create policy profiles_owner_delete on app.profiles for delete to authenticated using (app.is_admin());

create policy contacts_owner_read on app.user_contact_details for select to authenticated using (user_id = (select auth.uid()) or app.is_staff() or exists (select 1 from app.contact_unlocks u where u.viewer_user_id = (select auth.uid()) and u.profile_user_id = user_id and u.expires_at > now()));
create policy contacts_owner_write on app.user_contact_details for all to authenticated using (user_id = (select auth.uid()) or app.is_staff()) with check (user_id = (select auth.uid()) or app.is_staff());

create policy horoscope_owner on app.horoscopes for all to authenticated using (exists (select 1 from app.profiles p where p.id = profile_id and p.user_id = (select auth.uid())) or app.is_staff()) with check (exists (select 1 from app.profiles p where p.id = profile_id and p.user_id = (select auth.uid())) or app.is_staff());
create policy preferences_owner on app.partner_preferences for all to authenticated using (exists (select 1 from app.profiles p where p.id = profile_id and p.user_id = (select auth.uid())) or app.is_staff()) with check (exists (select 1 from app.profiles p where p.id = profile_id and p.user_id = (select auth.uid())) or app.is_staff());
create policy photos_owner_or_approved on app.profile_photos for select to authenticated using (uploaded_by = (select auth.uid()) or app.is_staff() or (status = 'approved' and storage_bucket = 'photos-approved'));
create policy photos_owner_insert on app.profile_photos for insert to authenticated with check (uploaded_by = (select auth.uid()) and exists (select 1 from app.profiles p where p.id = profile_id and p.user_id = (select auth.uid())));
create policy photos_owner_update on app.profile_photos for update to authenticated using (uploaded_by = (select auth.uid()) or app.is_staff()) with check (uploaded_by = (select auth.uid()) or app.is_staff());
create policy photos_staff_delete on app.profile_photos for delete to authenticated using (app.is_staff());

create policy blocks_owner on app.blocks for all to authenticated using (blocker_user_id = (select auth.uid()) or app.is_staff()) with check (blocker_user_id = (select auth.uid()));
create policy reports_owner_or_staff_read on app.reports for select to authenticated using (reporter_user_id = (select auth.uid()) or app.is_staff());
create policy reports_owner_insert on app.reports for insert to authenticated with check (reporter_user_id = (select auth.uid()));
create policy reports_staff_update on app.reports for update to authenticated using (app.is_staff()) with check (app.is_staff());

create policy interests_participants_read on app.interests for select to authenticated using (sender_user_id = (select auth.uid()) or receiver_user_id = (select auth.uid()) or app.is_staff());
create policy interests_sender_insert on app.interests for insert to authenticated with check (sender_user_id = (select auth.uid()));
create policy interests_participant_update on app.interests for update to authenticated using (receiver_user_id = (select auth.uid()) or sender_user_id = (select auth.uid()) or app.is_staff()) with check (receiver_user_id = (select auth.uid()) or sender_user_id = (select auth.uid()) or app.is_staff());

create policy shortlist_owner on app.shortlists for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy unlock_participant on app.contact_unlocks for select to authenticated using (viewer_user_id = (select auth.uid()) or profile_user_id = (select auth.uid()) or app.is_staff());
create policy unlock_insert_rpc_only on app.contact_unlocks for insert to authenticated with check (false);

create policy notifications_owner on app.notifications for select to authenticated using (user_id = (select auth.uid()) or app.is_staff());
create policy notifications_owner_update on app.notifications for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy package_public_read on app.packages for select to anon, authenticated using (is_active);
create policy package_staff_write on app.packages for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy package_quota_public_read on app.package_quotas for select to anon, authenticated using (exists (select 1 from app.packages p where p.id = package_id and p.is_active) or app.is_staff());
create policy package_quota_staff_write on app.package_quotas for all to authenticated using (app.is_admin()) with check (app.is_admin());

create policy subscription_owner_read on app.subscriptions for select to authenticated using (user_id = (select auth.uid()) or app.is_staff());
create policy subscription_staff_write on app.subscriptions for all to authenticated using (app.is_staff()) with check (app.is_staff());
create policy quota_owner_read on app.subscription_quotas for select to authenticated using (exists (select 1 from app.subscriptions s where s.id = subscription_id and (s.user_id = (select auth.uid()) or app.is_staff())));
create policy payments_owner_read on app.payments for select to authenticated using (user_id = (select auth.uid()) or app.is_staff());
create policy payments_staff_write on app.payments for all to authenticated using (app.is_staff()) with check (app.is_staff());
create policy payment_events_staff_read on app.payment_events for select to authenticated using (app.is_staff());
drop policy if exists refunds_staff_read on app.refunds;
create policy refunds_staff_read on app.refunds for select to authenticated using (app.is_staff());
create policy refunds_staff_write on app.refunds for all to authenticated using (app.is_admin()) with check (app.is_admin());

create policy consent_owner on app.consent_records for all to authenticated using (user_id = (select auth.uid()) or app.is_staff()) with check (user_id = (select auth.uid()) or app.is_staff());
create policy export_owner_read on app.data_export_requests for select to authenticated using (user_id = (select auth.uid()) or app.is_staff());
create policy export_owner_insert on app.data_export_requests for insert to authenticated with check (user_id = (select auth.uid()));
create policy export_staff_update on app.data_export_requests for update to authenticated using (app.is_staff()) with check (app.is_staff());
create policy deletion_owner_read on app.account_deletion_requests for select to authenticated using (user_id = (select auth.uid()) or app.is_staff());
create policy deletion_owner_insert on app.account_deletion_requests for insert to authenticated with check (user_id = (select auth.uid()));
create policy deletion_staff_update on app.account_deletion_requests for update to authenticated using (app.is_staff()) with check (app.is_staff());

create policy audit_staff_read on app.audit_logs for select to authenticated using (app.is_staff());
create policy audit_insert_server on app.audit_logs for insert to authenticated with check (app.is_staff() or actor_user_id = (select auth.uid()));
create policy audit_admin_delete_never on app.audit_logs for delete to authenticated using (false);
create policy settings_public_read on app.site_settings for select to anon, authenticated using (true);
create policy settings_admin_write on app.site_settings for all to authenticated using (app.is_admin()) with check (app.is_admin());

create policy pages_public_read on app.cms_pages for select to anon, authenticated using (status = 'published' or app.is_staff());
create policy pages_staff_write on app.cms_pages for all to authenticated using (app.is_staff()) with check (app.is_staff());
create policy banners_public_read on app.cms_banners for select to anon, authenticated using (is_active and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now()) or app.is_staff());
create policy banners_staff_write on app.cms_banners for all to authenticated using (app.is_staff()) with check (app.is_staff());
create policy faqs_public_read on app.cms_faqs for select to anon, authenticated using (is_published or app.is_staff());
create policy faqs_staff_write on app.cms_faqs for all to authenticated using (app.is_staff()) with check (app.is_staff());
create policy testimonials_public_read on app.cms_testimonials for select to anon, authenticated using (is_published or app.is_staff());
create policy testimonials_staff_write on app.cms_testimonials for all to authenticated using (app.is_staff()) with check (app.is_staff());
create policy stories_public_read on app.cms_success_stories for select to anon, authenticated using (is_published or app.is_staff());
create policy stories_staff_write on app.cms_success_stories for all to authenticated using (app.is_staff()) with check (app.is_staff());

create or replace view app.public_profiles
with (security_barrier = true)
as
select
  p.id,
  p.user_id,
  p.gender,
  extract(year from age(current_date, p.date_of_birth))::integer as age,
  p.profile_for,
  p.mother_tongue,
  p.religion_id,
  r.name as religion_name,
  p.caste_id,
  c.name as caste_name,
  p.marital_status_id,
  ms.name as marital_status_name,
  p.height_cm,
  p.city,
  p.state,
  p.education_id,
  e.name as education_name,
  p.occupation_category_id,
  oc.name as occupation_category_name,
  p.occupation,
  p.about_me,
  p.created_at
from app.profiles p
left join app.lookup_religions r on r.id = p.religion_id
left join app.lookup_castes c on c.id = p.caste_id
left join app.lookup_marital_statuses ms on ms.id = p.marital_status_id
left join app.lookup_education e on e.id = p.education_id
left join app.lookup_occupation_categories oc on oc.id = p.occupation_category_id
where p.status = 'approved' and p.deleted_at is null;

grant select on app.public_profiles to anon, authenticated;
