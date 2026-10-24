"""
TP2 BDG 2026 - Genera el informe (HTML -> PDF) leyendo los resultados
directamente de la base tp2_bdg, para que cada número del informe coincida
con lo que devuelve el script SQL.

Ejecutar con el Python de QGIS (trae psycopg2):
  "C:\\Program Files\\QGIS 3.44.15\\bin\\python-qgis-ltr.bat" generar_informe.py
"""
import datetime
import html
import os
import subprocess

import psycopg2

BASE = os.path.dirname(os.path.abspath(__file__))
HTML_OUT = os.path.join(BASE, "TP2_LaPaz_informe.html")
PDF_OUT = os.path.join(BASE, "TP2_LaPaz_informe.pdf")
EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"

INTEGRANTES = ["Facundo Tomas Hernandes", "Maria Victorina Cabrera", "Facundo Thomas Ramirez", "Mariano Gervasoni"]

con = psycopg2.connect(host="localhost", dbname="tp2_bdg", user="postgres", password="1234")
con.autocommit = True
cur = con.cursor()
cur.execute("SET search_path = entrerios, public")


# ------------------------------------------------------------------ helpers
def q(sql):
    cur.execute(sql)
    return [d[0] for d in cur.description], cur.fetchall()


def v(sql):
    cur.execute(sql)
    return cur.fetchone()[0]


def num(x, dec=None):
    """Formato numérico argentino: 1.234,5"""
    if x is None:
        return "—"
    if isinstance(x, bool):
        return "Sí" if x else "No"
    if isinstance(x, (int,)) and dec is None:
        return f"{x:,}".replace(",", ".")
    try:
        f = float(x)
    except (TypeError, ValueError):
        return html.escape(str(x))
    if dec is None:
        dec = 0 if f.is_integer() else (1 if abs(f) >= 100 else 2)
    s = f"{f:,.{dec}f}"
    return s.replace(",", "X").replace(".", ",").replace("X", ".")


def tabla(sql, headers=None, caption=None, dec=None, clase=""):
    cols, rows = q(sql)
    headers = headers or cols
    out = [f'<table class="{clase}">']
    if caption:
        out.append(f"<caption>{caption}</caption>")
    out.append("<thead><tr>" + "".join(f"<th>{html.escape(h)}</th>" for h in headers) + "</tr></thead><tbody>")
    for r in rows:
        tds = []
        for c in r:
            es_num = isinstance(c, (int, float)) or type(c).__name__ == "Decimal"
            tds.append(f'<td class="{"n" if es_num else ""}">{num(c, dec) if es_num or isinstance(c, bool) else html.escape("" if c is None else str(c))}</td>')
        out.append("<tr>" + "".join(tds) + "</tr>")
    out.append("</tbody></table>")
    return "\n".join(out)


def mapa(nombre, pie):
    ruta = os.path.join(BASE, "mapas", nombre + ".png")
    if not os.path.exists(ruta):
        return f'<p class="falta">[Mapa {nombre} no generado]</p>'
    return f'<figure><img src="mapas/{nombre}.png"><figcaption>{pie}</figcaption></figure>'


def code(txt):
    return f"<pre><code>{html.escape(txt.strip())}</code></pre>"


# ------------------------------------------------------------------ datos clave
LP = "(SELECT id FROM departamentos WHERE nombre = 'La Paz')"
sup_lp = v("SELECT ST_Area(geom_m)/1e6 FROM departamentos WHERE nombre='La Paz'")
n_loc_lp = v(f"SELECT count(*) FROM localidades WHERE id_depto = {LP}")
n_sal_lp = v(f"SELECT count(*) FROM salud WHERE id_depto = {LP}")
n_hosp_lp = v(f"SELECT count(*) FROM salud WHERE id_depto={LP} AND tipo='hospital'")
n_clin_lp = v(f"SELECT count(*) FROM salud WHERE id_depto={LP} AND tipo='clinic'")
vecinos = v("SELECT string_agg(vecino || ' (' || replace(limite_km::text, '.', ',') || ' km)', ', ' ORDER BY limite_km DESC) FROM r7_vecinos")
agua = q("SELECT * FROM r7_superficie_agua")[1][0]
rank_lp = q("SELECT ranking, cant_lagunas FROM r7_ranking_agua WHERE nombre='La Paz'")[1][0]
cursos_tot = v("SELECT sum(longitud_m) FROM r7_cursos_agua")
cursos_nom = v("SELECT count(*) FROM r7_cursos_agua WHERE nombre <> '(sin nombre)'")
km_rutas = v("SELECT sum(km) FROM r8_rutas_lapaz")
lejana = q("SELECT nombre, distancia_m, salud_mas_cercana FROM r8_dist_localidad_salud ORDER BY ranking_lejania LIMIT 1")[1][0]
sin_cob = v("SELECT count(*) FROM r8_localidades_sin_cobertura")
sin_cob_n = v("SELECT string_agg(nombre, ' y ' ORDER BY distancia_m DESC) FROM r8_localidades_sin_cobertura")
pct_cub = v("SELECT 100*ST_Area(ST_Intersection(c.geom_m,d.geom_m))/ST_Area(d.geom_m) FROM r8_cobertura_5km c, departamentos d WHERE d.nombre='La Paz'")
zrh = q("SELECT ST_Area(z.geom_m)/1e6, 100*ST_Area(z.geom_m)/ST_Area(d.geom_m), ST_Area(z.geom_m_principal)/1e6, 100*ST_Area(z.geom_m_principal)/ST_Area(d.geom_m) FROM zona_riesgo_hidrico z JOIN departamentos d ON d.id=z.id_depto WHERE z.depto='La Paz'")[1][0]
sal_exp = v("SELECT count(*) FROM r9_salud_expuesta")
n_sup30 = v("SELECT count(*) FROM r9_exposicion_deptos WHERE supera_30")
n_sup30p = v("SELECT count(*) FROM r9_exposicion_deptos WHERE supera_30_principal")
no_sup30p = v("SELECT string_agg(nombre, ', ') FROM r9_exposicion_deptos WHERE NOT supera_30_principal")
riesgo_alto = v('SELECT count(*) FROM localidades l CROSS JOIN LATERAL fn_riesgo_localidad(l.nombre) r WHERE r.osm_id=l.osm_id AND r.riesgo=$$Alto$$')
n_loc_prov = v('SELECT count(*) FROM localidades')
mbr = q("SELECT ST_Area(m.geom::geography)/1e6, ST_Area(p.geom::geography)/1e6 FROM r10_mbr m, provincia p")[1][0]
sup_prov_5347 = v("SELECT ST_Area(ST_Transform(geom,5347))/1e6 FROM provincia")
suma_deptos = v("SELECT sum(ST_Area(geom_m))/1e6 FROM departamentos")
calles = q("SELECT lp.km_calles, avg(t.km_calles), lp.densidad_km_km2, avg(t.densidad_km_km2) FROM r11_calles_depto t, r11_calles_depto lp WHERE lp.nombre='La Paz' GROUP BY 1,3")[1][0]
dens_top = q("SELECT localidad, densidad_km_km2, km_calles, sup_km2 FROM r11_densidad_localidad ORDER BY densidad_km_km2 DESC LIMIT 1")[1][0]
puentes = q("SELECT count(*), sum(largo_m) FROM r11_puentes")[1][0]
pct_agri = q("SELECT 100*sum(ST_Area(geom_m)) FILTER (WHERE ipc>=30)/sum(ST_Area(geom_m)), 100*sum(ST_Area(geom_m)) FILTER (WHERE ipc>=20)/sum(ST_Area(geom_m)), 100*sum(ST_Area(geom_m)) FILTER (WHERE ipc>=40)/sum(ST_Area(geom_m)) FROM r12_suelo_lapaz")[1][0]
agri_exp = q("SELECT sum(ST_Area(e.geom_m))/1e6, 100*sum(ST_Area(e.geom_m))/(SELECT sum(ST_Area(geom_m)) FROM r12_suelo_lapaz WHERE clase='Agrícola') FROM r12_agricola_expuesta e")[1][0]
corte = q("SELECT count(*) FILTER (WHERE cortado), sum(largo_m) FILTER (WHERE cortado)/1000, 100*sum(largo_m) FILTER (WHERE cortado)/sum(largo_m), count(*), sum(largo_m)/1000 FROM red_vial")[1][0]
mejor = q("SELECT ranking, lat, lon, localidad_ref, dist_localidad_m, ruta, dist_ruta_m, libre_km2, puntaje, localidades_45min FROM r14_mejores ORDER BY ranking")[1]
celdas = q("SELECT (SELECT count(*) FROM r14_grilla), (SELECT count(*) FROM r14_aptas)")[1][0]

hoy = datetime.date.today().strftime("%d/%m/%Y")

# ------------------------------------------------------------------ HTML
H = []
H.append("""<!doctype html><html lang="es"><head><meta charset="utf-8">
<title>TP2 BDG 2026 - La Paz</title>
<style>
@page { size: A4; margin: 18mm 16mm 18mm 16mm; }
body { font-family: Calibri, 'Segoe UI', Arial, sans-serif; font-size: 10.5pt; color: #1b1b1b; line-height: 1.38; }
h1 { font-size: 19pt; color: #1f3864; border-bottom: 2px solid #1f3864; padding-bottom: 3px; margin-top: 0; page-break-before: always; }
h1.noquiebre { page-break-before: avoid; }
h2 { font-size: 14pt; color: #1f3864; margin: 18px 0 6px; }
h3 { font-size: 12pt; color: #2e5597; margin: 14px 0 4px; }
p { margin: 5px 0 8px; text-align: justify; }
table { border-collapse: collapse; margin: 6px 0 10px; font-size: 9pt; width: auto; page-break-inside: avoid; }
caption { caption-side: top; text-align: left; font-weight: bold; font-size: 9pt; color: #444; padding-bottom: 2px; }
th { background: #1f3864; color: #fff; padding: 3px 6px; text-align: left; }
td { border-bottom: 1px solid #d9d9d9; padding: 2px 6px; vertical-align: top; }
td.n { text-align: right; font-variant-numeric: tabular-nums; }
tr:nth-child(even) td { background: #f4f6fa; }
figure { margin: 8px 0 12px; page-break-inside: avoid; text-align: center; }
figure img { width: 100%; border: 1px solid #bbb; }
figcaption { font-size: 8.5pt; color: #555; margin-top: 2px; }
pre { background: #f6f8fa; border: 1px solid #e1e4e8; border-left: 3px solid #2e5597; padding: 6px 8px; font-size: 7.6pt; white-space: pre-wrap; }
code { font-family: Consolas, 'Courier New', monospace; }
.nota { border-left: 3px solid #c55a11; background: #fdf3ec; padding: 5px 10px; margin: 8px 0; }
.portada { text-align: center; padding-top: 40mm; }
.portada h1 { border: none; font-size: 24pt; page-break-before: avoid; }
.portada .sub { font-size: 15pt; color: #2e5597; margin: 6px 0; }
.portada .dato { font-size: 12pt; margin: 4px 0; text-align: center; }
.indice li { margin: 2px 0; }
.falta { color: #c00; }
</style></head><body>
""")

# ---------------- portada
H.append(f"""
<div class="portada">
<p class="dato"><b>UNIVERSIDAD AUTÓNOMA DE ENTRE RÍOS</b></p>
<p class="dato">Facultad de Ciencia y Tecnología — Licenciatura en Sistemas de Información</p>
<p class="dato">Cátedra: Bases de Datos Avanzadas (4º año)</p>
<br><br>
<h1>Trabajo Práctico Nº 2<br>Bases de Datos Geográficas</h1>
<p class="sub">Riesgo Hídrico y Accesibilidad Sanitaria en Entre Ríos</p>
<br>
<p class="dato">Departamento de referencia: <b>La Paz</b></p>
<p class="dato">Localidad de referencia: <b>La Paz</b></p>
<br><br>
<p class="dato">Docentes: Lic. Sebastián Trossero — Ing. Jorge Schmukler</p>
<p class="dato">Integrantes: {" — ".join(INTEGRANTES)}</p>
<p class="dato">Fecha: {hoy}</p>
</div>
""")

