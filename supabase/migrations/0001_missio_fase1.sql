-- =============================================================================
-- MISSIO — Schema Fase 1
-- Separación plantilla / personalización + arcos dinámicos + reflexión + expert inputs
-- PostgreSQL / Supabase. Todo referenciado a auth.users.
-- Última actualización de diseño: 2026-07-08
-- =============================================================================
-- Principio rector: Missio mide identidad en construcción, no tareas completadas.
-- El schema separa (1) la plantilla genérica reutilizable, (2) las variables
-- personales del usuario, y (3) la instancia congelada renderizada para ese usuario.
-- =============================================================================

-- Extensiones -----------------------------------------------------------------
create extension if not exists "pgcrypto";   -- gen_random_uuid()

-- Tipos enumerados ------------------------------------------------------------
-- Los 5 tipos de misión del documento maestro.
create type mission_kind as enum (
  'one_shot',      -- se hace una vez, cierra sola
  'habit',         -- se repite, trackea racha, escala por niveles
  'arc_fixed',     -- pasos predefinidos en orden conocido
  'arc_dynamic',   -- cada paso siguiente se genera vía API según reflexión
  'arc_hybrid'     -- empieza fijo, luego pasa a dinámico indefinido
);

-- Estado de una instancia de misión ya generada para un usuario.
create type mission_status as enum (
  'available',     -- desbloqueada, aún no iniciada
  'active',        -- en curso
  'completed',     -- terminada
  'skipped'        -- omitida por el usuario
);

-- Resultado de una reflexión post-misión. Descartar NO es fracaso (caso Gestiona+).
create type reflection_result as enum (
  'avanza',        -- profundiza en el camino
  'pivota',        -- cambia de dirección dentro del arco
  'descarta'       -- decisión validada de no continuar (resultado legítimo)
);

-- Estado de un arco activo de un usuario.
create type arc_status as enum (
  'active',
  'paused',
  'completed',
  'discarded'      -- cerrado con evidencia real (ver Gestiona+)
);

-- Tipo de prerrequisito entre plantillas.
create type dependency_kind as enum (
  'mission_completed',   -- requiere una plantilla específica completada
  'skill_xp_min'         -- requiere XP mínimo en una skill
);


-- =============================================================================
-- 1. PLANTILLAS (contenido genérico, reutilizable entre usuarios)
-- =============================================================================

-- Un arco es un contenedor temático de plantillas (ej. "Camino del inversor").
create table public.arc_templates (
  id            uuid primary key default gen_random_uuid(),
  slug          text unique not null,            -- 'camino_inversor', 'marca_personal'
  name          text not null,
  description   text,
  kind          mission_kind not null,           -- arc_fixed | arc_dynamic | arc_hybrid
  -- Prompt base que guía la generación dinámica de este arco (para arc_dynamic/hybrid).
  generation_prompt text,
  -- Metadata de diseño: objetivo de identidad, skills primarias, etc.
  meta          jsonb not null default '{}'::jsonb,
  active         boolean not null default true,
  created_at     timestamptz not null default now()
);

-- Plantilla de misión individual. El texto usa variables {{mascota}}, {{cargo}}.
create table public.mission_templates (
  id            uuid primary key default gen_random_uuid(),
  arc_template_id uuid references public.arc_templates(id) on delete set null,
  slug          text unique not null,
  kind          mission_kind not null,
  -- step_order: posición en un arco fijo/híbrido; null en misiones dinámicas puras
  -- y en one_shot/habit sueltos.
  step_order    int,
  title         text not null,                   -- puede contener {{variables}}
  description   text not null,                   -- puede contener {{variables}}
  log_text      text,                            -- texto de bitácora al completar
  icon          text,
  -- skills y su XP: { "inversion": 20, "disciplina": 10 }
  skills        jsonb not null default '{}'::jsonb,
  tags          text[] not null default '{}',
  -- Para habits: config de racha/escalado por niveles.
  -- { "frequency": "2x_week", "levels": ["caminar_2x","caminar_5x","trotar"] }
  habit_config  jsonb,
  active         boolean not null default true,
  created_at     timestamptz not null default now()
);

create index on public.mission_templates (arc_template_id, step_order);

