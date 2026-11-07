/* ============================================================================
   REPORTE ESTÁNDAR DE MENCIONES  ·  VERSIÓN OPTIMIZADA  ·  v4.0
   ----------------------------------------------------------------------------

   Autor:   Juan Pablo Velandia Molina
   Versión: 4.0  (optimización de rendimiento sobre la v3.2)
   Fecha:   Agosto 2026

   Objetos:
     0) public.fn_normaliza_tipo_nodo(text)        -- helper de normalización (NUEVO)
     1) public.fn_categoria_nodo(text)             -- clasificador (única fuente de verdad)
     2) public.fn_reporte_menciones_estandar(text) -- reporte (drop-in, misma firma y salida)
     3) public.fn_diagnostico_tipos_nodo(text)     -- diagnóstico alineado al reporte
     4) public.fn_preparar_indices_reporte(text)   -- índices + ANALYZE por proyecto (NUEVO)

   ----------------------------------------------------------------------------
   CONTRATO: la salida es IDÉNTICA a la v3.2
   ----------------------------------------------------------------------------
   Mismas 34 columnas, mismos tipos, mismas filas y mismos valores, incluyendo
   los casos borde (menciones sin nodos, nombre NULL o vacío, tier NULL/'T5',
   fechaEmision NULL, provincia ausente, tipo de nodo NULL).
   ÚNICA salvedad: el ORDEN de las filas. Ni la v3.2 ni la v4.0 declaran
   ORDER BY, así que el orden nunca estuvo garantizado; al cambiar el plan,
   cambia. Si algún consumidor dependía del orden accidental, hay que añadir
   un ORDER BY explícito (ver nota al final del bloque 2).

   ----------------------------------------------------------------------------
   QUÉ SE OPTIMIZÓ Y POR QUÉ  (los 6 cambios que mueven la aguja)
   ----------------------------------------------------------------------------

   [1] El clasificador ahora SÍ se puede inlinear.
       PostgreSQL sólo inlinea una función SQL si su cuerpo es un SELECT sin
       FROM (sin rtable ni jointree->fromlist). La v3.2 usaba
       `... FROM (SELECT TRANSLATE(...) AS t) x`, lo que la volvía NO
       inlineable: cada evaluación pagaba el costo de invocar el ejecutor de
       funciones SQL. Y como en la v3.2 se llamaba DESPUÉS del join
       mencion_nodo <-> nodo, se pagaba UNA VEZ POR CADA FILA DE
       mencion_nodo_pXXX (millones).
       v4.0: cuerpo sin FROM (la normalización se delegó a un helper que
       también es inlineable) => el planner sustituye el CASE directamente en
       la query, costo de invocación cero.

   [2] El clasificador se evalúa por fila de nodo_pXXX, no por fila del join.
       nodo_pXXX es el catálogo (miles / decenas de miles de filas);
       mencion_nodo_pXXX es la tabla de enlace (millones). Clasificar del lado
       pequeño reduce el número de evaluaciones en 2-3 órdenes de magnitud.
       El CTE NODO_CLS va marcado AS MATERIALIZED justamente para impedir que
       el planner lo suba (pull-up) al nivel del join y vuelva a evaluar por
       fila de enlace.

   [3] Una sola pasada de agregación en lugar de tres.
       La v3.2 materializaba NODOS y lo leía 3 veces (TONO_DATA con función de
       ventana, AGREGADOS y OTROS_RAW), cada una con su propio ordenamiento del
       dataset completo. La v4.0 hace UN solo GROUP BY sobre el join
       (CTE N1) y luego un pivot barato sobre un conjunto ya diminuto (CTE AGG,
       ~1 fila por categoría por mención).
       De 3 sorts completos + 1 tuplestore grande => 1 sort completo, 0
       tuplestores intermedios (N1 y AGG se referencian una sola vez, así que
       el planner los fusiona en el mismo plan sin materializar).

   [4] El tono ya no usa función de ventana.
       ROW_NUMBER() OVER (PARTITION BY id_mencion ORDER BY nodo_id DESC)
       obligaba a ordenar TODO el conjunto de nodos de tono. Se reemplazó por
       (ARRAY_AGG(nombre ORDER BY nodo_id DESC) FILTER (WHERE cat = 1))[1],
       que es el mismo "argmax" pero resuelto dentro del GROUP BY que ya
       estábamos haciendo, y que sólo ordena las filas de tono de cada
       mención (típicamente 1). Semántica idéntica, incluido el desempate.

   [5] Clave de agrupación numérica en vez de texto.
       El sort grande compara (id_mencion, categoria, tipo). Comparar la
       categoría como texto implica comparación con collation (strcoll), cara.
       Se mapea la categoría a un smallint (cat 1..9) UNA sola vez, en el lado
       pequeño (nodo). El mapeo NO es un segundo clasificador: es una
       traducción mecánica del resultado de fn_categoria_nodo(), que sigue
       siendo la única fuente de verdad.

   [6] El JSONB se recorre una vez por fila, no 24.
       La v3.2 hacía 24 `data->>'campo'`: 24 llamadas y 24 búsquedas dentro del
       objeto JSONB por mención. La v4.0 usa jsonb_to_record(), que recorre el
       objeto UNA vez y llena todas las columnas de golpe. Equivalencia exacta:
       para columnas declaradas `text`, jsonb_to_record devuelve lo mismo que
       `->>` (string desescapado, número/booleano en su texto JSON, NULL si la
       clave falta o vale null).
       Además el CTE `A` de la v3.2 se referenciaba dos veces => PostgreSQL lo
       materializaba, escribiendo `titulo` y `resumen` completos a un
       tuplestore (con spill a disco casi asegurado) para releerlos. En la v4.0
       la mención se lee una sola vez y el payload ancho nunca se materializa;
       el semijoin usa un CTE de sólo ids (8 bytes por fila).

   Extras: work_mem propio de la función (evita spill a disco en el sort y en
   el hash join), y un instalador de índices por proyecto (bloque 4).

   ----------------------------------------------------------------------------
   CÓMO MEDIR
   ----------------------------------------------------------------------------
       EXPLAIN (ANALYZE, BUFFERS, TIMING)
       SELECT * FROM public.fn_reporte_menciones_estandar('101');

   Señales de que quedó bien: un único nodo Sort/GroupAggregate sobre el join,
   sin "Sort Method: external merge Disk", y sin CTE Scan sobre un tuplestore
   ancho. Si aparece "external merge", subir work_mem (ver bloque 2).

   ----------------------------------------------------------------------------
   ORDEN DE DESPLIEGUE
   ----------------------------------------------------------------------------
   Ejecutar este archivo completo, de arriba a abajo, en una sola transacción.
   Luego, por cada proyecto:  SELECT public.fn_preparar_indices_reporte('101');

============================================================================ */