# ---------------- índice
H.append("""
<h1>Índice</h1>
<ol class="indice">
<li>Introducción y área de estudio</li>
<li>Fuentes, herramientas y sistema de referencia</li>
<li>Construcción de la base de datos espacial (punto 6)</li>
<li>Hidrografía y características del departamento (punto 7)</li>
<li>Rutas y accesibilidad sanitaria (punto 8)</li>
<li>Gestión del riesgo hídrico (punto 9)</li>
<li>Funciones y automatización mediante SQL (punto 10)</li>
<li>Calles, OpenStreetMap y Argenmap (punto 11)</li>
<li>Información del INTA y uso del suelo (punto 12)</li>
<li>Consulta agregada: escenario de crecida (punto 13)</li>
<li>Problema: ubicación de un Centro de Atención Sanitaria de Emergencia (punto 14)</li>
<li>Conclusiones y limitaciones</li>
<li>Anexo: entregables y reproducción</li>
</ol>
""")

# ---------------- 1
H.append(f"""
<h1>1. Introducción y área de estudio</h1>
<p>En este trabajo construimos una base de datos espacial en PostgreSQL/PostGIS para analizar la relación entre
la red hídrica, la red vial, las localidades y los establecimientos de salud del departamento <b>La Paz</b>,
en el noroeste de Entre Ríos. Algunos análisis se extienden a toda la provincia para poder comparar.</p>
<p>Con <b>{num(sup_lp, 0)} km²</b> según el IGN, La Paz es el segundo departamento más extenso de la provincia,
después de Gualeguaychú. Limita al oeste con el río Paraná (y la provincia de Santa Fe), al norte con el río Guayquiraró (y Corrientes)
y, dentro de la provincia, con {vecinos}. En OpenStreetMap tiene <b>{n_loc_lp} localidades</b> y
<b>{n_sal_lp} establecimientos de salud</b>. Lo cruzan arroyos importantes (Feliciano, Estacas, Alcaraz, Hernandarias),
lo que lo convierte en un buen caso para estudiar riesgo hídrico y accesibilidad.</p>
<p>La idea que guió el trabajo fue que cada consulta respondiera una pregunta concreta, de las que podría hacerse
alguien de Defensa Civil o del hospital zonal durante una crecida, y no quedarse en el ejercicio técnico de aplicar
funciones espaciales. Por eso en cada punto, además del resultado y de cómo se calculó, discutimos qué dice
sobre el territorio y dónde el dato tiene limitaciones.</p>
{mapa("m06_datos", "Figura 1. Departamento La Paz: localidades, salud, rutas e hidrografía cargadas en PostGIS.")}
""")

# ---------------- 2
H.append(f"""
<h1>2. Fuentes, herramientas y sistema de referencia</h1>
<table><thead><tr><th>Fuente</th><th>Capa / servicio</th><th>Uso</th></tr></thead><tbody>
<tr><td>IGN</td><td>WFS <code>ign:departamento</code> (SHP, EPSG:4326, 17 departamentos de Entre Ríos)</td><td>departamentos, límites, superficies</td></tr>
<tr><td>IGN</td><td>Argenmap (TMS, EPSG:3857)</td><td>mapa base para visualizar y comparar (no se almacena)</td></tr>
<tr><td>OpenStreetMap</td><td>Extracto Geofabrik de Argentina (.osm.pbf), recortado a Entre Ríos con <code>ogr2ogr -spat</code></td><td>localidades, rutas, calles, ríos, lagunas, salud</td></tr>
<tr><td>INTA</td><td>WFS geo-nodo03: <i>Carta de Suelos de Entre Ríos 1:100.000</i></td><td>aptitud del suelo (índice de productividad)</td></tr>
</tbody></table>
<p>Para OpenStreetMap la consigna sugiere QuickOSM, que consulta la API Overpass. Mientras hacíamos el trabajo
el servidor principal de Overpass rechazaba las conexiones y los espejos devolvían <i>504 Gateway Timeout</i>,
porque la consulta de calles a escala provincial es grande. Como la consigna permite otro origen,
usamos el extracto diario de Geofabrik (son los mismos datos de OSM) y aplicamos los mismos filtros de etiquetas que
indica la consigna (<code>place</code>, <code>highway</code>, <code>waterway</code>, <code>natural=water</code>,
<code>amenity</code>), con un <code>osmconf.ini</code> propio para conservar <code>ref</code>, <code>bridge</code>,
<code>water</code> y <code>surface</code>.</p>
<p>En el caso del INTA, el WFS de la Región Entre Ríos publica <b>una sola capa vectorial</b>: la Carta de Suelos
1:100.000 (4.508 polígonos). No describe el <i>uso actual</i> del suelo sino su <i>aptitud</i>, a través del
<b>Índice de Productividad (IPC)</b> de cada unidad cartográfica. El punto 12 se resolvió con esa información
(los criterios están en la sección 9).</p>
<p>Las herramientas fueron PostgreSQL 18.3 con PostGIS 3.6.2 y pgRouting 4.0.1 (para los puntos 13 y 14), GDAL/ogr2ogr para la carga y
QGIS 3.44 para visualizar, componer y exportar los mapas.</p>

<h2>2.1 Sistema de referencia y cálculos métricos</h2>
<p>Los datos se almacenan en <b>EPSG:4326 (WGS84)</b>. Como los grados no son una unidad métrica, para
distancias, longitudes y superficies se reproyecta a <b>EPSG:5347 – POSGAR 2007 / Argentina faja 5</b>
(Gauss-Krüger, meridiano central −60°).</p>
<div class="nota">La elección de la faja importa. La Paz está entre −59,98° y −58,93° de longitud, a menos de 1,1° del
meridiano central de la faja 5, así que la deformación de escala es despreciable. El <b>EPSG:5343</b> que menciona la consigna como ejemplo
es la <b>faja 1</b> (meridiano −72°, en la cordillera): La Paz queda a unos 12° de su meridiano central y la proyección
introduce errores apreciables. Como control, la superficie provincial da <b>{num(mbr[1], 0)} km²</b> con
<code>geography</code> (elipsoide) y {num(sup_prov_5347, 0)} km² en EPSG:5347,
una diferencia menor al 0,03 %.</div>
<p>Para no repetir <code>ST_Transform</code> en cada consulta, cada tabla tiene una <b>columna generada</b>
<code>geom_m</code> en 5347, indexada con GiST:</p>
{code("geom_m geometry(MultiPolygon, 5347) GENERATED ALWAYS AS (ST_Transform(geom, 5347)) STORED")}
<p>La única excepción es <code>fn_hospital_cercano</code> (punto 10.3), que usa <code>geography</code> porque recibe una
coordenada arbitraria que puede estar en cualquier lugar.</p>
""")

# ---------------- 3 / punto 6
H.append(f"""
<h1>3. Construcción de la base de datos espacial (punto 6)</h1>
<p>La base <code>tp2_bdg</code> tiene las extensiones <code>postgis</code> y <code>pgrouting</code> y está organizada en dos esquemas.
En <code>fuentes</code> quedan las capas tal como se descargaron (cargadas con <code>ogr2ogr</code>), y en <code>entrerios</code>
las tablas depuradas, tipadas y recortadas a la provincia, más las tablas de resultados de cada punto (<code>r7_*</code> … <code>r14_*</code>).</p>
{code('''ogr2ogr -f PostgreSQL "PG:dbname=tp2_bdg user=postgres" departamentoPolygon.shp \\
        -nln ign_departamentos -lco SCHEMA=fuentes -lco GEOMETRY_NAME=geom \\
        -oo ENCODING=ISO-8859-1 -nlt PROMOTE_TO_MULTI
ogr2ogr -f PostgreSQL "PG:..." suelos.geojson -nln inta_suelos -lco SCHEMA=fuentes ...
ogr2ogr -f PostgreSQL "PG:..." entrerios_osm.gpkg lines -nln osm_lines -lco SCHEMA=fuentes ...''')}
<p>Tablas del esquema <code>entrerios</code> (las mínimas pedidas más algunas auxiliares):</p>
<table><thead><tr><th>Tabla</th><th>Origen y filtro</th><th>Decisiones</th></tr></thead><tbody>
<tr><td>departamentos</td><td>IGN, código INDEC 30xxx</td><td><code>ST_MakeValid</code>; contorno provincial auxiliar <code>provincia</code> = <code>ST_Union</code></td></tr>
<tr><td>localidades</td><td>OSM <code>place</code> = city, town, village</td><td>departamento por <code>ST_Within</code>; depuración de duplicados por Wikidata (ver abajo)</td></tr>
<tr><td>rutas</td><td>OSM <code>highway</code> = motorway, trunk, primary, secondary</td><td>jurisdicción derivada de <code>ref</code> (RN/RP); recorte a la provincia</td></tr>
<tr><td>rios</td><td>OSM <code>waterway</code> = river, stream</td><td>recorte a la provincia</td></tr>
<tr><td>lagunas</td><td>OSM <code>natural=water</code> (lake, pond, lagoon, oxbow, reservoir, sin subtipo)</td><td>se excluye <code>water=river</code> (cauces), que va a <code>rios_area</code></td></tr>
<tr><td>calles</td><td>OSM <code>highway</code> = primary, secondary, tertiary, residential, unclassified</td><td>marca de puente y superficie</td></tr>
<tr><td>salud</td><td>OSM <code>amenity</code> = hospital, clinic (puntos y polígonos)</td><td>polígono → <code>ST_PointOnSurface</code>; se descartan puntos dentro de un polígono de salud (duplicados)</td></tr>
<tr><td>suelo</td><td>INTA WFS Carta de Suelos</td><td>clase de aptitud según IPC (punto 12)</td></tr>
</tbody></table>
<p>Hubo dos decisiones de modelado que después pesaron en varios puntos. La primera fue qué contar como laguna.
OSM etiqueta con <code>natural=water</code> también el cauce de los ríos (<code>water=river</code>: el Paraná, el Guayquiraró,
los riachos del delta). En La Paz esos polígonos suman unos 144 km², contra {num(agua[1], 1)} km² de lagunas propiamente dichas;
si los dejábamos juntos, el Paraná dominaba cualquier indicador de agua y el ranking del punto 7.3 perdía sentido. Por eso los
separamos en una tabla aparte, <code>rios_area</code>, y en <code>lagunas</code> quedaron solo los polígonos con subtipo lake, pond,
lagoon, oxbow, reservoir o sin subtipo.</p>
<p>La segunda fue depurar una localidad duplicada. En OSM aparecen dos nodos «La Paz» dentro del departamento:
la ciudad (osm 198457357, <i>town</i>, 24.716 hab.) y un <i>village</i> de «500 hab.» ubicado 45 km al norte,
sobre la RN12. Los dos apuntan al mismo objeto de Wikidata (<b>Q2440276</b>), así que el segundo es un nodo duplicado y mal
ubicado. En lugar de borrarlo a mano lo eliminamos con una regla general: si dos localidades comparten Wikidata se conserva la de mayor
jerarquía. Sin esta depuración el nodo falso aparecía como la localidad más alejada de un servicio de salud (8.4) y corría la ubicación
propuesta en el punto 14, como se cuenta al final del informe.</p>

<h2>3.1 Controles de calidad de la importación</h2>
<p>Para no revisar tabla por tabla escribimos <code>fn_control_calidad()</code>, que recorre <code>geometry_columns</code> y arma
dinámicamente, con <code>format()</code> y <code>EXECUTE</code>, una consulta por tabla que compara el tipo de geometría declarado
con el real (<code>ST_GeometryType</code>), el SRID declarado con el real (<code>ST_SRID</code>), y cuenta registros, geometrías nulas,
vacías (<code>ST_IsEmpty</code>) e inválidas (<code>ST_IsValid</code>):</p>
{code('''CREATE OR REPLACE FUNCTION entrerios.fn_control_calidad()
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

SELECT * FROM entrerios.fn_control_calidad();''')}
{tabla("SELECT tabla, tipo_declarado, tipos_reales, srid_declarado, srids_reales, registros, nulas, vacias, invalidas FROM fn_control_calidad() WHERE tabla IN ('calles','departamentos','lagunas','localidades','provincia','rios','rios_area','rutas','salud','suelo')",
       ["Tabla", "Tipo declarado", "Tipo real", "SRID decl.", "SRID real", "Registros", "Nulas", "Vacías", "Inválidas"])}
<p>Las tablas depuradas no tienen geometrías inválidas porque la corrección se hizo durante la carga. En las <b>fuentes crudas</b> sí había,
y se repararon con <code>ST_MakeValid</code>:</p>
{code('''SELECT 'ign_departamentos' AS fuente, count(*) FILTER (WHERE NOT ST_IsValid(geom)) AS invalidas
FROM fuentes.ign_departamentos
UNION ALL
SELECT 'osm_multipolygons (natural=water)', count(*) FILTER (WHERE NOT ST_IsValid(geom))
FROM fuentes.osm_multipolygons WHERE "natural" = 'water'
UNION ALL
SELECT 'inta_suelos', count(*) FILTER (WHERE NOT ST_IsValid(geom))
FROM fuentes.inta_suelos;

SELECT osm_id, name, ST_IsValidReason(geom) AS motivo
FROM fuentes.osm_multipolygons
WHERE "natural" = 'water' AND NOT ST_IsValid(geom) LIMIT 10;

UPDATE entrerios.lagunas   SET geom = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3)) WHERE NOT ST_IsValid(geom);
UPDATE entrerios.rios_area SET geom = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3)) WHERE NOT ST_IsValid(geom);''')}
{tabla("""SELECT 'IGN departamentos' f, count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM fuentes.ign_departamentos
UNION ALL SELECT 'OSM natural=water', count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM fuentes.osm_multipolygons WHERE "natural"='water'
UNION ALL SELECT 'INTA suelos', count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM fuentes.inta_suelos""", ["Fuente", "Inválidas"])}
{tabla("SELECT ST_IsValidReason(geom) FROM fuentes.osm_multipolygons WHERE \"natural\"='water' AND NOT ST_IsValid(geom) LIMIT 3", ["Ejemplo de motivo (ST_IsValidReason)"])}
<p>Los polígonos de agua inválidos son <i>auto-intersecciones</i> en el borde del rectángulo de recorte de OSM (longitud −60,85°,
latitudes −34,1° y −30,1°): son polígonos cortados que quedan fuera de la provincia. Los 7 polígonos del INTA tienen
anillos que se cruzan a sí mismos y quedaron reparados. Como control topológico adicional verificamos que la suma de las superficies departamentales
({num(suma_deptos, 1)} km²) coincide con el área del contorno provincial
({num(sup_prov_5347, 1)} km²), o sea que no hay superposiciones ni huecos entre departamentos. También hicimos el control
puntual que pide la consigna, con <code>ST_GeometryType</code> y <code>ST_SRID</code> sobre los departamentos:</p>
{code('''SELECT nombre, ST_GeometryType(geom) AS tipo, ST_SRID(geom) AS srid,
       ST_IsValid(geom) AS valida, ST_NPoints(geom) AS vertices
FROM entrerios.departamentos ORDER BY nombre;''')}
""")

