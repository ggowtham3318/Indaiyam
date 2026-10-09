insert into app.lookup_religions(code, name) values
  ('hindu', 'Hindu'), ('christian', 'Christian'), ('muslim', 'Muslim'), ('other', 'Other')
on conflict (code) do nothing;

do $$
declare
  v_id uuid;
  v_admin uuid := '00000000-0000-0000-0000-000000000001';
  v_user uuid;
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data
  ) values (
    v_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    'seed-admin@example.local', crypt('LocalAdmin@12345', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{"display_name":"Seed Admin"}'::jsonb
  ) on conflict (id) do nothing;
  insert into app.user_roles(user_id, role) values (v_admin, 'admin') on conflict do nothing;
  update app.profiles set display_name = 'Seed Admin', status = 'approved', gender = 'other',
    date_of_birth = date '1980-01-01'
  where user_id = v_admin;

  for v_id in select gen_random_uuid() from generate_series(1, 10) loop
    insert into auth.users (
      id, instance_id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data
    ) values (
      v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
      'seed-' || replace(v_id::text, '-', '') || '@example.local',
      crypt('LocalUser@12345', gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('display_name', 'Seed Profile ' || left(v_id::text, 6))
    ) on conflict (id) do nothing;
    update app.profiles set display_name = 'Seed Profile ' || left(v_id::text, 6),
      status = 'approved',
      gender = case when (select count(*) from app.profiles where status = 'approved') % 2 = 0
        then 'male'::app.gender else 'female'::app.gender end,
      date_of_birth = date '1980-01-01',
      about_me = 'Local development sample profile.'
    where user_id = v_id;
  end loop;

  insert into app.cms_success_stories(title, story, is_published)
  values
    ('Seed Couple One', 'A local development success story.', true),
    ('Seed Couple Two', 'Another local development success story.', true);
end
$$;

insert into app.lookup_education(code, name) values
  ('be', 'B.E.'), ('btech', 'B.Tech'), ('me', 'M.E.'), ('mba', 'MBA'),
  ('mbbs', 'MBBS'), ('arts', 'Arts and Science'), ('other', 'Other')
on conflict (code) do nothing;

insert into app.lookup_rasis(code, name) values
  ('mesham','Mesham'), ('rishabam','Rishabam'), ('mithunam','Mithunam'),
  ('kadagam','Kadagam'), ('simmam','Simmam'), ('kanni','Kanni'),
  ('thulam','Thulam'), ('viruchigam','Viruchigam'), ('dhanusu','Dhanusu'),
  ('makaram','Makaram'), ('kumbam','Kumbam'), ('meenam','Meenam')
on conflict (code) do nothing;

insert into app.lookup_nakshatras(code, name) values
  ('ashwini','Ashwini'), ('bharani','Bharani'), ('krittika','Krittika'),
  ('rohini','Rohini'), ('mirugaseerisham','Mirugaseerisham'), ('thiruvathirai','Thiruvathirai'),
  ('punarpoosam','Punarpoosam'), ('poosam','Poosam'), ('ayilyam','Ayilyam'),
  ('magam','Magam'), ('pooram','Pooram'), ('uthiram','Uthiram'),
  ('hastham','Hastham'), ('chithirai','Chithirai'), ('swathi','Swathi'),
  ('visakam','Visakam'), ('anusham','Anusham'), ('kettai','Kettai'),
  ('moolam','Moolam'), ('pooradam','Pooradam'), ('uthradam','Uthradam'),
  ('thiruvonam','Thiruvonam'), ('avittam','Avittam'), ('sathayam','Sathayam'),
  ('poorattathi','Poorattathi'), ('uthrattathi','Uthrattathi'), ('revathi','Revathi')
on conflict (code) do nothing;

insert into app.lookup_marital_statuses(code, name) values
  ('never_married','Never married'), ('divorced','Divorced'),
  ('widowed','Widowed'), ('separated','Separated')
on conflict (code) do nothing;

insert into app.lookup_diets(code, name) values
  ('vegetarian','Vegetarian'), ('non_vegetarian','Non-vegetarian'), ('vegan','Vegan')
on conflict (code) do nothing;
