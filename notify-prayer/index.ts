// 중보기도 앱 - 관리자 알림 이메일 Edge Function
// 배포: Supabase 대시보드 > Edge Functions > Create function > 이름: notify-prayer
// 필요 Secrets (Edge Functions > Secrets):
//   RESEND_API_KEY   : Resend 가입 후 발급한 API 키
// (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY는 자동 제공됨)
// 주의: Resend 무료 발송은 기본 발신 주소(onboarding@resend.dev)로는
//       Resend 가입 계정 본인 이메일로만 보낼 수 있습니다.
//       다른 관리자 이메일로도 보내려면 Resend에서 도메인 인증이 필요합니다.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { prayer_id, site_url } = await req.json();
    if (!prayer_id) return json({ ok: false, error: "prayer_id required" }, 400);

    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { data: prayer } = await sb.from("prayers").select("*").eq("id", prayer_id).single();
    if (!prayer) return json({ ok: false, error: "prayer not found" }, 404);

    const { data: settingsRow } = await sb.from("app_settings").select("data").eq("id", 1).single();
    const emails: string[] = settingsRow?.data?.admin_emails ?? [];
    const resendKey = Deno.env.get("RESEND_API_KEY");
    if (!resendKey || !emails.length) return json({ ok: true, skipped: "email not configured" });

    const urgent = (prayer.types ?? []).includes("urgent");
    const kind = urgent ? "긴급기도" : "상시기도";
    const subject = `[중보기도] ${urgent ? "[긴급] " : ""}새 기도제목 접수: ${prayer.title}`;
    const who = prayer.is_anonymous ? "익명" : prayer.name;
    const when = new Date(prayer.created_at).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" });
    const text = [
      `새 기도제목이 접수되었습니다.`,
      ``,
      `구분: ${kind}`,
      `제목: ${prayer.title}`,
      `제출자: ${who}`,
      `접수 시각: ${when}`,
      ``,
      `내용은 앱의 관리자 화면에서 확인하세요.`,
      site_url ? `앱 주소: ${site_url}` : ``,
      ``,
      `※ 이 메일은 알림 전용입니다. 기도 내용은 메일에 포함하지 않습니다.`,
    ].join("\n");

    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Authorization": `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: "중보기도함 <onboarding@resend.dev>",
        to: emails,
        subject,
        text,
      }),
    });
    if (!res.ok) return json({ ok: false, error: await res.text() }, 502);
    return json({ ok: true });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}
