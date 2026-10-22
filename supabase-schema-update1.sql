-- =========================================================
-- 중보기도 앱 업데이트 1: 관리자·중보기도팀 가입을
-- 이메일/비밀번호 → 이름·연락처·PIN 방식으로 교체
-- SQL Editor에서 전체 실행 (중복 실행 안전)
-- 일반 성도 제출 방식은 기존 그대로 (변경 없음)
-- =========================================================

create table if not exists public.team_members (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text not null unique,
  pin_hash text not null,
  role text not null default 'pending'
    check (role in ('pending','viewer','admin')),
  created_at timestamptz not null default now(),
  last_login_at timestamptz
);

create table if not exists public.team_login_attempts (
  phone text not null,
  tried_at timestamptz not null default now()
);

alter table public.team_members enable row level security;
alter table public.team_login_attempts enable row level security;
-- 정책 없음 = anon/authenticated 직접 접근 차단. 아래 RPC(security definer)로만 접근.

-- ---------- 내부 헬퍼 ----------
create or replace function public.team_member_by_pin(p_phone text, p_pin text)
returns public.team_members language sql stable security definer set search_path = public as $$
  select * from public.team_members
  where phone = p_phone and pin_hash = crypt(p_pin, pin_hash) limit 1
$$;

-- ---------- 가입 / 로그인 ----------
create or replace function public.team_signup(p_name text, p_phone text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare new_role text; rec public.team_members;
begin
  if p_name is null or length(trim(p_name)) = 0 then raise exception 'name required'; end if;
  if p_pin is null or length(p_pin) <> 4 then raise exception 'PIN must be 4 digits'; end if;
  if exists (select 1 from public.team_members where phone = p_phone) then
    raise exception 'already registered';
  end if;
  -- 첫 가입자는 자동 관리자 (초기 세팅용). 이후 가입자는 승인 대기.
  if exists (select 1 from public.team_members where role = 'admin') then
    new_role := 'pending';
  else
    new_role := 'admin';
  end if;
  insert into public.team_members (name, phone, pin_hash, role)
  values (trim(p_name), p_phone, crypt(p_pin, gen_salt('bf')), new_role)
  returning * into rec;
  return jsonb_build_object('id', rec.id, 'name', rec.name, 'role', rec.role);
end $$;

create or replace function public.team_login(p_phone text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare rec public.team_members; fails int;
begin
  select count(*) into fails from public.team_login_attempts
  where phone = p_phone and tried_at > now() - interval '10 minutes';
  if fails >= 5 then raise exception 'too many attempts'; end if;
  select * into rec from public.team_member_by_pin(p_phone, p_pin);
  if rec.id is null then
    insert into public.team_login_attempts (phone) values (p_phone);
    return null;
  end if;
  delete from public.team_login_attempts where phone = p_phone;
  update public.team_members set last_login_at = now() where id = rec.id;
  return jsonb_build_object('id', rec.id, 'name', rec.name, 'role', rec.role);
end $$;

-- ---------- 데이터 (관리자/열람권한자) ----------
create or replace function public.team_list_prayers(p_phone text, p_pin text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare rec public.team_members; mask boolean; result jsonb;
begin
  select * into rec from public.team_member_by_pin(p_phone, p_pin);
  if rec.id is null or rec.role = 'pending' then return null; end if;
  select coalesce((data->>'viewer_phone_mask')::boolean, true) into mask
  from public.app_settings where id = 1;
  select coalesce(jsonb_agg(to_jsonb(p) - 'pin_hash' ||
    case when rec.role = 'viewer' and mask
         then jsonb_build_object('phone', left(p.phone, 3) || '****' || right(p.phone, 4))
         else '{}'::jsonb end
    order by p.created_at desc), '[]'::jsonb)
  into result from public.prayers p;
  return result;
end $$;

create or replace function public.team_set_status(p_phone text, p_pin text, p_id uuid, p_status text)
returns boolean language plpgsql security definer set search_path = public as $$
declare rec public.team_members;
begin
  select * into rec from public.team_member_by_pin(p_phone, p_pin);
  if rec.id is null or rec.role <> 'admin' then return false; end if;
  if p_status not in ('received','praying','answered','archived') then return false; end if;
  update public.prayers set status = p_status, updated_at = now() where id = p_id;
  return found;
end $$;

create or replace function public.team_delete_prayer(p_phone text, p_pin text, p_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare rec public.team_members;
begin
  select * into rec from public.team_member_by_pin(p_phone, p_pin);
  if rec.id is null or rec.role <> 'admin' then return false; end if;
  delete from public.prayers where id = p_id;
  return found;
end $$;

create or replace function public.team_list_memos(p_phone text, p_pin text, p_prayer_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare rec public.team_members; result jsonb;
begin
  select * into rec from public.team_member_by_pin(p_phone, p_pin);
  if rec.id is null or rec.role = 'pending' then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', m.id, 'memo', m.memo, 'author_name', m.author_name, 'created_at', m.created_at)
      order by m.created_at), '[]'::jsonb)
  into result from (
    select mm.*, coalesce(tm.name, mm.author_email, '') as author_name
    from public.prayer_memos mm left join public.team_members tm on tm.id = mm.author_id
    where mm.prayer_id = p_prayer_id
  ) m;
  return result;
end $$;

create or replace function public.team_add_memo(p_phone text, p_pin text, p_prayer_id uuid, p_memo text)
returns boolean language plpgsql security definer set search_path = public as $$
declare rec public.team_members;
begin
  select * into rec from public.team_member_by_pin(p_phone, p_pin);
  if rec.id is null or rec.role = 'pending' then return false; end if;
  -- author_id는 auth.users 참조라 팀원 id를 넣을 수 없어 비우고, 이름은 author_email 칸에 기록 (표시용)
  insert into public.prayer_memos (prayer_id, author_id, author_email, memo)
  values (p_prayer_id, null, rec.name, p_memo);
  return true;
end $$;

-- ---------- 권한 관리 / 설정 (관리자) ----------
create or replace function public.team_list_members(p_phone text, p_pin text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare rec public.team_members; result jsonb;
begin
  select * into rec from public.team_member_by_pin(p_phone, p_pin);
  if rec.id is null or rec.role <> 'admin' then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'phone', phone, 'role', role, 'created_at', created_at)
      order by created_at), '[]'::jsonb)
  into result from public.team_members;
  return result;
end $$;

create or replace function public.team_set_role(p_phone text, p_pin text, p_target uuid, p_role text)
returns boolean language plpgsql security definer set search_path = public as $$
declare rec public.team_members;
begin
  select * into rec from public.team_member_by_pin(p_phone, p_pin);
  if rec.id is null or rec.role <> 'admin' then return false; end if;
  if p_role not in ('pending','viewer','admin') then return false; end if;
  if p_target = rec.id and p_role <> 'admin' then return false; end if; -- 자기 강등 방지
  update public.team_members set role = p_role where id = p_target;
  return found;
end $$;

create or replace function public.team_save_settings(p_phone text, p_pin text, p_data jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare rec public.team_members;
begin
  select * into rec from public.team_member_by_pin(p_phone, p_pin);
  if rec.id is null or rec.role <> 'admin' then return false; end if;
  update public.app_settings set data = p_data where id = 1;
  return found;
end $$;

grant execute on function public.team_signup(text, text, text) to anon, authenticated;
grant execute on function public.team_login(text, text) to anon, authenticated;
grant execute on function public.team_list_prayers(text, text) to anon, authenticated;
grant execute on function public.team_set_status(text, text, uuid, text) to anon, authenticated;
grant execute on function public.team_delete_prayer(text, text, uuid) to anon, authenticated;
grant execute on function public.team_list_memos(text, text, uuid) to anon, authenticated;
grant execute on function public.team_add_memo(text, text, uuid, text) to anon, authenticated;
grant execute on function public.team_list_members(text, text) to anon, authenticated;
grant execute on function public.team_set_role(text, text, uuid, text) to anon, authenticated;
grant execute on function public.team_save_settings(text, text, jsonb) to anon, authenticated;
