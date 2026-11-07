/* ============================================================================
   PERFILADO Y AGRUPACIÓN DE COLUMNAS ENTRE PROYECTOS  ·  PostgreSQL
   ----------------------------------------------------------------------------

   Autor:   Juan Pablo Velandia Molina
   Versión: 1.0
   Fecha:   Agosto 2026

   CONTEXTO
   --------
   Cada proyecto vive en su propio juego de tablas con el número de proyecto
   como sufijo:
       mencion_pXXX  (id, ..., data JSONB)   las filas del proyecto
       nodo_pXXX     (id, nombre, tipo)      el catálogo de etiquetas ("nodos")
   Aunque todos los proyectos nacen de la misma plataforma, con el tiempo cada
   uno acumula columnas, claves JSON y tipos de nodo propios. Antes de construir
   una plantilla de reporte común hay que saber qué tienen en común y qué
   proyectos son "gemelos" estructurales.

   CONSULTAS
   ---------
     1) Columnas físicas en común         (information_schema.columns)
     2) Claves del JSONB `data` en común   (jsonb_object_keys)
     3) Tipos de nodo de cada proyecto     (conteo por proyecto y tipo)
     4) Tipos de nodo estandarizados       (en cuántos proyectos aparece cada uno)
     5) Proyectos con el mismo perfil      (agrupa los proyectos idénticos)

   CÓMO USAR
   ---------
   Editar en cada consulta la lista de tablas / proyectos que se quieren
   comparar (aquí, a modo de ejemplo, los proyectos 101 a 105). Son consultas
   de solo lectura: no crean ni modifican nada, salvo que se descomente el
   CREATE VIEW de la consulta 5.
============================================================================ */


/* ============================================================================
   1) COLUMNAS FÍSICAS EN COMÚN
   ----------------------------------------------------------------------------
   Qué columnas tiene cada tabla y en cuántas de las tablas comparadas aparece.
   Las que salen con cantidad_tablas = total son el núcleo común; las demás
   son particularidades de algunos proyectos.
   ============================================================================ */
SELECT
    column_name,
    COUNT(*)                                       AS cantidad_tablas,
    STRING_AGG(table_name, ', ' ORDER BY table_name) AS tablas
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN (
      'mencion_p101',
      'mencion_p102',
      'mencion_p103',
      'mencion_p104',
      'mencion_p105'
  )
GROUP BY column_name
ORDER BY cantidad_tablas DESC, column_name;


/* ============================================================================
   2) CLAVES DEL JSONB `data` EN COMÚN
   ----------------------------------------------------------------------------
   Muchas columnas no son columnas físicas sino claves dentro de un JSONB.
   jsonb_object_keys() las despliega fila a fila y se cuenta en cuántos
   proyectos distintos aparece cada clave.
   ============================================================================ */
SELECT
    key,
    COUNT(DISTINCT proyecto)                               AS cantidad_proyectos,
    STRING_AGG(DISTINCT proyecto, ', ' ORDER BY proyecto)  AS proyectos
FROM (
    SELECT '101' AS proyecto, jsonb_object_keys(data) AS key FROM public.mencion_p101
    UNION ALL
    SELECT '102', jsonb_object_keys(data) FROM public.mencion_p102
    UNION ALL
    SELECT '103', jsonb_object_keys(data) FROM public.mencion_p103
    UNION ALL
    SELECT '104', jsonb_object_keys(data) FROM public.mencion_p104
    UNION ALL
    SELECT '105', jsonb_object_keys(data) FROM public.mencion_p105
) t
GROUP BY key
ORDER BY cantidad_proyectos DESC, key;


/* ============================================================================
   3) TIPOS DE NODO DE CADA PROYECTO (en crudo)
   ----------------------------------------------------------------------------
   Los valores tal como están escritos en cada proyecto. Sirve para ver las
   variantes de un mismo concepto ('Tono', 'Tonalidad', 'TONO ') antes de
   estandarizarlas.
   ============================================================================ */
SELECT
    proyecto,
    tipo,
    COUNT(*) AS cantidad
FROM (
    SELECT '101' AS proyecto, tipo FROM public.nodo_p101
    UNION ALL
    SELECT '102', tipo FROM public.nodo_p102
    UNION ALL
    SELECT '103', tipo FROM public.nodo_p103
    UNION ALL
    SELECT '104', tipo FROM public.nodo_p104
    UNION ALL
    SELECT '105', tipo FROM public.nodo_p105
) t
GROUP BY proyecto, tipo
ORDER BY proyecto, cantidad DESC, tipo;


/* ============================================================================
   4) Y 5) TIPOS DE NODO ESTANDARIZADOS Y PROYECTOS CON EL MISMO PERFIL
   ----------------------------------------------------------------------------
   Las dos consultas comparten las mismas CTE:

     nodos_en_bruto        UNION ALL de los tipos de nodo de cada proyecto.
     nodos_normalizados    mayúsculas, sin espacios laterales y sin tildes,
                           en UN solo sitio antes del clasificador.
     nodos_estandarizados  diccionario de datos: homologa las variantes
                           ('Tonalidad', 'Tono') a una clave maestra ('TONO').
                           Es la única fuente de verdad del clasificador.

   Se excluyen 'GESTIONADO', 'COMUNICADO' y 'TIER' para comparar solo el
   "esqueleto" analítico de cada proyecto (temas, tono, voceros...), no las
   marcas operativas.
   ============================================================================ */