-- Prerrequisitos entre plantillas.
create table public.template_dependencies (
  id            uuid primary key default gen_random_uuid(),
  template_id   uuid not null references public.mission_templates(id) on delete cascade,
  kind          dependency_kind not null,
  -- Si kind = mission_completed: plantilla requerida.
  requires_template_id uuid references public.mission_templates(id) on delete cascade,
  -- Si kind = skill_xp_min: skill y umbral.
  requires_skill text,
  requires_xp    int,
  created_at     timestamptz not null default now(),
  constraint dep_shape check (
    (kind = 'mission_completed' and requires_template_id is not null)
    or
    (kind = 'skill_xp_min' and requires_skill is not null and requires_xp is not null)
  )
);

create index on public.template_dependencies (template_id);


-- =============================================================================
-- 2. PERSONALIZACIÓN (por usuario)
-- =============================================================================

-- Diccionario personal: se llena en el onboarding ("evaluar tu vida").
-- Cada fila es una variable {{clave}} -> valor.
create table public.user_variables (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  key           text not null,                   -- 'mascota', 'cargo', 'libro_actual'
  value         text not null,
  updated_at     timestamptz not null default now(),
  unique (user_id, key)
);

create index on public.user_variables (user_id);

-- Arco activo de un usuario. current_context es JSON libre y vivo:
-- qué material consume, nivel de hábito, conceptos que domina / le faltan.
create table public.user_arcs (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  arc_template_id uuid not null references public.arc_templates(id) on delete restrict,
  status         arc_status not null default 'active',
  current_context jsonb not null default '{}'::jsonb,
  -- Arco de descubrimiento puede generar arcos nuevos; se guarda el origen.
  spawned_from_arc_id uuid references public.user_arcs(id) on delete set null,
  started_at     timestamptz not null default now(),
  closed_at      timestamptz,
  unique (user_id, arc_template_id)
);

create index on public.user_arcs (user_id, status);

-- Instancia de misión ya generada y CONGELADA para un usuario.
-- El texto ya tiene las variables resueltas; no se recalcula si cambian luego.
create table public.missions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  -- template_id null cuando la misión fue generada 100% dinámicamente por la API.
  template_id   uuid references public.mission_templates(id) on delete set null,
  user_arc_id   uuid references public.user_arcs(id) on delete cascade,
  kind          mission_kind not null,
  status         mission_status not null default 'available',
  -- Texto ya resuelto (sin {{variables}}).
  title         text not null,
  description   text not null,
  log_text      text,
  icon          text,
  skills        jsonb not null default '{}'::jsonb,
  tags          text[] not null default '{}',
  -- Orden dentro del arco del usuario (para arcos fijos/híbridos).
  arc_step      int,
  -- Para habits: racha y nivel actual.
  streak_count  int not null default 0,
  habit_level   int not null default 0,
  -- Trazabilidad: qué generó esta misión (reflexión previa, expert_input, etc.).
  generated_from jsonb not null default '{}'::jsonb,
  created_at     timestamptz not null default now(),
  completed_at   timestamptz
);

create index on public.missions (user_id, status);
create index on public.missions (user_arc_id, arc_step);


-- =============================================================================
-- 3. REFLEXIÓN Y FEEDBACK
-- =============================================================================

-- Respuesta del usuario al completar una misión. Alimenta la generación dinámica.
create table public.reflections (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  mission_id    uuid not null references public.missions(id) on delete cascade,
  user_arc_id   uuid references public.user_arcs(id) on delete set null,
  resultado_tipo reflection_result not null,     -- avanza | pivota | descarta
  sentimiento    smallint check (sentimiento between 1 and 5),
  aprendizaje    text,                            -- qué aprendió
  aplicacion     text,                            -- cómo lo aplica a su vida
  -- Respuestas crudas del formulario (para poder evolucionar preguntas sin migrar).
  raw_answers    jsonb not null default '{}'::jsonb,
  created_at     timestamptz not null default now()
);

create index on public.reflections (user_id, created_at);
create index on public.reflections (mission_id);

-- Análisis de terceros (agencias, coaches) vinculado a un arco.
-- Ej: auditoría de LinkedIn de la agencia de marketing -> arco Marca personal.
create table public.expert_inputs (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  user_arc_id   uuid references public.user_arcs(id) on delete cascade,
  -- Arco al que aplica a nivel de plantilla (para promover patrones generalizables).
  arc_template_id uuid references public.arc_templates(id) on delete set null,
  source         text not null,                  -- 'agencia_marketing', 'coach_raquel'
  title          text,
  -- Contenido estructurado del análisis (el JSON del audit de LinkedIn va aquí).
  content        jsonb not null default '{}'::jsonb,
  created_at     timestamptz not null default now()
);

