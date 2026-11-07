# Reporte estándar de menciones en PostgreSQL (v4, optimizado)

Función de **PostgreSQL** que convierte los datos de un proyecto de monitoreo de medios
(menciones en JSONB + etiquetas en tablas de nodos) en **una tabla plana de 34 columnas**, lista
para consumir en Power BI. La v4 reescribe la v3.2 para que sea mucho más rápida **sin cambiar ni
una fila de la salida**.

## El problema

Cada proyecto tiene tres tablas, con el número de proyecto como sufijo:

| Tabla | Contenido | Tamaño típico |
|---|---|---|
| `mencion_pXXX` | una fila por mención; casi todo el detalle va en una columna `data` JSONB | cientos de miles |
| `nodo_pXXX` | catálogo de etiquetas (*nodos*): `id`, `nombre`, `tipo` (Tono, Temas, Voceros...) | miles |
| `mencion_nodo_pXXX` | tabla de enlace mención ↔ nodo | millones |

Power BI necesita una fila por mención con cada tipo de etiqueta en su propia columna. Además,
cada proyecto escribe los tipos a su manera (`Tono`, `Tonalidad`, `TONO `, `Región`,
`Cubrimiento`...), así que hay que estandarizarlos.

## La solución

```sql
SELECT * FROM public.fn_reporte_menciones_estandar('101');
```

| Objeto | Qué hace |
|---|---|
| `fn_normaliza_tipo_nodo(text)` | mayúsculas, sin tildes y sin espacios laterales |
| `fn_categoria_nodo(text)` | clasificador de tipos de nodo: la **única fuente de verdad** |
| `fn_reporte_menciones_estandar(text)` | el reporte: 24 campos del JSONB + 8 columnas de etiquetas + `OTROS_CAMPOS` (JSONB) |
| `fn_diagnostico_tipos_nodo(text)` | en qué columna caerá cada tipo de nodo del proyecto, usando el mismo clasificador |
| `fn_preparar_indices_reporte(text)` | crea los índices que necesita el plan y actualiza las estadísticas |

Los tipos de nodo que no tienen columna propia no se pierden: van a `OTROS_CAMPOS` como un objeto
JSON `{tipo: valores}`.

## Qué se optimizó (v3.2 → v4)

1. **Clasificador inlineable.** PostgreSQL solo inlinea una función SQL si su cuerpo es un
   `SELECT` sin `FROM`. Sacar la normalización a un helper hace que el planner sustituya el
   `CASE` dentro de la consulta, sin coste de invocación.
2. **Clasificar del lado pequeño.** El clasificador se evalúa una vez por nodo (miles de filas),
   no una vez por fila de la tabla de enlace (millones), con un CTE `AS MATERIALIZED` y una
   barrera `OFFSET 0`.
3. **Una sola agregación en vez de tres.** Un único `GROUP BY` sobre el join y luego un pivot
   barato sobre un conjunto ya pequeño.
4. **Sin función de ventana para el tono.** `ROW_NUMBER() OVER (...)` se cambió por
   `(ARRAY_AGG(nombre ORDER BY nodo_id DESC) FILTER (WHERE cat = 1))[1]`, con el mismo criterio
   de desempate.
5. **Claves numéricas.** La categoría se agrupa como `smallint` en lugar de texto, y así se evitan
   comparaciones con *collation*.
6. **El JSONB se recorre una vez.** `jsonb_to_record()` sustituye 24 `data->>'campo'`. Además, el
   texto ancho (título y resumen) ya no se copia a un almacén temporal.

A eso se suman un `work_mem` propio de la función, para que la ordenación no se derrame a disco,
y una función que crea los índices que hacen posible el plan: un índice cubriente
`(id_mencion, id_nodo)` para *Index Only Scan* + *Incremental Sort*, y un índice parcial de
menciones evaluadas.

## Cómo se garantizó que la salida es idéntica

El propio script (bloque 5) incluye el procedimiento de verificación. Se renombra la versión
anterior, se despliega la nueva y se compara en los dos sentidos con `EXCEPT ALL`, que también
detecta las filas duplicadas de más o de menos:

```sql
SELECT * FROM fn_reporte_menciones_estandar_v32('101')
EXCEPT ALL
SELECT * FROM fn_reporte_menciones_estandar('101');   -- debe devolver 0 filas (y al revés)
```

Después se comparan los tiempos con `EXPLAIN (ANALYZE, BUFFERS)` y la caché ya caliente.

## Instalación

1. Ejecuta `sql/reporte_menciones_estandar.sql` completo, en una sola transacción.
   - Cambia `rol_lectura` por el rol que vaya a consultar el reporte.
   - Cambia `postgres` por el propietario que uses.
2. Para cada proyecto, una vez:

   ```sql
   SELECT public.fn_preparar_indices_reporte('101');
   VACUUM mencion_p101, mencion_nodo_p101;
   ```

3. Consulta el reporte desde Power BI o desde cualquier cliente:

   ```sql
   SELECT * FROM public.fn_reporte_menciones_estandar('101');
   ```

Requiere PostgreSQL 12 o superior (`AS MATERIALIZED`). Con la 13 o superior se aprovecha además
*Incremental Sort*.

## Seguridad

El número de proyecto se valida con `^[0-9]+$`, y los nombres de tabla se construyen con
`format('%I')`, que los escapa como identificadores. Así, el SQL dinámico no admite inyección.

## Licencia

[MIT](../LICENSE)
