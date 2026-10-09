# Inaiyam Matrimony backend API

The frontend uses Supabase Auth, the `app` schema RPCs, and private Storage buckets.
All examples assume:

```ts
const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY)
```

Profiles must be approved before a user can search, send interests, or view another
user's contact details. Draft, rejected, suspended, and deleted profiles are excluded
from public views and search.

## Auth

Use Supabase Auth email/password methods. Local seed users are development-only.

```ts
await supabase.auth.signUp({ email, password })
await supabase.auth.signInWithPassword({ email, password })
```

Production email confirmation must be enabled.

## Public views and RPCs

### `public_teaser_profiles()`

Returns at most 12 safe teaser rows for anonymous or authenticated callers:
`profile_id`, `display_name`, `age`, `gender`, and `state`.

```ts
const { data, error } = await supabase.rpc('public_teaser_profiles')
```

### `get_profile_detail(p_profile_id)`

Returns one approved, non-deleted `public_profiles` row. It contains safe profile
fields only; it never contains phone, WhatsApp, or private email.

```ts
const { data, error } = await supabase.rpc('get_profile_detail', {
  p_profile_id: profileId
})
```

### `search_profiles(...)`

Authenticated callers with an approved, non-deleted profile receive approved,
non-deleted public profiles. It supports gender, age, religion, caste, state, city,
education, limit, and offset. It does not return exact address or contact data.

```ts
const { data, error } = await supabase.rpc('search_profiles', {
  p_gender: 'female',
  p_age_min: 25,
  p_age_max: 35,
  p_religion_id: null,
  p_caste_id: null,
  p_state: 'Tamil Nadu',
  p_city: null,
  p_education_id: null,
  p_limit: 20,
  p_offset: 0
})
```

## Profiles

Read the owner's private profile through the `profiles` table using the `app` schema.
Owners may edit ordinary profile fields. Status, moderation timestamps, deletion,
and identity fields are server-controlled. Submit a profile with:

```ts
await supabase.rpc('submit_profile_for_review', { p_profile_id: profileId })
```

Soft deletion is performed by staff through `admin_set_profile_status` with
`p_status: 'deleted'`. Deleted profiles are filtered from all public surfaces.

## Interests

### `send_interest(p_receiver_user_id, p_message)`

Creates an interest with `sender_user_id = auth.uid()`. Both profiles must be
approved and non-deleted. Self-interests and duplicate open interests fail.

```ts
await supabase.rpc('send_interest', {
  p_receiver_user_id: targetUserId,
  p_message: 'Hello'
})
```

### `respond_interest(p_interest_id, p_status)`

Only the receiver can set a pending interest to `accepted` or `declined`.

```ts
await supabase.rpc('respond_interest', {
  p_interest_id: interestId,
  p_status: 'accepted'
})
```

### `withdraw_interest(p_interest_id)`

Only the sender can withdraw a pending or accepted interest.

```ts
await supabase.rpc('withdraw_interest', { p_interest_id: interestId })
```

Interests are readable only by their sender, receiver, or staff.

## Contact details

Owners maintain their own `user_contact_details` row. Other users must call
`get_contact_details`; direct table reads do not reveal another user's contact data.
The target and viewer must have approved, non-deleted profiles and an accepted
interest in either direction. Staff may retrieve contact data for moderation.

```ts
const { data, error } = await supabase.rpc('get_contact_details', {
  p_target_user_id: targetUserId
})
```

## Photos and Storage

| Bucket | Access |
|---|---|
| `photos-pending` | Owner uploads under `{user_id}/`; owner/staff read according to moderation state |
| `photos-approved` | Staff writes; approved linked photos are readable to authenticated users |
| `horoscopes-private` | Owner and staff only |
| `cms-assets` | Staff only |

All buckets are private and limited to 5 MB. Photo buckets accept JPEG, PNG, and
WebP. Horoscope files accept JPEG, PNG, and PDF. CMS assets additionally accept SVG.

```ts
await supabase.storage
  .from('photos-pending')
  .upload(`${user.id}/photo.jpg`, file, { contentType: 'image/jpeg' })
```

After creating the matching `profile_photos` row through `add_profile_photo`, staff
can review it with `admin_review_photo`.

## Shortlists

`toggle_shortlist(p_profile_id)` adds or removes an approved profile from the
authenticated user's shortlist. The `shortlists` table is owner-only.

```ts
await supabase.rpc('toggle_shortlist', { p_profile_id: profileId })
```

## Staff RPCs

The following require staff or admin role:

- `admin_list_pending_profiles()`
- `admin_list_pending_photos()`
- `admin_list_users()`
- `admin_set_profile_status(p_profile_id, p_status, p_reason)`
- `admin_review_photo(p_photo_id, p_status, p_reason, p_approved_storage_path)`
- `admin_dashboard_stats()`

Admins are represented by `app.user_roles.role = 'admin'`; moderators use
`'moderator'`. Staff cannot mutate the role table through the client.

## CMS and success stories

Published CMS pages, banners, FAQs, testimonials, and success stories are publicly
readable. Staff-only policies protect all writes. Use normal Supabase table reads
with the `app` schema and filter published/active content.

## Contact form

Anonymous and authenticated callers may insert `app.contact_messages` rows with:
`name` up to 120 characters, `email` up to 320 characters, and `message` up to
5000 characters. Only staff can read submissions.

```ts
await supabase.from('contact_messages').insert({
  name,
  email,
  message
})
```

## Error handling

RPCs return explicit database errors such as `AUTH_REQUIRED`,
`APPROVED_PROFILE_REQUIRED`, `CONTACT_NOT_AVAILABLE`, `INTEREST_NOT_FOUND`, and
`STAFF_REQUIRED`. The frontend should display a user-safe message and log the
operation context without logging contact data or access tokens.
