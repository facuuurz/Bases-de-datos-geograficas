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


def bloque(titulo, que, como, significa, extra=""):
    return f"""
<h3>{titulo}</h3>
{extra}
<div class="qcs">
  <p><b>Qué se obtuvo.</b> {que}</p>
  <p><b>Cómo se obtuvo.</b> {como}</p>
  <p><b>Qué significa.</b> {significa}</p>
</div>"""


# ------------------------------------------------------------------ datos clave
LP = "(SELECT id FROM departamentos WHERE nombre = 'La Paz')"
sup_lp = v("SELECT ST_Area(geom_m)/1e6 FROM departamentos WHERE nombre='La Paz'")
n_loc_lp = v(f"SELECT count(*) FROM localidades WHERE id_depto = {LP}")
n_sal_lp = v(f"SELECT count(*) FROM salud WHERE id_depto = {LP}")
vecinos = v("SELECT string_agg(vecino || ' (' || replace(limite_km::text, '.', ',') || ' km)', ', ' ORDER BY limite_km DESC) FROM r7_vecinos")
agua = q("SELECT * FROM r7_superficie_agua")[1][0]
rank_lp = q("SELECT ranking, cant_lagunas FROM r7_ranking_agua WHERE nombre='La Paz'")[1][0]
cursos_tot = v("SELECT sum(longitud_m) FROM r7_cursos_agua")
cursos_nom = v("SELECT count(*) FROM r7_cursos_agua WHERE nombre <> '(sin nombre)'")
km_rutas = v("SELECT sum(km) FROM r8_rutas_lapaz")
lejana = q("SELECT nombre, distancia_m, salud_mas_cercana FROM r8_dist_localidad_salud ORDER BY ranking_lejania LIMIT 1")[1][0]
sin_cob = v("SELECT count(*) FROM r8_localidades_sin_cobertura")
sin_cob_n = v("SELECT string_agg(nombre, ', ' ORDER BY distancia_m DESC) FROM r8_localidades_sin_cobertura")
pct_cub = v("SELECT 100*ST_Area(ST_Intersection(c.geom_m,d.geom_m))/ST_Area(d.geom_m) FROM r8_cobertura_5km c, departamentos d WHERE d.nombre='La Paz'")
zrh = q("SELECT ST_Area(z.geom_m)/1e6, 100*ST_Area(z.geom_m)/ST_Area(d.geom_m), ST_Area(z.geom_m_principal)/1e6, 100*ST_Area(z.geom_m_principal)/ST_Area(d.geom_m) FROM zona_riesgo_hidrico z JOIN departamentos d ON d.id=z.id_depto WHERE z.depto='La Paz'")[1][0]
sal_exp = v("SELECT count(*) FROM r9_salud_expuesta")
n_sup30 = v("SELECT count(*) FROM r9_exposicion_deptos WHERE supera_30")
n_sup30p = v("SELECT count(*) FROM r9_exposicion_deptos WHERE supera_30_principal")
no_sup30p = v("SELECT string_agg(nombre, ', ') FROM r9_exposicion_deptos WHERE NOT supera_30_principal")
mbr = q("SELECT ST_Area(m.geom::geography)/1e6, ST_Area(p.geom::geography)/1e6 FROM r10_mbr m, provincia p")[1][0]
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
H.append(f"""<!doctype html><html lang="es"><head><meta charset="utf-8">
<title>TP2 BDG 2026 - La Paz</title>
<style>
@page {{ size: A4; margin: 18mm 16mm 18mm 16mm; }}
body {{ font-family: Calibri, 'Segoe UI', Arial, sans-serif; font-size: 10.5pt; color: #1b1b1b; line-height: 1.38; }}
h1 {{ font-size: 19pt; color: #1f3864; border-bottom: 2px solid #1f3864; padding-bottom: 3px; margin-top: 0; page-break-before: always; }}
h1.noquiebre {{ page-break-before: avoid; }}
h2 {{ font-size: 14pt; color: #1f3864; margin: 18px 0 6px; }}
h3 {{ font-size: 12pt; color: #2e5597; margin: 14px 0 4px; }}
table {{ border-collapse: collapse; margin: 6px 0 10px; font-size: 9pt; width: auto; page-break-inside: avoid; }}
caption {{ caption-side: top; text-align: left; font-weight: bold; font-size: 9pt; color: #444; padding-bottom: 2px; }}
th {{ background: #1f3864; color: #fff; padding: 3px 6px; text-align: left; }}
td {{ border-bottom: 1px solid #d9d9d9; padding: 2px 6px; vertical-align: top; }}
td.n {{ text-align: right; font-variant-numeric: tabular-nums; }}
tr:nth-child(even) td {{ background: #f4f6fa; }}
figure {{ margin: 8px 0 12px; page-break-inside: avoid; text-align: center; }}
figure img {{ width: 100%; border: 1px solid #bbb; }}
figcaption {{ font-size: 8.5pt; color: #555; margin-top: 2px; }}
pre {{ background: #f6f8fa; border: 1px solid #e1e4e8; border-left: 3px solid #2e5597; padding: 6px 8px; font-size: 8pt; white-space: pre-wrap; page-break-inside: avoid; }}
code {{ font-family: Consolas, 'Courier New', monospace; }}
.qcs {{ background: #f7f9fc; border: 1px solid #dfe5ef; padding: 4px 10px; margin: 6px 0 10px; page-break-inside: avoid; }}
.qcs p {{ margin: 4px 0; }}
.nota {{ border-left: 3px solid #c55a11; background: #fdf3ec; padding: 5px 10px; margin: 8px 0; }}
.portada {{ text-align: center; padding-top: 40mm; }}
.portada h1 {{ border: none; font-size: 24pt; page-break-before: avoid; }}
.portada .sub {{ font-size: 15pt; color: #2e5597; margin: 6px 0; }}
.portada .dato {{ font-size: 12pt; margin: 4px 0; }}
.indice li {{ margin: 2px 0; }}
.falta {{ color: #c00; }}
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
<p class="dato">Integrantes: ______________________________________</p>
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
<p>El trabajo construye una base de datos espacial en PostgreSQL/PostGIS para analizar la relación entre
la red hídrica, la red vial, las localidades y los establecimientos de salud del departamento <b>La Paz</b>,
en el noroeste de Entre Ríos. Algunos análisis se extienden a toda la provincia para comparar.</p>
<p>Con <b>{num(sup_lp, 0)} km²</b> según el IGN, La Paz es el segundo departamento más extenso de la provincia,
después de Gualeguaychú. Limita al oeste con el río Paraná (y la provincia de Santa Fe), al norte con el río Guayquiraró (y Corrientes)
y, dentro de la provincia, con {vecinos}. En OpenStreetMap tiene <b>{n_loc_lp} localidades</b> y
<b>{n_sal_lp} establecimientos de salud</b>. La cruzan arroyos importantes (Feliciano, Estacas, Alcaraz, Hernandarias),
lo que la vuelve un buen caso para estudiar riesgo hídrico y accesibilidad.</p>
<p>El objetivo no es solo producir mapas y consultas: buscamos que cada resultado sirva para responder una
pregunta útil en una emergencia real. Por eso cada resultado se presenta con tres partes: <i>qué se obtuvo,
cómo se obtuvo y qué significa</i>.</p>
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
<p><b>OpenStreetMap.</b> La consigna sugiere QuickOSM, que consulta la API Overpass. Durante el trabajo
el servidor principal de Overpass rechazaba las conexiones y los espejos devolvían <i>504 Gateway Timeout</i>,
porque la consulta de calles a escala provincial es grande. Como la consigna permite otro origen,
usamos el extracto diario de Geofabrik (mismos datos de OSM) y aplicamos los mismos filtros de etiquetas que
indica la consigna (<code>place</code>, <code>highway</code>, <code>waterway</code>, <code>natural=water</code>,
<code>amenity</code>), con un <code>osmconf.ini</code> propio para conservar <code>ref</code>, <code>bridge</code>,
<code>water</code> y <code>surface</code>.</p>
<p><b>INTA.</b> El WFS de la Región Entre Ríos publica <b>una sola capa vectorial</b>: la Carta de Suelos
1:100.000 (4.508 polígonos). No describe el <i>uso actual</i> del suelo sino su <i>aptitud</i>, a través del
<b>Índice de Productividad (IPC)</b> de cada unidad cartográfica. El punto 12 se resolvió con esa información
(ver criterios en la sección 9).</p>
<p><b>Herramientas.</b> PostgreSQL 18.3 + PostGIS 3.6.2, pgRouting 4.0.1 (puntos 13 y 14), GDAL/ogr2ogr y
QGIS 3.44 (visualización, composiciones y exportación de mapas).</p>

<h2>2.1 Sistema de referencia y cálculos métricos</h2>
<p>Los datos se almacenan en <b>EPSG:4326 (WGS84)</b>. Como los grados no son una unidad métrica, para
distancias, longitudes y superficies se reproyecta a <b>EPSG:5347 – POSGAR 2007 / Argentina faja 5</b>
(Gauss-Krüger, meridiano central −60°).</p>
<div class="nota"><b>Justificación.</b> La Paz está entre −59,98° y −58,93° de longitud, a menos de 1,1° del
meridiano central de la faja 5: la deformación de escala es despreciable. El <b>EPSG:5343</b> que menciona la consigna como ejemplo
es la <b>faja 1</b> (meridiano −72°, en la cordillera): La Paz queda a ~12° de su meridiano central y la proyección
introduce errores apreciables. Como control, la superficie provincial da <b>{num(mbr[1], 0)} km²</b> con
<code>geography</code> (elipsoide) y {num(v("SELECT ST_Area(ST_Transform(geom,5347))/1e6 FROM provincia"), 0)} km² en EPSG:5347,
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
<p>Base <code>tp2_bdg</code> con las extensiones <code>postgis</code> y <code>pgrouting</code>. Se usan dos esquemas:</p>
<ul>
<li><code>fuentes</code>: las capas tal como se descargaron (carga con <code>ogr2ogr</code>).</li>
<li><code>entrerios</code>: tablas depuradas, tipadas y recortadas a la provincia, más las tablas de resultados (<code>r7_*</code> … <code>r14_*</code>).</li>
</ul>
{code('''ogr2ogr -f PostgreSQL "PG:dbname=tp2_bdg user=postgres" departamentoPolygon.shp \\
        -nln ign_departamentos -lco SCHEMA=fuentes -lco GEOMETRY_NAME=geom \\
        -oo ENCODING=ISO-8859-1 -nlt PROMOTE_TO_MULTI
ogr2ogr -f PostgreSQL "PG:..." suelos.geojson -nln inta_suelos -lco SCHEMA=fuentes ...
ogr2ogr -f PostgreSQL "PG:..." entrerios_osm.gpkg lines -nln osm_lines -lco SCHEMA=fuentes ...''')}
<p>Tablas del esquema <code>entrerios</code> (mínimo pedido más tablas auxiliares):</p>
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
<div class="nota"><b>Decisión: lagunas vs. cauces.</b> OSM etiqueta como <code>natural=water</code> también el cauce de los ríos
(<code>water=river</code>: Paraná, Guayquiraró, riachos). En La Paz esos polígonos suman unos 144 km², contra
{num(agua[1], 1)} km² de lagunas. Si se los contaba como lagunas, el Paraná dominaba cualquier indicador.
Por eso se separaron en <code>rios_area</code>.</div>
<div class="nota"><b>Decisión: localidad duplicada.</b> En OSM aparecen dos nodos «La Paz» dentro del departamento:
la ciudad (osm 198457357, <i>town</i>, 24.716 hab.) y un <i>village</i> de «500 hab.» ubicado 45 km al norte,
sobre la RN12. Ambos apuntan al mismo objeto de Wikidata (<b>Q2440276</b>): el segundo es un nodo duplicado y mal
ubicado. Se eliminó con una regla general: si dos localidades comparten Wikidata se conserva la de mayor
jerarquía. Sin esta depuración, el nodo falso aparecía como «localidad más alejada» (8.4) y sesgaba la ubicación
propuesta en el punto 14.</div>

<h2>3.1 Controles de calidad de la importación</h2>
<p>La función <code>fn_control_calidad()</code> recorre <code>geometry_columns</code> y, para cada tabla, verifica
tipo de geometría declarado y real (<code>ST_GeometryType</code>), SRID (<code>ST_SRID</code>), cantidad de registros,
geometrías nulas, vacías e inválidas (<code>ST_IsValid</code>):</p>
{tabla("SELECT tabla, tipo_declarado, tipos_reales, srid_declarado, srids_reales, registros, nulas, vacias, invalidas FROM fn_control_calidad() WHERE tabla IN ('calles','departamentos','lagunas','localidades','provincia','rios','rios_area','rutas','salud','suelo')",
       ["Tabla", "Tipo declarado", "Tipo real", "SRID decl.", "SRID real", "Registros", "Nulas", "Vacías", "Inválidas"])}
<p>Geometrías inválidas detectadas en las <b>fuentes crudas</b> y corregidas con <code>ST_MakeValid</code> durante la carga:</p>
{tabla("""SELECT 'IGN departamentos' f, count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM fuentes.ign_departamentos
UNION ALL SELECT 'OSM natural=water', count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM fuentes.osm_multipolygons WHERE "natural"='water'
UNION ALL SELECT 'INTA suelos', count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM fuentes.inta_suelos""", ["Fuente", "Inválidas"])}
{tabla("SELECT ST_IsValidReason(geom) FROM fuentes.osm_multipolygons WHERE \"natural\"='water' AND NOT ST_IsValid(geom) LIMIT 3", ["Ejemplo de motivo (ST_IsValidReason)"])}
<p>Los polígonos de agua inválidos son <i>auto-intersecciones</i> en el borde del rectángulo de recorte de OSM (longitud −60,85°,
latitudes −34,1° y −30,1°): son polígonos cortados que quedan fuera de la provincia. Los 7 polígonos del INTA tienen
anillos que se cruzan a sí mismos y quedaron reparados. Como control topológico adicional, la suma de las superficies departamentales
({num(v("SELECT sum(ST_Area(geom_m))/1e6 FROM departamentos"), 1)} km²) coincide con el área del contorno provincial
({num(v("SELECT ST_Area(ST_Transform(geom,5347))/1e6 FROM provincia"), 1)} km²): no hay superposiciones ni huecos entre departamentos.</p>
{code('''SELECT nombre, ST_GeometryType(geom) AS tipo, ST_SRID(geom) AS srid,
       ST_IsValid(geom) AS valida, ST_NPoints(geom) AS vertices
FROM entrerios.departamentos ORDER BY nombre;

UPDATE entrerios.lagunas
SET geom = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
WHERE NOT ST_IsValid(geom);''')}
""")

