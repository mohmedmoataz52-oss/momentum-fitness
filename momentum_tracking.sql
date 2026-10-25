-- Run after momentum_connections.sql and momentum_plans.sql.
-- Daily snapshots keep earlier dates tied to the plan actually logged that day.
BEGIN;
CREATE TABLE IF NOT EXISTS public.momentum_daily_logs (
 athlete_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 log_date date NOT NULL,
 trainer_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 day_index integer NOT NULL CHECK(day_index BETWEEN 1 AND 7),
 snapshot jsonb NOT NULL, state jsonb NOT NULL,
 revision bigint NOT NULL DEFAULT 1,
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(athlete_id,log_date)
);
CREATE INDEX IF NOT EXISTS momentum_daily_trainer_date ON public.momentum_daily_logs(trainer_id,log_date);
ALTER TABLE public.momentum_daily_logs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.momentum_daily_logs FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.momentum_tracking_metrics(snap jsonb, activity jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE
 ex_total integer:=jsonb_array_length(coalesce(snap->'work'->'exercises','[]'));
 meal_total integer:=jsonb_array_length(coalesce(snap->'meals','[]'));
 ex_done integer; meal_done integer; wp numeric:=0; mp numeric:=0; waterp numeric:=0;
 water_target numeric:=coalesce((snap->>'water_target')::numeric,0);
 score numeric:=0; denominator numeric:=10;
 prescribed boolean:=coalesce((snap->>'prescribed_rest')::boolean,false);
 chosen_rest boolean:=coalesce((activity->>'rest_override')::boolean,false);
BEGIN
 SELECT count(*) INTO ex_done FROM jsonb_array_elements(coalesce(activity->'exercise_completed','[]')) v WHERE v='true'::jsonb;
 SELECT count(*) INTO meal_done FROM jsonb_array_elements(coalesce(activity->'meal_completed','[]')) v WHERE v='true'::jsonb;
 IF prescribed THEN wp:=100; ELSIF ex_total>0 AND NOT chosen_rest THEN wp:=100.0*ex_done/ex_total; END IF;
 IF prescribed OR ex_total>0 THEN score:=score+wp*0.4;denominator:=denominator+40;END IF;
 IF meal_total>0 THEN mp:=100.0*meal_done/meal_total;score:=score+mp*0.3;denominator:=denominator+30;END IF;
 IF water_target>0 THEN waterp:=least(100,100.0*coalesce((activity->>'water_ml')::numeric,0)/water_target);score:=score+waterp*0.2;denominator:=denominator+20;END IF;
 IF jsonb_typeof(activity->'body_weight')='number' THEN score:=score+10;END IF;
 RETURN jsonb_build_object('exercises_done',ex_done,'exercises_total',ex_total,'meals_done',meal_done,'meals_total',meal_total,
 'workout_percent',round(wp),'meal_percent',round(mp),'water_percent',round(waterp),
 'overall_percent',round(100*score/denominator),'prescribed_rest',prescribed,'rest_override',chosen_rest);
END $$;
REVOKE ALL ON FUNCTION public.momentum_tracking_metrics(jsonb,jsonb) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.momentum_tracking(
 action text, log_date date DEFAULT NULL, payload jsonb DEFAULT NULL,
 expected_revision bigint DEFAULT NULL, target uuid DEFAULT NULL,
 date_from date DEFAULT NULL, date_to date DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
 me uuid:=auth.uid(); my_role text; today date:=(now() AT TIME ZONE 'Africa/Cairo')::date;
 chosen_date date:=coalesce(log_date,(now() AT TIME ZONE 'Africa/Cairo')::date);
 chosen_day integer; plan jsonb; snap jsonb; activity jsonb; response jsonb;
 entry public.momentum_daily_logs%ROWTYPE; prior_weight jsonb;
 ex_total integer; meal_total integer; field text; element jsonb;
 owner_id uuid; coach uuid; start_date date; end_date date;
BEGIN
 IF me IS NULL THEN RAISE EXCEPTION 'Sign in first.';END IF;
 SELECT p.role INTO my_role FROM public.profiles p WHERE p.id=me;
 IF my_role IS NULL THEN RAISE EXCEPTION 'Profile missing.';END IF;
 IF action='history' THEN
  owner_id:=coalesce(target,me);
  IF my_role='trainer' THEN
   IF target IS NULL OR NOT EXISTS(SELECT 1 FROM public.trainer_requests r WHERE r.trainer_id=me AND r.athlete_id=target AND r.status='accepted') THEN
    RAISE EXCEPTION 'This athlete is not connected to your trainer account.';END IF;
  ELSIF my_role<>'athlete' OR owner_id<>me THEN RAISE EXCEPTION 'You can read only your own activity.';END IF;
  start_date:=coalesce(date_from,today-89);end_date:=coalesce(date_to,today);
  IF start_date>end_date OR end_date-start_date>366 THEN RAISE EXCEPTION 'Choose a date range of at most 367 days.';END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('date',l.log_date,'athlete_id',l.athlete_id,'trainer_id',l.trainer_id,
   'day_index',l.day_index,'snapshot',l.snapshot,'state',l.state,'revision',l.revision,
   'metrics',public.momentum_tracking_metrics(l.snapshot,l.state),'updated_at',l.updated_at) ORDER BY l.log_date DESC),'[]'::jsonb)
  INTO response FROM public.momentum_daily_logs l WHERE l.athlete_id=owner_id AND l.log_date BETWEEN start_date AND end_date
   AND (my_role='athlete' OR l.trainer_id=me);
  RETURN response;
 END IF;
 IF my_role<>'athlete' OR (target IS NOT NULL AND target<>me) THEN RAISE EXCEPTION 'Athlete account required for daily logging.';END IF;
 IF action NOT IN ('load','read','save') THEN RAISE EXCEPTION 'Unknown tracking action.';END IF;
 IF chosen_date>today THEN RAISE EXCEPTION 'Future activity cannot be logged.';END IF;
 IF action='save' THEN
  IF chosen_date<>today THEN RAISE EXCEPTION 'This page saves today only. Reload after midnight.';END IF;
  PERFORM 1 FROM public.profiles p WHERE p.id=me FOR UPDATE;
 END IF;
 SELECT * INTO entry FROM public.momentum_daily_logs l WHERE l.athlete_id=me AND l.log_date=chosen_date;
 IF entry.athlete_id IS NOT NULL THEN
  IF action='load' AND payload ? 'day' AND (payload->>'day')::integer<>entry.day_index THEN
   RAISE EXCEPTION 'Today already has recorded activity. Its plan day cannot be changed.';END IF;
  snap:=entry.snapshot;activity:=entry.state;chosen_day:=entry.day_index;coach:=entry.trainer_id;
 ELSIF action='read' OR chosen_date<today THEN RETURN NULL;
 ELSE
  plan:=public.momentum_plans('get');
  IF plan IS NULL OR plan->>'visibility'<>'published' THEN RAISE EXCEPTION 'No published plan. Ask your connected coach to publish your plans first.';END IF;
  chosen_day:=coalesce((payload->>'day')::integer,extract(isodow FROM chosen_date)::integer);
  IF chosen_day NOT BETWEEN 1 AND 7 THEN RAISE EXCEPTION 'Choose Day 1 through Day 7.';END IF;
  SELECT r.trainer_id INTO coach FROM public.trainer_requests r WHERE r.athlete_id=me AND r.status='accepted';
  snap:=jsonb_build_object('work',plan->'workPlan'->(chosen_day-1),'meals',coalesce(plan->'dietPlan'->(chosen_day-1)->'meals','[]'),
   'prescribed_rest',coalesce((plan->'workPlan'->(chosen_day-1)->>'isRest')::boolean,false),
   'water_target',coalesce((plan->>'waterTarget')::integer,3000),'plan_revision',plan->'revision',
   'subscription_start',plan->>'start','subscription_end',plan->>'end');
  SELECT jsonb_build_object('exercise_completed',coalesce(jsonb_agg(false),'[]'::jsonb),
   'exercise_weights',coalesce(jsonb_agg(NULL::numeric),'[]'::jsonb)) INTO activity
   FROM jsonb_array_elements(coalesce(snap->'work'->'exercises','[]'));
  activity:=activity||jsonb_build_object('meal_completed',(SELECT coalesce(jsonb_agg(false),'[]'::jsonb) FROM jsonb_array_elements(snap->'meals')),
   'rest_override',false,'water_ml',0,'body_weight',NULL,'workout_saved',false);
 END IF;
 IF action='save' THEN
  IF expected_revision IS NULL OR expected_revision<>coalesce(entry.revision,0) THEN
   RAISE EXCEPTION 'Activity changed in another tab. Reload before saving again.';END IF;
  IF NOT EXISTS(SELECT 1 FROM public.trainer_requests r WHERE r.athlete_id=me AND r.trainer_id=coach AND r.status='accepted') THEN
   RAISE EXCEPTION 'Your trainer connection changed. Reload the page.';END IF;
  IF nullif(snap->>'subscription_start','')::date>chosen_date OR nullif(snap->>'subscription_end','')::date<chosen_date THEN
   RAISE EXCEPTION 'Today is outside the subscription dates set by your coach.';END IF;
  IF entry.athlete_id IS NULL AND (payload->>'plan_revision')::bigint IS DISTINCT FROM (snap->>'plan_revision')::bigint THEN
   RAISE EXCEPTION 'The published plan changed. Reload before logging.';END IF;
  IF jsonb_typeof(payload->'state') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Invalid activity data.';END IF;
  prior_weight:=activity->'body_weight';activity:=payload->'state';
  ex_total:=jsonb_array_length(coalesce(snap->'work'->'exercises','[]'));meal_total:=jsonb_array_length(snap->'meals');
  FOREACH field IN ARRAY ARRAY['exercise_completed','exercise_weights','meal_completed'] LOOP
   IF jsonb_typeof(activity->field) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Invalid tracking arrays.';END IF;
   IF jsonb_array_length(activity->field)<>(CASE WHEN field='meal_completed' THEN meal_total ELSE ex_total END) THEN
    RAISE EXCEPTION 'Activity does not match the assigned plan.';END IF;
   FOR element IN SELECT value FROM jsonb_array_elements(activity->field) LOOP
    IF field='exercise_weights' THEN
     IF element<>'null'::jsonb AND (jsonb_typeof(element)<>'number' OR (element#>>'{}')::numeric NOT BETWEEN 0 AND 2000) THEN RAISE EXCEPTION 'Exercise weight must be between 0 and 2000 kg.';END IF;
    ELSIF jsonb_typeof(element) IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'Completion values must be true or false.';END IF;
   END LOOP;
  END LOOP;
  IF jsonb_typeof(activity->'rest_override') IS DISTINCT FROM 'boolean' OR jsonb_typeof(activity->'workout_saved') IS DISTINCT FROM 'boolean'
   OR jsonb_typeof(activity->'water_ml') IS DISTINCT FROM 'number' THEN RAISE EXCEPTION 'Invalid daily state.';END IF;
  IF (activity->>'water_ml')::numeric NOT BETWEEN 0 AND 20000 OR (activity->>'water_ml')::numeric<>trunc((activity->>'water_ml')::numeric) THEN RAISE EXCEPTION 'Invalid water amount.';END IF;
  IF NOT(activity ? 'body_weight') OR (activity->'body_weight'<>'null'::jsonb AND
   (jsonb_typeof(activity->'body_weight')<>'number' OR (activity->>'body_weight')::numeric NOT BETWEEN 20 AND 300)) THEN RAISE EXCEPTION 'Body weight must be between 20 and 300 kg.';END IF;
  -- Only the whitelisted state is stored. Identity, snapshot, and metrics are server-owned.
  activity:=jsonb_build_object('exercise_completed',activity->'exercise_completed','exercise_weights',activity->'exercise_weights',
   'meal_completed',activity->'meal_completed','rest_override',activity->'rest_override',
   'water_ml',activity->'water_ml','body_weight',activity->'body_weight','workout_saved',activity->'workout_saved');
  INSERT INTO public.momentum_daily_logs(athlete_id,log_date,trainer_id,day_index,snapshot,state)
  VALUES(me,chosen_date,coach,chosen_day,snap,activity)
  ON CONFLICT ON CONSTRAINT momentum_daily_logs_pkey DO UPDATE SET state=excluded.state,revision=momentum_daily_logs.revision+1,updated_at=now()
  RETURNING * INTO entry;
  IF activity->'body_weight'<>'null'::jsonb AND activity->'body_weight' IS DISTINCT FROM prior_weight THEN
   UPDATE public.profiles SET weight=(activity->>'body_weight')::numeric WHERE id=me;
  END IF;
 END IF;
 RETURN jsonb_build_object('date',chosen_date,'athlete_id',me,'trainer_id',coach,'day_index',chosen_day,
  'snapshot',snap,'state',activity,'revision',coalesce(entry.revision,0),
  'metrics',public.momentum_tracking_metrics(snap,activity),'updated_at',entry.updated_at);
END $$;
REVOKE ALL ON FUNCTION public.momentum_tracking(text,date,jsonb,bigint,uuid,date,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.momentum_tracking(text,date,jsonb,bigint,uuid,date,date) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
