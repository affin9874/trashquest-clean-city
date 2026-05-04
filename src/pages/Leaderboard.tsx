import { useEffect, useState } from "react";
import { AppHeader } from "@/components/AppHeader";
import { Card, CardContent } from "@/components/ui/card";
import { Trophy, Medal } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";

type Row = { id: string; display_name: string | null; avatar_url: string | null; total_points: number; total_reports: number; level: number };

const Leaderboard = () => {
  const [rows, setRows] = useState<Row[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    supabase.from("profiles").select("id,display_name,avatar_url,total_points,total_reports,level")
      .order("total_points", { ascending: false }).limit(100)
      .then(({ data }) => { setRows((data as Row[]) ?? []); setLoading(false); });
  }, []);

  const medalFor = (i: number) => i === 0 ? "🥇" : i === 1 ? "🥈" : i === 2 ? "🥉" : `#${i + 1}`;

  return (
    <div className="min-h-screen bg-background">
      <AppHeader />
      <main className="container max-w-3xl py-8">
        <div className="mb-6 flex items-center gap-3">
          <span className="grid h-12 w-12 place-items-center rounded-2xl bg-brand-amber text-brand-amber-foreground"><Trophy className="h-6 w-6" /></span>
          <div>
            <h1 className="font-display text-3xl font-extrabold">Leaderboard</h1>
            <p className="text-sm text-ink-soft">นักล่าขยะที่เก่งที่สุดของเดือน</p>
          </div>
        </div>

        {loading ? <p className="text-ink-soft">กำลังโหลด...</p> : rows.length === 0 ? (
          <Card><CardContent className="py-12 text-center text-ink-soft">ยังไม่มีอันดับ</CardContent></Card>
        ) : (
          <div className="space-y-2">
            {rows.map((r, i) => (
              <Card key={r.id} className={i < 3 ? "border-brand-amber/40" : ""}>
                <CardContent className="flex items-center gap-4 p-4">
                  <span className={`grid h-12 w-12 place-items-center rounded-2xl text-xl font-extrabold ${i < 3 ? "bg-brand-amber-soft" : "bg-secondary"}`}>
                    {medalFor(i)}
                  </span>
                  <div className="flex-1">
                    <p className="font-bold">{r.display_name ?? "นักล่าขยะ"}</p>
                    <p className="text-xs text-ink-soft">Lv.{r.level} · {r.total_reports} รายงาน</p>
                  </div>
                  <div className="text-right">
                    <p className="font-display text-2xl font-extrabold text-brand-green">{r.total_points.toLocaleString()}</p>
                    <p className="text-xs text-ink-soft">แต้ม</p>
                  </div>
                </CardContent>
              </Card>
            ))}
          </div>
        )}
      </main>
    </div>
  );
};

export default Leaderboard;