# ---------------- 4 / punto 7
H.append(f"""
<h1>4. Hidrografía y características del departamento (punto 7)</h1>

<h3>7.1 Departamentos vecinos</h3>
<p>La Paz limita con cuatro departamentos entrerrianos: {vecinos}. Para encontrarlos usamos <code>ST_Intersects</code>
entre el polígono de La Paz y el resto, y después medimos la longitud del límite compartido con <code>ST_Intersection</code>
de los <code>ST_Boundary</code>, para descartar los contactos que se dan en un solo punto. Un detalle que vale la pena contar es que
<code>ST_Touches</code> da verdadero solo para Paraná y Villaguay: en los otros límites los vértices del IGN no coinciden
exactamente y hay superposiciones de milímetros, así que no conviene depender de un único predicado topológico estricto.
Federal es el vecino con el que más límite se comparte. Además de estos cuatro, el departamento limita con Santa Fe (por el Paraná)
y con Corrientes (por el Guayquiraró), que no forman parte de la capa provincial.</p>
{tabla("SELECT vecino, touches, limite_km FROM r7_vecinos ORDER BY limite_km DESC", ["Vecino", "ST_Touches", "Límite (km)"])}

<h3>7.2 Frontera común</h3>
<p>La frontera con cada vecino se guardó como MultiLineString en <code>r7_frontera</code>, calculada con
<code>ST_LineMerge(ST_CollectionExtract(ST_Intersection(ST_Boundary(a.geom), ST_Boundary(b.geom)), 2))</code>, para poder dibujarla
en QGIS (Figura 2). La más larga es la frontera con Federal, y un 85 % de su recorrido pasa a menos de 300 m de un arroyo
(Feliciano, Estacas, del Yeso, Don Gonzalo y otros): los límites departamentales se trazaron siguiendo la red de drenaje.
Para el riesgo hídrico esto tiene una consecuencia práctica, porque casi cualquier paso entre La Paz y sus vecinos es un cruce de agua.</p>
{tabla("""SELECT f.frontera, ST_GeometryType(f.geom), round((ST_Length(f.geom::geography)/1000)::numeric,1),
       round((100*ST_Length(ST_Intersection(ST_Transform(f.geom,5347), ST_Buffer(ST_Collect(r.geom_m),300)))/ST_Length(ST_Transform(f.geom,5347)))::numeric,1)
FROM r7_frontera f JOIN rios r ON ST_DWithin(r.geom_m, ST_Transform(f.geom,5347), 300)
GROUP BY f.frontera, f.geom ORDER BY 3 DESC""", ["Frontera", "Tipo", "km", "% a ≤300 m de un curso de agua"])}
{mapa("m07_vecinos_frontera", "Figura 2. Departamentos vecinos y fronteras comunes.")}

<h3>7.3 Presencia de cuerpos de agua (ranking provincial)</h3>
<p>En el ranking provincial de cuerpos de agua La Paz ocupa el puesto <b>{rank_lp[0]}</b> de 17, con <b>{rank_lp[1]}</b> lagunas.
Cada laguna se asignó a un solo departamento con <code>ST_Within(ST_PointOnSurface(laguna), depto)</code>, para no
contar dos veces las que cruzan un límite, y además de la cantidad calculamos la superficie y la densidad cada 100 km².</p>
<p>Este ranking hay que leerlo con cuidado, porque la fuente tiene varias limitaciones. OSM es colaborativo y su completitud depende
de quién mapeó cada zona: Federación encabeza la lista por la cantidad de pequeños estanques y tajamares que alguien cargó, no necesariamente
por tener más agua. La cantidad tampoco mide importancia (Victoria tiene menos lagunas que Federación pero diez veces su superficie,
por las lagunas del delta), y una laguna grande puede estar partida en varios polígonos o cargada como uno solo. En La Paz, el 90 % de los
polígonos no tiene subtipo <code>water</code> ni nombre, así que no se puede distinguir una laguna natural de una represa. Y las lagunas
temporarias cambian con el régimen de lluvias, mientras que OSM refleja la imagen satelital que se usó al mapear.</p>
{tabla("SELECT ranking, nombre, cant_lagunas, sup_lagunas_km2, lagunas_c100km2 FROM r7_ranking_agua ORDER BY ranking, nombre",
       ["#", "Departamento", "Cantidad", "Superficie (km²)", "Cada 100 km²"])}
{mapa("m07_ranking_lagunas", "Figura 3. Cantidad de lagunas por departamento (cortes de Jenks).")}

<h3>7.4 Superficie cubierta por agua</h3>
<p>La superficie total del departamento es de {num(agua[0], 2)} km², de los cuales {num(agua[1], 2)} km² ({num(agua[3], 2)} %) están
cubiertos por lagunas y el resto, {num(agua[2], 2)} km², es tierra firme. Si se suman los cauces del Paraná y sus riachos, el agua llega a
{num(agua[4], 2)} km² ({num(agua[5], 2)} %). Para calcularlo intersectamos cada polígono de agua con el departamento
(<code>ST_Intersection</code>), disolvimos el resultado con <code>ST_Union</code> para no contar superposiciones y medimos con
<code>ST_Area</code> en EPSG:5347, dividiendo por 10⁶. Lo que queda claro es que el agua <i>permanente</i> ocupa una fracción mínima
del territorio: el riesgo hídrico de La Paz no está en sus lagunas sino en los desbordes de los arroyos y del Paraná, y por eso en el
punto 9 trabajamos con zonas de influencia y no solo con los espejos de agua.</p>
{tabla("SELECT sup_total_km2, sup_lagunas_km2, sup_restante_km2, pct_lagunas, sup_agua_con_cauces_km2, pct_agua_con_cauces FROM r7_superficie_agua",
       ["Total km²", "Lagunas km²", "Restante km²", "% lagunas", "Agua c/cauces km²", "% c/cauces"])}

<h3>7.5 Cursos de agua</h3>
<p>Dentro del departamento hay {cursos_nom} cursos de agua con nombre y {num(cursos_tot, 0)} m (unos {num(cursos_tot/1000, 0)} km) de ríos y
arroyos en total. La longitud se calculó con <code>ST_Length(ST_Intersection(rio.geom_m, depto.geom_m))</code>, agrupando por nombre
porque en OSM un mismo arroyo está partido en muchos <i>ways</i>. El arroyo Feliciano es el eje hídrico interno más importante, con unos
158 km dentro del departamento. Llama la atención que la mitad de la longitud corresponda a cursos sin nombre: la red de drenaje es muy
densa, y eso explica la extensión que alcanza la zona de riesgo del punto 9.</p>
{tabla("SELECT nombre, tipo, tramos, longitud_m FROM r7_cursos_agua ORDER BY longitud_m DESC LIMIT 15",
       ["Curso", "Tipo OSM", "Tramos", "Longitud (m)"], caption="Los 15 cursos más largos dentro de La Paz")}
{mapa("m07_cursos_agua", "Figura 4. Cursos y cuerpos de agua del departamento.")}
""")

