/* =====================================================================
   PUNTO 6 (cont.) - Controles de calidad de la importación
   Para cada tabla del esquema entrerios se verifica:
     tipo de geometría, SRID, cantidad de registros,
     geometrías nulas, vacías e inválidas.
   ===================================================================== */
SET search_path = entrerios, public;

CREATE OR REPLACE FUNCTION entrerios.fn_control_calidad()
RETURNS TABLE (tabla text, columna text, tipo_declarado text, srid_declarado int,
               tipos_reales text, srids_reales text, registros bigint,
               nulas bigint, vacias bigint, invalidas bigint)
LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
    FOR r IN SELECT f_table_name AS t, f_geometry_column AS c, type, srid
             FROM geometry_columns
             WHERE f_table_schema = 'entrerios' AND f_geometry_column = 'geom'
             ORDER BY 1
    LOOP
        RETURN QUERY EXECUTE format($q$
            SELECT %L::text, %L::text, %L::text, %s,
                   (SELECT string_agg(DISTINCT ST_GeometryType(%2$I), ', ') FROM entrerios.%1$I),
                   (SELECT string_agg(DISTINCT ST_SRID(%2$I)::text, ', ') FROM entrerios.%1$I),
                   count(*),
                   count(*) FILTER (WHERE %2$I IS NULL),
                   count(*) FILTER (WHERE ST_IsEmpty(%2$I)),
                   count(*) FILTER (WHERE NOT ST_IsValid(%2$I))
            FROM entrerios.%1$I $q$, r.t, r.c, r.type, r.srid);
    END LOOP;
END $$;

-- 6.a Resumen de control de calidad
SELECT * FROM entrerios.fn_control_calidad();

-- 6.b Control puntual con ST_GeometryType y ST_SRID (ejemplo pedido por la consigna)
SELECT nombre, ST_GeometryType(geom) AS tipo, ST_SRID(geom) AS srid,
       ST_IsValid(geom) AS valida, ST_NPoints(geom) AS vertices
FROM entrerios.departamentos
ORDER BY nombre;

-- 6.c Geometrías inválidas en la fuente cruda y su motivo.
--     (La carga ya aplicó ST_MakeValid; acá se muestra qué se corrigió.)
SELECT 'ign_departamentos' AS fuente, count(*) FILTER (WHERE NOT ST_IsValid(geom)) AS invalidas
FROM fuentes.ign_departamentos
UNION ALL
SELECT 'osm_multipolygons (natural=water)', count(*) FILTER (WHERE NOT ST_IsValid(geom))
FROM fuentes.osm_multipolygons WHERE "natural" = 'water'
UNION ALL
SELECT 'osm_multipolygons (salud)', count(*) FILTER (WHERE NOT ST_IsValid(geom))
FROM fuentes.osm_multipolygons WHERE amenity IN ('hospital', 'clinic')
UNION ALL
SELECT 'inta_suelos', count(*) FILTER (WHERE NOT ST_IsValid(geom))
FROM fuentes.inta_suelos;

SELECT osm_id, name, ST_IsValidReason(geom) AS motivo
FROM fuentes.osm_multipolygons
WHERE "natural" = 'water' AND NOT ST_IsValid(geom)
LIMIT 10;

-- 6.d Corrección con ST_MakeValid sobre cualquier geometría que quedara inválida
--     (idempotente: si no hay inválidas no modifica nada).
UPDATE entrerios.lagunas   SET geom = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3)) WHERE NOT ST_IsValid(geom);
UPDATE entrerios.rios_area SET geom = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3)) WHERE NOT ST_IsValid(geom);
UPDATE entrerios.departamentos SET geom = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3)) WHERE NOT ST_IsValid(geom);

-- 6.e Coherencia topológica: la suma de áreas departamentales vs. el área provincial
--     (detecta superposiciones o huecos entre departamentos del IGN).
SELECT round((SELECT sum(ST_Area(geom_m)) FROM entrerios.departamentos)::numeric / 1e6, 1) AS suma_deptos_km2,
       round(ST_Area(ST_Transform(geom, 5347))::numeric / 1e6, 1)                         AS provincia_km2
FROM entrerios.provincia;

-- 6.f Contenido por departamento (verificación de razonabilidad de OSM)
SELECT d.nombre,
       (SELECT count(*) FROM entrerios.localidades l WHERE l.id_depto = d.id) AS localidades,
       (SELECT count(*) FROM entrerios.salud s       WHERE s.id_depto = d.id) AS salud
FROM entrerios.departamentos d
ORDER BY d.nombre;
