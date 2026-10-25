-- Run after the existing MOMENTUM connection migration. No existing plans/logs are changed.
BEGIN;
CREATE TABLE IF NOT EXISTS public.momentum_avatars(
 user_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
 storage_path text NOT NULL UNIQUE,updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.momentum_avatars ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.momentum_avatars FROM PUBLIC,anon,authenticated;
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES('momentum-avatars','momentum-avatars',false,5242880,ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT(id) DO UPDATE SET public=false,file_size_limit=5242880,allowed_mime_types=excluded.allowed_mime_types;
CREATE OR REPLACE FUNCTION public.momentum_avatar_can_read(path text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT auth.uid() IS NOT NULL AND (split_part(path,'/',1)=auth.uid()::text OR EXISTS(
  SELECT 1 FROM public.momentum_avatars a JOIN public.trainer_requests r
  ON ((r.athlete_id=a.user_id AND r.trainer_id=auth.uid()) OR (r.trainer_id=a.user_id AND r.athlete_id=auth.uid()))
  WHERE a.storage_path=path AND r.status='accepted'));
$$;
REVOKE ALL ON FUNCTION public.momentum_avatar_can_read(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.momentum_avatar_can_read(text) TO authenticated,anon;
DROP POLICY IF EXISTS momentum_avatar_read_guard ON storage.objects;
CREATE POLICY momentum_avatar_read_guard ON storage.objects AS RESTRICTIVE FOR SELECT TO PUBLIC
USING(bucket_id<>'momentum-avatars' OR public.momentum_avatar_can_read(name));
DROP POLICY IF EXISTS momentum_avatar_insert_guard ON storage.objects;
CREATE POLICY momentum_avatar_insert_guard ON storage.objects AS RESTRICTIVE FOR INSERT TO PUBLIC
WITH CHECK(bucket_id<>'momentum-avatars' OR (auth.uid() IS NOT NULL AND split_part(name,'/',1)=auth.uid()::text AND name~('^'||auth.uid()::text||'/[0-9a-f-]{36}\.(jpg|png|webp)$') AND EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND role IN ('athlete','trainer'))));
DROP POLICY IF EXISTS momentum_avatar_delete_guard ON storage.objects;
CREATE POLICY momentum_avatar_delete_guard ON storage.objects AS RESTRICTIVE FOR DELETE TO PUBLIC
USING(bucket_id<>'momentum-avatars' OR (auth.uid() IS NOT NULL AND split_part(name,'/',1)=auth.uid()::text));
DROP POLICY IF EXISTS momentum_avatar_update_guard ON storage.objects;
CREATE POLICY momentum_avatar_update_guard ON storage.objects AS RESTRICTIVE FOR UPDATE TO PUBLIC USING(bucket_id<>'momentum-avatars') WITH CHECK(bucket_id<>'momentum-avatars');
DROP POLICY IF EXISTS momentum_avatar_read ON storage.objects;
CREATE POLICY momentum_avatar_read ON storage.objects FOR SELECT TO authenticated USING(bucket_id='momentum-avatars' AND public.momentum_avatar_can_read(name));
DROP POLICY IF EXISTS momentum_avatar_insert ON storage.objects;
CREATE POLICY momentum_avatar_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='momentum-avatars' AND split_part(name,'/',1)=auth.uid()::text);
DROP POLICY IF EXISTS momentum_avatar_delete ON storage.objects;
CREATE POLICY momentum_avatar_delete ON storage.objects FOR DELETE TO authenticated USING(bucket_id='momentum-avatars' AND split_part(name,'/',1)=auth.uid()::text);
CREATE OR REPLACE FUNCTION public.momentum_avatar(action text,target uuid DEFAULT NULL,payload jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE me uuid:=auth.uid();who uuid:=coalesce(target,auth.uid());path text;old_path text;object_meta jsonb;kind text;bytes bigint;
BEGIN
 IF me IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=me AND role IN ('trainer','athlete')) THEN RAISE EXCEPTION 'Sign in first.';END IF;
 IF action='get' THEN
  IF who<>me AND NOT EXISTS(SELECT 1 FROM public.trainer_requests r WHERE r.status='accepted' AND ((r.athlete_id=me AND r.trainer_id=who) OR (r.trainer_id=me AND r.athlete_id=who))) THEN RAISE EXCEPTION 'This profile photo is private.';END IF;
  SELECT a.storage_path INTO path FROM public.momentum_avatars a WHERE a.user_id=who;
  RETURN jsonb_build_object('user_id',who,'storage_path',path);
 ELSIF action IN ('set','remove') THEN
  IF who<>me THEN RAISE EXCEPTION 'You can change only your own profile photo.';END IF;
  PERFORM 1 FROM public.profiles WHERE id=me FOR UPDATE;
  SELECT a.storage_path INTO old_path FROM public.momentum_avatars a WHERE a.user_id=me;
  IF action='set' THEN
   path:=payload->>'storage_path';
   IF path IS NULL OR path!~('^'||me::text||'/[0-9a-f-]{36}\.(jpg|png|webp)$') THEN RAISE EXCEPTION 'Invalid profile photo path.';END IF;
   SELECT metadata INTO object_meta FROM storage.objects WHERE bucket_id='momentum-avatars' AND name=path;
   IF object_meta IS NULL THEN RAISE EXCEPTION 'Upload the image first.';END IF;
   kind:=object_meta->>'mimetype';bytes:=(object_meta->>'size')::bigint;
   IF kind IS NULL OR kind NOT IN ('image/jpeg','image/png','image/webp') OR bytes IS NULL OR bytes NOT BETWEEN 1 AND 5242880 OR (kind='image/jpeg' AND path NOT LIKE '%.jpg') OR (kind='image/png' AND path NOT LIKE '%.png') OR (kind='image/webp' AND path NOT LIKE '%.webp') THEN RAISE EXCEPTION 'Use JPEG, PNG or WebP up to 5 MB.';END IF;
   INSERT INTO public.momentum_avatars(user_id,storage_path) VALUES(me,path)
   ON CONFLICT(user_id) DO UPDATE SET storage_path=excluded.storage_path,updated_at=now();
  ELSE DELETE FROM public.momentum_avatars WHERE user_id=me;path:=NULL;END IF;
  RETURN jsonb_build_object('user_id',me,'storage_path',path,'previous_path',old_path);
 END IF;
 RAISE EXCEPTION 'Unsupported action.';
END $$;
REVOKE ALL ON FUNCTION public.momentum_avatar(text,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.momentum_avatar(text,uuid,jsonb) TO authenticated;

CREATE TABLE IF NOT EXISTS public.momentum_trainer_invites(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),trainer_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 athlete_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','accepted','rejected')),
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(trainer_id,athlete_id)
);
ALTER TABLE public.momentum_trainer_invites ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.momentum_trainer_invites FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.momentum_directory(action text,target uuid DEFAULT NULL,decision text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE me uuid:=auth.uid();my_role text;a uuid;inv public.momentum_trainer_invites%ROWTYPE;answer jsonb;
BEGIN
 IF me IS NULL THEN RAISE EXCEPTION 'Sign in first.';END IF;
 SELECT role INTO my_role FROM public.profiles WHERE id=me;
 IF my_role IS NULL OR my_role NOT IN ('trainer','athlete') THEN RAISE EXCEPTION 'Valid profile required.';END IF;
 IF action IN ('lookup','invite') THEN
  IF my_role<>'trainer' THEN RAISE EXCEPTION 'Trainer account required.';END IF;
  IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=target AND role='athlete') THEN RETURN NULL;END IF;
  IF action='invite' THEN
   PERFORM 1 FROM public.profiles WHERE id=target FOR UPDATE;
   IF EXISTS(SELECT 1 FROM public.trainer_requests WHERE athlete_id=target AND status='accepted') THEN RAISE EXCEPTION 'This athlete already has a trainer connection.';END IF;
   INSERT INTO public.momentum_trainer_invites(trainer_id,athlete_id) VALUES(me,target)
   ON CONFLICT(trainer_id,athlete_id) DO UPDATE SET status=CASE WHEN momentum_trainer_invites.status='rejected' THEN 'pending' ELSE momentum_trainer_invites.status END,created_at=now();
  END IF;
  SELECT jsonb_build_object('id',p.id,'name',p.full_name,'status',CASE
   WHEN EXISTS(SELECT 1 FROM public.trainer_requests WHERE athlete_id=target AND trainer_id=me AND status='accepted') THEN 'connected'
   WHEN EXISTS(SELECT 1 FROM public.trainer_requests WHERE athlete_id=target AND status='accepted') THEN 'unavailable'
   ELSE coalesce((SELECT status FROM public.momentum_trainer_invites WHERE athlete_id=target AND trainer_id=me),'not invited') END) INTO answer FROM public.profiles p WHERE p.id=target;
  RETURN answer;
 ELSIF action='inbox' THEN
  SELECT coalesce(jsonb_agg(jsonb_build_object('id',i.id,'trainer_id',i.trainer_id,'athlete_id',i.athlete_id,'name',p.full_name,'status',i.status,'created_at',i.created_at) ORDER BY i.created_at DESC),'[]') INTO answer
  FROM public.momentum_trainer_invites i JOIN public.profiles p ON p.id=CASE WHEN my_role='athlete' THEN i.trainer_id ELSE i.athlete_id END
  WHERE (my_role='athlete' AND i.athlete_id=me AND i.status='pending') OR (my_role='trainer' AND i.trainer_id=me AND i.status='pending');
  RETURN answer;
 ELSIF action='respond' THEN
  IF my_role<>'athlete' THEN RAISE EXCEPTION 'Athlete account required.';END IF;
  PERFORM 1 FROM public.profiles WHERE id=me FOR UPDATE;
  SELECT * INTO inv FROM public.momentum_trainer_invites WHERE id=target AND athlete_id=me FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invitation not found.';END IF;
  IF decision NOT IN ('accepted','rejected') OR decision IS NULL THEN RAISE EXCEPTION 'Choose accept or reject.';END IF;
  IF inv.status=decision THEN RETURN jsonb_build_object('status',decision);END IF;
  IF inv.status<>'pending' THEN RAISE EXCEPTION 'Invitation already answered.';END IF;
  IF decision='accepted' THEN
   IF EXISTS(SELECT 1 FROM public.trainer_requests WHERE athlete_id=me AND status='accepted' AND trainer_id<>inv.trainer_id) THEN RAISE EXCEPTION 'You already have another accepted trainer.';END IF;
   INSERT INTO public.trainer_requests(athlete_id,trainer_id,status) VALUES(me,inv.trainer_id,'accepted')
   ON CONFLICT(athlete_id,trainer_id) DO UPDATE SET status='accepted';
   UPDATE public.trainer_requests SET status='rejected' WHERE athlete_id=me AND trainer_id<>inv.trainer_id AND status='pending';
   UPDATE public.momentum_trainer_invites SET status='rejected' WHERE athlete_id=me AND id<>inv.id AND status='pending';
  END IF;
  UPDATE public.momentum_trainer_invites SET status=decision WHERE id=inv.id;
  RETURN jsonb_build_object('status',decision);
 END IF;
 RAISE EXCEPTION 'Unsupported action.';
END $$;
REVOKE ALL ON FUNCTION public.momentum_directory(text,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.momentum_directory(text,uuid,text) TO authenticated;
COMMIT;