# ---------------- 5 / punto 8
H.append(f"""
<h1>5. Rutas y accesibilidad sanitaria (punto 8)</h1>

<h3>8.1 y 8.2 Red vial principal y longitud de las rutas</h3>
<p>Atraviesan el departamento dos rutas nacionales (RN12 y RN127) y las provinciales RP1 y RP6, más los accesos RPA01 a RPA03;
en total son {num(km_rutas, 1)} km de red principal. La selección se hizo con el filtro <code>highway</code> = motorway/trunk/primary/secondary,
la jurisdicción se derivó del tag <code>ref</code> (RN o RP) y los kilómetros salen de
<code>ST_Length(ST_Intersection(ruta.geom_m, depto.geom_m))/1000</code> agrupado por ruta. La RN12 es la columna vertebral del
departamento: lo recorre de sur a norte y concentra el 40 % de los kilómetros. Los ~30 km que figuran «sin ref» son tramos
<i>secondary</i> a los que nadie les cargó el número en OSM, un problema de completitud de la fuente más que del análisis.</p>
{tabla("SELECT ref, jurisdiccion, categoria_osm, km FROM r8_rutas_lapaz ORDER BY km DESC", ["Ruta", "Jurisdicción", "Categoría OSM", "km"])}
{mapa("m08_rutas", "Figura 5. Red vial principal por jurisdicción.")}

<h3>8.3 Establecimientos de salud y distribución espacial</h3>
<p>En OSM figuran {n_sal_lp} establecimientos de salud en La Paz: {n_hosp_lp} hospitales y {n_clin_lp} clínicas o consultorios.
A cada uno le asignamos la localidad más cercana con el operador KNN (<code>&lt;-&gt;</code>) y calculamos la distancia al
establecimiento vecino más próximo. La distribución resulta claramente concentrada: todos están dentro o en el borde de una localidad
(la mediana de distancia entre vecinos es de unos 400 m) y la ciudad de La Paz reúne seis. El espacio rural entre localidades no tiene
ninguna oferta. Con 22,6 establecimientos cada 10.000 km², el departamento está en el puesto 7 de 17, muy lejos de Paraná (105,8).</p>
{tabla("SELECT localidad, count(*), count(*) FILTER (WHERE tipo='hospital'), count(*) FILTER (WHERE tipo='clinic') FROM r8_salud_lapaz GROUP BY 1 ORDER BY 2 DESC",
       ["Localidad", "Total", "Hospitales", "Clínicas"])}

<h3>8.4 Localidad más alejada</h3>
<p>La localidad más alejada de un servicio de salud es <b>{lejana[0]}</b>, a {num(lejana[1], 0)} m de «{lejana[2]}». El criterio
que adoptamos fue la distancia euclídea en EPSG:5347 desde el punto de la localidad hasta el establecimiento más cercano, buscado
<i>en toda la provincia</i>, porque una persona que vive en el borde del departamento puede atenderse en el vecino. La búsqueda usa KNN
(<code>ORDER BY s.geom_m &lt;-&gt; l.geom_m LIMIT 1</code>) dentro de un <code>CROSS JOIN LATERAL</code>; también calculamos la variante
«solo hospitales», y la distancia por red vial se trata en el punto 13. Las localidades sin oferta propia, Colonia Avigdor y Sir Leonard,
dependen de otra localidad. En el caso de Colonia Avigdor, por red vial el hospital más cercano está en <i>otro departamento</i>
(Hospital Crispín Velázquez, en Federal; ver punto 13).</p>
{tabla("SELECT ranking_lejania, nombre, poblacion, salud_mas_cercana, tipo_salud, distancia_m FROM r8_dist_localidad_salud ORDER BY ranking_lejania",
       ["#", "Localidad", "Población", "Establecimiento más cercano", "Tipo", "Distancia (m)"])}

<h3>8.5 Área de cobertura sanitaria (5 km)</h3>
<p>De las {n_loc_lp} localidades del departamento, <b>{sin_cob}</b> quedan fuera de la cobertura de 5 km: {sin_cob_n}.
La cobertura se construyó con <code>ST_Union(ST_Buffer(s.geom_m, 5000))</code> sobre los establecimientos a menos de 5 km del
departamento (incluyendo los de los vecinos), y las localidades sin cobertura salen de un
<code>NOT EXISTS (… ST_Intersects(cobertura, localidad))</code>. El área cubierta abarca solo el {num(pct_cub, 1)} % del territorio
departamental. Las localidades que quedan afuera son las más chicas y rurales: ahí la atención depende de traslados largos por caminos
de tierra que, como se ve en el punto 9, cruzan arroyos. Y el 92 % del territorio, donde vive la población rural dispersa, está a más de
5 km de cualquier servicio de salud.</p>
{tabla("SELECT nombre, poblacion, distancia_m FROM r8_localidades_sin_cobertura ORDER BY distancia_m DESC", ["Localidad", "Población", "Distancia al más cercano (m)"])}
{mapa("m08_cobertura", "Figura 6. Cobertura de 5 km alrededor de los establecimientos de salud.")}
""")

# ---------------- 6 / punto 9
H.append(f"""
<h1>6. Gestión del riesgo hídrico (punto 9)</h1>

<h3>9.1 Zona de Riesgo Hídrico (ZRH)</h3>
<p>La Zona de Riesgo Hídrico de La Paz ocupa <b>{num(zrh[0], 1)} km², el {num(zrh[1], 1)} %</b> del departamento. También calculamos una
variante «principal», sin los arroyos menores (<code>stream</code>), que da {num(zrh[2], 1)} km² ({num(zrh[3], 1)} %). Para cada departamento
se toman los elementos hídricos a menos de 2 km (<code>ST_DWithin</code>, que aprovecha el índice), se simplifican a 25 m con
<code>ST_Simplify</code>, se les aplica un <code>ST_Buffer</code> de 2.000 m, se disuelven con <code>ST_Union</code> y se recortan con
<code>ST_Intersection</code>. La simplificación no es un detalle menor: la primera versión, con el buffer sobre la colección completa,
tardaba más de 10 minutos por la cantidad de vértices; con un buffer de 2 km el detalle de 25 m es irrelevante y el cálculo bajó a
segundos por departamento.</p>
<p>Con una red de drenaje tan densa, un buffer de 2 km cubre casi dos tercios del territorio. Es una simplificación académica, que no
reemplaza un mapa oficial de inundación, y su resultado depende mucho de qué tan detallado esté mapeado OSM; por eso trabajamos con
las dos variantes a lo largo del informe.</p>
{code('''INSERT INTO entrerios.zona_riesgo_hidrico (id_depto, depto, geom_m, geom_m_principal)
SELECT d.id, d.nombre,
       ST_Multi(ST_CollectionExtract(ST_Intersection(
           ST_Union(ST_Buffer(ST_Simplify(h.g, 25), 2000, 4)), d.geom_m), 3)),
       ST_Multi(ST_CollectionExtract(ST_Intersection(
           ST_Union(ST_Buffer(ST_Simplify(h.g, 25), 2000, 4)) FILTER (WHERE h.principal), d.geom_m), 3))
FROM entrerios.departamentos d
CROSS JOIN LATERAL (
    SELECT r.geom_m AS g, r.tipo = 'river' AS principal FROM entrerios.rios r
     WHERE ST_DWithin(r.geom_m, d.geom_m, 2000)
    UNION ALL SELECT l.geom_m, true FROM entrerios.lagunas l   WHERE ST_DWithin(l.geom_m, d.geom_m, 2000)
    UNION ALL SELECT a.geom_m, true FROM entrerios.rios_area a WHERE ST_DWithin(a.geom_m, d.geom_m, 2000)
) h GROUP BY d.id;''')}
{mapa("m09_zrh", "Figura 7. Zona de Riesgo Hídrico (2 km) y establecimientos de salud expuestos. Se rotulan solo los hospitales; el detalle completo está en la tabla 9.2.")}

<h3>9.2 Infraestructura sanitaria expuesta</h3>
<p>Los <b>{sal_exp} establecimientos</b> de salud del departamento, es decir todos, están dentro de la ZRH. Se detectaron con
<code>ST_Intersects(zrh.geom_m, salud.geom_m)</code> y para cada uno buscamos el elemento hídrico más cercano con KNN sobre ríos, lagunas y
cauces. El resultado no sorprende si se piensa en cómo se fundaron las localidades de La Paz: junto al Paraná o a un arroyo, por el agua
para consumo, los puertos y los molinos. En la práctica la amenaza no es igual para todos (los de la ciudad de La Paz están sobre la
barranca, bien por encima del nivel del río), pero el dato indica que ante una crecida ningún establecimiento puede considerarse a salvo
del aislamiento, y que hay que planificar su acceso y abastecimiento (puntos 9.3 y 13).</p>
{tabla("SELECT nombre, tipo, agua_cercana, dist_agua_m FROM r9_salud_expuesta ORDER BY dist_agua_m", ["Establecimiento", "Tipo", "Agua más cercana", "Distancia (m)"])}

<h3>9.3 Posibles situaciones de aislamiento</h3>
<p>Para detectar posibles situaciones de aislamiento armamos una clasificación ALTO/MEDIO/BAJO por localidad y un inventario de cruces
entre la red vial principal y los cursos de agua. Para cada localidad buscamos el punto más cercano de la red RN/RP con
<code>ST_ClosestPoint</code> y construimos el conector localidad→ruta con <code>ST_MakeLine</code>; si ese conector cruza un río o arroyo
(<code>ST_Intersects</code>), la salida a la red principal depende de un puente o una alcantarilla. Después medimos qué proporción de las
vías a menos de 5 km (<code>ST_DWithin</code>) cae dentro de la ZRH. El riesgo es ALTO si se cumplen las dos condiciones (cruce de agua y más
del 50 % de las vías en ZRH) y MEDIO si se cumple una sola. Por último calculamos los puntos de cruce ruta × curso de agua
(<code>ST_Intersection</code> seguido de <code>ST_Dump</code>) y verificamos si OSM registra un puente a menos de 50 m.</p>
<p>Piedras Blancas, Colonia Avigdor y Sir Leonard llegan a la red principal cruzando arroyos (Hernandarias, Macieguitas): una crecida
puede dejarlas sin salida. La ciudad de La Paz también aparece en ALTO porque su conector cruza los arroyos urbanos Cabayú Cutiá y
Los Paraísos; en su caso el riesgo real es menor, porque tiene varios accesos y puentes urbanos, y ahí se ve la limitación de usar un
único conector en línea recta. Sobre la RN12 contamos 44 cruces con cursos de agua y en 29 OSM no registra puente: pueden ser alcantarillas
(un punto débil real ante crecidas) o puentes que nadie cargó, que es una limitación de la fuente (ver 11.4).</p>
{tabla("SELECT localidad, poblacion, ruta_mas_cercana, dist_ruta_m, cruces_agua, cursos_cruzados, pct_vias_entorno_en_zrh, riesgo_aislamiento FROM r9_aislamiento ORDER BY riesgo_aislamiento, pct_vias_entorno_en_zrh DESC",
       ["Localidad", "Pobl.", "Ruta", "Dist. (m)", "Cruces", "Cursos cruzados", "% vías en ZRH", "Riesgo"])}
{tabla("SELECT ruta, count(*), count(*) FILTER (WHERE puente_osm), count(*) FILTER (WHERE NOT puente_osm) FROM r9_cruces_ruta_agua GROUP BY ruta ORDER BY 2 DESC",
       ["Ruta", "Cruces", "Con puente OSM", "Sin puente registrado"])}
{mapa("m09_aislamiento", "Figura 8. Riesgo de aislamiento, conectores y cruces de agua.")}

<h3>9.4 Departamentos con mayor exposición (umbral 30 %)</h3>
<p>Con la ZRH completa, <b>{n_sup30} de los 17</b> departamentos superan el umbral del 30 %; con la variante principal lo superan {n_sup30p}
(queda por debajo {no_sup30p}). El cálculo es <code>ST_Area(zrh)/ST_Area(depto)</code> para cada departamento, junto con el porcentaje de
cuerpos de agua (lagunas más cauces, unidos). Lo que muestra la tabla es que el umbral del 30 % no discrimina: con un buffer de 2 km
sobre la red de drenaje de OSM, toda Entre Ríos queda «expuesta», y para priorizar haría falta un criterio más fino, como la cota, los
suelos hidromórficos o la recurrencia de crecidas. Diamante y Victoria encabezan la lista por el delta y las islas del Paraná. La Paz queda
en el puesto 14: tiene mucha agua en el borde (Paraná y Guayquiraró), pero en su interior la red de cursos mapeados es menos densa que en
el sur y el este de la provincia.</p>
{tabla("SELECT ranking, nombre, sup_km2, pct_agua, pct_zrh, supera_30, pct_zrh_principal, supera_30_principal FROM r9_exposicion_deptos ORDER BY ranking",
       ["#", "Departamento", "km²", "% agua", "% ZRH", "≥30 %", "% ZRH princ.", "≥30 % princ."])}
{mapa("m09_exposicion", "Figura 9. Porcentaje de superficie en ZRH por departamento.")}
""")

