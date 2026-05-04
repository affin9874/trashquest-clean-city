
-- Fix function search_path
ALTER FUNCTION public.update_updated_at() SET search_path = public;

-- Restrict EXECUTE on SECURITY DEFINER functions
REVOKE EXECUTE ON FUNCTION public.has_role(UUID, public.app_role) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_role(UUID, public.app_role) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.handle_report_status_change() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.update_updated_at() FROM PUBLIC, anon, authenticated;

-- Tighten storage SELECT policy: anon can only fetch by exact path (not list)
DROP POLICY IF EXISTS "Trash photos public read" ON storage.objects;
CREATE POLICY "Trash photos read by owner or via report"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'trash-photos' AND (
      auth.uid()::text = (storage.foldername(name))[1]
      OR EXISTS (
        SELECT 1 FROM public.report_photos rp
        JOIN public.reports r ON r.id = rp.report_id
        WHERE rp.storage_path = name AND r.status = 'approved'
      )
    )
  );
