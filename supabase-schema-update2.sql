-- =========================================================
-- 중보기도 앱 업데이트 2: 누구나 열람 가능한 공개 기도 게시판
-- SQL Editor에서 전체 실행 (중복 실행 안전)
-- - 제출 시 "공개"를 선택한 기도제목만 게시판에 표시
-- - 공개 목록에는 전화번호·PIN이 절대 포함되지 않음
-- - 관리자는 앱에서 공개/비공개를 언제든 전환 가능
-- =========================================================

alter table public.prayers
  add column if not exists is_public boolean not null default false;

-- ---------- 제출: 공개 여부 파라미터 추가 ----------
drop function if exists public.submit_prayer(text, boolean, text, text, text[], text, text, text, text, date);
create or replace function public.submit_prayer(
  p_name text, p_is_anonymous boolean, p_phone text, p_pin text,
  p_types text[], p_title text, p_content text,
  p_target_type text, p_target_name text, p_end_date date,
  p_is_public boolean default false
) returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if p_pin is null or length(p_pin) <> 4 then raise exception 'PIN must be 4 digits'; end if;
  if p_types is null or array_length(p_types, 1) is null then raise exception 'types required'; end if;
  if not (p_types <@ array['urgent','regular']::text[]) then raise exception 'invalid types'; end if;
  insert into public.prayers (name, is_anonymous, phone, pin_hash, types, title, content, target_type, target_name, desired_end_date, is_public)
  values (p_name, coalesce(p_is_anonymous, false), p_phone, crypt(p_pin, gen_salt('bf')),
          p_types, p_title, p_content, p_target_type, p_target_name, p_end_date, coalesce(p_is_public, false))
  returning id into new_id;
  return new_id;
end $$;

-- ---------- 내 기도 조회: 공개 여부 포함 (반환 형식 변경이라 재생성) ----------
drop function if exists public.my_prayers(text, text);
create function public.my_prayers(p_phone text, p_pin text)
returns table (
  id uuid, name text, is_anonymous boolean, types text[], title text, content text,
  target_type text, target_name text, desired_end_date date, status text,
  is_public boolean, created_at timestamptz, updated_at timestamptz
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.verify_pin(p_phone, p_pin) then return; end if;
  return query
    select p.id, p.name, p.is_anonymous, p.types, p.title, p.content,
           p.target_type, p.target_name, p.desired_end_date, p.status, p.is_public,
           p.created_at, p.updated_at
    from public.prayers p where p.phone = p_phone order by p.created_at desc;
end $$;

-- ---------- 내 기도 수정: 공개 여부 변경 가능 ----------
drop function if exists public.update_my_prayer(uuid, text, text, text, text, text[], date);
create or replace function public.update_my_prayer(
  p_id uuid, p_phone text, p_pin text,
  p_title text, p_content text, p_types text[], p_end_date date,
  p_is_public boolean default null
) returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.verify_pin(p_phone, p_pin) then return false; end if;
  if p_types is null or array_length(p_types, 1) is null then return false; end if;
  update public.prayers
     set title = p_title, content = p_content, types = p_types,
         desired_end_date = p_end_date,
         is_public = coalesce(p_is_public, is_public),
         updated_at = now()
   where id = p_id and phone = p_phone;
  return found;
end $$;

-- ---------- 공개 게시판 목록 (로그인 불필요, 전화번호 제외) ----------
create or replace function public.public_list_prayers()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare enabled boolean; result jsonb;
begin
  select coalesce((data->>'public_board_enabled')::boolean, true) into enabled
  from public.app_settings where id = 1;
  if not coalesce(enabled, true) then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id,
      'name', case when p.is_anonymous then '익명' else p.name end,
      'types', p.types,
      'title', p.title,
      'content', p.content,
      'target_type', p.target_type,
      'target_name', p.target_name,
      'desired_end_date', p.desired_end_date,
      'status', p.status,
      'created_at', p.created_at
    ) order by p.created_at desc), '[]'::jsonb)
  into result
  from public.prayers p
  where p.is_public and p.status <> 'archived'
  limit 100;
  return result;
end $$;

-- ---------- 관리자: 공개 전환 ----------
create or replace function public.team_set_public(p_phone text, p_pin text, p_id uuid, p_public boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare rec public.team_members;
begin
  select * into rec from public.team_member_by_pin(p_phone, p_pin);
  if rec.id is null or rec.role <> 'admin' then return false; end if;
  update public.prayers set is_public = p_public, updated_at = now() where id = p_id;
  return found;
end $$;

grant execute on function public.submit_prayer(text, boolean, text, text, text[], text, text, text, text, date, boolean) to anon, authenticated;
grant execute on function public.my_prayers(text, text) to anon, authenticated;
grant execute on function public.update_my_prayer(uuid, text, text, text, text, text[], date, boolean) to anon, authenticated;
grant execute on function public.public_list_prayers() to anon, authenticated;
grant execute on function public.team_set_public(text, text, uuid, boolean) to anon, authenticated;