# ---------------- 7 / punto 10
H.append(f"""
<h1>7. Funciones y automatización mediante SQL (punto 10)</h1>

<h3>10.1 fn_riesgo_localidad(nombre_localidad)</h3>
<p>La función devuelve, para la localidad pedida, el elemento hídrico más cercano, la distancia y la clase de riesgo: Alto si está a
menos de 1 km, Medio entre 1 y 3 km y Bajo a más de 3 km. Internamente hace tres búsquedas KNN (<code>&lt;-&gt;</code>), sobre ríos,
lagunas y cauces, y se queda con la menor de las tres distancias. Devuelve una fila por cada homónimo, con el departamento y el
<code>osm_id</code>, y la búsqueda ignora mayúsculas y tildes, así «concordia» o «Parana» también funcionan. Al aplicarla a toda la
provincia, {riesgo_alto} de {n_loc_prov} localidades quedan en riesgo Alto, lo cual es coherente con 9.4: casi todos los pueblos entrerrianos
están a menos de 1 km de algún curso de agua. La clasificación por distancia sirve como primer filtro, pero no reemplaza un análisis de cota.</p>
{code('''CREATE OR REPLACE FUNCTION entrerios.fn_riesgo_localidad(nombre_localidad text)
RETURNS TABLE (localidad text, departamento text, osm_id text,
               elemento_cercano text, tipo_elemento text, distancia_m numeric, riesgo text)
LANGUAGE sql STABLE AS $$
    WITH loc AS (
        SELECT l.*, d.nombre AS depto
        FROM entrerios.localidades l
        JOIN entrerios.departamentos d ON d.id = l.id_depto
        WHERE translate(lower(l.nombre), 'áéíóúü', 'aeiouu')
            = translate(lower(trim(nombre_localidad)), 'áéíóúü', 'aeiouu')
    )
    SELECT loc.nombre, loc.depto, loc.osm_id, h.nombre, h.tipo, round(h.dist::numeric, 0),
           CASE WHEN h.dist < 1000 THEN 'Alto'
                WHEN h.dist <= 3000 THEN 'Medio'
                ELSE 'Bajo' END
    FROM loc
    CROSS JOIN LATERAL (
        SELECT * FROM (
            (SELECT COALESCE(r.nombre, '(sin nombre)') AS nombre, r.tipo, ST_Distance(r.geom_m, loc.geom_m) AS dist
             FROM entrerios.rios r ORDER BY r.geom_m <-> loc.geom_m LIMIT 1)
            UNION ALL
            (SELECT COALESCE(g.nombre, '(sin nombre)'), 'laguna/' || g.tipo, ST_Distance(g.geom_m, loc.geom_m)
             FROM entrerios.lagunas g ORDER BY g.geom_m <-> loc.geom_m LIMIT 1)
            UNION ALL
            (SELECT COALESCE(a.nombre, '(sin nombre)'), 'cauce/' || a.tipo, ST_Distance(a.geom_m, loc.geom_m)
             FROM entrerios.rios_area a ORDER BY a.geom_m <-> loc.geom_m LIMIT 1)
        ) c ORDER BY dist LIMIT 1
    ) h
    ORDER BY loc.depto;
$$;

SELECT * FROM entrerios.fn_riesgo_localidad('Santa Elena');''')}
{tabla("SELECT r.localidad, r.elemento_cercano, r.tipo_elemento, r.distancia_m, r.riesgo FROM (SELECT DISTINCT nombre FROM localidades WHERE id_depto=" + LP + ") x CROSS JOIN LATERAL fn_riesgo_localidad(x.nombre) r WHERE r.departamento='La Paz' ORDER BY r.distancia_m",
       ["Localidad (La Paz)", "Elemento más cercano", "Tipo", "Distancia (m)", "Riesgo"])}
{tabla("SELECT * FROM fn_riesgo_localidad('Paraná') UNION ALL SELECT * FROM fn_riesgo_localidad('concordia') UNION ALL SELECT * FROM fn_riesgo_localidad('Villaguay')",
       ["Localidad", "Depto.", "osm_id", "Elemento", "Tipo", "Dist. (m)", "Riesgo"], caption="Pruebas con otras localidades (búsqueda sin tildes ni mayúsculas)")}

<h3>10.2 MBR de Entre Ríos</h3>
<p>El MBR de Entre Ríos mide {num(mbr[0], 0)} km², frente a los {num(mbr[1], 0)} km² de la provincia: el territorio ocupa el
{num(100*mbr[1]/mbr[0], 1)} % del rectángulo (relación {num(mbr[0]/mbr[1], 2)}). Se calculó con <code>ST_Envelope(provincia.geom)</code>
en 4326 y el área con <code>::geography</code>. El MBR es el rectángulo alineado con meridianos y paralelos definido por las coordenadas
extremas (mínimo y máximo de x e y), y es bastante más grande porque incluye superficie que no es provincia: Entre Ríos tiene forma irregular,
encajonada entre dos ríos que corren en diagonal, con el delta al sur y una punta norte angosta, así que las esquinas del rectángulo caen
sobre Santa Fe, Corrientes, Uruguay y el río. Por eso el MBR sirve como filtro rápido en los índices espaciales (el operador
<code>&amp;&amp;</code> compara MBR), pero nunca para medir.</p>
{mapa("m10_mbr", "Figura 10. MBR (ST_Envelope) y contorno real de Entre Ríos.")}

<h3>10.3 fn_hospital_cercano(lat, lon)</h3>
<p>Esta función simula el pedido de auxilio de una persona que solo puede dar su posición GPS: devuelve el establecimiento más cercano,
su departamento y la distancia. Primero preselecciona 10 candidatos con KNN (rápido, en grados) y después los ordena por
<code>ST_Distance(::geography)</code>, que es geodésica y exacta en cualquier lugar. Hay que tener cuidado con el orden de los parámetros,
porque <code>ST_MakePoint</code> recibe (lon, lat). Un tercer parámetro opcional permite buscar solo hospitales. En las pruebas se ve que en el
norte del departamento el hospital más cercano está a más de 30 km, y que en el centro-este el más cercano está en otro departamento
(Federal): la función lo encuentra porque busca en toda la provincia.</p>
{code('''CREATE OR REPLACE FUNCTION entrerios.fn_hospital_cercano(lat double precision, lon double precision,
                                                         solo_hospitales boolean DEFAULT false)
RETURNS TABLE (establecimiento text, tipo text, departamento text, distancia_m numeric, distancia_km numeric)
LANGUAGE sql STABLE AS $$
  WITH p AS (SELECT ST_SetSRID(ST_MakePoint(lon, lat), 4326) AS g),
  cand AS (SELECT s.nombre, s.tipo, s.id_depto, s.geom FROM entrerios.salud s, p
           WHERE NOT solo_hospitales OR s.tipo = 'hospital'
           ORDER BY s.geom <-> p.g LIMIT 10)
  SELECT c.nombre, c.tipo, d.nombre,
         round(ST_Distance(c.geom::geography, p.g::geography)::numeric, 0),
         round((ST_Distance(c.geom::geography, p.g::geography)/1000)::numeric, 2)
  FROM cand c, p, entrerios.departamentos d WHERE d.id = c.id_depto
  ORDER BY ST_Distance(c.geom::geography, p.g::geography) LIMIT 1;
$$;''')}
{tabla("""SELECT 'Plaza de La Paz (-30.7423, -59.6455)', * FROM fn_hospital_cercano(-30.7423, -59.6455)
UNION ALL SELECT 'Campo entre Bovril y Alcaraz (-31.10, -59.30)', * FROM fn_hospital_cercano(-31.10, -59.30)
UNION ALL SELECT 'Norte, cerca del Guayquiraró (-30.40, -59.40)', * FROM fn_hospital_cercano(-30.40, -59.40)
UNION ALL SELECT 'Mismo punto, solo hospitales', * FROM fn_hospital_cercano(-30.40, -59.40, true)""",
       ["Caso", "Establecimiento", "Tipo", "Depto.", "m", "km"])}

<h3>10.4 Agrupamiento con ST_ClusterKMeans (k = 3)</h3>
<p>Con <code>ST_ClusterKMeans(geom_m, 3) OVER ()</code>, que es una función de ventana aplicada en coordenadas métricas, agrupamos los
establecimientos en tres grupos y calculamos el centroide de cada uno con <code>ST_Centroid(ST_Collect(...))</code>. Los grupos coinciden
con los tres polos sanitarios del departamento: <b>La Paz (ciudad)</b> al noroeste, <b>Santa Elena–El Quebracho–Piedras Blancas</b> al oeste y
<b>Bovril–Alcaraz</b> al sudeste. Los centroides marcan el centro de gravedad de cada polo y son lugares razonables para una base de
ambulancias o un depósito de medicamentos que abastezca a todo el grupo. El de Bovril–Alcaraz cae en el campo, cerca de Sir Leonard, una
de las localidades sin cobertura, así que una base ahí acercaría el servicio a quienes hoy no lo tienen. La limitación es que el centroide
es geométrico y no considera la red vial; eso lo resuelven los puntos 13 y 14.</p>
{tabla("SELECT c.grupo, c.establecimientos, round(ST_Y(c.geom)::numeric,4), round(ST_X(c.geom)::numeric,4), c.integrantes FROM r10_kmeans_centroides c ORDER BY c.grupo",
       ["Grupo", "N", "Lat", "Lon", "Integrantes"])}
{mapa("m10_kmeans", "Figura 11. Grupos K-means y sus centroides.")}
""")

