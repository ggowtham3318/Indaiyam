import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

function response(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (request) => {
  try {
    if (request.method !== "POST") return response({ error: "METHOD_NOT_ALLOWED" }, 405);
    const authorization = request.headers.get("Authorization");
    if (!authorization) return response({ error: "AUTH_REQUIRED" }, 401);
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: authorization } } });
    const { data: { user } } = await anon.auth.getUser();
    if (!user) return response({ error: "AUTH_REQUIRED" }, 401);
    const { data: staff, error: staffError } = await anon.rpc("is_staff");
    if (staffError || !staff) return response({ error: "STAFF_REQUIRED" }, 403);
    const { photo_id, status, reason } = await request.json();
    if (typeof photo_id !== "string" || !["approved", "rejected", "removed"].includes(status)) return response({ error: "INVALID_REQUEST" }, 400);

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: photo, error: photoError } = await admin.from("profile_photos").select("id, storage_bucket, storage_path").eq("id", photo_id).single();
    if (photoError || !photo) return response({ error: "PHOTO_NOT_FOUND" }, 404);
    let approvedPath: string | null = null;
    if (status === "approved") {
      approvedPath = `${user.id}/${photo.id}`;
      const { error: copyError } = await admin.storage.from("photos-pending").copy(photo.storage_path, approvedPath, { destinationBucket: "photos-approved" });
      if (copyError) return response({ error: "PHOTO_COPY_FAILED" }, 502);
    }
    const { error: reviewError } = await anon.rpc("admin_review_photo", {
      p_photo_id: photo_id,
      p_status: status,
      p_reason: reason ?? null,
      p_approved_storage_path: approvedPath,
    });
    if (reviewError) {
      if (approvedPath) await admin.storage.from("photos-approved").remove([approvedPath]);
      return response({ error: "PHOTO_REVIEW_FAILED" }, 500);
    }
    if (status !== "approved" && photo.storage_bucket === "photos-pending") {
      await admin.storage.from("photos-pending").remove([photo.storage_path]);
    }
    return response({ ok: true });
  } catch (error) {
    console.error("review-photo", error);
    return response({ error: "INTERNAL_ERROR" }, 500);
  }
});
