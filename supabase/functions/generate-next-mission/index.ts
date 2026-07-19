// =============================================================================
// MISSIO — Edge Function: generate-next-mission
// Genera la SIGUIENTE misión de un arco dinámico (arc_dynamic / arc_hybrid).
//
// Entrada (POST JSON):   { user_arc_id: string, trigger_reflection_id?: string }
// Salida (200 JSON):     { mission: <fila insertada en public.missions> }
//
// Flujo:
//   1. Autentica al usuario (JWT de Supabase).
//   2. Arma el CONTEXTO desde la DB: arco + plantilla + variables + últimas
//      reflexiones + expert_inputs + misiones previas del arco.
//   3. Llama a la API de Claude con ese contexto (system prompt + user payload).
//   4. Valida la salida JSON contra el contrato esperado.
//   5. Resuelve las {{variables}} y persiste la nueva misión (status 'available').
//   6. Devuelve la misión creada.
//
// Deploy:  supabase functions deploy generate-next-mission
// Secrets: ANTHROPIC_API_KEY, (SUPABASE_URL y SUPABASE_ANON_KEY vienen del entorno)
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const ANTHROPIC_MODEL = "claude-sonnet-5"; // modelo de generación
const MAX_REFLECTIONS = 5;                 // cuántas reflexiones recientes mandar
const MAX_PAST_MISSIONS = 8;               // cuántas misiones previas del arco mandar

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
};

// -----------------------------------------------------------------------------
// CONTRATO DE SALIDA que le exigimos a Claude. La API debe devolver EXACTAMENTE
// este shape para que la misión sea persistible sin ambigüedad.
// -----------------------------------------------------------------------------
// {
//   "title": string,               // puede traer {{variables}}, las resolvemos acá
//   "description": string,          // idem
//   "log_text": string,
//   "icon": string,                 // nombre de ícono (ej. "trending-up")
//   "skills": { [skill: string]: number },   // XP por skill
//   "tags": string[],
//   "rationale": string,            // por qué esta misión sigue a la reflexión (no se muestra al usuario, se guarda en generated_from)
//   "context_update": object        // parche a fusionar en user_arcs.current_context
// }
// -----------------------------------------------------------------------------

interface GeneratedMission {
  title: string;
  description: string;
  log_text: string;
  icon: string;
  skills: Record<string, number>;
  tags: string[];
  rationale: string;
  context_update: Record<string, unknown>;
}