# ---------------- 8 / punto 11
H.append(f"""
<h1>8. Calles, OpenStreetMap y Argenmap (punto 11)</h1>

<h3>11.1 Densidad de la red vial</h3>
<p>La Paz suma {num(calles[0], 1)} km de calles, un {num(100*(float(calles[0])/float(calles[1])-1), 1)} % más que el promedio provincial
({num(calles[1], 1)} km). Su <b>densidad</b>, en cambio, es de {num(calles[2], 3)} km/km², por debajo del promedio ({num(calles[3], 3)}).
El cálculo es <code>ST_Length</code> de las calles recortadas a cada departamento, dividido por su superficie. La comparación por longitud
total engaña: La Paz tiene muchos kilómetros simplemente porque es grande. Por km² está en el puesto 12 de 17, lo que refleja una red
rural rala, donde el 74 % son caminos <i>unclassified</i>, casi todos de tierra.</p>
{tabla("SELECT nombre, km_calles, sup_km2, densidad_km_km2 FROM r11_calles_depto ORDER BY km_calles DESC", ["Departamento", "km de calles", "km²", "km/km²"])}

<h3>11.2 Densidad vial por localidad</h3>
<p>La mayor densidad vial por localidad es la de <b>{dens_top[0]}</b>: {num(dens_top[1], 2)} km/km² ({num(dens_top[2], 2)} km en
{num(dens_top[3], 3)} km²). Acá hubo que tomar una decisión, porque las localidades de OSM son puntos y los ejidos (admin_level 7/8)
incluyen grandes áreas rurales, así que ninguna de las dos cosas sirve como «superficie de la localidad». Estimamos la <b>mancha urbana</b>
a partir de la propia trama de calles: <code>ST_ClusterDBSCAN</code> (eps 100 m, minpoints 5) sobre las calles <i>residential</i>,
asignación de cada cluster a la localidad más cercana (a menos de 1,5 km) y superficie = <code>ST_Buffer(ST_ConcaveHull(cluster, 0.4), 50)</code>.
En un primer intento incluimos también las <i>unclassified</i>, pero DBSCAN encadenaba los caminos rurales y la «mancha» de La Paz daba
862 km². La densidad es los km de calles de todas las categorías dentro de la mancha, sobre su superficie. Las localidades chicas y
compactas como Alcaraz, Sir Leonard o San Gustavo, con damero denso y pocas manzanas, tienen más densidad que la ciudad de La Paz, cuya
mancha incluye barrios periféricos, quintas y la barranca, con una trama más abierta.</p>
{tabla("SELECT localidad, poblacion, sup_km2, km_calles, densidad_km_km2 FROM r11_densidad_localidad ORDER BY densidad_km_km2 DESC",
       ["Localidad", "Población", "Mancha (km²)", "km calles", "km/km²"])}
{mapa("m11_densidad", "Figura 12. Mancha urbana estimada por DBSCAN + envolvente cóncava (La Paz ciudad).")}

<h3>11.3 Categorías de calles</h3>
<p>Los kilómetros de calles <i>primary</i> y <i>secondary</i> dentro del departamento se obtienen filtrando por <code>highway</code> y
midiendo <code>ST_Length(ST_Intersection(...))</code>, con <code>GROUP BY ROLLUP</code> para el total. Coinciden con la red de rutas del
punto 8 (la RN127 y la RP1 son <i>primary</i>, la RP6 es <i>secondary</i>): en OSM las rutas son también «calles» de categoría alta.</p>
{tabla("""SELECT COALESCE(c.highway,'Total'), count(*), round((sum(ST_Length(ST_Intersection(c.geom_m,d.geom_m)))/1000)::numeric,2)
FROM calles c JOIN departamentos d ON d.nombre='La Paz' AND ST_Intersects(c.geom_m,d.geom_m)
WHERE c.highway IN ('primary','secondary') GROUP BY ROLLUP (c.highway) ORDER BY c.highway""", ["Categoría", "Tramos", "km"])}

<h3>11.4 Comparación con Argenmap</h3>
<p>Para comparar OSM con Argenmap superpusimos en QGIS las calles cargadas en PostGIS sobre el mapa base del IGN (servido como XYZ con
<code>{{-y}}</code>) y complementamos la vista con consultas sobre los tags <code>bridge</code> y <code>surface</code>: hay {puentes[0]}
puentes cargados en OSM, que suman {num(puentes[1], 0)} m, y la superficie declarada de las vías se resume en la tabla de más abajo.</p>
<p>En la planta urbana de La Paz (Figura 13) la trama de calles de OSM se superpone casi exactamente con las manzanas de Argenmap. En la
periferia y el campo, en cambio, OSM agrega la cuadrícula de caminos vecinales entre chacras, al sur y al este de la ciudad, que en Argenmap
no aparece o aparece con menor jerarquía. En cuanto a la ubicación de las vías, en la RN12, la avenida de acceso (A01) y las calles del
centro las diferencias son de pocos metros y no se distinguen a esta escala. En los sectores rurales la información de transitabilidad de
OSM es incompleta: el 73 % de los km figura como <i>unpaved</i> y el 19 % no tiene dato de superficie. Los arroyos urbanos (Cabayú Cutiá,
Los Paraísos) están en las dos fuentes, pero en OSM son líneas con nombre, y eso es justamente lo que permite calcular cruces y distancias
en PostGIS. Los puentes en OSM se modelan como un tramo con <code>bridge=yes</code>: en la ciudad se ven los de las calles sobre los arroyos
urbanos, y en el campo los de la RP6 sobre el Feliciano y la RP5 sobre el Estacas. Sobre la RN12, en cambio, 29 de los 44 cruces con
cursos de agua no tienen puente cargado (9.3), y queda pendiente contrastarlos uno por uno con Argenmap.</p>
<p>Las diferencias se explican porque son fuentes con objetivos y procesos distintos. Argenmap es cartografía oficial, generalizada para
una escala y actualizada por relevamiento institucional; OSM es colaborativo, más detallado donde hubo mapeadores y desparejo donde no
los hubo. Ninguna es «mejor» que la otra: OSM aporta detalle rural y atributos consultables, y Argenmap homogeneidad y respaldo oficial.</p>
{tabla("""SELECT CASE WHEN c.superficie IN ('asphalt','paved','concrete','paving_stones','sett','chipseal') THEN 'pavimentada'
 WHEN c.superficie IS NULL THEN 'sin dato' ELSE 'no pavimentada' END, round((sum(ST_Length(ST_Intersection(c.geom_m,d.geom_m)))/1000)::numeric,1)
FROM calles c JOIN departamentos d ON d.nombre='La Paz' AND ST_Intersects(c.geom_m,d.geom_m) GROUP BY 1 ORDER BY 2 DESC""", ["Superficie (OSM)", "km"])}
{mapa("m11_osm_argenmap", "Figura 13. Calles de OSM y puentes sobre el mapa base Argenmap (La Paz y alrededores).")}
""")

# ---------------- 9 / punto 12
H.append(f"""
<h1>9. Información del INTA y uso del suelo (punto 12)</h1>
<p>La capa usada es la <b>Carta de Suelos de Entre Ríos 1:100.000</b> (WFS INTA geo-nodo03), almacenada como <code>entrerios.suelo</code>.
Describe la <b>aptitud</b> del suelo y no su uso actual, así que adoptamos una clasificación a partir del Índice de Productividad (IPC):</p>
<table><thead><tr><th>Clase</th><th>Criterio</th><th>Interpretación</th></tr></thead><tbody>
<tr><td>Agrícola</td><td>IPC ≥ 30</td><td>Suelos aptos para cultivos (argiudoles de lomas)</td></tr>
<tr><td>Agrícola-ganadera</td><td>20 ≤ IPC &lt; 30</td><td>Cultivos con limitaciones, rotación con ganadería</td></tr>
<tr><td>Ganadera</td><td>1 ≤ IPC &lt; 20</td><td>Limitaciones severas (vertisoles, hidromorfismo, sodicidad)</td></tr>
<tr><td>Planicie inundable / agua</td><td>IPC = 0 y unidad Ar, AIB, CR, CAg</td><td>Arroyos, islas y bañados, cárcavas, cuerpos de agua</td></tr>
<tr><td>Urbana</td><td>IPC = 0 y unidad AU</td><td>Ejidos urbanos (la carta también les asigna IPC 0)</td></tr>
</tbody></table>
<div class="nota">Que las áreas urbanas tengan IPC = 0, igual que los bañados, lo detectamos al revisar el escenario del punto 13, que cortaba
calles urbanas como si fueran planicie inundable. Por eso las clases de IPC 0 se separan según el tipo de unidad cartográfica.</div>

<h3>12.1 Uso (aptitud) del suelo</h3>
<p>El <b>{num(pct_agri[0], 1)} %</b> del departamento tiene aptitud agrícola y el {num(100-float(pct_agri[0]), 1)} % corresponde a otros
usos. El resultado es sensible al umbral: con IPC ≥ 20 sería {num(pct_agri[1], 1)} % y con IPC ≥ 40, {num(pct_agri[2], 1)} %. Los valores
salen de intersectar las unidades de suelo con el departamento y sumar <code>ST_Area</code> por clase. La Paz es mayormente ganadera y
mixta: los vertisoles y los suelos con drenaje deficiente dominan el centro y el norte, y la agricultura se concentra en las lomas del sur
y sudeste (series Tacuaras, Alcaraz, Banderas, Malambo), alrededor de Bovril y Alcaraz.</p>
{tabla("SELECT clase, round((sum(ST_Area(geom_m))/1e6)::numeric,1), round((100*sum(ST_Area(geom_m))/(SELECT ST_Area(geom_m) FROM departamentos WHERE nombre='La Paz'))::numeric,1) FROM r12_suelo_lapaz GROUP BY clase ORDER BY 2 DESC",
       ["Clase", "km²", "% del depto."])}
{mapa("m12_suelo", "Figura 14. Aptitud del suelo según el índice de productividad (INTA).")}

<h3>12.2 Áreas agrícolas expuestas</h3>
<p>{num(agri_exp[0], 1)} km² de suelo agrícola están dentro de la ZRH, el <b>{num(agri_exp[1], 1)} %</b> del área agrícola, calculados con
<code>ST_Intersection(suelo_agricola.geom_m, zrh.geom_m)</code>. Más de dos tercios de la mejor tierra está a menos de 2 km de un curso de
agua, porque en las lomas agrícolas la red de arroyos es densa. Es una primera aproximación: el suelo agrícola suele estar en las partes
altas, así que la exposición real es menor que la geométrica. Las unidades con más superficie expuesta son Tacuaras (IPC 62, la mejor del
departamento), Malambo y Banderas.</p>
{tabla("SELECT unidad, ipc, round((sum(ST_Area(geom_m))/1e6)::numeric,1) FROM r12_agricola_expuesta GROUP BY 1,2 ORDER BY 3 DESC LIMIT 8",
       ["Unidad", "IPC", "km² expuestos"])}

<h3>12.3 Corredores productivos</h3>
<p>Para los corredores productivos calculamos, por ruta, los km que atraviesan suelo agrícola
(<code>ST_Intersection(ruta, ST_Union(agricola))</code>) y la superficie agrícola a menos de 2 km
(<code>ST_Intersection(ST_Buffer(ruta, 2000), agricola)</code>). La <b>RN12</b> es el corredor principal: 40 km sobre suelo agrícola y 151 km²
de producción con salida directa; es la ruta que saca la producción del sur del departamento (Bovril–Alcaraz) hacia Paraná. La RPA02 y
la RPA01 son corredores cortos pero intensos, mientras que la RP1 y la RN127 casi no atraviesan suelo agrícola. Esto se conecta con el
punto 13: los cortes de la RN127 y la RN12 por crecida afectan justamente al corredor productivo del sur.</p>
{tabla("SELECT ref, jurisdiccion, km_ruta, km_en_agricola, pct_en_agricola, sup_agricola_corredor_2km_km2 FROM r12_corredores ORDER BY km_en_agricola DESC",
       ["Ruta", "Jurisdicción", "km ruta", "km en agrícola", "%", "Corredor 2 km (km²)"])}
{mapa("m12_expuesta_corredores", "Figura 15. Suelo agrícola expuesto (ZRH) y corredores productivos.")}
""")

