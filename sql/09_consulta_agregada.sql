/* =====================================================================
   PUNTO 13 - Consulta agregada: situación de emergencia real

   PROBLEMA
   Una crecida de los ríos y arroyos principales (Feliciano, Estacas,
   Alcaraz, Guayquiraró, Paraná, etc.) deja intransitables los tramos de
   la red vial que atraviesan las planicies de inundación. ¿Qué
   localidades de La Paz pierden el acceso por ruta a su hospital, cuánto
   se alarga el viaje para las demás, cuál es el hospital alternativo y en
   qué orden deberían asistirse/evacuarse?

   INFORMACIÓN ESPACIAL UTILIZADA (5 tipos, 3 organismos)
     - Red vial OSM (calles + rutas)                 -> grafo ruteable
     - Hidrografía OSM (ríos y lagunas) -> ZRH principal (buffer 2 km)
     - Suelos INTA: unidades con IPC = 0 (arroyos, bañados, islas,
       planicies aluviales) = terreno bajo, el primero en anegarse
     - Departamentos IGN (área de estudio)
     - Establecimientos de salud y localidades OSM (con población)

   CRITERIO DE CORTE
   Un tramo de la red (que NO sea un puente según OSM) se considera cortado si:
     (a) cruza un río o arroyo: sin puente registrado el cruce es un vado
         o una alcantarilla, que una crecida desborda; o
     (b) está dentro de la ZRH principal Y sobre una unidad de suelo INTA
         de planicie inundable (Arroyos, Ambiente de islas y bañados,
         Cárcavas, Cuerpos de agua).
   Nota: las áreas urbanas (AU) también tienen IPC = 0 en la carta del
   INTA; por eso el criterio usa el tipo de unidad y no el IPC.

   HERRAMIENTAS: pgRouting (pgr_extractVertices, pgr_dijkstraCost,
   pgr_dijkstra), ST_DumpSegments, ST_Intersects, ST_DWithin, KNN.
   ===================================================================== */
SET search_path = entrerios, public;
CREATE EXTENSION IF NOT EXISTS pgrouting;