# ---------------- 4 / punto 7
H.append(f"""
<h1>4. Hidrografía y características del departamento (punto 7)</h1>
""")
H.append(bloque("7.1 Departamentos vecinos",
    f"La Paz limita con 4 departamentos entrerrianos: {vecinos}.",
    "<code>ST_Intersects</code> entre La Paz y el resto, midiendo la longitud del límite compartido "
    "(<code>ST_Intersection</code> de los <code>ST_Boundary</code>) para descartar contactos en un único punto. "
    "<code>ST_Touches</code> da verdadero solo para Paraná y Villaguay: en los otros límites los vértices del IGN no coinciden "
    "exactamente (hay superposiciones de milímetros), lo que muestra por qué no conviene depender solo de un predicado topológico estricto.",
    "Federal es el vecino con el que más límite comparte. Además de estos 4, La Paz limita con Santa Fe (Paraná) "
    "y Corrientes (Guayquiraró), que no forman parte de la capa provincial.",
    tabla("SELECT vecino, touches, limite_km FROM r7_vecinos ORDER BY limite_km DESC", ["Vecino", "ST_Touches", "Límite (km)"])))
H.append(bloque("7.2 Frontera común",
    "La geometría (MultiLineString) de las fronteras con los 4 vecinos, guardada en <code>r7_frontera</code> para QGIS.",
    "<code>ST_LineMerge(ST_CollectionExtract(ST_Intersection(ST_Boundary(a.geom), ST_Boundary(b.geom)), 2))</code>.",
    "La frontera La Paz–Federal es la más larga, y el 85 % de su recorrido está a menos de 300 m de un arroyo "
    "(Feliciano, Estacas, del Yeso, Don Gonzalo y otros): los límites departamentales se trazaron siguiendo la red de drenaje. "
    "Esto es relevante para el riesgo hídrico, porque <i>casi todo paso entre departamentos es un cruce de agua</i>.",
    tabla("""SELECT f.frontera, ST_GeometryType(f.geom), round((ST_Length(f.geom::geography)/1000)::numeric,1),
       round((100*ST_Length(ST_Intersection(ST_Transform(f.geom,5347), ST_Buffer(ST_Collect(r.geom_m),300)))/ST_Length(ST_Transform(f.geom,5347)))::numeric,1)
FROM r7_frontera f JOIN rios r ON ST_DWithin(r.geom_m, ST_Transform(f.geom,5347), 300)
GROUP BY f.frontera, f.geom ORDER BY 3 DESC""", ["Frontera", "Tipo", "km", "% a ≤300 m de un curso de agua"]) +
    mapa("m07_vecinos_frontera", "Figura 2. Departamentos vecinos y fronteras comunes.")))
