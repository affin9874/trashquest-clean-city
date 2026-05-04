
-- =========================
-- ENUMS
-- =========================
CREATE TYPE public.app_role AS ENUM ('admin', 'user');
CREATE TYPE public.report_status AS ENUM ('pending', 'analyzing', 'approved', 'rejected');
CREATE TYPE public.trash_type AS ENUM ('plastic', 'paper', 'glass', 'metal', 'organic', 'hazardous', 'electronic', 'general');

-- =========================
-- PROFILES
-- =========================
CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username TEXT UNIQUE,
  display_name TEXT,
  avatar_url TEXT,
  total_points INTEGER NOT NULL DEFAULT 0,
  total_reports INTEGER NOT NULL DEFAULT 0,
  level INTEGER NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Profiles are viewable by everyone" ON public.profiles
  FOR SELECT USING (true);
CREATE POLICY "Users can insert own profile" ON public.profiles
  FOR INSERT WITH CHECK (auth.uid() = id);
CREATE POLICY "Users can update own profile" ON public.profiles
  FOR UPDATE USING (auth.uid() = id);

-- =========================
-- USER ROLES (separate table for security)
-- =========================
CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  role public.app_role NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, role)
);
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role public.app_role)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = _user_id AND role = _role
  )
$$;

CREATE POLICY "Users can view own roles" ON public.user_roles
  FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Admins can view all roles" ON public.user_roles
  FOR SELECT USING (public.has_role(auth.uid(), 'admin'));

-- =========================
-- TRASH CATEGORIES
-- =========================
CREATE TABLE public.trash_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  type public.trash_type NOT NULL UNIQUE,
  name_th TEXT NOT NULL,
  name_en TEXT NOT NULL,
  points_per_item INTEGER NOT NULL DEFAULT 10,
  description TEXT,
  icon TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.trash_categories ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Categories are viewable by everyone" ON public.trash_categories
  FOR SELECT USING (true);
CREATE POLICY "Admins can manage categories" ON public.trash_categories
  FOR ALL USING (public.has_role(auth.uid(), 'admin'));

INSERT INTO public.trash_categories (type, name_th, name_en, points_per_item, description, icon) VALUES
  ('plastic',    'พลาสติก',     'Plastic',    15, 'ขวด ถุง พลาสติกทั่วไป', '🥤'),
  ('paper',      'กระดาษ',      'Paper',      10, 'กระดาษ กล่อง หนังสือ', '📄'),
  ('glass',      'แก้ว',        'Glass',      20, 'ขวดแก้ว เศษแก้ว',      '🍾'),
  ('metal',      'โลหะ',        'Metal',      25, 'กระป๋อง เหล็ก อลูมิเนียม','🥫'),
  ('organic',    'อินทรีย์',    'Organic',    8,  'เศษอาหาร ใบไม้',        '🍂'),
  ('hazardous',  'อันตราย',     'Hazardous',  40, 'แบตเตอรี่ สารเคมี หลอดไฟ','☢️'),
  ('electronic', 'อิเล็กทรอนิกส์','Electronic',35,'เครื่องใช้ไฟฟ้า สายไฟ', '🔌'),
  ('general',    'ทั่วไป',      'General',    5,  'ขยะทั่วไปที่แยกไม่ได้', '🗑️');

-- =========================
-- REPORTS
-- =========================
CREATE TABLE public.reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  latitude NUMERIC(10, 7) NOT NULL,
  longitude NUMERIC(10, 7) NOT NULL,
  address TEXT,
  note TEXT,
  photo_count INTEGER NOT NULL DEFAULT 0,
  primary_trash_type public.trash_type,
  estimated_items INTEGER NOT NULL DEFAULT 0,
  points_awarded INTEGER NOT NULL DEFAULT 0,
  status public.report_status NOT NULL DEFAULT 'pending',
  ai_summary TEXT,
  ai_rejection_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;

CREATE INDEX idx_reports_user ON public.reports(user_id);
CREATE INDEX idx_reports_status ON public.reports(status);
CREATE INDEX idx_reports_created ON public.reports(created_at DESC);

CREATE POLICY "Approved reports are viewable by everyone" ON public.reports
  FOR SELECT USING (status = 'approved' OR auth.uid() = user_id OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Users can create own reports" ON public.reports
  FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own pending reports" ON public.reports
  FOR UPDATE USING (auth.uid() = user_id AND status IN ('pending','rejected'));
CREATE POLICY "Admins can manage all reports" ON public.reports
  FOR ALL USING (public.has_role(auth.uid(), 'admin'));

-- =========================
-- REPORT PHOTOS
-- =========================
CREATE TABLE public.report_photos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id UUID REFERENCES public.reports(id) ON DELETE CASCADE NOT NULL,
  storage_path TEXT NOT NULL,
  public_url TEXT NOT NULL,
  detected_type public.trash_type,
  ai_confidence NUMERIC(3, 2),
  ai_description TEXT,
  is_valid_trash BOOLEAN,
  display_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.report_photos ENABLE ROW LEVEL SECURITY;

CREATE INDEX idx_report_photos_report ON public.report_photos(report_id);

CREATE POLICY "Photos viewable if report viewable" ON public.report_photos
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.reports r
      WHERE r.id = report_id
      AND (r.status = 'approved' OR r.user_id = auth.uid() OR public.has_role(auth.uid(), 'admin'))
    )
  );
CREATE POLICY "Users insert photos to own reports" ON public.report_photos
  FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM public.reports r WHERE r.id = report_id AND r.user_id = auth.uid())
  );
CREATE POLICY "Admins manage all photos" ON public.report_photos
  FOR ALL USING (public.has_role(auth.uid(), 'admin'));

-- =========================
-- TRIGGERS
-- =========================
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

CREATE TRIGGER trg_profiles_updated BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER trg_reports_updated BEFORE UPDATE ON public.reports
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- Auto-create profile on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (id, display_name, avatar_url, username)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'display_name', NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)),
    NEW.raw_user_meta_data->>'avatar_url',
    'user_' || substr(NEW.id::text, 1, 8)
  );
  INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'user');
  RETURN NEW;
END $$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Update points when report approved
CREATE OR REPLACE FUNCTION public.handle_report_status_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.status = 'approved' AND (OLD.status IS NULL OR OLD.status <> 'approved') THEN
    UPDATE public.profiles
    SET total_points = total_points + NEW.points_awarded,
        total_reports = total_reports + 1,
        level = 1 + ((total_points + NEW.points_awarded) / 500)
    WHERE id = NEW.user_id;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_report_status_change
  AFTER UPDATE OF status ON public.reports
  FOR EACH ROW EXECUTE FUNCTION public.handle_report_status_change();

-- =========================
-- STORAGE
-- =========================
INSERT INTO storage.buckets (id, name, public) VALUES ('trash-photos', 'trash-photos', true);

CREATE POLICY "Trash photos public read" ON storage.objects
  FOR SELECT USING (bucket_id = 'trash-photos');
CREATE POLICY "Authenticated upload trash photos" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'trash-photos' AND auth.uid() IS NOT NULL AND (storage.foldername(name))[1] = auth.uid()::text);
CREATE POLICY "Users delete own trash photos" ON storage.objects
  FOR DELETE USING (bucket_id = 'trash-photos' AND auth.uid()::text = (storage.foldername(name))[1]);
