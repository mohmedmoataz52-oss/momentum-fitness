-- Run after momentum_connections.sql. Keeps existing plans and activity unchanged.
BEGIN;
CREATE TABLE IF NOT EXISTS public.momentum_support_cases (
 id uuid PRIMARY KEY, athlete_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 trainer_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 subject text NOT NULL CHECK(length(subject) BETWEEN 1 AND 160),
 description text NOT NULL CHECK(length(description) BETWEEN 10 AND 1500),
 category text NOT NULL, priority text NOT NULL CHECK(priority IN ('Low','Medium','High')),
 contact_email text NOT NULL DEFAULT '', status text NOT NULL DEFAULT 'Open' CHECK(status IN ('Open','In Review','Resolved')),
 replies jsonb NOT NULL DEFAULT '[]', revision bigint NOT NULL DEFAULT 1,
 athlete_archived boolean NOT NULL DEFAULT false,trainer_archived boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS momentum_support_athlete ON public.momentum_support_cases(athlete_id,created_at);
CREATE INDEX IF NOT EXISTS momentum_support_trainer ON public.momentum_support_cases(trainer_id,created_at);
ALTER TABLE public.momentum_support_cases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.momentum_support_cases FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.momentum_support(action text,target uuid DEFAULT NULL,payload jsonb DEFAULT NULL,expected_revision bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE me uuid:=auth.uid(); my_role text; a uuid; t uuid; cid uuid; rec public.momentum_support_cases%ROWTYPE; answer jsonb; body text;
BEGIN
 IF me IS NULL THEN RAISE EXCEPTION 'Sign in first.'; END IF;
 SELECT p.role INTO my_role FROM public.profiles p WHERE p.id=me;
 IF my_role IS NULL OR my_role NOT IN ('athlete','trainer') THEN RAISE EXCEPTION 'Valid profile required.';END IF;
 IF action='list' THEN
  SELECT coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('athlete_name',p.full_name) ORDER BY c.updated_at DESC),'[]') INTO answer
  FROM public.momentum_support_cases c JOIN public.profiles p ON p.id=c.athlete_id
  WHERE (my_role='athlete' AND c.athlete_id=me AND NOT c.athlete_archived)
   OR (my_role='trainer' AND c.trainer_id=me AND NOT c.trainer_archived AND EXISTS(SELECT 1 FROM public.trainer_requests r WHERE r.athlete_id=c.athlete_id AND r.trainer_id=me AND r.status='accepted'));
  RETURN answer;
 ELSIF action='create' THEN
  cid:=(payload->>'id')::uuid;
  IF cid IS NULL THEN RAISE EXCEPTION 'Case ID required.';END IF;
  -- A retry after a lost response must return the existing case unchanged.
  SELECT * INTO rec FROM public.momentum_support_cases c WHERE c.id=cid;
  IF FOUND THEN
   IF (my_role='athlete' AND rec.athlete_id=me) OR (my_role='trainer' AND rec.trainer_id=me AND EXISTS(SELECT 1 FROM public.trainer_requests r WHERE r.athlete_id=rec.athlete_id AND r.trainer_id=me AND r.status='accepted')) THEN RETURN to_jsonb(rec);END IF;
   RAISE EXCEPTION 'Case ID already in use.';
  END IF;
  a:=CASE WHEN my_role='athlete' THEN me ELSE target END;
  PERFORM 1 FROM public.profiles p WHERE p.id=a AND p.role='athlete' FOR UPDATE;
  SELECT r.trainer_id INTO t FROM public.trainer_requests r WHERE r.athlete_id=a AND r.status='accepted';
  IF t IS NULL OR (my_role='trainer' AND t<>me) THEN RAISE EXCEPTION 'An accepted athlete–trainer connection is required.';END IF;
  IF coalesce(length(trim(payload->>'subject')),0) NOT BETWEEN 1 AND 160 OR coalesce(length(trim(payload->>'description')),0) NOT BETWEEN 10 AND 1500 THEN RAISE EXCEPTION 'Subject: 1–160 characters; details: 10–1500 characters.';END IF;
  IF coalesce(payload->>'priority','Low') NOT IN ('Low','Medium','High') OR coalesce(length(payload->>'category'),0) NOT BETWEEN 1 AND 100 OR length(coalesce(payload->>'contact_email',''))>254 THEN RAISE EXCEPTION 'Invalid category, priority, or email.';END IF;
  INSERT INTO public.momentum_support_cases(id,athlete_id,trainer_id,subject,description,category,priority,contact_email)
  VALUES(cid,a,t,trim(payload->>'subject'),trim(payload->>'description'),payload->>'category',coalesce(payload->>'priority','Low'),coalesce(payload->>'contact_email',''))
  ON CONFLICT(id) DO NOTHING;
  SELECT * INTO rec FROM public.momentum_support_cases c WHERE c.id=cid;
  IF rec.athlete_id<>a OR rec.trainer_id<>t THEN RAISE EXCEPTION 'Case ID already in use.'; END IF;
  RETURN to_jsonb(rec);
 END IF;
 SELECT * INTO rec FROM public.momentum_support_cases c WHERE c.id=target FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Case not found.';END IF;
 IF NOT ((my_role='athlete' AND rec.athlete_id=me) OR (my_role='trainer' AND rec.trainer_id=me AND EXISTS(SELECT 1 FROM public.trainer_requests r WHERE r.athlete_id=rec.athlete_id AND r.trainer_id=me AND r.status='accepted'))) THEN RAISE EXCEPTION 'This case is private.';END IF;
 IF action='archive' THEN
  UPDATE public.momentum_support_cases SET athlete_archived=CASE WHEN my_role='athlete' THEN true ELSE athlete_archived END,trainer_archived=CASE WHEN my_role='trainer' THEN true ELSE trainer_archived END WHERE id=target;
  RETURN jsonb_build_object('ok',true);
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.trainer_requests r WHERE r.athlete_id=rec.athlete_id AND r.trainer_id=rec.trainer_id AND r.status='accepted') THEN RAISE EXCEPTION 'Connection is no longer active. Previous messages remain available to the athlete.';END IF;
 IF expected_revision IS NULL OR expected_revision<>rec.revision THEN RAISE EXCEPTION 'This case changed. Refresh before saving again.';END IF;
 IF action='reply' THEN
  body:=trim(payload->>'body');IF coalesce(length(body),0) NOT BETWEEN 1 AND 1500 THEN RAISE EXCEPTION 'Reply must be 1–1500 characters.';END IF;
  rec.replies:=rec.replies||jsonb_build_array(jsonb_build_object('author_id',me,'role',my_role,'body',body,'created_at',now()));
 ELSIF action='status' AND my_role='trainer' THEN
  IF coalesce(payload->>'status','') NOT IN ('Open','In Review','Resolved') THEN RAISE EXCEPTION 'Invalid status.';END IF;
  rec.status:=payload->>'status';
 ELSE RAISE EXCEPTION 'Unsupported action.';END IF;
 UPDATE public.momentum_support_cases SET replies=rec.replies,status=rec.status,revision=revision+1,updated_at=now(),athlete_archived=false,trainer_archived=false WHERE id=target RETURNING * INTO rec;
 RETURN to_jsonb(rec);
END $$;
REVOKE ALL ON FUNCTION public.momentum_support(text,uuid,jsonb,bigint) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.momentum_support(text,uuid,jsonb,bigint) TO authenticated;
COMMIT;