H.append(bloque("7.3 Presencia de cuerpos de agua (ranking provincial)",
    f"La Paz ocupa el puesto <b>{rank_lp[0]}</b> de 17, con <b>{rank_lp[1]}</b> lagunas/cuerpos de agua.",
    "Cada laguna se asigna a un solo departamento con <code>ST_Within(ST_PointOnSurface(laguna), depto)</code>, para no "
    "contar dos veces las que cruzan un límite. Además de la cantidad se calculan la superficie y la densidad cada 100 km².",
    "<b>Limitaciones de la fuente.</b> (1) OSM es colaborativo y su completitud depende de quién mapeó cada zona: Federación "
    "encabeza el ranking por la cantidad de pequeños estanques y tajamares mapeados, no necesariamente por tener más agua. "
    "(2) La cantidad no mide importancia: Victoria tiene menos lagunas que Federación pero diez veces su superficie (lagunas del delta). "
    "(3) Una laguna grande puede estar partida en varios polígonos o mapeada como uno solo. "
    "(4) En La Paz, el 90 % de los polígonos no tiene subtipo <code>water</code> ni nombre, así que no es posible distinguir lagunas naturales de represas. "
    "(5) Las lagunas temporarias cambian con el régimen de lluvias y OSM refleja la imagen satelital que se usó al mapear.",
    tabla("SELECT ranking, nombre, cant_lagunas, sup_lagunas_km2, lagunas_c100km2 FROM r7_ranking_agua ORDER BY ranking, nombre",
          ["#", "Departamento", "Cantidad", "Superficie (km²)", "Cada 100 km²"]) +
    mapa("m07_ranking_lagunas", "Figura 3. Cantidad de lagunas por departamento (cortes de Jenks).")))
H.append(bloque("7.4 Superficie cubierta por agua",
    f"Superficie total {num(agua[0], 2)} km²; lagunas {num(agua[1], 2)} km² ({num(agua[3], 2)} %); "
    f"resto {num(agua[2], 2)} km². Si se suman los cauces del Paraná y sus riachos, el agua llega a {num(agua[4], 2)} km² ({num(agua[5], 2)} %).",
    "Intersección (<code>ST_Intersection</code>) de cada polígono con el departamento, disuelta con <code>ST_Union</code> para no "
    "contar superposiciones, y <code>ST_Area</code> en EPSG:5347 ÷ 10⁶.",
    "El agua <i>permanente</i> ocupa una fracción mínima del territorio. El riesgo hídrico de La Paz no está en sus lagunas: viene de los "
    "desbordes de los arroyos y del Paraná, por eso el punto 9 trabaja con zonas de influencia y no solo con espejos de agua.",
    tabla("SELECT sup_total_km2, sup_lagunas_km2, sup_restante_km2, pct_lagunas, sup_agua_con_cauces_km2, pct_agua_con_cauces FROM r7_superficie_agua",
          ["Total km²", "Lagunas km²", "Restante km²", "% lagunas", "Agua c/cauces km²", "% c/cauces"])))
H.append(bloque("7.5 Cursos de agua",
    f"{cursos_nom} cursos con nombre y {num(cursos_tot, 0)} m (≈ {num(cursos_tot/1000, 0)} km) de ríos y arroyos dentro del departamento.",
    "<code>ST_Length(ST_Intersection(rio.geom_m, depto.geom_m))</code>, agrupando por nombre porque en OSM un arroyo está "
    "partido en muchos <i>ways</i>.",
    "El arroyo Feliciano es el principal eje hídrico interno (≈158 km dentro del departamento). La mitad de la longitud corresponde a "
    "cursos sin nombre en OSM: la red de drenaje es muy densa, lo que explica la extensión de la zona de riesgo del punto 9.",
    tabla("SELECT nombre, tipo, tramos, longitud_m FROM r7_cursos_agua ORDER BY longitud_m DESC LIMIT 15",
          ["Curso", "Tipo OSM", "Tramos", "Longitud (m)"], caption="Los 15 cursos más largos dentro de La Paz") +
    mapa("m07_cursos_agua", "Figura 4. Cursos y cuerpos de agua del departamento.")))

# ---------------- 5 / punto 8
H.append("<h1>5. Rutas y accesibilidad sanitaria (punto 8)</h1>")
H.append(bloque("8.1 y 8.2 Red vial principal y longitud de las rutas",
    f"Atraviesan el departamento 2 rutas nacionales (RN12, RN127) y las provinciales RP1, RP6 y los accesos RPA01–03; "
    f"en total {num(km_rutas, 1)} km de red principal.",
    "Filtro <code>highway</code> motorway/trunk/primary/secondary, jurisdicción derivada del tag <code>ref</code> y "
    "<code>ST_Length(ST_Intersection(ruta.geom_m, depto.geom_m))/1000</code> agrupado por ruta.",
    "La RN12 es la columna vertebral: recorre el departamento de sur a norte y concentra el 40 % de los km. Los ~30 km "
    "«sin ref» son tramos <i>secondary</i> sin número en OSM, un problema de completitud de la fuente.",
    tabla("SELECT ref, jurisdiccion, categoria_osm, km FROM r8_rutas_lapaz ORDER BY km DESC", ["Ruta", "Jurisdicción", "Categoría OSM", "km"]) +
    mapa("m08_rutas", "Figura 5. Red vial principal por jurisdicción.")))
