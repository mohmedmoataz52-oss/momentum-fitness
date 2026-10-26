-- Run AFTER momentum_connections.sql. No Auth/signup changes.
-- A transactional bundle keeps the seven-day workout and diet snapshots in sync.
BEGIN;
CREATE TABLE IF NOT EXISTS public.momentum_athlete_plans (
 athlete_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
 trainer_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 work_draft jsonb NOT NULL DEFAULT '[]', diet_draft jsonb NOT NULL DEFAULT '[]',
 work_published jsonb, diet_published jsonb,
 details jsonb NOT NULL DEFAULT '{}',
 visibility text NOT NULL DEFAULT 'draft' CHECK (visibility IN ('draft','published')),
 revision bigint NOT NULL DEFAULT 0,
 updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.momentum_athlete_plans ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.momentum_athlete_plans FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.momentum_plans(
 action text, target uuid DEFAULT NULL, payload jsonb DEFAULT NULL,
 expected_revision bigint DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE
 me uuid:=auth.uid(); my_role text; result jsonb; existing public.momentum_athlete_plans%ROWTYPE;
 w jsonb; d jsonb; day_item jsonb; item jsonb; food jsonb; value_key text;
 mode text; settings jsonb; photo text; field_num numeric;
BEGIN
 IF me IS NULL THEN RAISE EXCEPTION 'Sign in first.'; END IF;
 SELECT p.role INTO my_role FROM public.profiles p WHERE p.id=me;
 IF my_role IS NULL OR my_role NOT IN ('trainer','athlete') THEN RAISE EXCEPTION 'Valid profile required.'; END IF;
 IF action IN ('list','get') THEN
  IF action='list' AND my_role<>'trainer' THEN RAISE EXCEPTION 'Trainer account required.'; END IF;
  IF my_role='athlete' THEN
   IF target IS NOT NULL AND target<>me THEN RAISE EXCEPTION 'You can read only your own published plans.'; END IF;
   target:=me;
  ELSIF action='get' AND target IS NULL THEN RAISE EXCEPTION 'Choose an athlete first.';
  END IF;
  SELECT coalesce(jsonb_agg(record ORDER BY record->>'name'),'[]'::jsonb) INTO result FROM (
   SELECT
    jsonb_build_object('id',p.id,'name',p.full_name,'age',p.age,'weight',p.weight,'height',p.height,
     'phone',p.whatsapp,'email',u.email,'goal',coalesce(pl.details->>'goal','General Fitness'),
     'start',coalesce(pl.details->>'start',''),'end',coalesce(pl.details->>'end',''),
     'status',coalesce(pl.details->>'status','Active'),'photo',coalesce(pl.details->>'photo',''),
     'waterTarget',coalesce((pl.details->>'waterTarget')::numeric,3000),
     'visibility',coalesce(pl.visibility,'draft'),'updated_at',pl.updated_at,
     'revision',coalesce(pl.revision,0),
     'workPlan',CASE WHEN my_role='trainer' THEN coalesce(pl.work_draft,'[]') WHEN pl.visibility='published' THEN coalesce(pl.work_published,'[]') ELSE '[]'::jsonb END,
     'dietPlan',CASE WHEN my_role='trainer' THEN coalesce(pl.diet_draft,'[]') WHEN pl.visibility='published' THEN coalesce(pl.diet_published,'[]') ELSE '[]'::jsonb END)
    || CASE WHEN my_role='trainer' THEN jsonb_build_object('notes',coalesce(pl.details->>'notes','')) ELSE '{}'::jsonb END AS record
   FROM public.trainer_requests r JOIN public.profiles p ON p.id=r.athlete_id
   JOIN auth.users u ON u.id=p.id
   LEFT JOIN public.momentum_athlete_plans pl ON pl.athlete_id=p.id AND pl.trainer_id=r.trainer_id
   WHERE r.status='accepted' AND ((my_role='trainer' AND r.trainer_id=me) OR (my_role='athlete' AND r.athlete_id=me))
    AND (action='list' OR p.id=target)
  ) q;
  IF action='get' THEN RETURN result->0; ELSE RETURN result; END IF;
 ELSIF action='save' THEN
  IF my_role<>'trainer' THEN RAISE EXCEPTION 'Only the accepted trainer can edit plans.'; END IF;
  IF target IS NULL THEN RAISE EXCEPTION 'Choose an athlete first.'; END IF;
  -- Same athlete lock as connection acceptance serializes changes and saves.
  PERFORM 1 FROM public.profiles WHERE id=target FOR UPDATE;
  IF NOT EXISTS(SELECT 1 FROM public.trainer_requests WHERE trainer_id=me AND athlete_id=target AND status='accepted') THEN
   RAISE EXCEPTION 'This athlete is not connected to your trainer account.'; END IF;
  IF jsonb_typeof(payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Invalid plan payload.'; END IF;
  INSERT INTO public.momentum_athlete_plans(athlete_id,trainer_id) VALUES(target,me) ON CONFLICT(athlete_id) DO NOTHING;
  SELECT * INTO existing FROM public.momentum_athlete_plans WHERE athlete_id=target FOR UPDATE;
  IF existing.trainer_id<>me THEN RAISE EXCEPTION 'Existing plans belong to a different trainer; migration is required.'; END IF;
  IF expected_revision IS NULL OR expected_revision<>existing.revision THEN
   RAISE EXCEPTION 'Plan changed in another session. Reload before saving; your edits have not been applied.'; END IF;
  w:=payload->'workPlan'; d:=payload->'dietPlan';
  IF jsonb_typeof(w) IS DISTINCT FROM 'array' OR jsonb_typeof(d) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Plans must be arrays.'; END IF;
  IF jsonb_array_length(w)<>7 OR jsonb_array_length(d)<>7 THEN RAISE EXCEPTION 'Both plans must contain exactly seven days.'; END IF;
  FOR day_item IN SELECT value FROM jsonb_array_elements(w) LOOP
   IF jsonb_typeof(day_item) IS DISTINCT FROM 'object' OR jsonb_typeof(day_item->'exercises') IS DISTINCT FROM 'array'
    OR jsonb_typeof(day_item->'isRest') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'Invalid workout day.'; END IF;
   FOR item IN SELECT value FROM jsonb_array_elements(day_item->'exercises') LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Invalid exercise.'; END IF;
    FOREACH value_key IN ARRAY ARRAY['sets','weight','rest'] LOOP
     field_num:=nullif(item->>value_key,'')::numeric;
     IF field_num IS NULL OR field_num<0 OR field_num>100000 THEN RAISE EXCEPTION 'Exercise numbers must be non-negative.'; END IF;
    END LOOP;
   END LOOP;
  END LOOP;
  FOR day_item IN SELECT value FROM jsonb_array_elements(d) LOOP
   IF jsonb_typeof(day_item) IS DISTINCT FROM 'object' OR jsonb_typeof(day_item->'meals') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Invalid diet day.'; END IF;
   FOR item IN SELECT value FROM jsonb_array_elements(day_item->'meals') LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object' OR jsonb_typeof(item->'foods') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Invalid meal.'; END IF;
    FOR food IN SELECT value FROM jsonb_array_elements(item->'foods') LOOP
     IF jsonb_typeof(food) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Invalid food item.'; END IF;
     FOREACH value_key IN ARRAY ARRAY['quantity','calories','protein','carbs','fat'] LOOP
      field_num:=nullif(food->>value_key,'')::numeric;
      IF field_num IS NULL OR field_num<0 OR field_num>100000 THEN RAISE EXCEPTION 'Food values must be non-negative numbers.'; END IF;
     END LOOP;
    END LOOP;
   END LOOP;
  END LOOP;
  mode:=payload->>'visibility';
  IF mode IS NULL OR mode NOT IN ('draft','published') THEN RAISE EXCEPTION 'Invalid visibility.'; END IF;
  photo:=coalesce(payload->>'photo','');
  IF photo<>'' AND photo !~* '^https?://' THEN RAISE EXCEPTION 'Photo URL must start with https:// or http://.'; END IF;
  field_num:=coalesce(nullif(payload->>'waterTarget','')::numeric,3000);
  IF field_num<0 OR field_num>20000 THEN RAISE EXCEPTION 'Water target must be between 0 and 20000 ml.'; END IF;
  IF nullif(payload->>'start','') IS NOT NULL AND nullif(payload->>'end','') IS NOT NULL
   AND (payload->>'start')::date>(payload->>'end')::date THEN RAISE EXCEPTION 'Subscription end must follow its start.'; END IF;
  settings:=jsonb_build_object('goal',payload->>'goal','start',payload->>'start','end',payload->>'end',
   'status',payload->>'status','photo',photo,'waterTarget',field_num,'notes',payload->>'notes');
  IF payload->>'section'='profile' THEN
   IF length(trim(coalesce(payload->>'name','')))=0 THEN RAISE EXCEPTION 'Athlete name is required.'; END IF;
   IF nullif(payload->>'age','')::integer NOT BETWEEN 1 AND 110
    OR nullif(payload->>'weight','')::numeric<=0 OR nullif(payload->>'height','')::numeric<=0 THEN RAISE EXCEPTION 'Enter valid age, weight and height.'; END IF;
   UPDATE public.profiles SET full_name=trim(payload->>'name'), age=nullif(payload->>'age','')::integer,
    weight=nullif(payload->>'weight','')::numeric,height=nullif(payload->>'height','')::numeric,whatsapp=payload->>'phone' WHERE id=target;
  END IF;
  UPDATE public.momentum_athlete_plans SET work_draft=w,diet_draft=d,details=settings,visibility=mode,
   work_published=CASE WHEN mode='published' THEN w ELSE work_published END,
   diet_published=CASE WHEN mode='published' THEN d ELSE diet_published END,
   revision=revision+1,updated_at=now() WHERE athlete_id=target;
  RETURN public.momentum_plans('get',target);
 ELSE RAISE EXCEPTION 'Unknown plan action.';
 END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.momentum_plans(text,uuid,jsonb,bigint) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.momentum_plans(text,uuid,jsonb,bigint) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
