create extension if not exists pgcrypto;
create extension if not exists btree_gist;

create schema if not exists app;

create type app.user_role as enum ('admin', 'moderator');
create type app.profile_status as enum ('draft', 'pending_review', 'approved', 'rejected', 'suspended', 'deleted');
create type app.gender as enum ('male', 'female', 'other');
create type app.profile_for_type as enum ('self', 'son', 'daughter', 'sibling', 'relative', 'friend');
create type app.photo_status as enum ('pending', 'approved', 'rejected', 'removed');
create type app.interest_status as enum ('pending', 'accepted', 'declined', 'withdrawn', 'expired');
create type app.report_status as enum ('open', 'reviewing', 'resolved', 'dismissed');
create type app.subscription_status as enum ('pending', 'active', 'expired', 'cancelled', 'refunded');
create type app.payment_status as enum ('created', 'authorized', 'captured', 'failed', 'refunded', 'partially_refunded');
create type app.request_status as enum ('requested', 'processing', 'completed', 'rejected', 'cancelled');
create type app.cms_status as enum ('draft', 'published', 'archived');

create or replace function app.touch_updated_at() returns trigger
language plpgsql set search_path = app, public, pg_temp as $$
begin new.updated_at = now(); return new; end $$;

create or replace function app.set_updated_at() returns trigger
language plpgsql set search_path = app, public, pg_temp as $$
begin
  if tg_op = 'UPDATE' then new.updated_at = now(); end if;
  return new;
end $$;

create table app.user_roles (
  user_id uuid not null references auth.users(id) on delete cascade,
  role app.user_role not null,
  created_at timestamptz not null default now(),
  primary key (user_id, role)
);

create table app.lookup_religions (
  id uuid primary key default gen_random_uuid(), code text not null unique, name text not null unique, is_active boolean not null default true
);
create table app.lookup_castes (
  id uuid primary key default gen_random_uuid(), religion_id uuid not null references app.lookup_religions(id), code text not null, name text not null, is_active boolean not null default true, unique (religion_id, code), unique (religion_id, name)
);
create table app.lookup_sub_castes (
  id uuid primary key default gen_random_uuid(), caste_id uuid not null references app.lookup_castes(id), code text not null, name text not null, is_active boolean not null default true, unique (caste_id, code), unique (caste_id, name)
);
create table app.lookup_education (
  id uuid primary key default gen_random_uuid(), code text not null unique, name text not null unique, is_active boolean not null default true
);
create table app.lookup_rasis (
  id uuid primary key default gen_random_uuid(), code text not null unique, name text not null unique, is_active boolean not null default true
);
create table app.lookup_nakshatras (
  id uuid primary key default gen_random_uuid(), code text not null unique, name text not null unique, is_active boolean not null default true
);
create table app.lookup_marital_statuses (
  id uuid primary key default gen_random_uuid(), code text not null unique, name text not null unique, is_active boolean not null default true
);
create table app.lookup_body_types (
  id uuid primary key default gen_random_uuid(), code text not null unique, name text not null unique, is_active boolean not null default true
);
create table app.lookup_complexions (
  id uuid primary key default gen_random_uuid(), code text not null unique, name text not null unique, is_active boolean not null default true
);
create table app.lookup_diets (
  id uuid primary key default gen_random_uuid(), code text not null unique, name text not null unique, is_active boolean not null default true
);
create table app.lookup_occupation_categories (
  id uuid primary key default gen_random_uuid(), code text not null unique, name text not null unique, is_active boolean not null default true
);
create table app.lookup_income_ranges (
  id uuid primary key default gen_random_uuid(), code text not null unique, name text not null unique, value_range int8range not null, is_active boolean not null default true
);

create table app.profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  profile_for app.profile_for_type not null default 'self',
  gender app.gender not null default 'other',
  date_of_birth date check (date_of_birth is null or date_of_birth <= current_date - interval '18 years'),
  status app.profile_status not null default 'draft',
  marital_status_id uuid references app.lookup_marital_statuses(id),
  height_cm smallint check (height_cm between 80 and 250),
  weight_kg numeric(5,2) check (weight_kg between 20 and 300),
  body_type_id uuid references app.lookup_body_types(id),
  complexion_id uuid references app.lookup_complexions(id),
  physical_status text,
  mother_tongue text,
  religion_id uuid references app.lookup_religions(id),
  caste_id uuid references app.lookup_castes(id),
  sub_caste_id uuid references app.lookup_sub_castes(id),
  kulam text,
  gothram text,
  diet_id uuid references app.lookup_diets(id),
  smoking boolean not null default false,
  drinking boolean not null default false,
  education_id uuid references app.lookup_education(id),
  occupation_category_id uuid references app.lookup_occupation_categories(id),
  occupation text,
  employer_type text,
  annual_income_range int8range,
  country text not null default 'India',
  state text,
  city text,
  citizenship text not null default 'Indian',
  about_me text check (char_length(about_me) <= 5000),
  family_details jsonb not null default '{}'::jsonb,
  display_name text,
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id),
  rejection_reason text,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table app.user_contact_details (
  user_id uuid primary key references auth.users(id) on delete cascade,
  phone text not null check (phone ~ '^\+?[1-9][0-9]{7,14}$'),
  email text not null,
  whatsapp text check (whatsapp is null or whatsapp ~ '^\+?[1-9][0-9]{7,14}$'),
  updated_at timestamptz not null default now()
);