create index on public.expert_inputs (user_arc_id);


-- =============================================================================
-- 4. CAPA DE APRENDIZAJE COLECTIVO (fases posteriores; tabla lista desde ya)
-- =============================================================================

-- Agregado anonimizado por plantilla. Requiere consentimiento del usuario.
create table public.template_outcomes (
  id            uuid primary key default gen_random_uuid(),
  template_id   uuid references public.mission_templates(id) on delete cascade,
  arc_template_id uuid references public.arc_templates(id) on delete cascade,
  completion_rate    numeric(5,2),               -- 0.00 - 100.00
  avg_sentimiento    numeric(3,2),
  count_avanza       int not null default 0,
  count_pivota       int not null default 0,
  count_descarta     int not null default 0,
  sample_size        int not null default 0,
  updated_at         timestamptz not null default now(),
  constraint outcome_target check (template_id is not null or arc_template_id is not null)
);

-- Consentimiento explícito para usar datos anonimizados (onboarding).
alter table public.usuarios
  add column if not exists collective_learning_consent boolean not null default false;


-- =============================================================================
-- 5. ROW LEVEL SECURITY
-- =============================================================================
-- Plantillas: lectura pública (catálogo compartido), escritura solo service_role.
-- Datos de usuario: cada quien solo ve/edita lo suyo.

-- Plantillas (solo lectura para usuarios autenticados) ------------------------
alter table public.arc_templates        enable row level security;
alter table public.mission_templates     enable row level security;
alter table public.template_dependencies enable row level security;
alter table public.template_outcomes     enable row level security;

create policy "arc_templates_read"  on public.arc_templates
  for select to authenticated using (true);
create policy "mission_templates_read" on public.mission_templates
  for select to authenticated using (true);
create policy "template_dependencies_read" on public.template_dependencies
  for select to authenticated using (true);
create policy "template_outcomes_read" on public.template_outcomes
  for select to authenticated using (true);
-- Escritura de plantillas: solo service_role (sin policy = denegado a authenticated).

-- Datos de usuario (dueño = auth.uid()) ---------------------------------------
alter table public.user_variables enable row level security;
alter table public.user_arcs      enable row level security;
alter table public.missions       enable row level security;
alter table public.reflections    enable row level security;
alter table public.expert_inputs  enable row level security;

-- Helper: una policy por tabla que cubre todas las operaciones.
create policy "own_user_variables" on public.user_variables
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own_user_arcs" on public.user_arcs
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own_missions" on public.missions
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own_reflections" on public.reflections
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own_expert_inputs" on public.expert_inputs
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());


-- =============================================================================
-- 6. NOTAS DE MIGRACIÓN (desde el modelo actual hardcodeado)
-- =============================================================================
-- El estado actual tiene: misiones (contenido hardcodeado a Koji), estado_rpg, usuarios.
--
-- Plan de migración sugerido (ejecutar como script aparte, revisado a mano):
--
--  a) De cada fila de `misiones`, extraer el texto y detectar las constantes
--     personalizadas (nombre de mascota, colegas, cargo). Reemplazarlas por
--     {{variables}} para poblar `mission_templates`, y crear las filas
--     correspondientes en `user_variables` para Koji.
--
--  b) Agrupar las plantillas bajo los 10 arcos definidos creando filas en
--     `arc_templates`. Nota: "Gestiona+ como estudio legal" se importa con
--     el user_arc en status 'discarded' (cerrado con evidencia, no fracaso).
--     La misión sin clasificar id=10 ("Un contacto que vale") queda active=false
--     hasta reinterpretar o descartar.
--
--  c) `estado_rpg` (XP, nivel, skills, log) permanece como está; se puede
--     recomputar XP desde reflections/missions una vez migrado, o mantener el
--     valor histórico como snapshot inicial.
--
--  d) Renombrado de identidad de negocio: el contenido personalizado a Koji
--     (cargo) debe reflejar el rol vigente al momento de generar cada instancia,
--     pero las instancias ya congeladas NO se recalculan (por diseño).
-- =============================================================================