// Reemplaza {{clave}} por el valor correspondiente del diccionario del usuario.
function resolveVariables(text: string, vars: Record<string, string>): string {
  return text.replace(/\{\{\s*([\w.]+)\s*\}\}/g, (_m, key) =>
    key in vars ? vars[key] : `{{${key}}}`
  );
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    // --- 1. AUTENTICACIÓN --------------------------------------------------
    const authHeader = req.headers.get("Authorization") ?? "";
    // Cliente ligado al JWT del usuario: respeta RLS automáticamente.
    const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: userData, error: userErr } = await supabase.auth.getUser();
    if (userErr || !userData?.user) {
      return json({ error: "No autenticado" }, 401);
    }
    const userId = userData.user.id;

    const { user_arc_id, trigger_reflection_id } = await req.json();
    if (!user_arc_id) return json({ error: "Falta user_arc_id" }, 400);

    // --- 2. ARMAR CONTEXTO DESDE LA DB ------------------------------------
    // (RLS garantiza que solo se lea lo del propio usuario.)

    // 2a. Arco del usuario + plantilla del arco (para el generation_prompt base).
    const { data: arc, error: arcErr } = await supabase
      .from("user_arcs")
      .select("id, arc_template_id, status, current_context, arc_templates(name, description, kind, generation_prompt, meta)")
      .eq("id", user_arc_id)
      .single();
    if (arcErr || !arc) return json({ error: "Arco no encontrado" }, 404);
    if (arc.status !== "active") return json({ error: "El arco no está activo" }, 409);

    // 2b. Diccionario de variables del usuario -> { mascota: "...", cargo: "..." }.
    const { data: varRows } = await supabase
      .from("user_variables")
      .select("key, value")
      .eq("user_id", userId);
    const variables: Record<string, string> = {};
    for (const r of varRows ?? []) variables[r.key] = r.value;

    // 2c. Últimas reflexiones del arco (la señal más importante).
    const { data: reflections } = await supabase
      .from("reflections")
      .select("resultado_tipo, sentimiento, aprendizaje, aplicacion, created_at")
      .eq("user_arc_id", user_arc_id)
      .order("created_at", { ascending: false })
      .limit(MAX_REFLECTIONS);

    // 2d. Expert inputs vinculados al arco (ej. audit de LinkedIn).
    const { data: expertInputs } = await supabase
      .from("expert_inputs")
      .select("source, title, content")
      .eq("user_arc_id", user_arc_id);

    // 2e. Misiones previas del arco, para no repetir y dar continuidad.
    const { data: pastMissions } = await supabase
      .from("missions")
      .select("title, description, status, arc_step, created_at")
      .eq("user_arc_id", user_arc_id)
      .order("created_at", { ascending: false })
      .limit(MAX_PAST_MISSIONS);

    // --- 3. LLAMADA A LA API DE CLAUDE ------------------------------------
    const arcTpl = (arc as any).arc_templates;
    const userPayload = {
      arco: { nombre: arcTpl?.name, descripcion: arcTpl?.description, tipo: arcTpl?.kind },
      current_context: arc.current_context,
      variables_disponibles: Object.keys(variables), // solo nombres; los valores se resuelven local
      reflexiones_recientes: reflections ?? [],
      expert_inputs: expertInputs ?? [],
      misiones_previas: pastMissions ?? [],
    };

    const systemPrompt = buildSystemPrompt(arcTpl?.generation_prompt ?? "");

    const claudeRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: ANTHROPIC_MODEL,
        max_tokens: 1200,
        system: systemPrompt,
        messages: [
          {
            role: "user",
            content:
              "Genera la siguiente misión de este arco. Contexto:\n\n" +
              JSON.stringify(userPayload, null, 2) +
              "\n\nResponde SOLO con el objeto JSON de la misión, sin texto adicional.",
          },
        ],
      }),
    });

    if (!claudeRes.ok) {
      const detail = await claudeRes.text();
      return json({ error: "Fallo al llamar a Claude", detail }, 502);
    }

    const claudeJson = await claudeRes.json();
    const rawText: string = claudeJson?.content?.[0]?.text ?? "";

    // --- 4. VALIDAR LA SALIDA ---------------------------------------------
    const generated = safeParseMission(rawText);
    if (!generated) {
      return json({ error: "Salida de Claude no parseable", rawText }, 422);
    }

    // --- 5. RESOLVER VARIABLES Y PERSISTIR --------------------------------
    const resolvedTitle = resolveVariables(generated.title, variables);
    const resolvedDesc = resolveVariables(generated.description, variables);
    const resolvedLog = resolveVariables(generated.log_text ?? "", variables);

    // Siguiente arc_step = max(previos) + 1.
    const maxStep = Math.max(
      0,
      ...((pastMissions ?? []).map((m: any) => m.arc_step ?? 0)),
    );

    const { data: inserted, error: insErr } = await supabase
      .from("missions")
      .insert({
        user_id: userId,
        template_id: null, // generada 100% dinámicamente
        user_arc_id: user_arc_id,
        kind: arcTpl?.kind ?? "arc_dynamic",
        status: "available",
        title: resolvedTitle,
        description: resolvedDesc,
        log_text: resolvedLog,
        icon: generated.icon ?? null,
        skills: generated.skills ?? {},
        tags: generated.tags ?? [],
        arc_step: maxStep + 1,
        generated_from: {
          rationale: generated.rationale,
          trigger_reflection_id: trigger_reflection_id ?? null,
          model: ANTHROPIC_MODEL,
          generated_at: new Date().toISOString(),
        },
      })
      .select()
      .single();

    if (insErr) return json({ error: "No se pudo guardar la misión", detail: insErr.message }, 500);

    // 5b. Fusionar el parche de contexto en el arco (memoria viva del arco).
    if (generated.context_update && Object.keys(generated.context_update).length) {
      const mergedContext = { ...(arc.current_context as object), ...generated.context_update };
      await supabase.from("user_arcs").update({ current_context: mergedContext }).eq("id", user_arc_id);
    }

    // --- 6. RESPONDER ------------------------------------------------------
    return json({ mission: inserted }, 200);
  } catch (e) {
    return json({ error: "Error inesperado", detail: String(e) }, 500);
  }
});

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "content-type": "application/json" },
  });
}