create table app.horoscopes (
  profile_id uuid primary key references app.profiles(id) on delete cascade,
  birth_time time,
  birth_place text,
  rasi_id uuid references app.lookup_rasis(id),
  nakshatra_id uuid references app.lookup_nakshatras(id),
  lagnam text,
  dosham_flags jsonb not null default '{}'::jsonb,
  image_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table app.partner_preferences (
  profile_id uuid primary key references app.profiles(id) on delete cascade,
  age_range int4range check (age_range is null or not isempty(age_range)),
  height_range_cm int4range check (height_range_cm is null or not isempty(height_range_cm)),
  marital_status_ids uuid[] not null default '{}',
  religion_ids uuid[] not null default '{}',
  caste_ids uuid[] not null default '{}',
  education_ids uuid[] not null default '{}',
  occupation_ids uuid[] not null default '{}',
  locations jsonb not null default '[]'::jsonb,
  diet_ids uuid[] not null default '{}',
  additional_preferences jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table app.profile_photos (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references app.profiles(id) on delete cascade,
  uploaded_by uuid not null references auth.users(id) on delete cascade,
  storage_bucket text not null default 'photos-pending' check (storage_bucket in ('photos-pending', 'photos-approved')),
  storage_path text not null unique,
  status app.photo_status not null default 'pending',
  is_primary boolean not null default false,
  is_blurred boolean not null default false,
  is_private boolean not null default false,
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id),
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table app.blocks (
  blocker_user_id uuid not null references auth.users(id) on delete cascade,
  blocked_user_id uuid not null references auth.users(id) on delete cascade,
  reason text,
  created_at timestamptz not null default now(),
  primary key (blocker_user_id, blocked_user_id),
  check (blocker_user_id <> blocked_user_id)
);

create table app.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_user_id uuid not null references auth.users(id) on delete cascade,
  reported_user_id uuid not null references auth.users(id) on delete cascade,
  category text not null check (category in ('fake_profile','harassment','scam','inappropriate_content','underage','other')),
  description text not null check (char_length(description) between 10 and 2000),
  status app.report_status not null default 'open',
  resolved_by uuid references auth.users(id),
  resolution_notes text,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  check (reporter_user_id <> reported_user_id)
);

create table app.interests (
  id uuid primary key default gen_random_uuid(),
  sender_user_id uuid not null references auth.users(id) on delete cascade,
  receiver_user_id uuid not null references auth.users(id) on delete cascade,
  status app.interest_status not null default 'pending',
  message text check (message is null or char_length(message) <= 1000),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  check (sender_user_id <> receiver_user_id)
);

create unique index interests_one_open_per_pair on app.interests (sender_user_id, receiver_user_id)
where status in ('pending','accepted');

create table app.shortlists (
  user_id uuid not null references auth.users(id) on delete cascade,
  shortlisted_profile_id uuid not null references app.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, shortlisted_profile_id)
);

create table app.packages (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  price_paise bigint not null check (price_paise >= 0),
  currency char(3) not null default 'INR',
  validity_days integer not null check (validity_days between 1 and 3650),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table app.package_quotas (
  package_id uuid primary key references app.packages(id) on delete cascade,
  contact_views integer not null default 0 check (contact_views >= 0),
  interests_sent integer not null default 0 check (interests_sent >= 0),
  photo_slots integer not null default 1 check (photo_slots >= 0),
  unlimited_contact_views boolean not null default false,
  unlimited_interests boolean not null default false,
  unlimited_photo_slots boolean not null default false
);

create table app.subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  package_id uuid not null references app.packages(id),
  status app.subscription_status not null default 'pending',
  starts_at timestamptz,
  ends_at timestamptz,
  razorpay_order_id text unique,
  razorpay_payment_id text unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at is null or starts_at is null or ends_at > starts_at)
);

create unique index one_active_subscription_per_user on app.subscriptions(user_id)
where status = 'active';

create table app.subscription_quotas (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid not null unique references app.subscriptions(id) on delete cascade,
  contact_views_remaining integer not null default 0 check (contact_views_remaining >= 0),
  interests_remaining integer not null default 0 check (interests_remaining >= 0),
  photo_slots_remaining integer not null default 0 check (photo_slots_remaining >= 0),
  unlimited_contact_views boolean not null default false,
  unlimited_interests boolean not null default false,
  unlimited_photo_slots boolean not null default false
);

