import { ReactNode } from "react";
import { Navigate } from "react-router-dom";
import { useAuth } from "@/contexts/AuthContext";

export const RequireAuth = ({ children }: { children: ReactNode }) => {
  const { user, loading } = useAuth();
  if (loading) {
    return (
      <div className="grid min-h-screen place-items-center text-ink-soft">กำลังโหลด...</div>
    );
  }
  if (!user) return <Navigate to="/auth" replace />;
  return <>{children}</>;
};
