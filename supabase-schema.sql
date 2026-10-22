-- =========================================================
-- 충무교회 중보기도 앱 - Supabase 스키마 (한 번만 실행)
-- 실행 위치: Supabase 대시보드 > SQL Editor > New query
-- 순서대로 전체를 붙여넣고 Run. 중복 실행해도 안전하게 작성됨.
-- =========================================================

create extension if not exists pgcrypto;
-- Supabase는 pgcrypto를 extensions 스키마에 두는 경우가 있어 crypt()를 못 찾음(42883).
-- public으로 옮겨야 아래 함수들이 만들어진다 (2026-10-22 실제 실행에서 확인된 필수 단계).
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pgcrypto') then
    execute 'alter extension pgcrypto set schema public';
  end if;
exception when others then null;
end $$;

-- ---------- 테이블 ----------
create table if not exists public.prayers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  is_anonymous boolean not null default false,
  phone text not null,
  pin_hash text not null,
  types text[] not null default '{}',
  title text not null,
  content text not null,
  target_type text,
  target_name text,
  desired_end_date date,
  status text not null default 'received'
    check (status in ('received','praying','answered','archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  role text not null default 'pending'
    check (role in ('pending','viewer','admin')),
  created_at timestamptz not null default now()
);

create table if not exists public.prayer_memos (
  id uuid primary key default gen_random_uuid(),
  prayer_id uuid not null references public.prayers(id) on delete cascade,
  author_id uuid references auth.users(id) on delete set null,
  author_email text,
  memo text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.app_settings (
  id int primary key,
  data jsonb not null
);

insert into public.app_settings (id, data) values (1, '{
  "app_name": "중보기도함",
  "church_name": "충무교회",
  "greeting": "기도제목을 남겨주세요.\n중보기도팀이 함께 기도합니다.",
  "verse_text": "\"아무 것도 염려하지 말고 다만 모든 일에 기도와 간구로, 너희 구할 것을 감사함으로 하나님께 아뢰라\" (빌립보서 4:6)",
  "allow_anonymous": true,
  "viewer_phone_mask": true,
  "retention_months": 3,
  "admin_emails": []
}'::jsonb) on conflict (id) do nothing;

-- ---------- RLS ----------
alter table public.prayers enable row level security;
alter table public.profiles enable row level security;
alter table public.prayer_memos enable row level security;
alter table public.app_settings enable row level security;

create or replace function public.current_role()
returns text language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid()
$$;

-- prayers: anon 직접 접근 없음(RPC로만). 로그인+역할 있는 사람만 조회, 수정/삭제는 관리자만
drop policy if exists prayers_select on public.prayers;
create policy prayers_select on public.prayers for select to authenticated
  using (public.current_role() in ('admin','viewer'));
drop policy if exists prayers_update on public.prayers;
create policy prayers_update on public.prayers for update to authenticated
  using (public.current_role() = 'admin') with check (public.current_role() = 'admin');
drop policy if exists prayers_delete on public.prayers;
create policy prayers_delete on public.prayers for delete to authenticated
  using (public.current_role() = 'admin');

-- profiles: 본인 또는 관리자 조회, 관리자만 역할 변경
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.current_role() = 'admin');
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (public.current_role() = 'admin') with check (public.current_role() = 'admin');

-- memos: 관리자/열람권한자 조회·등록, 본인 또는 관리자 삭제
drop policy if exists memos_select on public.prayer_memos;
create policy memos_select on public.prayer_memos for select to authenticated
  using (public.current_role() in ('admin','viewer'));
drop policy if exists memos_insert on public.prayer_memos;
create policy memos_insert on public.prayer_memos for insert to authenticated
  with check (public.current_role() in ('admin','viewer') and author_id = auth.uid());
drop policy if exists memos_delete on public.prayer_memos;
create policy memos_delete on public.prayer_memos for delete to authenticated
  using (author_id = auth.uid() or public.current_role() = 'admin');

-- app_settings: 누구나 조회(앱 표시용), 관리자만 수정
drop policy if exists settings_select on public.app_settings;
create policy settings_select on public.app_settings for select to anon, authenticated using (true);
drop policy if exists settings_update on public.app_settings;
create policy settings_update on public.app_settings for update to authenticated
  using (public.current_role() = 'admin') with check (public.current_role() = 'admin');

-- 명시적 권한 부여 (2026-10-30 이후 Supabase 정책 대응)
grant select on public.app_settings to anon, authenticated;
grant update on public.app_settings to authenticated;
grant select, update, delete on public.prayers to authenticated;
grant select, insert, delete on public.prayer_memos to authenticated;
grant select, update on public.profiles to authenticated;

-- ---------- 가입 시 profiles 자동 생성 ----------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

-- ---------- 제출자용 RPC (PIN 본인 확인) ----------
create or replace function public.verify_pin(p_phone text, p_pin text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.prayers
    where phone = p_phone and pin_hash = crypt(p_pin, pin_hash)
  )
$$;

create or replace function public.submit_prayer(
  p_name text, p_is_anonymous boolean, p_phone text, p_pin text,
  p_types text[], p_title text, p_content text,
  p_target_type text, p_target_name text, p_end_date date
) returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if p_pin is null or length(p_pin) <> 4 then raise exception 'PIN must be 4 digits'; end if;
  if p_types is null or array_length(p_types, 1) is null then raise exception 'types required'; end if;
  if not (p_types <@ array['urgent','regular']::text[]) then raise exception 'invalid types'; end if;
  insert into public.prayers (name, is_anonymous, phone, pin_hash, types, title, content, target_type, target_name, desired_end_date)
  values (p_name, coalesce(p_is_anonymous, false), p_phone, crypt(p_pin, gen_salt('bf')),
          p_types, p_title, p_content, p_target_type, p_target_name, p_end_date)
  returning id into new_id;
  return new_id;
end $$;

create or replace function public.my_prayers(p_phone text, p_pin text)
returns table (
  id uuid, name text, is_anonymous boolean, types text[], title text, content text,
  target_type text, target_name text, desired_end_date date, status text,
  created_at timestamptz, updated_at timestamptz
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.verify_pin(p_phone, p_pin) then return; end if;
  return query
    select p.id, p.name, p.is_anonymous, p.types, p.title, p.content,
           p.target_type, p.target_name, p.desired_end_date, p.status, p.created_at, p.updated_at
    from public.prayers p where p.phone = p_phone order by p.created_at desc;
end $$;

create or replace function public.update_my_prayer(
  p_id uuid, p_phone text, p_pin text,
  p_title text, p_content text, p_types text[], p_end_date date
) returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.verify_pin(p_phone, p_pin) then return false; end if;
  if p_types is null or array_length(p_types, 1) is null then return false; end if;
  update public.prayers
     set title = p_title, content = p_content, types = p_types,
         desired_end_date = p_end_date, updated_at = now()
   where id = p_id and phone = p_phone;
  return found;
end $$;

create or replace function public.delete_my_prayer(p_id uuid, p_phone text, p_pin text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.verify_pin(p_phone, p_pin) then return false; end if;
  delete from public.prayers where id = p_id and phone = p_phone;
  return found;
end $$;

grant execute on function public.verify_pin(text, text) to anon, authenticated;
grant execute on function public.submit_prayer(text, boolean, text, text, text[], text, text, text, text, date) to anon, authenticated;
grant execute on function public.my_prayers(text, text) to anon, authenticated;
grant execute on function public.update_my_prayer(uuid, text, text, text, text, text[], date) to anon, authenticated;
grant execute on function public.delete_my_prayer(uuid, text, text) to anon, authenticated;

-- =========================================================
-- [최초 1회] 관리자 지정: 앱에서 회원가입한 뒤 아래 문장의
-- 이메일만 바꿔서 실행하세요.
-- update public.profiles set role = 'admin' where email = '관리자이메일';
-- =========================================================
