insert into storage.buckets (id, name, public)
values
  ('photos-pending', 'photos-pending', false),
  ('photos-approved', 'photos-approved', false),
  ('horoscopes-private', 'horoscopes-private', false),
  ('cms-assets', 'cms-assets', false)
on conflict (id) do update set public = excluded.public;

create policy photos_pending_owner_upload
on storage.objects for insert to authenticated
with check (
  bucket_id = 'photos-pending'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and exists (select 1 from app.profiles p where p.user_id = (select auth.uid()))
);

create policy photos_pending_owner_read
on storage.objects for select to authenticated
using (
  bucket_id = 'photos-pending'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy photos_pending_staff_read
on storage.objects for select to authenticated
using (bucket_id = 'photos-pending' and app.is_staff());

create policy photos_pending_owner_delete
on storage.objects for delete to authenticated
using (bucket_id = 'photos-pending' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy approved_photo_read
on storage.objects for select to authenticated
using (
  bucket_id = 'photos-approved'
  and (
    app.is_staff()
    or exists (
      select 1 from app.profile_photos ph
      join app.profiles p on p.id = ph.profile_id
      where ph.storage_bucket = 'photos-approved'
        and ph.storage_path = name
        and ph.status = 'approved'
        and (p.status = 'approved' and p.deleted_at is null)
    )
  )
);

create policy approved_photo_staff_write
on storage.objects for all to authenticated
using (bucket_id = 'photos-approved' and app.is_staff())
with check (bucket_id = 'photos-approved' and app.is_staff());

create policy horoscope_owner_upload
on storage.objects for insert to authenticated
with check (
  bucket_id = 'horoscopes-private'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy horoscope_owner_read
on storage.objects for select to authenticated
using (bucket_id = 'horoscopes-private' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy horoscope_staff_read
on storage.objects for select to authenticated
using (bucket_id = 'horoscopes-private' and app.is_staff());

create policy cms_assets_staff
on storage.objects for all to authenticated
using (bucket_id = 'cms-assets' and app.is_staff())
with check (bucket_id = 'cms-assets' and app.is_staff());