H.append(bloque("8.3 Establecimientos de salud y distribución espacial",
    f"{n_sal_lp} establecimientos en OSM ({v(f'SELECT count(*) FROM salud WHERE id_depto={LP} AND tipo=$$hospital$$')} hospitales y "
    f"{v(f'SELECT count(*) FROM salud WHERE id_depto={LP} AND tipo=$$clinic$$')} clínicas/consultorios).",
    "Se asigna a cada establecimiento la localidad más cercana (KNN con el operador <code>&lt;-&gt;</code>) y se calcula la distancia "
    "al vecino más cercano entre establecimientos.",
    "La distribución es <b>concentrada</b>: todos los establecimientos están dentro o en el borde de una localidad (mediana entre "
    "vecinos ≈400 m), y La Paz (ciudad) reúne 6. El espacio rural entre localidades no tiene oferta. Con 22,6 establecimientos cada "
    "10.000 km², La Paz está en el puesto 7 de 17, muy lejos de Paraná (105,8).",
    tabla("SELECT localidad, count(*), count(*) FILTER (WHERE tipo='hospital'), count(*) FILTER (WHERE tipo='clinic') FROM r8_salud_lapaz GROUP BY 1 ORDER BY 2 DESC",
          ["Localidad", "Total", "Hospitales", "Clínicas"])))
H.append(bloque("8.4 Localidad más alejada",
    f"<b>{lejana[0]}</b>, a {num(lejana[1], 0)} m de «{lejana[2]}».",
    "<b>Criterio:</b> distancia euclídea en EPSG:5347 desde el punto de la localidad al establecimiento más cercano, buscado "
    "<i>en toda la provincia</i> (una persona del borde puede atenderse en el departamento vecino). Se usa KNN (<code>ORDER BY "
    "s.geom_m &lt;-&gt; l.geom_m LIMIT 1</code>) con <code>CROSS JOIN LATERAL</code>. También se calculó la variante «solo hospitales». "
    "La distancia por red vial está en el punto 13.",
    "Las localidades sin oferta propia (Colonia Avigdor, Sir Leonard) dependen de otra localidad. En el caso de Colonia Avigdor, "
    "por red vial su hospital más cercano está en <i>otro departamento</i> (Hospital Crispín Velázquez, Federal; ver punto 13).",
    tabla("SELECT ranking_lejania, nombre, poblacion, salud_mas_cercana, tipo_salud, distancia_m FROM r8_dist_localidad_salud ORDER BY ranking_lejania",
          ["#", "Localidad", "Población", "Establecimiento más cercano", "Tipo", "Distancia (m)"])))
H.append(bloque("8.5 Área de cobertura sanitaria (5 km)",
    f"<b>{sin_cob}</b> de {n_loc_lp} localidades quedan fuera de la cobertura de 5 km: {sin_cob_n}. "
    f"La cobertura abarca solo el {num(pct_cub, 1)} % del territorio departamental.",
    "<code>ST_Union(ST_Buffer(s.geom_m, 5000))</code> sobre los establecimientos a menos de 5 km del departamento (incluye vecinos) "
    "y <code>NOT EXISTS (… ST_Intersects(cobertura, localidad))</code>.",
    "Las localidades fuera de cobertura son las más pequeñas y rurales: allí la atención depende de traslados largos, por caminos de "
    "tierra que, como se ve en el punto 9, cruzan arroyos. El 92 % del territorio (población rural dispersa) queda a más de 5 km de un servicio de salud.",
    tabla("SELECT nombre, poblacion, distancia_m FROM r8_localidades_sin_cobertura ORDER BY distancia_m DESC", ["Localidad", "Población", "Distancia al más cercano (m)"]) +
    mapa("m08_cobertura", "Figura 6. Cobertura de 5 km alrededor de los establecimientos de salud.")))

# ---------------- 6 / punto 9
H.append("<h1>6. Gestión del riesgo hídrico (punto 9)</h1>")
H.append(bloque("9.1 Zona de Riesgo Hídrico (ZRH)",
    f"ZRH de La Paz: <b>{num(zrh[0], 1)} km² ({num(zrh[1], 1)} %)</b> del departamento. Variante «principal», sin los arroyos menores "
    f"(<code>stream</code>): {num(zrh[2], 1)} km² ({num(zrh[3], 1)} %).",
    "Para cada departamento: elementos hídricos a menos de 2 km (<code>ST_DWithin</code>, que usa el índice), <code>ST_Simplify</code> a 25 m, "
    "<code>ST_Buffer</code> de 2.000 m, disolución con <code>ST_Union</code> y recorte con <code>ST_Intersection</code>. "
    "La primera versión (buffer sobre la colección sin simplificar) tardaba más de 10 minutos por la cantidad de vértices; con "
    "un buffer de 2 km el detalle de 25 m es irrelevante y el cálculo bajó a segundos por departamento.",
    "Con una red de drenaje tan densa, un buffer de 2 km cubre casi dos tercios del territorio. Se trata de una simplificación académica "
    "(no reemplaza a un mapa oficial de inundación), y su resultado depende mucho de qué tan detallado esté mapeado OSM. Por eso se "
    "trabaja con las dos variantes.",
    code('''INSERT INTO entrerios.zona_riesgo_hidrico (id_depto, depto, geom_m, geom_m_principal)
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
) h GROUP BY d.id;''') + mapa("m09_zrh", "Figura 7. Zona de Riesgo Hídrico (2 km) y establecimientos de salud expuestos.")))
H.append(bloque("9.2 Infraestructura sanitaria expuesta",
    f"<b>{sal_exp} de {n_sal_lp}</b> establecimientos están dentro de la ZRH.",
    "<code>ST_Intersects(zrh.geom_m, salud.geom_m)</code> y, para cada uno, el elemento hídrico más cercano (KNN sobre ríos, lagunas y cauces).",
    "Todos los establecimientos de salud están expuestos: las localidades de La Paz se fundaron junto al Paraná o a arroyos "
    "(agua para consumo, puertos, molinos). En la práctica, la amenaza no es igual para todos. Los de La Paz (ciudad) están sobre la "
    "barranca, por encima del nivel del río. Pero el resultado indica que, ante una crecida, ningún establecimiento puede considerarse a "
    "salvo del aislamiento, y que hay que planificar su acceso y abastecimiento (puntos 9.3 y 13).",
    tabla("SELECT nombre, tipo, agua_cercana, dist_agua_m FROM r9_salud_expuesta ORDER BY dist_agua_m", ["Establecimiento", "Tipo", "Agua más cercana", "Distancia (m)"])))
H.append(bloque("9.3 Posibles situaciones de aislamiento",
    "Una clasificación de riesgo de aislamiento (ALTO/MEDIO/BAJO) por localidad y el inventario de cruces entre la red vial principal y los cursos de agua.",
    "<b>Metodología.</b> (a) Para cada localidad se busca el punto más cercano de la red RN/RP (<code>ST_ClosestPoint</code>) y se "
    "construye el conector localidad→ruta (<code>ST_MakeLine</code>); si el conector cruza un río o arroyo (<code>ST_Intersects</code>), "
    "la salida a la red principal depende de un puente o una alcantarilla. (b) Se mide qué proporción de las vías a menos de 5 km "
    "(<code>ST_DWithin</code>) está dentro de la ZRH. Es ALTO si se cumplen ambas condiciones (cruce de agua y más del 50 % de vías en ZRH) y "
    "MEDIO si se cumple una. (c) Se calculan los puntos de cruce ruta × curso (<code>ST_Intersection</code> → <code>ST_Dump</code>) y se verifica "
    "si OSM registra un puente a menos de 50 m (<code>ST_DWithin</code>).",
    "Piedras Blancas, Colonia Avigdor y Sir Leonard llegan a la red principal cruzando arroyos (Hernandarias, Macieguitas): una crecida "
    "puede dejarlas sin salida. La Paz (ciudad) también aparece en ALTO porque su conector cruza los arroyos urbanos Cabayú Cutiá y "
    "Los Paraísos. En su caso el riesgo es menor de lo que indica la clasificación, porque tiene varios accesos y puentes urbanos, y eso muestra la "
    "limitación de usar un único conector en línea recta. Sobre la RN12 hay 44 cruces con cursos de agua y en 29 OSM no registra puente: pueden ser alcantarillas "
    "(un punto débil real ante crecidas) o puentes que nadie cargó (una limitación de la fuente, ver 11.4).",
    tabla("SELECT localidad, poblacion, ruta_mas_cercana, dist_ruta_m, cruces_agua, cursos_cruzados, pct_vias_entorno_en_zrh, riesgo_aislamiento FROM r9_aislamiento ORDER BY riesgo_aislamiento, pct_vias_entorno_en_zrh DESC",
          ["Localidad", "Pobl.", "Ruta", "Dist. (m)", "Cruces", "Cursos cruzados", "% vías en ZRH", "Riesgo"]) +
    tabla("SELECT ruta, count(*), count(*) FILTER (WHERE puente_osm), count(*) FILTER (WHERE NOT puente_osm) FROM r9_cruces_ruta_agua GROUP BY ruta ORDER BY 2 DESC",
          ["Ruta", "Cruces", "Con puente OSM", "Sin puente registrado"]) +
    mapa("m09_aislamiento", "Figura 8. Riesgo de aislamiento, conectores y cruces de agua.")))