create table app.payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  subscription_id uuid references app.subscriptions(id),
  provider text not null default 'razorpay',
  provider_order_id text not null unique,
  provider_payment_id text unique,
  amount_paise bigint not null check (amount_paise >= 0),
  currency char(3) not null default 'INR',
  status app.payment_status not null default 'created',
  provider_payload jsonb not null default '{}'::jsonb,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table app.payment_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null default 'razorpay',
  provider_event_id text not null unique,
  provider_payment_id text,
  event_type text not null,
  payload jsonb not null,
  processed_at timestamptz not null default now()
);

create table app.refunds (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references app.payments(id),
  provider_refund_id text not null unique,
  amount_paise bigint not null check (amount_paise > 0),
  status text not null check (status in ('pending','processed','failed')),
  provider_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table app.contact_unlocks (
  id uuid primary key default gen_random_uuid(),
  viewer_user_id uuid not null references auth.users(id) on delete cascade,
  profile_user_id uuid not null references auth.users(id) on delete cascade,
  subscription_id uuid not null references app.subscriptions(id),
  unlocked_at timestamptz not null default now(),
  expires_at timestamptz not null,
  unique (viewer_user_id, profile_user_id),
  check (viewer_user_id <> profile_user_id),
  check (expires_at > unlocked_at)
);

create table app.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  notification_type text not null,
  title text not null,
  body text not null,
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create table app.consent_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  consent_type text not null,
  policy_version text not null,
  granted boolean not null,
  granted_at timestamptz not null default now(),
  withdrawn_at timestamptz
);

create table app.data_export_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  status app.request_status not null default 'requested',
  reviewed_by uuid references auth.users(id),
  requested_at timestamptz not null default now(),
  completed_at timestamptz
);

create table app.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  status app.request_status not null default 'requested',
  reason text,
  reviewed_by uuid references auth.users(id),
  requested_at timestamptz not null default now(),
  completed_at timestamptz
);

create table app.audit_logs (
  id bigint generated always as identity primary key,
  actor_user_id uuid references auth.users(id),
  actor_role app.user_role,
  action text not null,
  target_table text not null,
  target_id uuid,
  before_data jsonb,
  after_data jsonb,
  ip_address inet,
  user_agent text,
  created_at timestamptz not null default now()
);

create table app.site_settings (
  key text primary key,
  value jsonb not null,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);
create table app.cms_pages (
  id uuid primary key default gen_random_uuid(), slug text not null unique, title text not null, content text not null, status app.cms_status not null default 'draft', updated_by uuid references auth.users(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table app.cms_banners (
  id uuid primary key default gen_random_uuid(), title text not null, content text, image_path text, target_url text, is_active boolean not null default false, starts_at timestamptz, ends_at timestamptz, updated_by uuid references auth.users(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now(), check (ends_at is null or starts_at is null or ends_at > starts_at)
);
create table app.cms_faqs (
  id uuid primary key default gen_random_uuid(), question text not null, answer text not null, display_order integer not null default 0, is_published boolean not null default false, updated_by uuid references auth.users(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table app.cms_testimonials (
  id uuid primary key default gen_random_uuid(), name text not null, content text not null, image_path text, is_published boolean not null default false, updated_by uuid references auth.users(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table app.cms_success_stories (
  id uuid primary key default gen_random_uuid(), title text not null, story text not null, image_path text, is_published boolean not null default false, updated_by uuid references auth.users(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create index profiles_search_idx on app.profiles (gender, date_of_birth, religion_id, caste_id, state, city, marital_status_id);
create index profiles_approved_search_idx on app.profiles (gender, date_of_birth, state, city, religion_id, caste_id) where status = 'approved' and deleted_at is null;
create index profiles_user_status_idx on app.profiles (user_id, status);
create index profile_photos_profile_status_idx on app.profile_photos(profile_id, status, created_at desc);
create index interests_receiver_idx on app.interests(receiver_user_id, status, created_at desc);
create index interests_sender_idx on app.interests(sender_user_id, status, created_at desc);
create index reports_status_idx on app.reports(status, created_at desc);
create index notifications_user_idx on app.notifications(user_id, read_at, created_at desc);
create index audit_logs_target_idx on app.audit_logs(target_table, target_id, created_at desc);
create index subscriptions_user_status_idx on app.subscriptions(user_id, status, ends_at desc);
create index payments_user_idx on app.payments(user_id, created_at desc);
create index contact_unlocks_viewer_idx on app.contact_unlocks(viewer_user_id, expires_at);

create or replace function app.handle_new_user() returns trigger
language plpgsql security definer set search_path = app, public, pg_temp as $$
begin
  insert into app.profiles(user_id, gender, date_of_birth, display_name)
  values (new.id, 'other', date '1900-01-01', coalesce(new.raw_user_meta_data->>'display_name', ''))
  on conflict (user_id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users for each row execute function app.handle_new_user();

do $$
declare r record;
begin
  for r in
    select table_name
    from information_schema.columns
    where table_schema = 'app' and column_name = 'updated_at'
    group by table_name
  loop
    execute format('create trigger %I_updated_at before update on app.%I for each row execute function app.set_updated_at()', r.table_name, r.table_name);
  end loop;
end $$;