/* ---------------------------------------------------------------------
   13.1 Grafo ruteable
   Área: La Paz + 30 km (para incluir hospitales de deptos vecinos).
   En OSM las vías se conectan compartiendo NODOS (coordenadas idénticas),
   pero un nodo compartido puede estar en el medio de un way. Para que el
   grafo quede bien conectado se parte cada way en sus segmentos
   elementales (ST_DumpSegments): así cada nodo OSM es un vértice.
   Costo = tiempo de viaje en minutos según categoría de la vía.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.red_vial CASCADE;
CREATE TABLE entrerios.red_vial AS
WITH area AS (
    -- Se simplifica el contorno antes del buffer (para 30 km el detalle es irrelevante)
    -- y se lleva a 4326 para que el filtro use el índice GiST de la tabla cruda.
    SELECT ST_Transform(ST_Buffer(ST_Simplify(geom_m, 200), 30000), 4326) AS g
    FROM entrerios.departamentos WHERE nombre = 'La Paz'
), vias AS (
    SELECT l.osm_id, l.name, l.ref, l.highway,
           COALESCE(l.bridge, 'no') <> 'no' AS puente,
           ST_Transform(l.geom, 5347) AS g
    FROM fuentes.osm_lines l, area
    WHERE l.highway IN ('motorway', 'motorway_link', 'trunk', 'trunk_link', 'primary', 'primary_link',
                        'secondary', 'secondary_link', 'tertiary', 'tertiary_link',
                        'unclassified', 'residential')
      AND l.geom && area.g
      AND ST_Intersects(l.geom, area.g)
)
SELECT row_number() OVER ()::bigint AS id,
       v.osm_id, v.name, v.ref, v.highway, v.puente,
       CASE WHEN v.highway LIKE 'motorway%' OR v.highway LIKE 'trunk%' THEN 90
            WHEN v.highway LIKE 'primary%'   THEN 80
            WHEN v.highway LIKE 'secondary%' THEN 60
            WHEN v.highway LIKE 'tertiary%'  THEN 50
            WHEN v.highway = 'unclassified'  THEN 40
            ELSE 30 END AS vel_kmh,
       s.geom::geometry(LineString, 5347) AS geom_m
FROM vias v
CROSS JOIN LATERAL ST_DumpSegments(v.g) s;

ALTER TABLE entrerios.red_vial
    ADD COLUMN largo_m double precision, ADD COLUMN costo_min double precision,
    ADD COLUMN source bigint, ADD COLUMN target bigint, ADD COLUMN cortado boolean DEFAULT false;
UPDATE entrerios.red_vial SET largo_m = ST_Length(geom_m),
                              costo_min = ST_Length(geom_m) / 1000.0 / vel_kmh * 60;

-- Vértices (pgRouting 4: pgr_extractVertices reemplaza a pgr_createTopology)
DROP TABLE IF EXISTS entrerios.red_vial_vertices;
CREATE TABLE entrerios.red_vial_vertices AS
SELECT * FROM pgr_extractVertices('SELECT id, geom_m AS geom FROM entrerios.red_vial');

-- pgr_extractVertices devuelve, por vértice, las aristas que salen (out_edges)
-- y las que llegan (in_edges): con eso se asignan source y target sin
-- comparar geometrías.
UPDATE entrerios.red_vial e SET source = v.id
FROM (SELECT id, unnest(out_edges) AS eid FROM entrerios.red_vial_vertices) v WHERE v.eid = e.id;
UPDATE entrerios.red_vial e SET target = v.id
FROM (SELECT id, unnest(in_edges) AS eid FROM entrerios.red_vial_vertices) v WHERE v.eid = e.id;

CREATE INDEX ON entrerios.red_vial (source);
CREATE INDEX ON entrerios.red_vial (target);
CREATE INDEX ON entrerios.red_vial USING gist (geom_m);
CREATE INDEX ON entrerios.red_vial_vertices USING gist (geom);
ANALYZE entrerios.red_vial;  ANALYZE entrerios.red_vial_vertices;

SELECT count(*) AS aristas, round((sum(largo_m) / 1000)::numeric) AS km,
       (SELECT count(*) FROM entrerios.red_vial_vertices) AS vertices
FROM entrerios.red_vial;

-- Conectividad: componentes conexas (la principal debería tener casi todo)
SELECT component, count(*) AS vertices
FROM pgr_connectedComponents('SELECT id, source, target, largo_m AS cost, largo_m AS reverse_cost FROM entrerios.red_vial')
GROUP BY component ORDER BY 2 DESC LIMIT 5;

/* ---------------------------------------------------------------------
   13.2 Tramos cortados por la crecida
   --------------------------------------------------------------------- */
UPDATE entrerios.red_vial SET cortado = false;

-- (a) cruces de agua sin puente
UPDATE entrerios.red_vial e SET cortado = true
WHERE NOT e.puente
  AND EXISTS (SELECT 1 FROM entrerios.rios r WHERE ST_Intersects(r.geom_m, e.geom_m));

-- (b) planicie inundable (INTA) dentro de la ZRH principal.
--     Se materializa la intersección por polígono (sin ST_Union global,
--     que generaría un único polígono gigante y lento de consultar).
DROP TABLE IF EXISTS tmp_planicie;
CREATE TEMP TABLE tmp_planicie AS
SELECT (ST_Dump(ST_Intersection(s.geom_m, z.geom_m_principal))).geom AS g
FROM entrerios.suelo s
JOIN entrerios.zona_riesgo_hidrico z ON ST_Intersects(s.geom_m, z.geom_m_principal)
WHERE s.clase = 'Planicie inundable / agua'
  AND ST_DWithin(s.geom_m, (SELECT geom_m FROM entrerios.departamentos WHERE nombre = 'La Paz'), 30000);
CREATE INDEX ON tmp_planicie USING gist (g);
ANALYZE tmp_planicie;

UPDATE entrerios.red_vial e SET cortado = true
WHERE NOT e.cortado AND NOT e.puente
  AND EXISTS (SELECT 1 FROM tmp_planicie p WHERE ST_Intersects(p.g, e.geom_m));

SELECT count(*) FILTER (WHERE cortado) AS aristas_cortadas,
       round((sum(largo_m) FILTER (WHERE cortado) / 1000)::numeric, 1) AS km_cortados,
       round((100 * sum(largo_m) FILTER (WHERE cortado) / sum(largo_m))::numeric, 1) AS pct_red
FROM entrerios.red_vial;