-- 4) En cuántos proyectos aparece cada tipo de nodo estandarizado.
--    Su salida también sirve para pedirle a una IA que proponga grupos.
WITH
nodos_en_bruto AS (
    SELECT '101' AS proyecto, tipo FROM public.nodo_p101
    UNION ALL
    SELECT '102', tipo FROM public.nodo_p102
    UNION ALL
    SELECT '103', tipo FROM public.nodo_p103
    UNION ALL
    SELECT '104', tipo FROM public.nodo_p104
    UNION ALL
    SELECT '105', tipo FROM public.nodo_p105
),
nodos_normalizados AS (
    SELECT
        proyecto,
        TRANSLATE(UPPER(TRIM(tipo)), 'ÁÉÍÓÚ', 'AEIOU') AS t
    FROM nodos_en_bruto
),
nodos_estandarizados AS (
    SELECT
        proyecto,
        CASE
            WHEN t LIKE 'TONO%'        OR t LIKE 'TONAL%'  THEN 'TONO'
            WHEN t LIKE 'TIE%'                             THEN 'TIER'
            WHEN t LIKE 'FORMAT%'                          THEN 'FORMATO'
            WHEN t LIKE 'TEMA%'                            THEN 'TEMAS'
            WHEN t LIKE 'VOCER%'                           THEN 'VOCEROS'
            WHEN t LIKE 'PERSONAJE%'                       THEN 'PERSONAJE'
            WHEN t LIKE 'GESTION%'                         THEN 'GESTIONADO'
            WHEN t LIKE 'COMUNICAD%'                       THEN 'COMUNICADO'
            WHEN t LIKE 'ENTIDADES%'                       THEN 'ENTIDADES_ADSCRITAS'
            WHEN t LIKE 'CUBRIMIENTO%' OR t LIKE 'REGI%'   THEN 'CUBRIMIENTO'
            ELSE t
        END AS tipo_nodo
    FROM nodos_normalizados
)
SELECT
    tipo_nodo,
    COUNT(DISTINCT proyecto)                               AS cantidad_proyectos,
    STRING_AGG(DISTINCT proyecto, ', ' ORDER BY proyecto)  AS proyectos
FROM nodos_estandarizados
WHERE tipo_nodo NOT IN ('GESTIONADO', 'COMUNICADO', 'TIER')
GROUP BY tipo_nodo
ORDER BY cantidad_proyectos DESC, tipo_nodo;


-- 5) Proyectos que comparten EXACTAMENTE el mismo conjunto de tipos de nodo.
--    Cada proyecto se resume en una "firma" (sus tipos ordenados y unidos por
--    comas) y se agrupa por firma: cada fila de la salida es un grupo de
--    proyectos gemelos que pueden usar la misma plantilla.
--
--    Para dejarlo persistido, descomentar la línea siguiente:
-- CREATE OR REPLACE VIEW public.vw_perfiles_nodos_proyectos AS
WITH
nodos_en_bruto AS (
    SELECT '101' AS proyecto, tipo FROM public.nodo_p101
    UNION ALL
    SELECT '102', tipo FROM public.nodo_p102
    UNION ALL
    SELECT '103', tipo FROM public.nodo_p103
    UNION ALL
    SELECT '104', tipo FROM public.nodo_p104
    UNION ALL
    SELECT '105', tipo FROM public.nodo_p105
),
nodos_normalizados AS (
    SELECT
        proyecto,
        TRANSLATE(UPPER(TRIM(tipo)), 'ÁÉÍÓÚ', 'AEIOU') AS t
    FROM nodos_en_bruto
),
nodos_estandarizados AS (
    SELECT
        proyecto,
        CASE
            WHEN t LIKE 'TONO%'        OR t LIKE 'TONAL%'  THEN 'TONO'
            WHEN t LIKE 'TIE%'                             THEN 'TIER'
            WHEN t LIKE 'FORMAT%'                          THEN 'FORMATO'
            WHEN t LIKE 'TEMA%'                            THEN 'TEMAS'
            WHEN t LIKE 'VOCER%'                           THEN 'VOCEROS'
            WHEN t LIKE 'PERSONAJE%'                       THEN 'PERSONAJE'
            WHEN t LIKE 'GESTION%'                         THEN 'GESTIONADO'
            WHEN t LIKE 'COMUNICAD%'                       THEN 'COMUNICADO'
            WHEN t LIKE 'ENTIDADES%'                       THEN 'ENTIDADES_ADSCRITAS'
            WHEN t LIKE 'CUBRIMIENTO%' OR t LIKE 'REGI%'   THEN 'CUBRIMIENTO'
            ELSE t
        END AS tipo_nodo
    FROM nodos_normalizados
),
-- La "firma" de cada proyecto: sus tipos de nodo, sin repetir y en orden.
perfiles_por_proyecto AS (
    SELECT
        proyecto,
        STRING_AGG(DISTINCT tipo_nodo, ', ' ORDER BY tipo_nodo) AS nodos_coincidentes
    FROM nodos_estandarizados
    WHERE tipo_nodo NOT IN ('GESTIONADO', 'COMUNICADO', 'TIER')
    GROUP BY proyecto
)
SELECT
    -- NULLIF: si un proyecto entra con identificador vacío (''), el cast a
    -- INT fallaría con "invalid input syntax for type integer". Así se ordena
    -- como NULL en vez de romper la consulta.
    STRING_AGG(proyecto, ', ' ORDER BY NULLIF(proyecto, '')::INT) AS "Proyectos",
    COUNT(proyecto)                                                AS "Cantidad de Proyectos",
    nodos_coincidentes                                             AS "Nodos Coincidentes"
FROM perfiles_por_proyecto
GROUP BY nodos_coincidentes
ORDER BY "Cantidad de Proyectos" DESC, "Proyectos";