// Extrae el primer objeto JSON del texto (por si Claude lo envuelve en ```json).
function safeParseMission(text: string): GeneratedMission | null {
  try {
    const match = text.match(/\{[\s\S]*\}/);
    if (!match) return null;
    const obj = JSON.parse(match[0]);
    if (typeof obj.title !== "string" || typeof obj.description !== "string") return null;
    return {
      title: obj.title,
      description: obj.description,
      log_text: obj.log_text ?? "",
      icon: obj.icon ?? "target",
      skills: obj.skills ?? {},
      tags: Array.isArray(obj.tags) ? obj.tags : [],
      rationale: obj.rationale ?? "",
      context_update: obj.context_update ?? {},
    };
  } catch {
    return null;
  }
}

function buildSystemPrompt(arcGenerationPrompt: string): string {
  return `Eres el motor de generación de misiones de Missio, un sistema de desarrollo personal gamificado tipo RPG.

PRINCIPIO RECTOR (gobierna toda decisión):
Missio NO mide tareas completadas — mide identidad en construcción. No es "hiciste X cosas", es "te estás convirtiendo en inversor, en líder, en alguien que se conoce mejor". Evita checklists cerrados. Convertirse en algo es un proceso continuo de profundización que se retroalimenta con la reflexión real del usuario.

TU TAREA:
Recibes el contexto de UN arco dinámico de UN usuario (su descripción, su current_context, sus reflexiones recientes, expert_inputs de terceros, y sus misiones previas). Generas la SIGUIENTE misión: una sola, concreta, accionable, que profundiza en la identidad del arco y responde directamente a lo que el usuario reflexionó por última vez.

REGLAS:
- Una sola misión. Concreta y ejecutable en el mundo real, no abstracta.
- Debe dar continuidad: conecta con la última reflexión (qué aprendió, qué aplicó, cómo se sintió).
- Si la última reflexión fue "descarta", NO fuerces continuar el mismo camino: propone una misión de cierre digno o de pivote. Descartar es un resultado válido, no un fracaso.
- Si la última reflexión fue "pivota", ajusta el rumbo dentro del mismo arco.
- No repitas misiones previas (te paso el historial).
- Usa los expert_inputs cuando existan: son análisis de terceros de mayor calidad que la sola reflexión propia. Deben calibrar la dificultad y el foco.
- Puedes usar variables tipo {{mascota}}, {{cargo}}, {{libro_actual}} en title/description; se resolverán después. Solo usa las variables cuyos nombres aparezcan en variables_disponibles.
- El campo context_update es tu memoria: registra qué conceptos ya domina, qué le falta, en qué nivel va. Se fusiona en current_context para la próxima generación.

CALIBRA la dificultad con el sentimiento y el resultado_tipo de las reflexiones: si viene con buena energía y "avanza", puedes subir la exigencia; si viene con sentimiento bajo, propone algo más ligero que reconstruya impulso.

${arcGenerationPrompt ? `GUÍA ESPECÍFICA DE ESTE ARCO:\n${arcGenerationPrompt}\n` : ""}
FORMATO DE SALIDA (obligatorio, SOLO este objeto JSON, sin texto alrededor):
{
  "title": "string corto y motivador",
  "description": "qué hacer exactamente y por qué importa para la identidad que se construye",
  "log_text": "frase de bitácora que se registra al completar (en primera persona)",
  "icon": "nombre-de-icono-lucide",
  "skills": { "nombre_skill": xp_entero },
  "tags": ["tag1", "tag2"],
  "rationale": "por qué esta misión sigue lógicamente a la última reflexión (interno, no se muestra al usuario)",
  "context_update": { "clave": "valor a fusionar en current_context" }
}`;
}
