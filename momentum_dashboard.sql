-- Requires momentum_connections.sql, momentum_plans.sql and momentum_tracking.sql.
-- Read-only aggregate; does not modify plans or daily records.
BEGIN;
CREATE OR REPLACE FUNCTION public.momentum_dashboard()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE me uuid:=auth.uid();today date:=(now() AT TIME ZONE 'Africa/Cairo')::date;month_start date:=date_trunc('month',now() AT TIME ZONE 'Africa/Cairo')::date;answer jsonb;
BEGIN
 IF me IS NULL THEN RAISE EXCEPTION 'Sign in first.';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=me AND p.role='trainer') THEN RAISE EXCEPTION 'Trainer account required.';END IF;
 WITH connected AS (
  SELECT p.id,pl.visibility,pl.details,pl.work_published,pl.diet_published,
   greatest(month_start,coalesce(nullif(pl.details->>'start','')::date,month_start)) AS period_start,
   least(today,coalesce(nullif(pl.details->>'end','')::date,today)) AS period_end
  FROM public.trainer_requests r JOIN public.profiles p ON p.id=r.athlete_id
  LEFT JOIN public.momentum_athlete_plans pl ON pl.athlete_id=p.id AND pl.trainer_id=me
  WHERE r.trainer_id=me AND r.status='accepted'
 ), activity AS (
  SELECT l.athlete_id,l.log_date,l.snapshot,public.momentum_tracking_metrics(l.snapshot,l.state) AS metrics
  FROM public.momentum_daily_logs l JOIN connected c ON c.id=l.athlete_id
  WHERE l.trainer_id=me AND l.log_date BETWEEN c.period_start AND c.period_end
 ), per_athlete AS (
  SELECT c.id,greatest(0,c.period_end-c.period_start+1) AS eligible_days,
   (SELECT count(*) FROM activity a WHERE a.athlete_id=c.id) AS logged_days,
   (SELECT round(avg((a.metrics->>'overall_percent')::numeric)) FROM activity a WHERE a.athlete_id=c.id) AS average,
   (SELECT (a.metrics->>'overall_percent')::numeric FROM activity a WHERE a.athlete_id=c.id AND a.log_date=today) AS today_percent,
   coalesce(c.visibility='published'
    AND coalesce(nullif(c.details->>'status',''),'Active')='Active'
    AND coalesce(nullif(c.details->>'start','')::date,today)<=today
    AND coalesce(nullif(c.details->>'end','')::date,today)>=today
    AND (EXISTS(SELECT 1 FROM jsonb_array_elements(coalesce(c.work_published,'[]')) d WHERE jsonb_array_length(coalesce(d->'exercises','[]'))>0)
      OR EXISTS(SELECT 1 FROM jsonb_array_elements(coalesce(c.diet_published,'[]')) d WHERE jsonb_array_length(coalesce(d->'meals','[]'))>0)),false) AS active_plan
  FROM connected c
 ), today_stats AS (
  SELECT count(*) AS recorded_athletes,
   round(avg((metrics->>'workout_percent')::numeric) FILTER(WHERE coalesce((snapshot->>'prescribed_rest')::boolean,false) OR jsonb_array_length(coalesce(snapshot->'work'->'exercises','[]'))>0)) AS workout,
   round(avg((metrics->>'meal_percent')::numeric) FILTER(WHERE jsonb_array_length(coalesce(snapshot->'meals','[]'))>0)) AS diet,
   round(avg((metrics->>'water_percent')::numeric) FILTER(WHERE coalesce((snapshot->>'water_target')::numeric,0)>0)) AS water,
   round(avg((metrics->>'overall_percent')::numeric)) AS overall
  FROM activity WHERE log_date=today
 )
 SELECT jsonb_build_object('date',today,'month_start',month_start,
  'athletes',coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM per_athlete p),'[]'),
  'active_plans',(SELECT count(*) FROM per_athlete WHERE active_plan),
  'average',(SELECT round(avg((metrics->>'overall_percent')::numeric)) FROM activity),
  'logged_days',(SELECT count(*) FROM activity),
  'eligible_days',coalesce((SELECT sum(eligible_days) FROM per_athlete),0),
  'today',(SELECT to_jsonb(t) FROM today_stats t)) INTO answer;
 RETURN answer;
END $$;
REVOKE ALL ON FUNCTION public.momentum_dashboard() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.momentum_dashboard() TO authenticated;
COMMIT;