H.append(bloque("9.4 Departamentos con mayor exposición (umbral 30 %)",
    f"Con la ZRH completa, <b>{n_sup30} de 17</b> departamentos superan el 30 %. Con la variante principal, {n_sup30p} lo superan "
    f"(queda debajo {no_sup30p}).",
    "Para cada departamento, <code>ST_Area(zrh)/ST_Area(depto)</code> y el porcentaje de cuerpos de agua (lagunas + cauces, unidos).",
    "El umbral del 30 % no discrimina: con un buffer de 2 km sobre la red de drenaje de OSM, toda Entre Ríos queda «expuesta». "
    "Esto es un resultado en sí mismo: la provincia es estructuralmente hídrica, y para priorizar hace falta un criterio más fino "
    "(cota, suelos hidromórficos, recurrencia de crecidas). Diamante y Victoria encabezan por el delta y las islas del Paraná. "
    "La Paz queda en el puesto 14: tiene mucha agua en el borde (Paraná y Guayquiraró), pero en su interior la red de cursos mapeados es menos densa que en el sur y el este de la provincia.",
    tabla("SELECT ranking, nombre, sup_km2, pct_agua, pct_zrh, supera_30, pct_zrh_principal, supera_30_principal FROM r9_exposicion_deptos ORDER BY ranking",
          ["#", "Departamento", "km²", "% agua", "% ZRH", "≥30 %", "% ZRH princ.", "≥30 % princ."]) +
    mapa("m09_exposicion", "Figura 9. Porcentaje de superficie en ZRH por departamento.")))

# ---------------- 7 / punto 10
H.append("<h1>7. Funciones y automatización mediante SQL (punto 10)</h1>")
H.append(bloque("10.1 fn_riesgo_localidad(nombre_localidad)",
    "Una función que devuelve, para la localidad pedida, el elemento hídrico más cercano, la distancia y la clase Alto (&lt; 1 km), Medio (1–3 km) o Bajo (&gt; 3 km).",
    "KNN (<code>&lt;-&gt;</code>) sobre ríos, lagunas y cauces, tomando el mínimo de los tres. Devuelve una fila por homónimo (con departamento y "
    "osm_id) e ignora mayúsculas y tildes.",
    f"{v('SELECT count(*) FROM localidades l CROSS JOIN LATERAL fn_riesgo_localidad(l.nombre) r WHERE r.osm_id=l.osm_id AND r.riesgo=$$Alto$$')} de "
    f"{v('SELECT count(*) FROM localidades')} localidades de la provincia quedan en riesgo Alto: es coherente con 9.4, porque casi todos los pueblos "
    "entrerrianos están a menos de 1 km de algún curso de agua. La clasificación por distancia sirve como primer filtro, pero no reemplaza un análisis de cota.",
    code('''CREATE OR REPLACE FUNCTION entrerios.fn_riesgo_localidad(nombre_localidad text)
RETURNS TABLE (localidad text, departamento text, osm_id text, elemento_cercano text,
               tipo_elemento text, distancia_m numeric, riesgo text)
LANGUAGE sql STABLE AS $$
  WITH loc AS (SELECT l.*, d.nombre AS depto FROM entrerios.localidades l
               JOIN entrerios.departamentos d ON d.id = l.id_depto
               WHERE translate(lower(l.nombre),'áéíóúü','aeiouu')
                   = translate(lower(trim(nombre_localidad)),'áéíóúü','aeiouu'))
  SELECT loc.nombre, loc.depto, loc.osm_id, h.nombre, h.tipo, round(h.dist::numeric),
         CASE WHEN h.dist < 1000 THEN 'Alto' WHEN h.dist <= 3000 THEN 'Medio' ELSE 'Bajo' END
  FROM loc CROSS JOIN LATERAL (
     SELECT * FROM (
       (SELECT r.nombre, r.tipo, ST_Distance(r.geom_m, loc.geom_m) dist FROM entrerios.rios r
         ORDER BY r.geom_m <-> loc.geom_m LIMIT 1)
       UNION ALL (... lagunas ...) UNION ALL (... rios_area ...)
     ) c ORDER BY dist LIMIT 1) h;
$$;''') +
    tabla("SELECT r.localidad, r.elemento_cercano, r.tipo_elemento, r.distancia_m, r.riesgo FROM (SELECT DISTINCT nombre FROM localidades WHERE id_depto=" + LP + ") x CROSS JOIN LATERAL fn_riesgo_localidad(x.nombre) r WHERE r.departamento='La Paz' ORDER BY r.distancia_m",
          ["Localidad (La Paz)", "Elemento más cercano", "Tipo", "Distancia (m)", "Riesgo"]) +
    tabla("SELECT * FROM fn_riesgo_localidad('Paraná') UNION ALL SELECT * FROM fn_riesgo_localidad('concordia') UNION ALL SELECT * FROM fn_riesgo_localidad('Villaguay')",
          ["Localidad", "Depto.", "osm_id", "Elemento", "Tipo", "Dist. (m)", "Riesgo"], caption="Pruebas con otras localidades (búsqueda sin tildes ni mayúsculas)")))
H.append(bloque("10.2 MBR de Entre Ríos",
    f"Un MBR de {num(mbr[0], 0)} km² frente a una provincia de {num(mbr[1], 0)} km²: el territorio ocupa el "
    f"{num(100*mbr[1]/mbr[0], 1)} % del rectángulo (relación {num(mbr[0]/mbr[1], 2)}).",
    "<code>ST_Envelope(provincia.geom)</code> en 4326 y área con <code>::geography</code>.",
    "El MBR es el rectángulo alineado con meridianos y paralelos definido por las coordenadas extremas (mín./máx. de x e y). Es más grande "
    "porque incluye superficie que no es provincia: Entre Ríos tiene forma irregular, «encajonada» entre dos ríos que corren en diagonal, con "
    "el delta al sur y una punta norte angosta, así que las esquinas del rectángulo caen sobre Santa Fe, Corrientes, Uruguay y el río. Por eso el MBR "
    "sirve como filtro rápido en los índices espaciales (el operador <code>&amp;&amp;</code> compara MBR), pero nunca para medir.",
    mapa("m10_mbr", "Figura 10. MBR (ST_Envelope) y contorno real de Entre Ríos.")))
