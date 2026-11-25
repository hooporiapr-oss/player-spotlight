-- Production function definitions captured before release. Review ACL restoration separately.
BEGIN;
CREATE OR REPLACE FUNCTION public.spotlight_image(p_code text, p_school text, p_key text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s text := public.spotlight_school(p_code, p_school); tm text[];
begin
  if s is null then return null; end if;
  tm := public.coach_teams(p_code, s);
  return (select image from public.spotlight_cards where school = s and card_key = p_key and (tm is null or team = any(tm)));
end $function$;
-- Original ACL: {postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}

CREATE OR REPLACE FUNCTION public.spotlight_list(p_code text, p_school text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s text := public.spotlight_school(p_code, p_school); tm text[];
begin
  if s is null then return null; end if;
  tm := public.coach_teams(p_code, s);
  return jsonb_build_object('school', s, 'teams', to_jsonb(tm), 'cards', coalesce((
    select jsonb_agg(jsonb_build_object('key', card_key, 'name', name, 'team', team, 'category', category, 'thumb', thumb, 'at', updated_at)
                     order by length(team), lower(team), lower(category), lower(name))
      from public.spotlight_cards where school = s and (tm is null or team = any(tm))), '[]'::jsonb));
end $function$;
-- Original ACL: {postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}

CREATE OR REPLACE FUNCTION public.spotlight_publish(p_code text, p_school text, p_key text, p_name text, p_team text, p_category text, p_thumb text, p_image text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s text := public.spotlight_school(p_code, p_school);
begin
  if s is null then return null; end if;
  if p_key !~ '^[A-Za-z0-9_-]{1,64}$' or length(btrim(coalesce(p_name, ''))) not between 1 and 80
     or p_thumb !~ '^data:image/jpeg;base64,' or length(p_thumb) > 200000
     or p_image !~ '^data:image/jpeg;base64,' or length(p_image) > 2000000 then
    raise exception 'bad card';
  end if;
  insert into public.spotlight_cards (school, card_key, name, team, category, thumb, image, updated_at)
  values (s, p_key, btrim(p_name), left(btrim(coalesce(p_team, '')), 60), left(btrim(coalesce(p_category, '')), 40), p_thumb, p_image, now())
  on conflict (school, card_key) do update set name = excluded.name, team = excluded.team, category = excluded.category,
    thumb = excluded.thumb, image = excluded.image, updated_at = now();
  return jsonb_build_object('ok', true, 'school', s);
end $function$;
-- Original ACL: {postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}

CREATE OR REPLACE FUNCTION public.spotlight_remove(p_code text, p_school text, p_key text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s text := public.spotlight_school(p_code, p_school);
begin
  if s is null then return false; end if;
  delete from public.spotlight_cards where school = s and card_key = p_key;
  return found;
end $function$;
-- Original ACL: {postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}

CREATE OR REPLACE FUNCTION public.studio_del(p_code text, p_school text, p_id text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s text := public.spotlight_school(p_code, p_school);
begin
  if s is null then return null; end if;
  update public.studio_players set deleted = true, updated_at = now(), saved_at = now() where school = s and id = p_id;
  return true;
end $function$;
-- Original ACL: {postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}

CREATE OR REPLACE FUNCTION public.studio_get(p_code text, p_school text, p_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s text := public.spotlight_school(p_code, p_school);
begin
  if s is null then return null; end if;
  return (select data from public.studio_players where school = s and id = p_id and not deleted);
end $function$;
-- Original ACL: {postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}

CREATE OR REPLACE FUNCTION public.studio_list(p_code text, p_school text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s text := public.spotlight_school(p_code, p_school);
begin
  if s is null then return null; end if;
  return jsonb_build_object('school', s,
    'players', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'at', updated_at, 'deleted', deleted)) from public.studio_players where school = s), '[]'::jsonb),
    'settings_at', (select updated_at from public.studio_settings where school = s));
end $function$;
-- Original ACL: {postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}

CREATE OR REPLACE FUNCTION public.studio_put(p_code text, p_school text, p_id text, p_data jsonb, p_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s text := public.spotlight_school(p_code, p_school);
begin
  if s is null then return null; end if;
  if p_id !~ '^[A-Za-z0-9_-]{1,64}$' or jsonb_typeof(p_data) <> 'object' or length(p_data::text) > 6000000 then raise exception 'bad player'; end if;
  insert into public.studio_players (school, id, data, deleted, updated_at) values (s, p_id, p_data, false, p_at)
  on conflict (school, id) do update set data = excluded.data, deleted = false, updated_at = excluded.updated_at, saved_at = now()
   where public.studio_players.updated_at <= excluded.updated_at;
  return true;
end $function$;
-- Original ACL: {postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}

CREATE OR REPLACE FUNCTION public.studio_settings_put(p_code text, p_school text, p_data jsonb, p_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s text := public.spotlight_school(p_code, p_school);
begin
  if s is null then return null; end if;
  if jsonb_typeof(p_data) <> 'object' or length(p_data::text) > 4000000 then raise exception 'bad settings'; end if;
  insert into public.studio_settings (school, data, updated_at) values (s, p_data, p_at)
  on conflict (school) do update set data = excluded.data, updated_at = excluded.updated_at, saved_at = now()
   where public.studio_settings.updated_at <= excluded.updated_at;
  return true;
end $function$;
-- Original ACL: {postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}
COMMIT;