# ---------------- 10 / punto 13
H.append(f"""
<h1>10. Consulta agregada: escenario de crecida (punto 13)</h1>
<h2>10.1 Planteo del problema</h2>
<p>Una crecida de los ríos y arroyos deja intransitables los cruces de agua sin puente (vados y alcantarillas) y los caminos que atraviesan
las planicies de inundación. <b>¿Qué localidades pierden el acceso por ruta al hospital, cuánto se alarga el viaje, cuál es el camino
alternativo y en qué orden hay que asistirlas?</b></p>
<h2>10.2 Información espacial necesaria</h2>
<table><thead><tr><th>Información</th><th>Fuente</th><th>Uso</th></tr></thead><tbody>
<tr><td>Red vial (calles + rutas)</td><td>OSM</td><td>grafo ruteable con pgRouting</td></tr>
<tr><td>Ríos y arroyos; ZRH principal</td><td>OSM (punto 9)</td><td>cruces de agua; zona de influencia</td></tr>
<tr><td>Unidades de suelo de planicie inundable</td><td>INTA</td><td>terreno bajo que se anega primero</td></tr>
<tr><td>Departamentos</td><td>IGN</td><td>área de estudio (La Paz + 30 km)</td></tr>
<tr><td>Hospitales, localidades y población</td><td>OSM</td><td>orígenes, destinos y prioridad</td></tr>
</tbody></table>
<h2>10.3 Desarrollo</h2>
<p>El grafo se armó con las vías transitables en un radio de 30 km alrededor de La Paz, para incluir los hospitales de los departamentos
vecinos. En OSM las vías se conectan compartiendo nodos, que pueden estar en el medio de un <i>way</i>, así que partimos cada way en sus
segmentos elementales con <code>ST_DumpSegments</code>, de modo que cada nodo sea un vértice. Los vértices se obtuvieron con
<code>pgr_extractVertices</code>, que en pgRouting 4 reemplaza a <code>pgr_createTopology</code> y devuelve, por vértice, las aristas que salen
(<code>out_edges</code>) y las que llegan (<code>in_edges</code>); con eso asignamos <code>source</code> y <code>target</code> sin comparar
geometrías. El costo es el tiempo de viaje en minutos según la categoría de la vía (90 km/h troncales, 80 primarias, 60 secundarias,
50 terciarias, 40 vecinales, 30 urbanas). El grafo quedó con {num(corte[3])} aristas y {num(corte[4], 0)} km.</p>
{code('''-- 13.1 Grafo ruteable: La Paz + 30 km, cada way partido en segmentos
CREATE TABLE entrerios.red_vial AS
WITH area AS (
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
      AND l.geom && area.g AND ST_Intersects(l.geom, area.g)
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
CREATE TABLE entrerios.red_vial_vertices AS
SELECT * FROM pgr_extractVertices('SELECT id, geom_m AS geom FROM entrerios.red_vial');

UPDATE entrerios.red_vial e SET source = v.id
FROM (SELECT id, unnest(out_edges) AS eid FROM entrerios.red_vial_vertices) v WHERE v.eid = e.id;
UPDATE entrerios.red_vial e SET target = v.id
FROM (SELECT id, unnest(in_edges) AS eid FROM entrerios.red_vial_vertices) v WHERE v.eid = e.id;

CREATE INDEX ON entrerios.red_vial (source);
CREATE INDEX ON entrerios.red_vial (target);
CREATE INDEX ON entrerios.red_vial USING gist (geom_m);
CREATE INDEX ON entrerios.red_vial_vertices USING gist (geom);''')}
<p>Un tramo se considera <b>cortado</b> cuando no es un puente según OSM y, o bien cruza un río o arroyo (o sea que es un vado o una
alcantarilla), o bien está dentro de la ZRH principal sobre una unidad del INTA de planicie inundable. Con ese criterio se cortan
<b>{num(corte[1], 1)} km ({num(corte[2], 1)} % de la red)</b>, entre ellos tramos de la RN127, la RN12, la RP8 y la RP10.</p>
{code('''-- 13.2 (a) cruces de agua sin puente
UPDATE entrerios.red_vial e SET cortado = true
WHERE NOT e.puente
  AND EXISTS (SELECT 1 FROM entrerios.rios r WHERE ST_Intersects(r.geom_m, e.geom_m));

-- 13.2 (b) planicie inundable (INTA) dentro de la ZRH principal
CREATE TEMP TABLE tmp_planicie AS
SELECT (ST_Dump(ST_Intersection(s.geom_m, z.geom_m_principal))).geom AS g
FROM entrerios.suelo s
JOIN entrerios.zona_riesgo_hidrico z ON ST_Intersects(s.geom_m, z.geom_m_principal)
WHERE s.clase = 'Planicie inundable / agua'
  AND ST_DWithin(s.geom_m, (SELECT geom_m FROM entrerios.departamentos WHERE nombre = 'La Paz'), 30000);
CREATE INDEX ON tmp_planicie USING gist (g);

UPDATE entrerios.red_vial e SET cortado = true
WHERE NOT e.cortado AND NOT e.puente
  AND EXISTS (SELECT 1 FROM tmp_planicie p WHERE ST_Intersects(p.g, e.geom_m));''')}
<p>Cada localidad y cada hospital se «enganchan» al vértice más cercano del grafo con KNN. Con <code>pgr_dijkstraCost</code> (muchos a
muchos) calculamos el tiempo mínimo desde cada localidad a cada hospital, en situación normal y sobre la red sin los tramos cortados, y nos
quedamos con el menor por localidad. El mismo esquema se repite contra el Hospital Zonal 9 de Julio, que es el de referencia del
departamento, para medir la derivación:</p>
{code('''-- 13.5 Derivación al hospital de referencia: tiempo normal vs. crecida
CREATE TEMP TABLE tmp_zonal AS
SELECT l.id, l.nombre, COALESCE(l.poblacion, 0) AS poblacion,
       (SELECT v.id FROM entrerios.red_vial_vertices v ORDER BY v.geom <-> l.geom_m LIMIT 1) AS vid
FROM entrerios.localidades l
JOIN entrerios.departamentos d ON d.id = l.id_depto AND d.nombre = 'La Paz';

CREATE TEMP TABLE tmp_zonal_h AS
SELECT (SELECT v.id FROM entrerios.red_vial_vertices v ORDER BY v.geom <-> s.geom_m LIMIT 1) AS vid
FROM entrerios.salud s WHERE s.nombre = 'Hospital Zonal 9 de Julio';

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

-- Ruta normal y ruta alternativa de cada localidad afectada (pgr_dijkstra), para dibujarlas en QGIS
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
            FROM pgr_dijkstra('SELECT id, source, target, costo_min AS cost, costo_min AS reverse_cost '
                              'FROM entrerios.red_vial' || filtro, r.vid, hv) p
            JOIN entrerios.red_vial e ON e.id = p.edge;
        END LOOP;
    END LOOP;
END $$;''')}
<h2>10.4 Resultados</h2>
<p>La primera tabla mira el <b>establecimiento más cercano</b> de cada localidad, sin distinguir complejidad. Ahí la crecida casi no cambia
nada, porque casi cada pueblo tiene una sala o una clínica local: para La Paz el más cercano es Alianza Médica, para Piedras Blancas el
Centro de Salud, y así. Conviene aclarar que OSM los etiqueta como <code>hospital</code>, pero son centros de atención primaria, sin
internación compleja. La única localidad que cambia de establecimiento es Sir Leonard, que pasa del Hospital San Miguel (Bovril) al
Hospital Ecuador (Alcaraz).</p>
{tabla("SELECT localidad, poblacion, hospital_normal, min_normal, hospital_crecida, min_crecida, demora_extra_min, situacion FROM r13_impacto_crecida ORDER BY demora_extra_min DESC NULLS FIRST",
       ["Localidad", "Pobl.", "Establecimiento (normal)", "min", "Establecimiento (crecida)", "min", "+min", "Situación"],
       caption="Establecimiento más cercano (atención primaria)")}
<p>En una emergencia hídrica real, sin embargo, esos centros no resuelven una internación compleja ni una cirugía: los casos graves se derivan
al <b>Hospital Zonal 9 de Julio</b>, en la ciudad de La Paz. Por eso la segunda tabla mide el tiempo de derivación a la cabecera, y ahí sí
aparece el impacto de la crecida:</p>
{tabla("SELECT rank() OVER (ORDER BY (situacion='AISLADA') DESC, poblacion*COALESCE(demora_extra_min,0) DESC), localidad, poblacion, min_normal, min_crecida, demora_extra_min, pct_extra, situacion FROM r13_derivacion_zonal ORDER BY 1",
       ["Prioridad", "Localidad", "Pobl.", "min normal", "min crecida", "+min", "+%", "Situación"],
       caption="Derivación al hospital de referencia (Hospital Zonal 9 de Julio, La Paz)")}
{tabla("SELECT localidad, escenario, minutos, km FROM r13_rutas_hospital WHERE hospital LIKE '%derivación%' ORDER BY localidad, escenario DESC",
       ["Localidad", "Escenario", "min", "km"], caption="Ruta normal y ruta alternativa (pgr_dijkstra) hacia el hospital zonal")}
{mapa("m13_crecida", "Figura 16. Tramos cortados por la crecida y rutas normal/alternativa de derivación.")}
<h2>10.5 Decisiones que se pueden tomar</h2>
<ul>
<li><b>Piedras Blancas queda aislada</b> del hospital zonal. Su único establecimiento local (el Centro de Salud) debe recibir antes de la crecida
insumos y personal para operar de forma autónoma, o hay que coordinar una evacuación aérea o fluvial (está sobre el Paraná).</li>
<li><b>Alcaraz y Sir Leonard</b> casi duplican el tiempo de derivación (+84 y +92 min) porque se cortan tramos de la RN127, la RN12 y caminos vecinales de su ruta habitual.
Conviene preposicionar una ambulancia de alta complejidad en Bovril o Alcaraz durante el evento, en lugar de depender del traslado a La Paz.</li>
<li>Los tramos cortados que usan las rutas de derivación normales (RN127, RN12, caminos vecinales) son los primeros
candidatos para una obra: elevar la rasante o reemplazar alcantarillas por puentes.</li>
<li>La ciudad de La Paz, Santa Elena y San Gustavo no se ven afectadas en el acceso y pueden funcionar como base logística.</li>
</ul>
""")

# ---------------- 11 / punto 14
mj = "".join(f"<li><b>#{m[0]}</b> ({num(m[1], 5)}, {num(m[2], 5)}): sobre la {m[5]} (a {num(m[6], 0)} m), a {num(m[4]/1000, 1)} km de {m[3]}; "
             f"{num(m[7], 2)} km² libres; puntaje {num(m[8], 3)}. Localidades a ≤ 45 min en crecida: {m[9] or '—'}.</li>" for m in mejor)
