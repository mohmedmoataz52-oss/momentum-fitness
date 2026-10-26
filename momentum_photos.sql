-- Run after momentum_connections.sql. Existing plans and daily logs stay unchanged.
BEGIN;
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES('momentum-progress-photos','momentum-progress-photos',false,10485760,ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT(id) DO UPDATE SET public=false,file_size_limit=10485760,allowed_mime_types=excluded.allowed_mime_types;
CREATE TABLE IF NOT EXISTS public.momentum_progress_photos (
 id uuid PRIMARY KEY,
 athlete_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 trainer_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
 photo_date date NOT NULL,
 position text NOT NULL CHECK(position IN ('Front','Side','Back')),
 storage_path text NOT NULL UNIQUE,
 original_name text NOT NULL,
 mime_type text NOT NULL,
 size_bytes bigint NOT NULL CHECK(size_bytes>0 AND size_bytes<=10485760),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS momentum_photo_athlete_date ON public.momentum_progress_photos(athlete_id,photo_date DESC,created_at DESC);
ALTER TABLE public.momentum_progress_photos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.momentum_progress_photos FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.momentum_photo_can_read(object_name text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT auth.uid() IS NOT NULL AND (
  split_part(object_name,'/',1)=auth.uid()::text
  OR EXISTS(SELECT 1 FROM public.momentum_progress_photos p
   JOIN public.trainer_requests r ON r.athlete_id=p.athlete_id AND r.trainer_id=p.trainer_id AND r.status='accepted'
   JOIN public.profiles coach ON coach.id=r.trainer_id AND coach.role='trainer'
   WHERE p.storage_path=object_name AND p.trainer_id=auth.uid())
 );
$$;
REVOKE ALL ON FUNCTION public.momentum_photo_can_read(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.momentum_photo_can_read(text) TO anon,authenticated;

-- Restrictive guards protect this bucket even if an older, broad storage policy exists.
DROP POLICY IF EXISTS momentum_photos_read_guard ON storage.objects;
CREATE POLICY momentum_photos_read_guard ON storage.objects AS RESTRICTIVE FOR SELECT TO PUBLIC
USING(bucket_id<>'momentum-progress-photos' OR public.momentum_photo_can_read(name));
DROP POLICY IF EXISTS momentum_photos_insert_guard ON storage.objects;
CREATE POLICY momentum_photos_insert_guard ON storage.objects AS RESTRICTIVE FOR INSERT TO PUBLIC
WITH CHECK(bucket_id<>'momentum-progress-photos' OR (
 split_part(name,'/',1)=auth.uid()::text AND name~('^'||auth.uid()::text||'/[0-9a-f-]{36}\.(jpg|png|webp)$')
 AND EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND role='athlete')
));
DROP POLICY IF EXISTS momentum_photos_delete_guard ON storage.objects;
CREATE POLICY momentum_photos_delete_guard ON storage.objects AS RESTRICTIVE FOR DELETE TO PUBLIC
USING(bucket_id<>'momentum-progress-photos' OR split_part(name,'/',1)=auth.uid()::text);
DROP POLICY IF EXISTS momentum_photos_update_guard ON storage.objects;
CREATE POLICY momentum_photos_update_guard ON storage.objects AS RESTRICTIVE FOR UPDATE TO PUBLIC
USING(bucket_id<>'momentum-progress-photos') WITH CHECK(bucket_id<>'momentum-progress-photos');
DROP POLICY IF EXISTS momentum_photos_read ON storage.objects;
CREATE POLICY momentum_photos_read ON storage.objects FOR SELECT TO authenticated
USING(bucket_id='momentum-progress-photos' AND public.momentum_photo_can_read(name));
DROP POLICY IF EXISTS momentum_photos_upload ON storage.objects;
CREATE POLICY momentum_photos_upload ON storage.objects FOR INSERT TO authenticated
WITH CHECK(bucket_id='momentum-progress-photos' AND split_part(name,'/',1)=auth.uid()::text
 AND EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND role='athlete'));
DROP POLICY IF EXISTS momentum_photos_delete ON storage.objects;
CREATE POLICY momentum_photos_delete ON storage.objects FOR DELETE TO authenticated
USING(bucket_id='momentum-progress-photos' AND split_part(name,'/',1)=auth.uid()::text);

CREATE OR REPLACE FUNCTION public.momentum_photos(action text,target uuid DEFAULT NULL,payload jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
 me uuid:=auth.uid(); my_role text; owner_id uuid; coach uuid; photo_id uuid;
 entry public.momentum_progress_photos%ROWTYPE; path text; mime text; size bigint;
 position_name text; day_date date; original text; start_date date; end_date date;
 page_offset integer; page_limit integer; total_count bigint; result jsonb; extension text;
BEGIN
 IF me IS NULL THEN RAISE EXCEPTION 'Sign in first.';END IF;
 SELECT p.role INTO my_role FROM public.profiles p WHERE p.id=me;
 IF my_role IS NULL THEN RAISE EXCEPTION 'Profile missing.';END IF;
 IF action='list' THEN
  owner_id:=coalesce(target,me);
  IF my_role='trainer' THEN
   IF target IS NULL OR NOT EXISTS(SELECT 1 FROM public.trainer_requests r WHERE r.trainer_id=me AND r.athlete_id=target AND r.status='accepted') THEN
    RAISE EXCEPTION 'This athlete is not connected to your trainer account.';END IF;
  ELSIF my_role<>'athlete' OR owner_id<>me THEN RAISE EXCEPTION 'You can read only your own photos.';END IF;
  start_date:=nullif(payload->>'date_from','')::date;end_date:=nullif(payload->>'date_to','')::date;
  IF start_date>end_date THEN RAISE EXCEPTION 'Invalid photo date range.';END IF;
  position_name:=nullif(payload->>'position','');
  IF position_name IS NOT NULL AND position_name NOT IN ('Front','Side','Back') THEN RAISE EXCEPTION 'Invalid photo position.';END IF;
  page_offset:=coalesce((payload->>'offset')::integer,0);page_limit:=coalesce((payload->>'limit')::integer,100);
  IF page_offset<0 OR page_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid photo page.';END IF;
  SELECT count(*) INTO total_count FROM public.momentum_progress_photos p
   WHERE p.athlete_id=owner_id AND (my_role='athlete' OR p.trainer_id=me)
   AND (start_date IS NULL OR p.photo_date>=start_date) AND (end_date IS NULL OR p.photo_date<=end_date)
   AND (position_name IS NULL OR p.position=position_name);
  SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.photo_date DESC,q.created_at DESC,q.id DESC),'[]'::jsonb) INTO result
   FROM (SELECT p.* FROM public.momentum_progress_photos p
   WHERE p.athlete_id=owner_id AND (my_role='athlete' OR p.trainer_id=me)
   AND (start_date IS NULL OR p.photo_date>=start_date) AND (end_date IS NULL OR p.photo_date<=end_date)
   AND (position_name IS NULL OR p.position=position_name)
   ORDER BY p.photo_date DESC,p.created_at DESC,p.id DESC LIMIT page_limit OFFSET page_offset) q;
  RETURN jsonb_build_object('items',result,'total',total_count,'has_more',page_offset+jsonb_array_length(result)<total_count,
   'next_offset',page_offset+jsonb_array_length(result));
 END IF;
 IF my_role<>'athlete' OR (target IS NOT NULL AND target<>me) THEN RAISE EXCEPTION 'Only athletes can manage their own photos.';END IF;
 photo_id:=(payload->>'id')::uuid;
 IF photo_id IS NULL THEN RAISE EXCEPTION 'Photo ID is required.';END IF;
 SELECT * INTO entry FROM public.momentum_progress_photos p WHERE p.id=photo_id;
 IF entry.id IS NOT NULL AND entry.athlete_id<>me THEN RAISE EXCEPTION 'This photo belongs to another athlete.';END IF;
 IF action='add' THEN
  -- Idempotent retry after an interrupted response never creates a duplicate.
  IF entry.id IS NOT NULL THEN RETURN to_jsonb(entry);END IF;
  path:=payload->>'storage_path';day_date:=(payload->>'photo_date')::date;position_name:=payload->>'position';
  IF day_date IS NULL OR day_date>(now() AT TIME ZONE 'Africa/Cairo')::date THEN RAISE EXCEPTION 'Choose today or an earlier photo date.';END IF;
  IF position_name IS NULL OR position_name NOT IN ('Front','Side','Back') THEN RAISE EXCEPTION 'Choose Front, Side, or Back.';END IF;
  IF path IS NULL OR path NOT IN (me::text||'/'||photo_id::text||'.jpg',me::text||'/'||photo_id::text||'.png',me::text||'/'||photo_id::text||'.webp') THEN
   RAISE EXCEPTION 'Invalid photo storage path.';END IF;
  SELECT o.metadata->>'mimetype',nullif(o.metadata->>'size','')::bigint INTO mime,size
   FROM storage.objects o WHERE o.bucket_id='momentum-progress-photos' AND o.name=path;
  IF mime IS NULL OR mime NOT IN ('image/jpeg','image/png','image/webp') OR size IS NULL OR size NOT BETWEEN 1 AND 10485760 THEN
   RAISE EXCEPTION 'Upload a JPG, PNG, or WEBP image up to 10 MB first.';END IF;
  extension:=CASE mime WHEN 'image/jpeg' THEN '.jpg' WHEN 'image/png' THEN '.png' ELSE '.webp' END;
  IF path<>me::text||'/'||photo_id::text||extension THEN RAISE EXCEPTION 'Image type does not match its file extension.';END IF;
  original:=left(coalesce(nullif(payload->>'original_name',''),'Progress photo'),200);
  SELECT r.trainer_id INTO coach FROM public.trainer_requests r WHERE r.athlete_id=me AND r.status='accepted';
  INSERT INTO public.momentum_progress_photos(id,athlete_id,trainer_id,photo_date,position,storage_path,original_name,mime_type,size_bytes)
  VALUES(photo_id,me,coach,day_date,position_name,path,original,mime,size) RETURNING * INTO entry;
  RETURN to_jsonb(entry);
 ELSIF action='get' THEN RETURN CASE WHEN entry.id IS NULL THEN NULL ELSE to_jsonb(entry) END;
 ELSIF action='remove' THEN
  IF entry.id IS NULL THEN RETURN jsonb_build_object('deleted',true);END IF;
  IF EXISTS(SELECT 1 FROM storage.objects o WHERE o.bucket_id='momentum-progress-photos' AND o.name=entry.storage_path) THEN
   RAISE EXCEPTION 'Remove the image through Storage before removing its photo record.';END IF;
  DELETE FROM public.momentum_progress_photos WHERE id=entry.id;
  RETURN jsonb_build_object('deleted',true);
 ELSE RAISE EXCEPTION 'Unknown photo action.';
 END IF;
END $$;
REVOKE ALL ON FUNCTION public.momentum_photos(text,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.momentum_photos(text,uuid,jsonb) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