H.append(bloque("10.3 fn_hospital_cercano(lat, lon)",
    "Una función que, dada una posición GPS, devuelve el establecimiento más cercano, su departamento y la distancia.",
    "Se preseleccionan 10 candidatos con KNN (rápido, en grados) y se ordenan por <code>ST_Distance(::geography)</code> (geodésica, exacta en "
    "cualquier lugar). Atención: <code>ST_MakePoint</code> recibe (lon, lat). Tiene un tercer parámetro opcional para buscar solo hospitales.",
    "Simula el pedido de auxilio de una persona que solo puede dar su posición. En el norte del departamento el hospital más cercano está "
    "a más de 30 km; en el centro-este, el más cercano está en otro departamento (Federal). La función toma ese caso porque busca en toda la provincia.",
    code('''CREATE OR REPLACE FUNCTION entrerios.fn_hospital_cercano(lat double precision, lon double precision,
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
$$;''') +
    tabla("""SELECT 'Plaza de La Paz (-30.7423, -59.6455)', * FROM fn_hospital_cercano(-30.7423, -59.6455)
UNION ALL SELECT 'Campo entre Bovril y Alcaraz (-31.10, -59.30)', * FROM fn_hospital_cercano(-31.10, -59.30)
UNION ALL SELECT 'Norte, cerca del Guayquiraró (-30.40, -59.40)', * FROM fn_hospital_cercano(-30.40, -59.40)
UNION ALL SELECT 'Mismo punto, solo hospitales', * FROM fn_hospital_cercano(-30.40, -59.40, true)""",
          ["Caso", "Establecimiento", "Tipo", "Depto.", "m", "km"])))
H.append(bloque("10.4 Agrupamiento con ST_ClusterKMeans (k = 3)",
    "Tres grupos de establecimientos con su centroide.",
    "<code>ST_ClusterKMeans(geom_m, 3) OVER ()</code> (función de ventana, en coordenadas métricas) y <code>ST_Centroid(ST_Collect(...))</code> por grupo.",
    "Los grupos coinciden con los tres polos sanitarios del departamento: <b>La Paz (ciudad)</b> al noroeste, <b>Santa Elena–El Quebracho–Piedras "
    "Blancas</b> al oeste y <b>Bovril–Alcaraz</b> al sudeste. Los centroides marcan el «centro de gravedad» de cada polo: son lugares razonables "
    "para una base de ambulancias o un depósito de medicamentos que abastezca a todo el grupo. El centroide de Bovril–Alcaraz cae en el campo, "
    "cerca de Sir Leonard, una de las localidades sin cobertura, así que una base ahí acercaría el servicio a quien hoy no lo tiene. Como "
    "limitación, el centroide es geométrico: no tiene en cuenta la red vial (eso lo resuelven los puntos 13 y 14).",
    tabla("SELECT c.grupo, c.establecimientos, round(ST_Y(c.geom)::numeric,4), round(ST_X(c.geom)::numeric,4), c.integrantes FROM r10_kmeans_centroides c ORDER BY c.grupo",
          ["Grupo", "N", "Lat", "Lon", "Integrantes"]) +
    mapa("m10_kmeans", "Figura 11. Grupos K-means y sus centroides.")))

# ---------------- 8 / punto 11
H.append("<h1>8. Calles, OpenStreetMap y Argenmap (punto 11)</h1>")
H.append(bloque("11.1 Densidad de la red vial",
    f"La Paz suma {num(calles[0], 1)} km de calles, un {num(100*(float(calles[0])/float(calles[1])-1), 1)} % más que el promedio provincial "
    f"({num(calles[1], 1)} km). Su <b>densidad</b>, en cambio, es de {num(calles[2], 3)} km/km², por debajo del promedio ({num(calles[3], 3)}).",
    "<code>ST_Length</code> de las calles recortadas a cada departamento y división por su superficie.",
    "La comparación por longitud total engaña: La Paz tiene muchos km porque es grande. Por km² está en el puesto 12 de 17, lo que muestra una "
    "red rural rala (el 74 % son caminos <i>unclassified</i>, casi todos de tierra).",
    tabla("SELECT nombre, km_calles, sup_km2, densidad_km_km2 FROM r11_calles_depto ORDER BY km_calles DESC", ["Departamento", "km de calles", "km²", "km/km²"])))
H.append(bloque("11.2 Densidad vial por localidad",
    f"La mayor densidad es la de <b>{dens_top[0]}</b>: {num(dens_top[1], 2)} km/km² ({num(dens_top[2], 2)} km en {num(dens_top[3], 3)} km²).",
    "<b>Decisiones.</b> Las localidades de OSM son puntos y los ejidos (admin_level 7/8) incluyen grandes áreas rurales, así que no sirven como «superficie de la "
    "localidad». Se estimó la <b>mancha urbana</b> a partir de la propia trama de calles: <code>ST_ClusterDBSCAN(eps 100 m, minpoints 5)</code> sobre las calles "
    "<i>residential</i>, asignación del cluster a la localidad más cercana (&lt; 1,5 km) y superficie = <code>ST_Buffer(ST_ConcaveHull(cluster, 0.4), 50)</code>. "
    "En un primer intento se incluyeron las <i>unclassified</i>, pero DBSCAN encadenaba los caminos rurales y la «mancha» de La Paz daba 862 km². "
    "Densidad = km de calles (todas las categorías) dentro de la mancha / km².",
    "Las localidades chicas y compactas (Alcaraz, Sir Leonard, San Gustavo), con damero denso y pocas manzanas, tienen más densidad que la ciudad de "
    "La Paz, cuya mancha incluye barrios periféricos, quintas y la barranca con trama más abierta.",
    tabla("SELECT localidad, poblacion, sup_km2, km_calles, densidad_km_km2 FROM r11_densidad_localidad ORDER BY densidad_km_km2 DESC",
          ["Localidad", "Población", "Mancha (km²)", "km calles", "km/km²"]) +
    mapa("m11_densidad", "Figura 12. Mancha urbana estimada por DBSCAN + envolvente cóncava (La Paz ciudad).")))
H.append(bloque("11.3 Categorías de calles",
    "Kilómetros de calles <i>primary</i> y <i>secondary</i> dentro del departamento.",
    "Filtro por <code>highway</code> y <code>ST_Length(ST_Intersection(...))</code> con <code>GROUP BY ROLLUP</code>.",
    "Coinciden con la red de rutas del punto 8 (RN127/RP1 primary, RP6 secondary): en OSM las rutas son también «calles» de categoría alta.",
    tabla("""SELECT COALESCE(c.highway,'Total'), count(*), round((sum(ST_Length(ST_Intersection(c.geom_m,d.geom_m)))/1000)::numeric,2)
FROM calles c JOIN departamentos d ON d.nombre='La Paz' AND ST_Intersects(c.geom_m,d.geom_m)
WHERE c.highway IN ('primary','secondary') GROUP BY ROLLUP (c.highway) ORDER BY c.highway""", ["Categoría", "Tramos", "km"])))
H.append(bloque("11.4 Comparación con Argenmap",
    f"Una comparación visual de las calles de OSM sobre Argenmap en QGIS, más indicadores: {puentes[0]} puentes en OSM ({num(puentes[1], 0)} m) y la superficie declarada de las vías.",
    "Superposición en QGIS (Argenmap como XYZ <code>{-y}</code>, calles OSM de PostGIS) y consultas sobre <code>bridge</code> y <code>surface</code>.",
    "<b>Cobertura:</b> en la planta urbana de La Paz (Figura 13) la trama de calles de OSM se superpone casi exactamente con las manzanas "
    "de Argenmap. En la periferia y el campo, OSM agrega la cuadrícula de caminos vecinales entre chacras (al sur y al este de la ciudad), "
    "que en Argenmap no aparece o aparece con menor jerarquía. "
    "<b>Ubicación de las vías:</b> en la RN12, la avenida de acceso (A01) y las calles del centro, las diferencias no se distinguen a esta escala "
    "(pocos metros). "
    "<b>Sectores rurales:</b> la información de transitabilidad de OSM es incompleta: el 73 % de los km figura como <i>unpaved</i> y el 19 % no tiene dato de superficie. "
    "<b>Ríos y arroyos:</b> los arroyos urbanos (Cabayú Cutiá, Los Paraísos) están en ambas fuentes; en OSM son líneas con nombre, y eso es "
    "lo que permite calcular cruces y distancias en PostGIS. "
    "<b>Puentes:</b> OSM modela cada puente como un tramo con <code>bridge=yes</code>: en la ciudad se ven los puentes de las calles sobre los "
    "arroyos urbanos, y en el campo los de la RP6 sobre el Feliciano y la RP5 sobre el Estacas. Sobre la RN12, en cambio, 29 de 44 cruces con cursos "
    "de agua no tienen puente cargado en OSM (9.3); queda pendiente contrastarlos punto por punto con Argenmap. "
    "<b>Por qué difieren:</b> son fuentes con objetivos y procesos distintos. Argenmap es cartografía oficial, generalizada para una escala y "
    "actualizada por relevamiento institucional; OSM es colaborativo, más detallado donde hubo mapeadores y desparejo donde no los hubo. "
    "Ninguna es «mejor»: OSM aporta detalle rural y atributos consultables; Argenmap, homogeneidad y respaldo oficial.",
    tabla("""SELECT CASE WHEN c.superficie IN ('asphalt','paved','concrete','paving_stones','sett','chipseal') THEN 'pavimentada'
 WHEN c.superficie IS NULL THEN 'sin dato' ELSE 'no pavimentada' END, round((sum(ST_Length(ST_Intersection(c.geom_m,d.geom_m)))/1000)::numeric,1)
FROM calles c JOIN departamentos d ON d.nombre='La Paz' AND ST_Intersects(c.geom_m,d.geom_m) GROUP BY 1 ORDER BY 2 DESC""", ["Superficie (OSM)", "km"]) +
    mapa("m11_osm_argenmap", "Figura 13. Calles de OSM y puentes sobre el mapa base Argenmap (La Paz y alrededores).")))

