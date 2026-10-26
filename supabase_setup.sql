-- Run in Supabase SQL Editor AFTER column names are weight, height, whatsapp.
-- Extends the existing function; does not recreate or duplicate your trigger.
BEGIN;
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  INSERT INTO public.profiles (id,full_name,role,created_at,weight,height,age,whatsapp)
  VALUES (NEW.id,COALESCE(NEW.raw_user_meta_data->>'full_name',''),
    CASE WHEN NEW.raw_user_meta_data->>'role'='trainer' THEN 'trainer' ELSE 'athlete' END,
    NOW(),NULLIF(NEW.raw_user_meta_data->>'weight','')::numeric,
    NULLIF(NEW.raw_user_meta_data->>'height','')::numeric,
    NULLIF(NEW.raw_user_meta_data->>'age','')::integer,
    NEW.raw_user_meta_data->>'whatsapp');
  RETURN NEW;
END;
$function$;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.profiles TO authenticated;
DROP POLICY IF EXISTS momentum_read_own_profile ON public.profiles;
CREATE POLICY momentum_read_own_profile ON public.profiles FOR SELECT TO authenticated
USING ((SELECT auth.uid())=id);
COMMIT;
-- Existing policies remain unchanged. Review any broader policies separately.