H.append(f"""
<h1>11. Problema: ubicación de un Centro de Atención Sanitaria de Emergencia (punto 14)</h1>
<h2>11.1 Definición del problema</h2>
<p>Hay que elegir uno o más sitios en el departamento La Paz para un Centro de Atención Sanitaria de Emergencia (CASE) que funcione
<i>justamente durante una crecida</i>: fuera de zonas inundables y de cuerpos de agua, cerca de una ruta principal, sin ocupar los mejores
suelos agrícolas, con superficie suficiente y en una posición que mejore el acceso de las localidades peor servidas y atienda a varias localidades.</p>
<h2>11.2 Criterios utilizados</h2>
<table><thead><tr><th>Condición de la consigna</th><th>Criterio adoptado</th><th>Tipo</th></tr></thead><tbody>
<tr><td>Fuera de la Zona de Riesgo Hídrico</td><td>Fuera de la ZRH <i>principal</i> (ríos, lagunas, cauces). La ZRH completa cubre el 61 % y a los 15 establecimientos: como restricción dura dejaba sin territorio útil, por eso se usa como penalización</td><td>Excluyente + puntaje (15 %)</td></tr>
<tr><td>No dentro de cuerpos de agua</td><td>Se restan lagunas y cauces</td><td>Excluyente</td></tr>
<tr><td>Fuera de determinadas áreas agrícolas</td><td>Fuera de los suelos de mayor aptitud (IPC ≥ 40)</td><td>Excluyente</td></tr>
<tr><td>Superficie adecuada</td><td>Parche libre continuo ≥ 0,5 km² (50 ha: edificio, helipuerto, playa logística, ampliación)</td><td>Excluyente</td></tr>
<tr><td>Próximo a una ruta principal</td><td>≤ 3 km de una RN o RP; más cerca, más puntaje</td><td>Excluyente + puntaje (15 %)</td></tr>
<tr><td>Atender localidades con menor accesibilidad</td><td>Σ población × minutos ahorrados respecto del hospital más cercano actual, en escenario de crecida</td><td>Puntaje (45 %)</td></tr>
<tr><td>Atender varias localidades / accesibilidad razonable</td><td>Cantidad de localidades a ≤ 45 min por la red vial en crecida</td><td>Puntaje (25 %)</td></tr>
</tbody></table>
<h2>11.3 Datos necesarios</h2>
<p>Departamentos (IGN), ZRH y ZRH principal (punto 9), lagunas y cauces (OSM), suelo e IPC (INTA), rutas y red vial ruteable con tramos cortados
(OSM + punto 13), localidades con población (OSM) y tiempos actuales al hospital (punto 13).</p>
<h2>11.4 Funciones de PostGIS/pgRouting investigadas</h2>
<ul>
<li><code>ST_HexagonGrid</code>: genera una grilla hexagonal sobre el departamento. Elegimos hexágonos y no cuadrados porque todas las celdas vecinas quedan a la misma distancia.</li>
<li><code>ST_Difference</code> / <code>ST_Union</code>: restan del hexágono las áreas excluidas.</li>
<li><code>ST_Dump</code> + <code>ST_Area</code>: separan el área libre en parches, para quedarse con el mayor parche <i>continuo</i> (no alcanza con 50 ha dispersas).</li>
<li><code>ST_PointOnSurface</code>: el sitio concreto, garantizado dentro del parche libre (el centroide podría caer afuera).</li>
<li><code>ST_DWithin</code>, <code>ST_Distance</code>, operador KNN <code>&lt;-&gt;</code>: proximidad a rutas y localidades.</li>
<li><code>pgr_dijkstraCost</code> (muchos a muchos): tiempos por red vial desde cada sitio a cada localidad, en escenario de crecida.</li>
</ul>
<h2>11.5 Procedimiento</h2>
<ol>
<li>Grilla de hexágonos de 750 m de lado (~1,46 km²): <b>{num(celdas[0])}</b> celdas dentro del departamento.</li>
<li>Restricciones excluyentes → <b>{num(celdas[1])}</b> celdas aptas.</li>
<li>Para cada sitio apto se calculan con pgRouting los tiempos a las localidades sobre la red sin los tramos cortados.</li>
<li>Puntaje = 0,45·beneficio + 0,25·localidades a ≤ 45 min + 0,15·(1 − fracción en ZRH completa) + 0,15·cercanía a la ruta (cada término normalizado de 0 a 1).</li>
<li>Selección voraz de los 3 mejores sitios separados por al menos 10 km (para proponer alternativas distintas y no tres celdas contiguas).</li>
</ol>
{code('''-- 14.1 Grilla hexagonal (750 m de lado) dentro del departamento
CREATE TABLE entrerios.r14_grilla AS
SELECT row_number() OVER () AS id, h.geom::geometry(Polygon, 5347) AS geom_m
FROM entrerios.departamentos d
CROSS JOIN LATERAL ST_HexagonGrid(750, d.geom_m) h
WHERE d.nombre = 'La Paz' AND ST_Within(h.geom, d.geom_m);
CREATE INDEX ON entrerios.r14_grilla USING gist (geom_m);

-- 14.2 Restricciones excluyentes: ZRH principal (E1) + lagunas y cauces (E2) + suelo IPC >= 40 (E3)
CREATE TEMP TABLE tmp_restriccion AS
SELECT ST_Union(g) AS g FROM (
    SELECT geom_m_principal AS g FROM entrerios.zona_riesgo_hidrico WHERE depto = 'La Paz'
    UNION ALL
    SELECT ST_Buffer(geom_m, 0) FROM entrerios.lagunas l
    WHERE ST_Intersects(l.geom_m, (SELECT geom_m FROM entrerios.departamentos WHERE nombre = 'La Paz'))
    UNION ALL
    SELECT geom_m FROM entrerios.rios_area a
    WHERE ST_Intersects(a.geom_m, (SELECT geom_m FROM entrerios.departamentos WHERE nombre = 'La Paz'))
    UNION ALL
    SELECT geom_m FROM entrerios.r12_suelo_lapaz WHERE ipc >= 40
) x;

-- Celdas aptas: mayor parche libre continuo >= 0,5 km² (E4) y a <= 3 km de una RN/RP (E5)
CREATE TABLE entrerios.r14_aptas AS
WITH libre AS (
    SELECT g.id, g.geom_m,
           ST_Difference(g.geom_m, COALESCE(ST_Intersection(r.g, g.geom_m), 'POLYGON EMPTY'::geometry)) AS libre
    FROM entrerios.r14_grilla g, tmp_restriccion r
), mayor_parche AS (
    SELECT DISTINCT ON (l.id) l.id, l.geom_m, p.geom AS parche, ST_Area(p.geom) AS area_parche
    FROM libre l CROSS JOIN LATERAL ST_Dump(ST_CollectionExtract(l.libre, 3)) p
    ORDER BY l.id, ST_Area(p.geom) DESC
)
SELECT m.id, m.geom_m, m.parche, round((m.area_parche / 1e6)::numeric, 3) AS libre_km2,
       ST_PointOnSurface(m.parche) AS sitio_m,
       rt.ref AS ruta, rt.dist AS dist_ruta_m
FROM mayor_parche m
CROSS JOIN LATERAL (
    SELECT r.ref, ST_Distance(r.geom_m, m.parche) AS dist
    FROM entrerios.rutas r WHERE r.jurisdiccion IN ('Nacional', 'Provincial')
    ORDER BY r.geom_m <-> m.parche LIMIT 1
) rt
WHERE m.area_parche >= 500000
  AND rt.dist <= 3000;

-- 14.3 Tiempos por red vial en crecida desde cada sitio apto a cada localidad
CREATE TEMP TABLE tmp_vsitio AS
SELECT a.id, v.id AS vid
FROM entrerios.r14_aptas a
CROSS JOIN LATERAL (SELECT id FROM entrerios.red_vial_vertices ORDER BY geom <-> a.sitio_m LIMIT 1) v;

CREATE TEMP TABLE tmp_vloc AS
SELECT i.id, i.localidad, GREATEST(i.poblacion, 100) AS poblacion,      -- sin dato OSM -> 100 hab.
       COALESCE(i.min_crecida, 180) AS min_actual, v.id AS vid          -- aislada -> 180 min
FROM entrerios.r13_impacto_crecida i
JOIN entrerios.localidades l ON l.id = i.id
CROSS JOIN LATERAL (SELECT id FROM entrerios.red_vial_vertices ORDER BY geom <-> l.geom_m LIMIT 1) v;

CREATE TEMP TABLE tmp_tiempos AS
SELECT * FROM pgr_dijkstraCost(
    'SELECT id, source, target, costo_min AS cost, costo_min AS reverse_cost FROM entrerios.red_vial WHERE NOT cortado',
    (SELECT array_agg(DISTINCT vid) FROM tmp_vsitio),
    (SELECT array_agg(DISTINCT vid) FROM tmp_vloc));

-- 14.4 Puntaje multicriterio
CREATE TABLE entrerios.r14_candidatos AS
WITH m AS (
    SELECT s.id,
           sum(l.poblacion * GREATEST(0, l.min_actual - t.agg_cost))          AS beneficio,
           count(*) FILTER (WHERE t.agg_cost <= 45)                           AS loc_45min,
           string_agg(l.localidad || ' ' || round(t.agg_cost::numeric) || ' min', ', ' ORDER BY t.agg_cost)
               FILTER (WHERE t.agg_cost <= 45)                                AS localidades_45min
    FROM tmp_vsitio s
    JOIN tmp_tiempos t ON t.start_vid = s.vid
    JOIN tmp_vloc l    ON l.vid = t.end_vid
    GROUP BY s.id
), z AS (
    SELECT a.id, ST_Area(ST_Intersection(a.geom_m, zr.geom_m)) / ST_Area(a.geom_m) AS frac_zrh
    FROM entrerios.r14_aptas a, entrerios.zona_riesgo_hidrico zr WHERE zr.depto = 'La Paz'
)
SELECT a.id, a.libre_km2, a.ruta, round(a.dist_ruta_m::numeric) AS dist_ruta_m,
       round(m.beneficio::numeric) AS beneficio_hab_min, m.loc_45min, m.localidades_45min,
       round((100 * z.frac_zrh)::numeric, 1) AS pct_zrh_completa,
       round((0.45 * m.beneficio / NULLIF(max(m.beneficio) OVER (), 0)
            + 0.25 * m.loc_45min::numeric / NULLIF(max(m.loc_45min) OVER (), 0)
            + 0.15 * (1 - z.frac_zrh)
            + 0.15 * (1 - a.dist_ruta_m / 3000.0))::numeric, 4) AS puntaje,
       ST_Transform(a.geom_m, 4326)::geometry(Polygon, 4326) AS geom,
       a.sitio_m
FROM entrerios.r14_aptas a
JOIN m ON m.id = a.id
JOIN z ON z.id = a.id;''')}
<h2>11.6 Resultados</h2>
{tabla("SELECT ranking, puntaje, lat, lon, localidad_ref, dist_localidad_m, ruta, dist_ruta_m, libre_km2, pct_zrh_completa, beneficio_hab_min, loc_45min FROM r14_mejores ORDER BY ranking",
       ["#", "Puntaje", "Lat", "Lon", "Localidad próx.", "Dist. (m)", "Ruta", "Dist. ruta", "Libre km²", "% ZRH", "Beneficio (hab·min)", "Loc. ≤45'"])}
<ul>{mj}</ul>
{mapa("m14_centro", "Figura 17. Celdas aptas según su puntaje y las tres ubicaciones propuestas.")}
<h2>11.7 Análisis de los candidatos y conclusión</h2>
<div id="analisis14">{{ANALISIS14}}</div>
""")

# ---------------- 12 conclusiones
H.append("""
<h1>12. Conclusiones y limitaciones</h1>
<ul>
<li><b>El riesgo hídrico es estructural.</b> Con un criterio simple (2 km de cualquier curso de agua), el 61 % de La Paz y los 17 departamentos superan el
30 %. El indicador sirve más para <i>comparar</i> (variante principal, combinación con suelos INTA) que como umbral absoluto.</li>
<li><b>La oferta sanitaria está concentrada y toda expuesta.</b> Los 15 establecimientos están en localidades y dentro de la ZRH. El 92 % del territorio está a
más de 5 km de un servicio, y 2 localidades no tienen ninguno a menos de 5 km.</li>
<li><b>El impacto de una crecida está en la derivación</b>, no en la atención primaria. Piedras Blancas queda aislada y el eje Bovril–Alcaraz–Sir
Leonard ve casi duplicado el tiempo al hospital zonal, porque se cortan tramos de la RN127, la RN12 y caminos vecinales.</li>
<li><b>La red vial y la producción coinciden con el riesgo.</b> El corredor productivo principal (RN12 y el sur agrícola) está, en buena parte, dentro de la ZRH.</li>
<li><b>El análisis de redes cambia las conclusiones</b> frente a las distancias en línea recta: localidades «cercanas» a un hospital pueden quedar a horas si el
camino cruza un arroyo crecido.</li>
</ul>
<h2>Limitaciones</h2>
<ul>
<li><b>OSM es colaborativo:</b> completitud despareja (lagunas, puentes sin cargar, rutas sin <code>ref</code>, población desactualizada o faltante). Hubo un nodo duplicado
de La Paz que hubo que depurar.</li>
<li><b>La ZRH es una simplificación</b> sin cota ni caudales; no es un mapa de inundación.</li>
<li><b>La capa del INTA es de aptitud y no de uso actual</b>, a escala 1:100.000. Los límites no coinciden exactamente con el IGN (99,4 % de cobertura).</li>
<li><b>Las velocidades del grafo</b> son supuestas por categoría; no hay datos de estado real de caminos.</li>
</ul>
""")

# ---------------- anexo
H.append("""
<h1>13. Anexo: entregables y reproducción</h1>
<table><thead><tr><th>Archivo</th><th>Contenido</th></tr></thead><tbody>
<tr><td><code>TP2_LaPaz.sql</code></td><td>Script único y comentado: esquema, tablas, controles, consultas, funciones y análisis (puntos 6 a 14)</td></tr>
<tr><td><code>sql/01…10_*.sql</code></td><td>El mismo script separado por punto</td></tr>
<tr><td><code>sql/salidas/*.txt</code></td><td>Salida completa de la ejecución de cada script</td></tr>
<tr><td><code>qgis/TP2_LaPaz.qgz</code></td><td>Proyecto QGIS: conexión PostGIS, capas agrupadas por punto, simbología, Argenmap y composiciones de impresión</td></tr>
<tr><td><code>qgis/generar_proyecto.py</code></td><td>Script PyQGIS que arma el proyecto y exporta los mapas</td></tr>
<tr><td><code>informe/mapas/*.png</code></td><td>Mapas del informe</td></tr>
</tbody></table>
<p>Para reproducirlo: (1) descargar las fuentes (IGN WFS, INTA WFS, Geofabrik); (2) cargar en el esquema <code>fuentes</code> con ogr2ogr;
(3) ejecutar <code>TP2_LaPaz.sql</code> (unos 20 min; los puntos 9 y 13 son los más pesados); (4) abrir <code>TP2_LaPaz.qgz</code>.</p>
</body></html>
""")

doc = "\n".join(H)

# Análisis del punto 14 (texto escrito a partir de los resultados; se completa en ANALISIS14.html)
ana_path = os.path.join(BASE, "ANALISIS14.html")
analisis = open(ana_path, encoding="utf-8").read() if os.path.exists(ana_path) else "<p>(pendiente)</p>"
doc = doc.replace("{ANALISIS14}", analisis)

with open(HTML_OUT, "w", encoding="utf-8") as f:
    f.write(doc)
print("HTML:", HTML_OUT)

r = subprocess.run([EDGE, "--headless", "--disable-gpu", "--no-pdf-header-footer",
                    f"--print-to-pdf={PDF_OUT}", "file:///" + HTML_OUT.replace("\\", "/")],
                   capture_output=True, text=True, timeout=180)
print("PDF:", PDF_OUT if os.path.exists(PDF_OUT) else "ERROR " + r.stderr[-500:])