# ---------------- 9 / punto 12
H.append("<h1>9. Información del INTA y uso del suelo (punto 12)</h1>")
H.append("""<p>Capa: <b>Carta de Suelos de Entre Ríos 1:100.000</b> (WFS INTA geo-nodo03), almacenada como <code>entrerios.suelo</code>.
Describe la <b>aptitud</b> (no el uso actual). Clasificación adoptada a partir del Índice de Productividad (IPC):</p>
<table><thead><tr><th>Clase</th><th>Criterio</th><th>Interpretación</th></tr></thead><tbody>
<tr><td>Agrícola</td><td>IPC ≥ 30</td><td>Suelos aptos para cultivos (argiudoles de lomas)</td></tr>
<tr><td>Agrícola-ganadera</td><td>20 ≤ IPC &lt; 30</td><td>Cultivos con limitaciones, rotación con ganadería</td></tr>
<tr><td>Ganadera</td><td>1 ≤ IPC &lt; 20</td><td>Limitaciones severas (vertisoles, hidromorfismo, sodicidad)</td></tr>
<tr><td>Planicie inundable / agua</td><td>IPC = 0 y unidad Ar, AIB, CR, CAg</td><td>Arroyos, islas y bañados, cárcavas, cuerpos de agua</td></tr>
<tr><td>Urbana</td><td>IPC = 0 y unidad AU</td><td>Ejidos urbanos (la carta también les asigna IPC 0)</td></tr>
</tbody></table>
<div class="nota">Que las áreas urbanas tengan IPC = 0, igual que los bañados, se detectó al revisar el escenario del punto 13 (cortaba calles urbanas como si fueran planicie inundable).
Por eso las clases de IPC 0 se separan según el tipo de unidad cartográfica.</div>""")
H.append(bloque("12.1 Uso (aptitud) del suelo",
    f"El <b>{num(pct_agri[0], 1)} %</b> del departamento tiene aptitud agrícola y el {num(100-float(pct_agri[0]), 1)} % corresponde a otros usos. "
    f"Sensibilidad al umbral: con IPC ≥ 20 sería {num(pct_agri[1], 1)} %; con IPC ≥ 40, {num(pct_agri[2], 1)} %.",
    "Intersección de las unidades de suelo con el departamento y <code>ST_Area</code> por clase.",
    "La Paz es mayormente ganadera y mixta: los vertisoles y los suelos con drenaje deficiente dominan el centro y el norte. La agricultura se "
    "concentra en las lomas del sur y sudeste (series Tacuaras, Alcaraz, Banderas, Malambo), alrededor de Bovril y Alcaraz.",
    tabla("SELECT clase, round((sum(ST_Area(geom_m))/1e6)::numeric,1), round((100*sum(ST_Area(geom_m))/(SELECT ST_Area(geom_m) FROM departamentos WHERE nombre='La Paz'))::numeric,1) FROM r12_suelo_lapaz GROUP BY clase ORDER BY 2 DESC",
          ["Clase", "km²", "% del depto."]) +
    mapa("m12_suelo", "Figura 14. Aptitud del suelo según el índice de productividad (INTA).")))
H.append(bloque("12.2 Áreas agrícolas expuestas",
    f"{num(agri_exp[0], 1)} km² de suelo agrícola están dentro de la ZRH: el <b>{num(agri_exp[1], 1)} %</b> del área agrícola.",
    "<code>ST_Intersection(suelo_agricola.geom_m, zrh.geom_m)</code>.",
    "Más de dos tercios de la mejor tierra está a menos de 2 km de un curso de agua: en las lomas agrícolas la red de arroyos es densa. "
    "Es una primera aproximación: el suelo agrícola suele estar en las partes altas, así que la exposición real es menor que la geométrica. "
    "Las unidades con más superficie expuesta son Tacuaras (IPC 62, la mejor del departamento), Malambo y Banderas.",
    tabla("SELECT unidad, ipc, round((sum(ST_Area(geom_m))/1e6)::numeric,1) FROM r12_agricola_expuesta GROUP BY 1,2 ORDER BY 3 DESC LIMIT 8",
          ["Unidad", "IPC", "km² expuestos"])))
H.append(bloque("12.3 Corredores productivos",
    "Los km de cada ruta que atraviesan suelo agrícola, y la superficie agrícola a menos de 2 km de cada ruta (el «corredor»).",
    "<code>ST_Intersection(ruta, ST_Union(agricola))</code> para la longitud y <code>ST_Intersection(ST_Buffer(ruta, 2000), agricola)</code> para el corredor.",
    "La <b>RN12</b> es el corredor productivo principal: 40 km sobre suelo agrícola y 151 km² de producción con salida directa. Es la ruta que saca la "
    "producción del sur del departamento (Bovril–Alcaraz) hacia Paraná. La RPA02 y la RPA01 son corredores cortos pero intensos. La RP1 y la RN127 casi no "
    "atraviesan suelo agrícola. Esto se cruza con el punto 13: los cortes de la RN127 y la RN12 por crecida afectan justamente el corredor productivo del sur.",
    tabla("SELECT ref, jurisdiccion, km_ruta, km_en_agricola, pct_en_agricola, sup_agricola_corredor_2km_km2 FROM r12_corredores ORDER BY km_en_agricola DESC",
          ["Ruta", "Jurisdicción", "km ruta", "km en agrícola", "%", "Corredor 2 km (km²)"]) +
    mapa("m12_expuesta_corredores", "Figura 15. Suelo agrícola expuesto (ZRH) y corredores productivos.")))

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
<p><b>Grafo.</b> Se tomaron las vías transitables en un radio de 30 km alrededor de La Paz (para incluir hospitales de los departamentos vecinos).
En OSM las vías se conectan compartiendo nodos, que pueden estar en el medio de un <i>way</i>, así que cada way se partió en sus segmentos
(<code>ST_DumpSegments</code>) para que cada nodo sea un vértice. Los vértices se obtuvieron con <code>pgr_extractVertices</code>; en pgRouting 4
reemplaza a <code>pgr_createTopology</code> y devuelve las aristas entrantes y salientes de cada vértice. El costo es el tiempo de viaje en minutos según la categoría
(90 km/h troncales, 80 primarias, 60 secundarias, 50 terciarias, 40 vecinales, 30 urbanas). Resultado: {num(corte[3])} aristas,
{num(corte[4], 0)} km.</p>
<p><b>Tramos cortados</b> (no puente según OSM): (a) cruzan un río o arroyo (vado/alcantarilla) o (b) están en la ZRH principal sobre una
unidad INTA de planicie inundable. Se cortan <b>{num(corte[1], 1)} km ({num(corte[2], 1)} % de la red)</b>, entre ellos tramos de la RN127, la RN12, la RP8 y la RP10.</p>
{code('''-- (a) cruces de agua sin puente
UPDATE entrerios.red_vial e SET cortado = true
WHERE NOT e.puente AND EXISTS (SELECT 1 FROM entrerios.rios r WHERE ST_Intersects(r.geom_m, e.geom_m));
-- (b) planicie inundable INTA dentro de la ZRH principal
UPDATE entrerios.red_vial e SET cortado = true
WHERE NOT e.cortado AND NOT e.puente
  AND EXISTS (SELECT 1 FROM tmp_planicie p WHERE ST_Intersects(p.g, e.geom_m));

-- tiempos normal vs crecida al hospital de referencia
SELECT * FROM pgr_dijkstraCost(
  'SELECT id, source, target, costo_min AS cost, costo_min AS reverse_cost
   FROM entrerios.red_vial WHERE NOT cortado',
  (SELECT array_agg(vid) FROM tmp_zonal), (SELECT vid FROM tmp_zonal_h));''')}
