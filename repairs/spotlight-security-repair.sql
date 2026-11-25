-- RELEASE CANDIDATE: review and test on staging before production.
-- Coordinated with spotlight-sync-repair.js; older Studio publishing is deliberately disabled.
-- No DELETE, TRUNCATE, DROP TABLE or migration of player data.
BEGIN;
ALTER TABLE public.spotlight_cards ADD COLUMN IF NOT EXISTS visible boolean NOT NULL DEFAULT true;

CREATE OR REPLACE FUNCTION public.studio_list(p_code text,p_school text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO public AS $$
DECLARE s text := public.spotlight_school(p_code,p_school); tm text[];
BEGIN
 IF s IS NULL THEN RETURN NULL; END IF;
 tm := public.coach_teams(p_code,s);
 RETURN jsonb_build_object('school',s,'players',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'at',updated_at,'deleted',deleted)) FROM public.studio_players WHERE school=s AND (tm IS NULL OR data->>'team'=ANY(tm))),'[]'::jsonb),'settings_at',(SELECT updated_at FROM public.studio_settings WHERE school=s),'can_edit_settings',tm IS NULL);
END $$;
CREATE OR REPLACE FUNCTION public.studio_get(p_code text,p_school text,p_id text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO public AS $$
DECLARE s text := public.spotlight_school(p_code,p_school); tm text[];
BEGIN
 IF s IS NULL THEN RETURN NULL; END IF;
 tm := public.coach_teams(p_code,s);
 RETURN (SELECT data FROM public.studio_players WHERE school=s AND id=p_id AND NOT deleted AND (tm IS NULL OR data->>'team'=ANY(tm)));
END $$;
CREATE OR REPLACE FUNCTION public.studio_put(p_code text,p_school text,p_id text,p_data jsonb,p_at timestamptz)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public AS $$
DECLARE s text := public.spotlight_school(p_code,p_school); tm text[]; affected integer;
BEGIN
 IF s IS NULL THEN RETURN NULL; END IF;
 tm := public.coach_teams(p_code,s);
 IF p_id IS NULL OR p_id !~ '^[A-Za-z0-9_-]{1,64}$' OR jsonb_typeof(p_data) IS DISTINCT FROM 'object' OR length(p_data::text)>6000000 OR p_data->>'id' IS DISTINCT FROM p_id OR p_at IS NULL OR nullif(p_data->>'updatedAt','')::timestamptz IS DISTINCT FROM p_at THEN RAISE EXCEPTION 'bad player'; END IF;
 IF tm IS NOT NULL AND NOT coalesce(p_data->>'team'=ANY(tm),false) THEN RETURN false; END IF;
 IF coalesce(p_data->>'photo','')<>'' OR coalesce(p_data->>'card','')<>'' OR coalesce(p_data#>>'{adj,mask}','')<>'' THEN
  IF NOT coalesce(p_data->>'consent' IN ('guardian','adult'),false) OR coalesce(p_data->>'consentAt','')='' THEN RAISE EXCEPTION 'photo permission required'; END IF;
 END IF;
 INSERT INTO public.studio_players(school,id,data,deleted,updated_at) VALUES(s,p_id,p_data,false,p_at)
 ON CONFLICT(school,id) DO UPDATE SET data=excluded.data,deleted=false,updated_at=excluded.updated_at,saved_at=now()
 WHERE NOT public.studio_players.deleted AND public.studio_players.updated_at<excluded.updated_at AND (tm IS NULL OR public.studio_players.data->>'team'=ANY(tm));
 GET DIAGNOSTICS affected=ROW_COUNT;
 IF affected=0 THEN
  -- Equal revision retry is success only if it is the exact same data, not a conflicting overwrite.
  RETURN EXISTS(SELECT 1 FROM public.studio_players WHERE school=s AND id=p_id AND NOT deleted AND updated_at=p_at AND data=p_data AND (tm IS NULL OR data->>'team'=ANY(tm)));
 END IF;
 -- An edited record must not continue serving an old card, including after consent or team changes.
 UPDATE public.spotlight_cards SET visible=false WHERE school=s AND card_key=p_id;
 RETURN true;
END $$;
CREATE OR REPLACE FUNCTION public.studio_del(p_code text,p_school text,p_id text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public AS $$
DECLARE s text := public.spotlight_school(p_code,p_school); tm text[]; player_row public.studio_players%ROWTYPE;
BEGIN
 IF s IS NULL THEN RETURN NULL; END IF;
 tm := public.coach_teams(p_code,s);
 SELECT * INTO player_row FROM public.studio_players WHERE school=s AND id=p_id FOR UPDATE;
 IF NOT FOUND THEN RETURN NOT EXISTS(SELECT 1 FROM public.spotlight_cards WHERE school=s AND card_key=p_id AND visible); END IF;
 IF tm IS NOT NULL AND NOT coalesce(player_row.data->>'team'=ANY(tm),false) THEN RETURN false; END IF;
 IF NOT player_row.deleted THEN
  UPDATE public.studio_players SET deleted=true,updated_at=greatest(updated_at,now()),saved_at=now() WHERE school=s AND id=p_id;
 END IF;
 UPDATE public.spotlight_cards SET visible=false WHERE school=s AND card_key=p_id;
 RETURN true;
END $$;

CREATE OR REPLACE FUNCTION public.studio_settings_put(p_code text,p_school text,p_data jsonb,p_at timestamptz)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public AS $$
DECLARE s text := public.spotlight_school(p_code,p_school); affected integer;
BEGIN
 IF s IS NULL THEN RETURN NULL; END IF;
 IF public.coach_teams(p_code,s) IS NOT NULL THEN RETURN false; END IF;
 IF jsonb_typeof(p_data) IS DISTINCT FROM 'object' OR length(p_data::text)>4000000 OR p_at IS NULL THEN RAISE EXCEPTION 'bad settings'; END IF;
 INSERT INTO public.studio_settings(school,data,updated_at) VALUES(s,p_data,p_at)
 ON CONFLICT(school) DO UPDATE SET data=excluded.data,updated_at=excluded.updated_at,saved_at=now() WHERE public.studio_settings.updated_at<excluded.updated_at;
 GET DIAGNOSTICS affected=ROW_COUNT;
 RETURN affected=1 OR EXISTS(SELECT 1 FROM public.studio_settings WHERE school=s AND updated_at=p_at AND data=p_data);
END $$;

CREATE OR REPLACE FUNCTION public.spotlight_publish_checked(p_code text,p_school text,p_key text,p_name text,p_team text,p_category text,p_thumb text,p_image text,p_at timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public AS $$
DECLARE s text := public.spotlight_school(p_code,p_school); tm text[]; pr public.studio_players%ROWTYPE; target_team text:=left(btrim(coalesce(p_team,'')),60);
BEGIN
 IF s IS NULL THEN RETURN NULL; END IF;
 tm:=public.coach_teams(p_code,s);
 IF p_key IS NULL OR p_key !~ '^[A-Za-z0-9_-]{1,64}$' OR length(btrim(coalesce(p_name,''))) NOT BETWEEN 1 AND 80 OR p_thumb IS NULL OR p_thumb !~ '^data:image/jpeg;base64,' OR length(p_thumb)>200000 OR p_image IS NULL OR p_image !~ '^data:image/jpeg;base64,' OR length(p_image)>2000000 OR p_at IS NULL THEN RAISE EXCEPTION 'bad card'; END IF;
 -- Lock the source record so a stale publication cannot race a player edit/removal.
 SELECT * INTO pr FROM public.studio_players WHERE school=s AND id=p_key FOR UPDATE;
 IF NOT FOUND OR pr.deleted OR pr.updated_at IS DISTINCT FROM p_at THEN RETURN NULL; END IF;
 IF tm IS NOT NULL AND NOT coalesce(pr.data->>'team'=ANY(tm),false) THEN RETURN NULL; END IF;
 IF pr.data->>'team' IS DISTINCT FROM target_team OR btrim(pr.data->>'name') IS DISTINCT FROM btrim(p_name) OR coalesce(pr.data->>'category','') IS DISTINCT FROM coalesce(p_category,'') THEN RETURN NULL; END IF;
 IF NOT coalesce(pr.data->>'consent' IN ('guardian','adult'),false) OR coalesce(pr.data->>'consentAt','')='' OR coalesce(pr.data->>'photo','')='' THEN RETURN NULL; END IF;
 INSERT INTO public.spotlight_cards(school,card_key,name,team,category,thumb,image,updated_at,visible)
 VALUES(s,p_key,btrim(p_name),target_team,left(btrim(coalesce(p_category,'')),40),p_thumb,p_image,now(),true)
 ON CONFLICT(school,card_key) DO UPDATE SET name=excluded.name,team=excluded.team,category=excluded.category,thumb=excluded.thumb,image=excluded.image,updated_at=now(),visible=true;
 RETURN jsonb_build_object('ok',true,'school',s);
END $$;
REVOKE ALL ON FUNCTION public.spotlight_publish_checked(text,text,text,text,text,text,text,text,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.spotlight_publish_checked(text,text,text,text,text,text,text,text,timestamptz) TO anon,authenticated;
-- Close the legacy entry point rather than letting old clients bypass the checked RPC.
REVOKE EXECUTE ON FUNCTION public.spotlight_publish(text,text,text,text,text,text,text,text) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.spotlight_remove(p_code text,p_school text,p_key text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public AS $$
DECLARE s text := public.spotlight_school(p_code,p_school); tm text[];
BEGIN
 IF s IS NULL THEN RETURN false; END IF;
 tm:=public.coach_teams(p_code,s);
 UPDATE public.spotlight_cards SET visible=false WHERE school=s AND card_key=p_key AND (tm IS NULL OR team=ANY(tm));
 RETURN FOUND;
END $$;
-- The old removal RPC could also hide a card independently of its player. New clients use studio_del.
REVOKE EXECUTE ON FUNCTION public.spotlight_remove(text,text,text) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.spotlight_list(p_code text,p_school text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO public AS $$
DECLARE s text := public.spotlight_school(p_code,p_school); tm text[];
BEGIN
 IF s IS NULL THEN RETURN NULL; END IF;
 tm:=public.coach_teams(p_code,s);
 RETURN jsonb_build_object('school',s,'teams',to_jsonb(tm),'cards',coalesce((
 SELECT jsonb_agg(jsonb_build_object('key',c.card_key,'name',c.name,'team',c.team,'category',c.category,'thumb',c.thumb,'at',c.updated_at) ORDER BY length(c.team),lower(c.team),lower(c.category),lower(c.name))
 FROM public.spotlight_cards c JOIN public.studio_players p ON p.school=c.school AND p.id=c.card_key
 WHERE c.school=s AND c.visible AND NOT p.deleted AND c.team=p.data->>'team' AND (tm IS NULL OR c.team=ANY(tm)) AND p.data->>'consent' IN ('guardian','adult') AND coalesce(p.data->>'consentAt','')<>'' AND coalesce(p.data->>'photo','')<>''),'[]'::jsonb));
END $$;
CREATE OR REPLACE FUNCTION public.spotlight_image(p_code text,p_school text,p_key text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO public AS $$
DECLARE s text := public.spotlight_school(p_code,p_school); tm text[];
BEGIN
 IF s IS NULL THEN RETURN NULL; END IF;
 tm:=public.coach_teams(p_code,s);
 RETURN (SELECT c.image FROM public.spotlight_cards c JOIN public.studio_players p ON p.school=c.school AND p.id=c.card_key WHERE c.school=s AND c.card_key=p_key AND c.visible AND NOT p.deleted AND c.team=p.data->>'team' AND (tm IS NULL OR c.team=ANY(tm)) AND p.data->>'consent' IN ('guardian','adult') AND coalesce(p.data->>'consentAt','')<>'' AND coalesce(p.data->>'photo','')<>'');
END $$;
COMMIT;