DROP TABLE IF EXISTS entrerios.r13_tramos_cortados;
CREATE TABLE entrerios.r13_tramos_cortados AS
SELECT row_number() OVER () AS id, COALESCE(ref, name, highway) AS via,
       ST_Multi(ST_Transform(ST_LineMerge(ST_Collect(geom_m)), 4326))::geometry(MultiLineString, 4326) AS geom,
       round(sum(largo_m)::numeric) AS metros
FROM entrerios.red_vial WHERE cortado
GROUP BY COALESCE(ref, name, highway);

SELECT via, metros FROM entrerios.r13_tramos_cortados ORDER BY metros DESC LIMIT 15;

/* ---------------------------------------------------------------------
   13.3 Acceso a hospitales: situación normal vs. con crecida
   Cada localidad y cada hospital se "enganchan" al vértice más cercano
   del grafo (KNN). Con pgr_dijkstraCost (muchos-a-muchos) se obtiene el
   tiempo mínimo a cada hospital; se toma el menor por localidad.
   Solo se consideran hospitales (no consultorios) porque en una
   emergencia se necesita internación/guardia.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS tmp_nodos;
CREATE TEMP TABLE tmp_nodos AS
SELECT 'L' AS clase, l.id, l.nombre, l.poblacion, v.id AS vid
FROM entrerios.localidades l
JOIN entrerios.departamentos d ON d.id = l.id_depto AND d.nombre = 'La Paz'
CROSS JOIN LATERAL (SELECT id FROM entrerios.red_vial_vertices ORDER BY geom <-> l.geom_m LIMIT 1) v
UNION ALL
SELECT 'H', s.id, s.nombre, NULL, v.id
FROM entrerios.salud s
JOIN entrerios.departamentos lp ON lp.nombre = 'La Paz' AND ST_DWithin(s.geom_m, lp.geom_m, 30000)
CROSS JOIN LATERAL (SELECT id FROM entrerios.red_vial_vertices ORDER BY geom <-> s.geom_m LIMIT 1) v
WHERE s.tipo = 'hospital';

DROP TABLE IF EXISTS tmp_normal, tmp_crecida;
CREATE TEMP TABLE tmp_normal AS
SELECT * FROM pgr_dijkstraCost(
    'SELECT id, source, target, costo_min AS cost, costo_min AS reverse_cost FROM entrerios.red_vial',
    (SELECT array_agg(DISTINCT vid) FROM tmp_nodos WHERE clase = 'L'),
    (SELECT array_agg(DISTINCT vid) FROM tmp_nodos WHERE clase = 'H'));
CREATE TEMP TABLE tmp_crecida AS
SELECT * FROM pgr_dijkstraCost(
    'SELECT id, source, target, costo_min AS cost, costo_min AS reverse_cost FROM entrerios.red_vial WHERE NOT cortado',
    (SELECT array_agg(DISTINCT vid) FROM tmp_nodos WHERE clase = 'L'),
    (SELECT array_agg(DISTINCT vid) FROM tmp_nodos WHERE clase = 'H'));

DROP TABLE IF EXISTS entrerios.r13_impacto_crecida;
CREATE TABLE entrerios.r13_impacto_crecida AS
WITH mejor_normal AS (
    SELECT DISTINCT ON (l.id) l.id, l.nombre, l.poblacion, h.nombre AS hospital, n.agg_cost AS min_normal
    FROM tmp_nodos l JOIN tmp_normal n ON n.start_vid = l.vid
    JOIN tmp_nodos h ON h.clase = 'H' AND h.vid = n.end_vid
    WHERE l.clase = 'L' ORDER BY l.id, n.agg_cost
), mejor_crecida AS (
    SELECT DISTINCT ON (l.id) l.id, h.nombre AS hospital, c.agg_cost AS min_crecida
    FROM tmp_nodos l JOIN tmp_crecida c ON c.start_vid = l.vid
    JOIN tmp_nodos h ON h.clase = 'H' AND h.vid = c.end_vid
    WHERE l.clase = 'L' ORDER BY l.id, c.agg_cost
)
SELECT n.id, n.nombre AS localidad, COALESCE(n.poblacion, 0) AS poblacion,
       n.hospital AS hospital_normal, round(n.min_normal::numeric, 1) AS min_normal,
       c.hospital AS hospital_crecida, round(c.min_crecida::numeric, 1) AS min_crecida,
       round((c.min_crecida - n.min_normal)::numeric, 1) AS demora_extra_min,
       CASE WHEN c.id IS NULL THEN 'AISLADA (sin acceso a hospital)'
            WHEN c.hospital <> n.hospital THEN 'Debe derivarse a otro hospital'
            WHEN c.min_crecida > n.min_normal * 1.25 THEN 'Acceso demorado'
            ELSE 'Sin afectación relevante' END AS situacion,
       loc.geom
FROM mejor_normal n
LEFT JOIN mejor_crecida c ON c.id = n.id
JOIN entrerios.localidades loc ON loc.id = n.id;

-- Prioridad de asistencia: aisladas primero, luego por población x demora
SELECT rank() OVER (ORDER BY (situacion LIKE 'AISLADA%') DESC,
                             poblacion * COALESCE(demora_extra_min, 999) DESC) AS prioridad,
       localidad, poblacion, hospital_normal, min_normal, hospital_crecida, min_crecida,
       demora_extra_min, situacion
FROM entrerios.r13_impacto_crecida
ORDER BY prioridad;

/* ---------------------------------------------------------------------
   13.4 Ruta alternativa para la localidad más afectada (pgr_dijkstra)
   Se dibujan la ruta normal y la alternativa para QGIS.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS entrerios.r13_rutas_hospital;
CREATE TABLE entrerios.r13_rutas_hospital (
    localidad text, escenario text, hospital text, minutos numeric, km numeric,
    geom geometry(MultiLineString, 4326));

DO $$
DECLARE r record; lv bigint; hv bigint; esc text; filtro text;
BEGIN
    FOR r IN SELECT * FROM entrerios.r13_impacto_crecida
             WHERE situacion <> 'Sin afectación relevante' LOOP
        SELECT vid INTO lv FROM tmp_nodos WHERE clase = 'L' AND id = r.id;
        FOREACH esc IN ARRAY ARRAY['normal', 'crecida'] LOOP
            filtro := CASE WHEN esc = 'normal' THEN '' ELSE ' WHERE NOT cortado' END;
            SELECT vid INTO hv FROM tmp_nodos
            WHERE clase = 'H' AND nombre = CASE WHEN esc = 'normal' THEN r.hospital_normal ELSE r.hospital_crecida END
            LIMIT 1;
            CONTINUE WHEN hv IS NULL;
            INSERT INTO entrerios.r13_rutas_hospital
            SELECT r.localidad, esc, CASE WHEN esc = 'normal' THEN r.hospital_normal ELSE r.hospital_crecida END,
                   round(max(p.agg_cost)::numeric, 1), round((sum(e.largo_m) / 1000)::numeric, 1),
                   ST_Multi(ST_Transform(ST_Collect(e.geom_m), 4326))
            FROM pgr_dijkstra('SELECT id, source, target, costo_min AS cost, costo_min AS reverse_cost FROM entrerios.red_vial' || filtro,
                              lv, hv) p
            JOIN entrerios.red_vial e ON e.id = p.edge;
        END LOOP;
    END LOOP;
END $$;

SELECT localidad, escenario, hospital, minutos, km FROM entrerios.r13_rutas_hospital ORDER BY localidad, escenario DESC;

/* ---------------------------------------------------------------------
   13.5 Derivación al hospital de referencia (Hospital Zonal 9 de Julio)
   La mayoría de las localidades tiene un centro de salud propio, por lo
   que el corte de caminos casi no cambia su acceso al establecimiento
   MÁS CERCANO. Pero los casos graves se derivan al hospital zonal de la
   cabecera (La Paz). Se compara el tiempo de derivación normal vs.
   crecida para cada localidad y se dibujan ambas rutas.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS tmp_zonal;
CREATE TEMP TABLE tmp_zonal AS
SELECT l.id, l.nombre, COALESCE(l.poblacion, 0) AS poblacion,
       (SELECT v.id FROM entrerios.red_vial_vertices v ORDER BY v.geom <-> l.geom_m LIMIT 1) AS vid
FROM entrerios.localidades l
JOIN entrerios.departamentos d ON d.id = l.id_depto AND d.nombre = 'La Paz';

DROP TABLE IF EXISTS tmp_zonal_h;
CREATE TEMP TABLE tmp_zonal_h AS
SELECT (SELECT v.id FROM entrerios.red_vial_vertices v ORDER BY v.geom <-> s.geom_m LIMIT 1) AS vid
FROM entrerios.salud s WHERE s.nombre = 'Hospital Zonal 9 de Julio';

DROP TABLE IF EXISTS entrerios.r13_derivacion_zonal;
CREATE TABLE entrerios.r13_derivacion_zonal AS
WITH n AS (
    SELECT * FROM pgr_dijkstraCost(
        'SELECT id, source, target, costo_min AS cost, costo_min AS reverse_cost FROM entrerios.red_vial',
        (SELECT array_agg(DISTINCT vid) FROM tmp_zonal), (SELECT vid FROM tmp_zonal_h))
), c AS (
    SELECT * FROM pgr_dijkstraCost(
        'SELECT id, source, target, costo_min AS cost, costo_min AS reverse_cost FROM entrerios.red_vial WHERE NOT cortado',
        (SELECT array_agg(DISTINCT vid) FROM tmp_zonal), (SELECT vid FROM tmp_zonal_h))
)
SELECT z.id, z.nombre AS localidad, z.poblacion,
       round(n.agg_cost::numeric, 1) AS min_normal,
       round(c.agg_cost::numeric, 1) AS min_crecida,
       round((c.agg_cost - n.agg_cost)::numeric, 1) AS demora_extra_min,
       round((100 * (c.agg_cost / NULLIF(n.agg_cost, 0) - 1))::numeric, 0) AS pct_extra,
       CASE WHEN c.agg_cost IS NULL THEN 'AISLADA'
            WHEN c.agg_cost - n.agg_cost >= 15 THEN 'Demora crítica (>= 15 min)'
            WHEN c.agg_cost - n.agg_cost >= 5  THEN 'Demora moderada (5-15 min)'
            ELSE 'Sin afectación relevante' END AS situacion,
       l.geom
FROM tmp_zonal z
JOIN entrerios.localidades l ON l.id = z.id
LEFT JOIN n ON n.start_vid = z.vid
LEFT JOIN c ON c.start_vid = z.vid;

-- Prioridad de asistencia: población afectada x minutos de demora
SELECT rank() OVER (ORDER BY (situacion = 'AISLADA') DESC, poblacion * COALESCE(demora_extra_min, 0) DESC) AS prioridad,
       localidad, poblacion, min_normal, min_crecida, demora_extra_min, pct_extra, situacion
FROM entrerios.r13_derivacion_zonal ORDER BY prioridad;

-- Rutas normal y alternativa de cada localidad afectada hacia el hospital zonal
DELETE FROM entrerios.r13_rutas_hospital WHERE hospital = 'Hospital Zonal 9 de Julio (derivación)';
DO $$
DECLARE r record; esc text; filtro text; hv bigint;
BEGIN
    SELECT vid INTO hv FROM tmp_zonal_h;
    FOR r IN SELECT d.*, z.vid FROM entrerios.r13_derivacion_zonal d JOIN tmp_zonal z ON z.id = d.id
             WHERE d.situacion <> 'Sin afectación relevante' AND d.min_crecida IS NOT NULL LOOP
        FOREACH esc IN ARRAY ARRAY['normal', 'crecida'] LOOP
            filtro := CASE WHEN esc = 'normal' THEN '' ELSE ' WHERE NOT cortado' END;
            INSERT INTO entrerios.r13_rutas_hospital
            SELECT r.localidad, esc, 'Hospital Zonal 9 de Julio (derivación)',
                   round(max(p.agg_cost)::numeric, 1), round((sum(e.largo_m) / 1000)::numeric, 1),
                   ST_Multi(ST_Transform(ST_LineMerge(ST_Collect(e.geom_m)), 4326))
            FROM pgr_dijkstra('SELECT id, source, target, costo_min AS cost, costo_min AS reverse_cost FROM entrerios.red_vial' || filtro,
                              r.vid, hv) p
            JOIN entrerios.red_vial e ON e.id = p.edge;
        END LOOP;
    END LOOP;
END $$;

SELECT localidad, escenario, minutos, km FROM entrerios.r13_rutas_hospital
WHERE hospital LIKE '%derivación%' ORDER BY localidad, escenario DESC;

-- Tramos cortados que más pesan: los usados por la ruta normal de derivación
SELECT t.via, t.metros
FROM entrerios.r13_tramos_cortados t
WHERE EXISTS (SELECT 1 FROM entrerios.r13_rutas_hospital h
              WHERE h.escenario = 'normal' AND h.hospital LIKE '%derivación%' AND ST_Intersects(h.geom, t.geom))
ORDER BY t.metros DESC;
