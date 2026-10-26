-- Trainer settings. Requires the existing profiles table; does not alter Auth.
BEGIN;
CREATE TABLE IF NOT EXISTS public.momentum_trainer_settings(
 trainer_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
 bio text NOT NULL DEFAULT '',water_target integer NOT NULL DEFAULT 3000 CHECK(water_target BETWEEN 0 AND 20000),
 visibility text NOT NULL DEFAULT 'draft' CHECK(visibility IN ('draft','published')),
 units text NOT NULL DEFAULT 'metric' CHECK(units IN ('metric','imperial')),
 note text NOT NULL DEFAULT '',revision bigint NOT NULL DEFAULT 1,updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.momentum_trainer_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.momentum_trainer_settings FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.momentum_settings(action text,payload jsonb DEFAULT NULL,expected_revision bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE me uuid:=auth.uid();p public.profiles%ROWTYPE;s public.momentum_trainer_settings%ROWTYPE;phone text;water numeric;
BEGIN
 IF me IS NULL THEN RAISE EXCEPTION 'Sign in first.';END IF;
 SELECT * INTO p FROM public.profiles WHERE id=me FOR UPDATE;
 IF NOT FOUND OR p.role<>'trainer' THEN RAISE EXCEPTION 'Trainer account required.';END IF;
 SELECT * INTO s FROM public.momentum_trainer_settings WHERE trainer_id=me FOR UPDATE;
 IF action='save' THEN
  IF expected_revision IS NULL OR expected_revision<>coalesce(s.revision,0) THEN RAISE EXCEPTION 'Settings changed. Reload saved settings before trying again.';END IF;
  IF coalesce(length(trim(payload->>'full_name')),0) NOT BETWEEN 1 AND 120 THEN RAISE EXCEPTION 'Name must be 1–120 characters.';END IF;
  phone:=regexp_replace(coalesce(payload->>'whatsapp',''),'[[:space:]()+.-]','','g');
  IF phone LIKE '0020%' THEN phone:=substr(phone,3);END IF;
  IF phone ~ '^01[0-9]{9}$' THEN phone:='20'||substr(phone,2);END IF;
  IF phone<>'' AND phone !~ '^[1-9][0-9]{7,14}$' THEN RAISE EXCEPTION 'Enter a valid WhatsApp number including country code, or an Egyptian mobile number.';END IF;
  water:=nullif(payload->>'water_target','')::numeric;
  IF water IS NULL OR water<0 OR water>20000 OR water<>trunc(water) THEN RAISE EXCEPTION 'Water target must be a whole number from 0 to 20000 ml.';END IF;
  IF coalesce(payload->>'visibility','') NOT IN ('draft','published') OR coalesce(payload->>'units','') NOT IN ('metric','imperial') THEN RAISE EXCEPTION 'Invalid preferences.';END IF;
  IF length(coalesce(payload->>'bio',''))>1500 OR length(coalesce(payload->>'note',''))>1500 THEN RAISE EXCEPTION 'Bio and note must be at most 1500 characters.';END IF;
  UPDATE public.profiles SET full_name=trim(payload->>'full_name'),whatsapp=nullif(phone,'') WHERE id=me RETURNING * INTO p;
  INSERT INTO public.momentum_trainer_settings AS prefs(trainer_id,bio,water_target,visibility,units,note)
  VALUES(me,coalesce(payload->>'bio',''),water::integer,payload->>'visibility',payload->>'units',coalesce(payload->>'note',''))
  ON CONFLICT(trainer_id) DO UPDATE SET bio=excluded.bio,water_target=excluded.water_target,visibility=excluded.visibility,units=excluded.units,note=excluded.note,revision=prefs.revision+1,updated_at=now()
  RETURNING * INTO s;
 ELSIF action<>'get' THEN RAISE EXCEPTION 'Unsupported action.';END IF;
 RETURN jsonb_build_object('id',me,'full_name',p.full_name,'whatsapp',coalesce(p.whatsapp,''),'bio',coalesce(s.bio,''),'water_target',coalesce(s.water_target,3000),'visibility',coalesce(s.visibility,'draft'),'units',coalesce(s.units,'metric'),'note',coalesce(s.note,''),'revision',coalesce(s.revision,0));
END $$;
REVOKE ALL ON FUNCTION public.momentum_settings(text,jsonb,bigint) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.momentum_settings(text,jsonb,bigint) TO authenticated;
COMMIT;