/* ============================================================================
   0) HELPER DE NORMALIZACIÓN
   ----------------------------------------------------------------------------
   Mayúsculas + sin tildes + sin espacios en los extremos.
   Existe por dos razones:
     a) permite que fn_categoria_nodo NO tenga cláusula FROM y por tanto sea
        inlineable (ver nota [1] de la cabecera);
     b) mantiene la normalización en UN solo sitio, igual que antes.
   Es a su vez inlineable (SELECT de una sola expresión, sin FROM), así que al
   inlinear fn_categoria_nodo estas llamadas también desaparecen.

   NO marcar STRICT: con p_txt NULL debe seguir propagando NULL hacia el CASE
   para que fn_categoria_nodo caiga en el ELSE ('OTROS_CAMPOS'), tal como la
   v3.2.
   ============================================================================ */
CREATE OR REPLACE FUNCTION public.fn_normaliza_tipo_nodo(p_txt TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT TRANSLATE(UPPER(BTRIM(p_txt)), 'ÁÉÍÓÚ', 'AEIOU')
$$;

ALTER FUNCTION public.fn_normaliza_tipo_nodo(text) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.fn_normaliza_tipo_nodo(text) TO rol_lectura;


/* ============================================================================
   1) CLASIFICADOR DE TIPOS DE NODO  (única fuente de verdad)
   ----------------------------------------------------------------------------
   Recibe el `tipo` crudo de nodo_pXXX y devuelve la categoría estándar.
   Mismas reglas y MISMO ORDEN de evaluación que la v3.2.

   Cambios respecto a la v3.2 (ninguno afecta el resultado):
     · Sin cláusula FROM  -> la función es inlineable por el planner.
     · ILIKE -> LIKE: el operando ya viene en mayúsculas y sin tildes, así que
       ILIKE estaba pagando un plegado de mayúsculas/minúsculas redundante en
       cada comparación. LIKE da exactamente el mismo resultado y es más rápido.
     · 'Región' sigue comparándose por IGUALDAD EXACTA (no 'REGION%'), para no
       capturar 'Región Origen' ni similares. El clasificador sólo ve nodo.tipo,
       nunca el JSONB, así que no interfiere con data->>'region'.

   Para promover un nuevo tipo a columna propia se sigue agregando UNA sola
   línea aquí (y su columna en el reporte + su código en el mapa `cat`).
   ============================================================================ */
CREATE OR REPLACE FUNCTION public.fn_categoria_nodo(p_tipo TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN public.fn_normaliza_tipo_nodo(p_tipo) LIKE 'TONO%'
          OR public.fn_normaliza_tipo_nodo(p_tipo) LIKE 'TONAL%'        THEN 'TONO'
        WHEN public.fn_normaliza_tipo_nodo(p_tipo) LIKE 'TEMA%'         THEN 'TEMAS'
        WHEN public.fn_normaliza_tipo_nodo(p_tipo) LIKE 'VOCER%'        THEN 'VOCEROS'
        -- PERSONAJE es su propia columna (antes se agrupaba en VOCEROS).
        WHEN public.fn_normaliza_tipo_nodo(p_tipo) LIKE 'PERSONAJE%'    THEN 'PERSONAJE'
        WHEN public.fn_normaliza_tipo_nodo(p_tipo) LIKE 'GESTION%'      THEN 'GESTIONADO'
        WHEN public.fn_normaliza_tipo_nodo(p_tipo) LIKE 'COMUNICAD%'    THEN 'COMUNICADO'
        WHEN public.fn_normaliza_tipo_nodo(p_tipo) LIKE 'ENTIDADES%'    THEN 'ENTIDADES_ADSCRITAS'
        -- 'Región' es como otros proyectos llaman a Cubrimiento.
        WHEN public.fn_normaliza_tipo_nodo(p_tipo) LIKE 'CUBRIMIENTO%'
          OR public.fn_normaliza_tipo_nodo(p_tipo) =    'REGION'        THEN 'CUBRIMIENTO'
        ELSE 'OTROS_CAMPOS'
    END
$$;

ALTER FUNCTION public.fn_categoria_nodo(text) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.fn_categoria_nodo(text) TO rol_lectura;


/* ============================================================================
   2) REPORTE ESTÁNDAR
   ----------------------------------------------------------------------------
   NOTA 1: el DROP es obligatorio (no basta CREATE OR REPLACE) si en el entorno
           la firma de retorno difiere. Se mantiene por seguridad.
   NOTA 2: guard defensivo: si existe una vista dependiente de la función
           (p. ej. una vista creada sobre la v3), bloquearía el DROP FUNCTION. Se
           elimina primero; si no existe, no hace nada. Este script NO crea
           vistas.
   ============================================================================ */
DROP VIEW IF EXISTS public.vw_menciones_proyecto;   -- guard de dependencia (no-op si no existe)

DROP FUNCTION IF EXISTS public.fn_reporte_menciones_estandar(text);

CREATE OR REPLACE FUNCTION public.fn_reporte_menciones_estandar(p_sufijo TEXT)
RETURNS TABLE (
    id_proyecto                  INTEGER,   -- primera columna
    "codigoReferenciaMultimedia" TEXT,
    "nombreTipoFuente"           TEXT,
    "nombreMedio"                TEXT,
    "nombreProgramaSeccion"      TEXT,
    "seccionEspecifica"          TEXT,
    region                       TEXT,      -- JSONB data->>'region' (NO confundir
                                            -- con el nodo 'Región' -> "CUBRIMIENTO")
    pais                         TEXT,
    provincia                    TEXT,
    titulo                       TEXT,
    resumen                      TEXT,
    "urlLanding"                 TEXT,
    "fechaEmision"               TEXT,
    valorizacion                 TEXT,
    cm2                          TEXT,
    duracion                     TEXT,
    "nivelLectura"               TEXT,
    "esHorarioEstelar"           INTEGER,
    "porcentajeAparicion"        TEXT,
    "cantidadCaracteres"         TEXT,
    tier                         TEXT,
    audiencia                    TEXT,
    lecturabilidad               TEXT,
    circulacion                  TEXT,
    "nombreCategoria"            TEXT,
    "TONO"                       TEXT,
    "TEMAS"                      TEXT,
    "VOCEROS"                    TEXT,
    "PERSONAJE"                  TEXT,
    "GESTIONADO"                 TEXT,
    "COMUNICADO"                 TEXT,
    "ENTIDADES_ADSCRITAS"        TEXT,
    "CUBRIMIENTO"                TEXT,      -- nodos 'Cubrimiento' y 'Región'
    "OTROS_CAMPOS"               JSONB
) AS $$
DECLARE
    v_query TEXT;
BEGIN
    -- Guard de seguridad: el sufijo del proyecto debe ser numérico (ej. '101').
    IF p_sufijo !~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'Sufijo de proyecto inválido: %. Debe ser numérico.', p_sufijo;
    END IF;

    v_query := format($q$
        WITH
        -- ====================================================================
        -- MENC_OK: SOLO los ids de menciones evaluadas.
        --   Sirve para el semijoin contra la tabla de enlace. Se deja sin
        --   MATERIALIZED a propósito: al referenciarse una única vez el
        --   planner lo inlinea y puede resolverlo con un Index Only Scan sobre
        --   el índice parcial (ver bloque 4), leyendo 8 bytes por fila en vez
        --   de tocar el heap con el JSONB completo.
        --   En la v3.2 este papel lo hacía el CTE `A`, que arrastraba titulo y
        --   resumen a un tuplestore.
        -- ====================================================================
        MENC_OK AS (
            SELECT id
            FROM %1$I
            WHERE estado = 'evaluado'::estado_mencion
        ),

        -- ====================================================================
        -- NODO_CLS: catálogo de nodos ya clasificado. Del lado PEQUEÑO.
        --   AS MATERIALIZED es obligatorio aquí: sin él, el planner sube estas
        --   expresiones al nivel del join y volvería a clasificar una vez por
        --   fila de la tabla de enlace (el problema de la v3.2).
        --
        --   El OFFSET 0 de la subconsulta interna es una barrera de pull-up:
        --   garantiza que fn_categoria_nodo() se evalúe UNA sola vez por nodo,
        --   y no una vez por cada CASE que consume su resultado.
        --
        --   Mapa de códigos `cat` (traducción mecánica de fn_categoria_nodo;
        --   la lógica de clasificación sigue viviendo sólo en esa función):
        --     1 TONO   2 TEMAS   3 VOCEROS   4 PERSONAJE   5 GESTIONADO
        --     6 COMUNICADO   7 ENTIDADES_ADSCRITAS   8 CUBRIMIENTO
        --     9 OTROS_CAMPOS
        --
        --   tipo_key: sólo tiene valor para cat = 9, porque es la clave del
        --   JSONB de OTROS_CAMPOS. Para el resto va NULL, de modo que todos
        --   los nodos de una misma categoría caigan en UN solo grupo aunque
        --   provengan de tipos distintos (p. ej. 'Tema' y 'Temas' -> TEMAS).
        --   Eso reproduce exactamente el DISTINCT por categoría de la v3.2.
        -- ====================================================================
        NODO_CLS AS MATERIALIZED (
            SELECT
                z.nodo_id,
                z.nombre,
                CASE WHEN z.categoria = 'OTROS_CAMPOS' THEN z.tipo_trim END AS tipo_key,
                (CASE z.categoria
                     WHEN 'TONO'                THEN 1
                     WHEN 'TEMAS'               THEN 2
                     WHEN 'VOCEROS'             THEN 3
                     WHEN 'PERSONAJE'           THEN 4
                     WHEN 'GESTIONADO'          THEN 5
                     WHEN 'COMUNICADO'          THEN 6
                     WHEN 'ENTIDADES_ADSCRITAS' THEN 7
                     WHEN 'CUBRIMIENTO'         THEN 8
                     ELSE                            9
                 END)::smallint                                            AS cat
            FROM (
                SELECT
                    nd.id                              AS nodo_id,
                    nd.nombre                          AS nombre,
                    TRIM(nd.tipo)                      AS tipo_trim,
                    public.fn_categoria_nodo(nd.tipo)  AS categoria
                FROM %3$I nd
                OFFSET 0                                -- barrera de pull-up
            ) z
        ),

        -- ====================================================================
        -- PARES: ÚNICO join mencion_nodo <-> nodo, restringido a menciones
        --   evaluadas. Sin MATERIALIZED: se consume una sola vez, así que el
        --   planner lo funde con la agregación de abajo y no escribe ningún
        --   tuplestore intermedio.
        --   nodo_id se toma de mn.id_nodo (mismo valor que nc.nodo_id) para no
        --   arrastrar una columna extra desde la tabla hash.
        -- ====================================================================
        PARES AS (
            SELECT
                mn.id_mencion,
                nc.cat,
                nc.tipo_key,
                nc.nombre,
                mn.id_nodo AS nodo_id
            FROM %2$I mn
            JOIN NODO_CLS nc ON nc.nodo_id = mn.id_nodo
            JOIN MENC_OK  mo ON mo.id      = mn.id_mencion
        ),

        -- ====================================================================
        -- N1: LA ÚNICA agregación pesada del reporte (antes eran tres).
        --   Un grupo por (mención, categoría) y, dentro de OTROS_CAMPOS, uno
        --   por tipo de nodo.
        --
        --   valor: multi-valor deduplicado y ordenado. Idéntico al
        --          STRING_AGG(DISTINCT nombre, ', ' ORDER BY nombre) de la
        --          v3.2, pero calculado una sola vez para las 8 columnas en
        --          lugar de 8 agregados DISTINCT independientes.
        --          El FILTER (cat <> 1) evita gastar el sort interno en los
        --          grupos de tono, que no lo usan.
        --
        --   tono_nombre: sustituye a la función de ventana. Toma el nombre del
        --          nodo de tono con mayor id (mismo criterio de desempate que
        --          ROW_NUMBER() ... ORDER BY nodo_id DESC). Si no hay nodos de
        --          tono devuelve NULL, y si el nombre es NULL devuelve NULL:
        --          ambos casos terminan en 'Sin Tono' abajo, igual que antes.
        -- ====================================================================
        N1 AS (
            SELECT
                id_mencion,
                cat,
                tipo_key,
                STRING_AGG(DISTINCT nombre, ', ' ORDER BY nombre)
                    FILTER (WHERE cat <> 1)                    AS valor,
                (ARRAY_AGG(nombre ORDER BY nodo_id DESC)
                    FILTER (WHERE cat = 1))[1]                 AS tono_nombre
            FROM PARES
            GROUP BY id_mencion, cat, tipo_key
        ),

        -- ====================================================================
        -- AGG: pivot. Opera sobre un conjunto ya diminuto (una decena de filas
        --   por mención), y su entrada llega ordenada por id_mencion desde N1,
        --   así que este GROUP BY normalmente no necesita ordenar nada.
        --   MAX() aquí no compara nada real: por construcción hay a lo sumo un
        --   grupo por (mención, cat) para cat 1..8, así que MAX simplemente
        --   recoge ese único valor.
        -- ====================================================================
        AGG AS (
            SELECT
                id_mencion,
                MAX(tono_nombre) FILTER (WHERE cat = 1) AS tono,
                MAX(valor)       FILTER (WHERE cat = 2) AS temas,
                MAX(valor)       FILTER (WHERE cat = 3) AS voceros,
                MAX(valor)       FILTER (WHERE cat = 4) AS personaje,
                MAX(valor)       FILTER (WHERE cat = 5) AS gestionado,
                MAX(valor)       FILTER (WHERE cat = 6) AS comunicado,
                MAX(valor)       FILTER (WHERE cat = 7) AS entidades,
                MAX(valor)       FILTER (WHERE cat = 8) AS cubrimiento,
                JSONB_OBJECT_AGG(tipo_key, valor)
                                 FILTER (WHERE cat = 9) AS otros
            FROM N1
            GROUP BY id_mencion
        )

        -- ====================================================================
        -- Consolidación final.
        --   · Se parte de la tabla de menciones (no de un CTE materializado):
        --     el JSONB se lee del heap una sola vez y nunca se copia a un
        --     tuplestore.
        --   · jsonb_to_record recorre el objeto UNA vez y devuelve las 24
        --     columnas; sustituye a los 24 `data->>` de la v3.2.
        --   · El CASE sobre jsonb_typeof cubre data NULL o data que no sea un
        --     objeto JSON: en esos casos jsonb_to_record recibe '{}' y todas
        --     las columnas salen NULL, que es justo lo que devolvía `->>`.
        --   · LEFT JOIN contra AGG para no perder menciones sin nodos.
        -- ====================================================================
        SELECT
            m.id_proyecto::int                                    AS id_proyecto,
            d."codigoReferenciaMultimedia",
            d."nombreTipoFuente",
            d."nombreMedio",
            d."nombreProgramaSeccion",
            d."seccionEspecifica",
            d.region,
            d.pais,
            COALESCE(d.provincia, '')                             AS provincia,
            d.titulo,
            d.resumen,
            d."urlLanding",
            TO_CHAR(d."fechaEmision"::timestamp,
                    'DD/MM/YYYY HH24:MI')                         AS "fechaEmision",
            d.valorizacion,
            d.cm2,
            d.duracion,
            d."nivelLectura",
            CASE WHEN d."esHorarioEstelar" = 'false' THEN 0
                 ELSE 1
            END                                                   AS "esHorarioEstelar",
            d."porcentajeAparicion",
            d."cantidadCaracteres",
            CASE WHEN d.tier IS NULL OR d.tier = 'T5' THEN 'T4'
                 ELSE d.tier
            END                                                   AS tier,
            d.audiencia,
            d.lecturabilidad,
            d.circulacion,
            d."nombreCategoria",
            COALESCE(NULLIF(g.tono, ''), 'Sin Tono')              AS "TONO",
            COALESCE(g.temas,       '')                           AS "TEMAS",
            COALESCE(g.voceros,     '')                           AS "VOCEROS",
            COALESCE(g.personaje,   '')                           AS "PERSONAJE",
            COALESCE(g.gestionado,  '')                           AS "GESTIONADO",
            COALESCE(g.comunicado,  '')                           AS "COMUNICADO",
            COALESCE(g.entidades,   '')                           AS "ENTIDADES_ADSCRITAS",
            COALESCE(g.cubrimiento, '')                           AS "CUBRIMIENTO",
            COALESCE(g.otros, '{}'::jsonb)                        AS "OTROS_CAMPOS"
        FROM %1$I m
        CROSS JOIN LATERAL jsonb_to_record(
            CASE WHEN jsonb_typeof(m.data) = 'object'
                 THEN m.data
                 ELSE '{}'::jsonb
            END
        ) AS d(
            "codigoReferenciaMultimedia" text,
            "nombreTipoFuente"           text,
            "nombreMedio"                text,
            "nombreProgramaSeccion"      text,
            "seccionEspecifica"          text,
            region                       text,
            pais                         text,
            provincia                    text,
            titulo                       text,
            resumen                      text,
            "urlLanding"                 text,
            "fechaEmision"               text,
            valorizacion                 text,
            cm2                          text,
            duracion                     text,
            "nivelLectura"               text,
            "esHorarioEstelar"           text,
            "porcentajeAparicion"        text,
            "cantidadCaracteres"         text,
            tier                         text,
            audiencia                    text,
            lecturabilidad               text,
            circulacion                  text,
            "nombreCategoria"            text
        )
        LEFT JOIN AGG g ON g.id_mencion = m.id
        WHERE m.estado = 'evaluado'::estado_mencion
    $q$,
        'mencion_p'      || p_sufijo,   -- %1$I
        'mencion_nodo_p' || p_sufijo,   -- %2$I
        'nodo_p'         || p_sufijo    -- %3$I
    );

    RETURN QUERY EXECUTE v_query;
END;
$$ LANGUAGE plpgsql;

/* ----------------------------------------------------------------------------
   work_mem propio de la función.
   El sort del bloque N1 y el hash join contra los ids de menciones son los dos
   consumidores de memoria del plan. Con el work_mem por defecto (4MB) ambos
   se derraman a disco y ahí se va la mayor parte del tiempo de pared.
   256MB es un punto de partida razonable para un reporte que se ejecuta pocas
   veces al día. BÁJALO si el servidor tiene poca RAM o si hay muchas
   ejecuciones concurrentes; cada worker paralelo puede reclamar su propia
   porción.
   Para quitarlo:  ALTER FUNCTION public.fn_reporte_menciones_estandar(text)
                       RESET work_mem;
   ---------------------------------------------------------------------------- */
ALTER FUNCTION public.fn_reporte_menciones_estandar(text) SET work_mem = '256MB';

/* ----------------------------------------------------------------------------
   OPCIONAL — paralelismo.
   El agregado final no se puede paralelizar (los agregados con DISTINCT/ORDER
   BY no tienen agregación parcial), pero el escaneo y el join que van por
   debajo sí. Si al mirar el EXPLAIN aparece un nodo Gather / Gather Merge,
   subir este valor ayuda; si no aparece, no cambia nada. Verificar con EXPLAIN
   antes de dejarlo fijo.

       ALTER FUNCTION public.fn_reporte_menciones_estandar(text)
           SET max_parallel_workers_per_gather = 4;
   ---------------------------------------------------------------------------- */

/* ----------------------------------------------------------------------------
   NOTA SOBRE EL ORDEN DE LAS FILAS.
   Ni esta versión ni la v3.2 declaran ORDER BY: el orden de salida es un
   accidente del plan. Si algún consumidor lo necesita estable, añadirlo en el
   consumidor (más barato, porque puede combinarse con su propio filtrado):

       SELECT * FROM public.fn_reporte_menciones_estandar('101')
       ORDER BY "fechaEmision", "codigoReferenciaMultimedia";

   (ojo: "fechaEmision" sale como texto DD/MM/YYYY, así que ordenar por esa
   columna ordena alfabéticamente, no cronológicamente — igual que en la v3.2.)
   ---------------------------------------------------------------------------- */

ALTER FUNCTION public.fn_reporte_menciones_estandar(text) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.fn_reporte_menciones_estandar(text) TO rol_lectura;


/* ============================================================================
   3) DIAGNÓSTICO DE TIPOS DE NODO
   ----------------------------------------------------------------------------
   Usa el MISMO clasificador que el reporte, así que muestra exactamente en qué
   columna caerá cada tipo (no puede "mentir" respecto al reporte).
   'Región' aparece con categoria_estandar = 'CUBRIMIENTO' y 'Región Origen' sigue
   como 'OTROS_CAMPOS', automáticamente.

   La función se evalúa una vez por grupo (no por fila), y ahora además se
   inlinea, así que su costo es despreciable. Sin cambios de comportamiento.
   ============================================================================ */
DROP FUNCTION IF EXISTS public.fn_diagnostico_tipos_nodo(text);

CREATE OR REPLACE FUNCTION public.fn_diagnostico_tipos_nodo(p_sufijo TEXT)
RETURNS TABLE (
    tipo_original      TEXT,
    categoria_estandar TEXT,
    cantidad_nodos     BIGINT
) AS $$
DECLARE
    v_query TEXT;
BEGIN
    IF p_sufijo !~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'Sufijo de proyecto inválido: %. Debe ser numérico.', p_sufijo;
    END IF;

    v_query := format($q$
        SELECT
            tipo                            AS tipo_original,
            public.fn_categoria_nodo(tipo)  AS categoria_estandar,
            COUNT(*)                        AS cantidad_nodos
        FROM %1$I
        GROUP BY tipo
        ORDER BY 2, 3 DESC
    $q$, 'nodo_p' || p_sufijo);

    RETURN QUERY EXECUTE v_query;
END;
$$ LANGUAGE plpgsql;

ALTER FUNCTION public.fn_diagnostico_tipos_nodo(text) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.fn_diagnostico_tipos_nodo(text) TO rol_lectura;


/* ============================================================================
   4) ÍNDICES Y ESTADÍSTICAS POR PROYECTO
   ----------------------------------------------------------------------------
   En la v3.2 esto era un bloque comentado. Aquí es una función, porque los dos
   índices que crea son los que hacen que el plan optimizado tenga sentido:

     · mencion_nodo_pXXX (id_mencion, id_nodo)
       Cubre por completo el escaneo de la tabla de enlace: Index Only Scan sin
       tocar el heap, y además entrega las filas YA ORDENADAS por id_mencion.
       Eso habilita Incremental Sort (PG 13+) en el bloque N1: en vez de
       ordenar millones de filas por las tres claves, sólo ordena dentro de
       cada id_mencion. Es la diferencia más grande del bloque.

     · mencion_pXXX (id) WHERE estado = 'evaluado'
       Índice parcial para resolver MENC_OK con un Index Only Scan sobre 8
       bytes por fila, en vez de escanear el heap con el JSONB entero.

   Para que los Index Only Scan realmente eviten el heap hace falta que el
   visibility map esté fresco: correr VACUUM después de cargas grandes
   (VACUUM no puede ejecutarse dentro de una función, va aparte).

   Uso:  SELECT public.fn_preparar_indices_reporte('101');

   En producción con la tabla en uso, considerar crear los índices a mano con
   CREATE INDEX CONCURRENTLY (no se puede desde dentro de una función porque
   ésta corre dentro de una transacción).
   ============================================================================ */
CREATE OR REPLACE FUNCTION public.fn_preparar_indices_reporte(p_sufijo TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    s TEXT := p_sufijo;
BEGIN
    IF s !~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'Sufijo de proyecto inválido: %. Debe ser numérico.', s;
    END IF;

    -- Escaneo cubierto + orden por id_mencion para la agregación.
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I (id_mencion, id_nodo)',
                   'ix_mn_' || s || '_idm_idn', 'mencion_nodo_p' || s);

    -- Lista barata de menciones evaluadas.
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON %I (id) WHERE estado = ''evaluado''::estado_mencion',
        'ix_m_' || s || '_eval', 'mencion_p' || s);

    -- Sin estadísticas frescas el planner se equivoca de estrategia de join.
    EXECUTE format('ANALYZE %I', 'mencion_p'      || s);
    EXECUTE format('ANALYZE %I', 'mencion_nodo_p' || s);
    EXECUTE format('ANALYZE %I', 'nodo_p'         || s);

    RETURN 'Índices y estadísticas listos para el proyecto ' || s
        || '. Recomendado: VACUUM mencion_p' || s
        || ', mencion_nodo_p' || s || ';';
END;
$$;

ALTER FUNCTION public.fn_preparar_indices_reporte(text) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.fn_preparar_indices_reporte(text) TO rol_lectura;


/* ============================================================================
   5) VERIFICACIÓN DE EQUIVALENCIA  (recomendado antes de dar por buena la v4)
   ----------------------------------------------------------------------------
   No hay que creerle a los comentarios: se compara contra la v3.2.

   PASO 1 — antes de desplegar este archivo, renombrar la función vieja:

       ALTER FUNCTION public.fn_reporte_menciones_estandar(text)
           RENAME TO fn_reporte_menciones_estandar_v32;

   PASO 2 — desplegar este archivo completo.

   PASO 3 — comparar en AMBOS sentidos. Las dos consultas deben devolver
   CERO filas. Se usa EXCEPT ALL (no EXCEPT) para que también detecte
   diferencias en el número de filas duplicadas:

       SELECT 'sobra en v3.2' AS lado, *
       FROM (
           SELECT * FROM public.fn_reporte_menciones_estandar_v32('101')
           EXCEPT ALL
           SELECT * FROM public.fn_reporte_menciones_estandar('101')
       ) x;

       SELECT 'sobra en v4.0' AS lado, *
       FROM (
           SELECT * FROM public.fn_reporte_menciones_estandar('101')
           EXCEPT ALL
           SELECT * FROM public.fn_reporte_menciones_estandar_v32('101')
       ) x;

   PASO 4 — comparar tiempos con la caché ya templada (correr cada una dos
   veces y quedarse con la segunda medición):

       EXPLAIN (ANALYZE, BUFFERS)
       SELECT count(*) FROM public.fn_reporte_menciones_estandar_v32('101');

       EXPLAIN (ANALYZE, BUFFERS)
       SELECT count(*) FROM public.fn_reporte_menciones_estandar('101');

   PASO 5 — cuando la comparación dé cero filas en ambos sentidos:

       DROP FUNCTION public.fn_reporte_menciones_estandar_v32(text);

   ----------------------------------------------------------------------------
   COMPORTAMIENTOS HEREDADOS QUE NO SE TOCARON (para que no sorprendan)
   ----------------------------------------------------------------------------
   · Si algún nodo tiene `tipo` NULL, cae en OTROS_CAMPOS y JSONB_OBJECT_AGG
     falla con "field name must not be null". Es exactamente lo que hacía la
     v3.2; no se silenció para no cambiar el resultado. Para detectarlo antes:
         SELECT count(*) FROM nodo_p101 WHERE tipo IS NULL;
   · Si un proyecto tiene a la vez nodos 'Cubrimiento' y 'Región', ambos se
     concatenan en la columna "CUBRIMIENTO" (dato visible, no silenciado).
   · "fechaEmision" sale como texto con formato DD/MM/YYYY HH24:MI.
   · tier NULL o 'T5' se reescriben como 'T4'.

   ----------------------------------------------------------------------------
   SI AÚN ASÍ SE QUEDA CORTO
   ----------------------------------------------------------------------------
   El límite duro que queda es estructural: RETURN QUERY en PL/pgSQL materializa
   TODO el resultado en un tuplestore antes de entregar la primera fila. Con
   millones de menciones (y `resumen` adentro) eso es inevitable mientras la
   salida sea una función de conjunto.
   Si el consumidor es Power BI o cualquier proceso que lee el reporte completo
   varias veces, sale mucho más barato precalcularlo una vez:

       CREATE TABLE rpt_menciones_101 AS
           SELECT * FROM public.fn_reporte_menciones_estandar('101');
       CREATE INDEX ON rpt_menciones_101 ("codigoReferenciaMultimedia");
       ANALYZE rpt_menciones_101;

   ...y refrescarlo con la periodicidad del proyecto. A partir de ahí las
   lecturas son escaneos de tabla plana, sin joins ni agregación.
============================================================================ */