<h2>10.4 Resultados</h2>
<p><b>Acceso al hospital más cercano.</b> Como casi todas las localidades tienen un centro de salud propio, la crecida casi no cambia el acceso
al establecimiento más cercano. La excepción es Sir Leonard, que debe derivarse a otro hospital:</p>
{tabla("SELECT localidad, poblacion, hospital_normal, min_normal, hospital_crecida, min_crecida, demora_extra_min, situacion FROM r13_impacto_crecida ORDER BY demora_extra_min DESC NULLS FIRST",
       ["Localidad", "Pobl.", "Hospital (normal)", "min", "Hospital (crecida)", "min", "+min", "Situación"])}
<p><b>Derivación al hospital de referencia (Hospital Zonal 9 de Julio, La Paz).</b> Los casos graves se derivan a la cabecera, y ahí aparece el impacto:</p>
{tabla("SELECT rank() OVER (ORDER BY (situacion='AISLADA') DESC, poblacion*COALESCE(demora_extra_min,0) DESC), localidad, poblacion, min_normal, min_crecida, demora_extra_min, pct_extra, situacion FROM r13_derivacion_zonal ORDER BY 1",
       ["Prioridad", "Localidad", "Pobl.", "min normal", "min crecida", "+min", "+%", "Situación"])}
{tabla("SELECT localidad, escenario, minutos, km FROM r13_rutas_hospital WHERE hospital LIKE '%derivación%' ORDER BY localidad, escenario DESC",
       ["Localidad", "Escenario", "min", "km"], caption="Ruta normal y ruta alternativa (pgr_dijkstra) hacia el hospital zonal")}
{mapa("m13_crecida", "Figura 16. Tramos cortados por la crecida y rutas normal/alternativa de derivación.")}
<h2>10.5 Decisiones que se pueden tomar</h2>
<ul>
<li><b>Piedras Blancas queda aislada</b> del hospital zonal. Su único hospital local (Centro de Salud) debe recibir antes de la crecida
insumos y personal para operar de forma autónoma, o hay que coordinar una evacuación aérea o fluvial (está sobre el Paraná).</li>
<li><b>Alcaraz y Sir Leonard</b> casi duplican el tiempo de derivación (+84 y +92 min) porque se cortan tramos de la RN127, la RN12 y caminos vecinales de su ruta habitual.
Conviene preposicionar una ambulancia de alta complejidad en Bovril o Alcaraz durante el evento, en lugar de depender del traslado a La Paz.</li>
<li><b>Prioridad de obra:</b> los tramos cortados que usan las rutas de derivación normales (RN127, RN12, caminos vecinales) son los primeros
candidatos para elevar la rasante o reemplazar alcantarillas por puentes.</li>
<li>La ciudad de La Paz, Santa Elena y San Gustavo no se ven afectadas en el acceso: pueden funcionar como base logística.</li>
</ul>
""")

# ---------------- 11 / punto 14
mj = "".join(f"<li><b>#{m[0]}</b> ({num(m[1], 5)}, {num(m[2], 5)}): sobre la {m[5]} (a {num(m[6], 0)} m), a {num(m[4]/1000, 1)} km de {m[3]}; "
             f"{num(m[7], 2)} km² libres; puntaje {num(m[8], 3)}. Localidades a ≤ 45 min en crecida: {m[9] or '—'}.</li>" for m in mejor)
H.append(f"""
<h1>11. Problema: ubicación de un Centro de Atención Sanitaria de Emergencia (punto 14)</h1>
<h2>11.1 Definición del problema</h2>
<p>Elegir uno o más sitios en el departamento La Paz para un Centro de Atención Sanitaria de Emergencia (CASE) que funcione
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
<li><code>ST_HexagonGrid</code>: genera una grilla hexagonal sobre el departamento. Se eligió hexágono y no cuadrado porque todas las celdas vecinas están a la misma distancia.</li>
<li><code>ST_Difference</code> / <code>ST_Union</code>: restan del hexágono las áreas excluidas.</li>
<li><code>ST_Dump</code> + <code>ST_Area</code>: separan el área libre en parches y se queda con el mayor parche <i>continuo</i> (no alcanza con 50 ha dispersas).</li>
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
{code('''-- criterios excluyentes: mayor parche libre continuo de cada hexágono
WITH libre AS (
  SELECT g.id, ST_Difference(g.geom_m, ST_Intersection(r.g, g.geom_m)) AS libre
  FROM entrerios.r14_grilla g, tmp_restriccion r          -- ZRH principal ∪ agua ∪ IPC>=40
), parche AS (
  SELECT DISTINCT ON (l.id) l.id, p.geom, ST_Area(p.geom) AS area
  FROM libre l CROSS JOIN LATERAL ST_Dump(ST_CollectionExtract(l.libre, 3)) p
  ORDER BY l.id, ST_Area(p.geom) DESC)
SELECT ... WHERE area >= 500000 AND dist_ruta <= 3000;

-- puntaje
0.45 * beneficio / max(beneficio) + 0.25 * loc_45min / max(loc_45min)
 + 0.15 * (1 - frac_zrh) + 0.15 * (1 - dist_ruta_m / 3000.0)''')}
<h2>11.6 Resultados</h2>
{tabla("SELECT ranking, puntaje, lat, lon, localidad_ref, dist_localidad_m, ruta, dist_ruta_m, libre_km2, pct_zrh_completa, beneficio_hab_min, loc_45min FROM r14_mejores ORDER BY ranking",
       ["#", "Puntaje", "Lat", "Lon", "Localidad próx.", "Dist. (m)", "Ruta", "Dist. ruta", "Libre km²", "% ZRH", "Beneficio (hab·min)", "Loc. ≤45'"])}
<ul>{mj}</ul>
{mapa("m14_centro", "Figura 17. Celdas aptas según su puntaje y las tres ubicaciones propuestas.")}
<h2>11.7 Análisis de los candidatos y conclusión</h2>
<div id="analisis14">{{ANALISIS14}}</div>
""")

# ---------------- 12 conclusiones
H.append(f"""
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
<p><b>Reproducción:</b> (1) descargar las fuentes (IGN WFS, INTA WFS, Geofabrik); (2) cargar en el esquema <code>fuentes</code> con ogr2ogr;
(3) ejecutar <code>TP2_LaPaz.sql</code> (≈20 min; los puntos 9 y 13 son los más pesados); (4) abrir <code>TP2_LaPaz.qgz</code>.</p>
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
