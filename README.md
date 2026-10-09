# Inaiyam Matrimony backend

Supabase backend for a free matrimony application using Postgres, RLS, Auth, and
private Storage. The frontend API contract is documented in [BACKEND_API.md](./BACKEND_API.md).

## Local setup

```powershell
npx supabase start
npx supabase db reset
npx supabase gen types typescript --local > types/database.ts
```

Local seed data includes ten approved sample profiles, two published success stories,
and `seed-admin@example.local` with password `LocalAdmin@12345`. Never use these
credentials outside local development.

Run the repeatable local integration suite by providing the local URL, publishable
key, and service-role key without committing them:

```powershell
$env:SUPABASE_URL = "http://127.0.0.1:54321"
$env:SUPABASE_ANON_KEY = "<local-publishable-key>"
$env:SUPABASE_SERVICE_ROLE_KEY = "<local-service-role-key>"
powershell -ExecutionPolicy Bypass -File .\tests\rls.ps1
```

## Migrations

Migrations 001-008 establish the schema, RLS, moderation flow, private buckets, and
5 MB file limits. Migration 009 removes paid plans, subscriptions, payment ledgers,
and Razorpay dependencies. It also adds accepted-interest contact gating, free
interest withdrawal, profile details, staff administration helpers, and the contact
form.

## Production checklist

Before launch:

- Authenticate and link the intended Supabase project.
- Use `npx supabase db push`; never use `db reset` remotely.
- Enable email confirmations and signup in the Auth dashboard.
- Set minimum password length to 8.
- Set the production Site URL and redirect URLs.
- Expose the `app` schema through the API settings.
- Confirm all four buckets are private and have the migration 008 MIME/size limits.
- Configure backups, PITR, logs, retention, DPDP notices, consent, and deletion
  procedures with the product/legal owner.
- Run `tests/rls.ps1` against an isolated project using a gitignored environment file.

No payment gateway, subscriptions, plans, messaging, or ID-document bucket is part
of this backend.
