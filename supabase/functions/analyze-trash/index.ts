import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const TRASH_TYPES = ["plastic","paper","glass","metal","organic","hazardous","electronic","general"] as const;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  try {
    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
    if (!LOVABLE_API_KEY) throw new Error("LOVABLE_API_KEY not configured");

    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const authHeader = req.headers.get("Authorization") ?? "";

    // Auth check
    const userClient = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { reportId } = await req.json();
    if (!reportId || typeof reportId !== "string") {
      return new Response(JSON.stringify({ error: "reportId required" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    // Load report + photos, verify ownership
    const { data: report, error: rErr } = await admin
      .from("reports").select("*").eq("id", reportId).single();
    if (rErr || !report) throw new Error("Report not found");
    if (report.user_id !== user.id) {
      return new Response(JSON.stringify({ error: "Forbidden" }), {
        status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: photos } = await admin
      .from("report_photos").select("*").eq("report_id", reportId).order("display_order");
    if (!photos || photos.length < 3) throw new Error("ต้องมีรูปอย่างน้อย 3 รูป");
    if (photos.length > 5) throw new Error("ไม่เกิน 5 รูป");

    await admin.from("reports").update({ status: "analyzing" }).eq("id", reportId);

    // Build image messages
    const imageContent = photos.map((p) => ({
      type: "image_url",
      image_url: { url: p.public_url },
    }));

    const systemPrompt = `คุณเป็น AI ตรวจสอบรายงานขยะของแอป TrashQuest
หน้าที่: วิเคราะห์ภาพถ่ายขยะ ${photos.length} รูปจากผู้ใช้ที่รายงานจุดทิ้งขยะในเมือง
ตอบเฉพาะผ่าน tool call analyze_trash_report เท่านั้น
- is_real_trash: true เฉพาะเมื่อภาพแสดงขยะจริงในที่สาธารณะ/ไม่ใช่ภาพปลอม/ไม่ใช่รูปอื่น
- ถ้าเป็นรูปคน เซลฟี่ มีม screenshot รูปสุ่ม → is_real_trash=false
- ประเมิน estimated_items แบบสมเหตุสมผล (1-200 ชิ้น)`;

    const tools = [{
      type: "function",
      function: {
        name: "analyze_trash_report",
        description: "Analyze trash photos from user report",
        parameters: {
          type: "object",
          properties: {
            is_real_trash: { type: "boolean" },
            primary_type: { type: "string", enum: TRASH_TYPES as unknown as string[] },
            estimated_items: { type: "integer", minimum: 0, maximum: 500 },
            summary_th: { type: "string", description: "สรุปสั้นๆ ภาษาไทย 1-2 ประโยค" },
            rejection_reason: { type: "string", description: "เหตุผลปฏิเสธ ถ้า is_real_trash=false" },
            per_photo: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  detected_type: { type: "string", enum: TRASH_TYPES as unknown as string[] },
                  confidence: { type: "number", minimum: 0, maximum: 1 },
                  description: { type: "string" },
                  is_valid: { type: "boolean" },
                },
                required: ["detected_type","confidence","description","is_valid"],
              },
            },
          },
          required: ["is_real_trash","primary_type","estimated_items","summary_th","per_photo"],
        },
      },
    }];

    const aiResp = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${LOVABLE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "google/gemini-2.5-flash",
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: [
            { type: "text", text: `วิเคราะห์รูปขยะ ${photos.length} ใบนี้` },
            ...imageContent,
          ]},
        ],
        tools,
        tool_choice: { type: "function", function: { name: "analyze_trash_report" } },
      }),
    });

    if (!aiResp.ok) {
      const txt = await aiResp.text();
      console.error("AI gateway error", aiResp.status, txt);
      if (aiResp.status === 429) {
        await admin.from("reports").update({ status: "pending" }).eq("id", reportId);
        return new Response(JSON.stringify({ error: "AI กำลังคิวเยอะ ลองใหม่อีกครั้ง" }), {
          status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (aiResp.status === 402) {
        await admin.from("reports").update({ status: "pending" }).eq("id", reportId);
        return new Response(JSON.stringify({ error: "เครดิต AI หมด กรุณาเติมที่ Workspace" }), {
          status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      throw new Error(`AI error ${aiResp.status}`);
    }

    const aiJson = await aiResp.json();
    const toolCall = aiJson.choices?.[0]?.message?.tool_calls?.[0];
    if (!toolCall) throw new Error("AI did not return structured result");
    const result = JSON.parse(toolCall.function.arguments);

    // Get points per type
    const { data: cats } = await admin.from("trash_categories").select("type, points_per_item");
    const pointsMap = new Map(cats?.map((c: any) => [c.type, c.points_per_item]) ?? []);

    let pointsAwarded = 0;
    let newStatus: "approved" | "rejected" = "rejected";

    if (result.is_real_trash) {
      const perItemPoints = pointsMap.get(result.primary_type) ?? 5;
      const items = Math.max(1, Math.min(result.estimated_items ?? photos.length, 200));
      const photoBonus = photos.length * 5; // bonus per photo submitted
      pointsAwarded = items * perItemPoints + photoBonus;
      newStatus = "approved";
    }

    // Update photos
    for (let i = 0; i < photos.length; i++) {
      const pp = result.per_photo?.[i];
      if (!pp) continue;
      await admin.from("report_photos").update({
        detected_type: pp.detected_type,
        ai_confidence: pp.confidence,
        ai_description: pp.description,
        is_valid_trash: pp.is_valid,
      }).eq("id", photos[i].id);
    }

    // Update report
    await admin.from("reports").update({
      status: newStatus,
      points_awarded: pointsAwarded,
      primary_trash_type: result.primary_type,
      estimated_items: result.estimated_items ?? 0,
      ai_summary: result.summary_th,
      ai_rejection_reason: result.is_real_trash ? null : (result.rejection_reason ?? "AI ไม่สามารถยืนยันว่าเป็นขยะจริง"),
    }).eq("id", reportId);

    return new Response(JSON.stringify({
      success: true,
      status: newStatus,
      points_awarded: pointsAwarded,
      summary: result.summary_th,
      rejection_reason: result.is_real_trash ? null : result.rejection_reason,
    }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (err) {
    console.error("analyze-trash error:", err);
    return new Response(JSON.stringify({
      error: err instanceof Error ? err.message : "Unknown error",
    }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
