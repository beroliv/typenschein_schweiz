#!/bin/sh

BASE="/volume1/docker/typenschein"
DATA_DIR="$BASE/data"
TEMPLATES_DIR="$BASE/templates"
IMAGE_NAME="typenschein:latest"
CONTAINER_NAME="typenschein"

echo "==> Setup Verzeichnisse"
mkdir -p "$DATA_DIR" "$TEMPLATES_DIR"

# Dockerfile
echo "==> Schreibe Dockerfile"
cat > "$BASE/Dockerfile" <<'EOF'
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates wget && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --upgrade pip
RUN pip install -r requirements.txt

COPY app.py .
COPY templates ./templates

EXPOSE 5000
CMD ["python", "app.py"]
EOF

# requirements.txt
echo "==> Schreibe requirements.txt"
cat > "$BASE/requirements.txt" <<'EOF'
flask
pandas
requests
fpdf2
EOF

# app.py mit min 3 Zeichen Teil-/Exakt-Suche
echo "==> Schreibe app.py"
cat > "$BASE/app.py" <<'EOF'
# -*- coding: utf-8 -*-
import os
import pandas as pd
from flask import Flask, render_template, request, send_file
from threading import Thread, Lock
import time
from datetime import datetime
import requests
from fpdf import FPDF

app = Flask(__name__)

DATA_DIR = "data"
FILES = {
    "moto": "TG-Moto.txt",
    "auto": "TG-Automobil.txt",
}
URLS = {
    "moto": "https://opendata.astra.admin.ch/ivzod/2000-Typengenehmigungen_TG_TARGA/2200-Basisdaten_TG_ab_1995/TG-Moto.txt",
    "auto": "https://opendata.astra.admin.ch/ivzod/2000-Typengenehmigungen_TG_TARGA/2200-Basisdaten_TG_ab_1995/TG-Automobil.txt",
}

_cache = {}
_lock = Lock()
last_update_time = None
MAX_AGE_SECONDS = 30 * 24 * 3600  # 30 Tage

def needs_update(path):
    if not os.path.exists(path):
        return True
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return True
    return (datetime.now().timestamp() - mtime) > MAX_AGE_SECONDS

def download_if_needed():
    global last_update_time, _cache
    for key, url in URLS.items():
        dest = os.path.join(DATA_DIR, FILES[key])
        try:
            if not needs_update(dest):
                continue
            r = requests.get(url, timeout=30)
            r.raise_for_status()
            with open(dest, "wb") as f:
                f.write(r.content)
            with _lock:
                if key in _cache:
                    del _cache[key]
        except Exception as e:
            print(f"Download error for {key}: {e}")
    last_update_time = datetime.now().strftime("%d.%m.%Y %H:%M")

def periodic_update():
    while True:
        download_if_needed()
        time.sleep(24 * 3600)

def load_csv(key):
    with _lock:
        if key in _cache:
            return _cache[key]
        path = os.path.join(DATA_DIR, FILES.get(key, ""))
        if os.path.exists(path):
            try:
                df = pd.read_csv(path, sep="\t", encoding="latin1", dtype=str, low_memory=False)
            except Exception:
                df = pd.DataFrame()
        else:
            df = pd.DataFrame()
        _cache[key] = df
        return df

def find_typ_col(df):
    for c in df.columns:
        if "typ" in c.lower():
            return c
    return df.columns[0] if len(df.columns) else None

@app.route("/", methods=["GET"])
def index():
    typ = (request.args.get("typ") or "").strip()
    data_type = request.args.get("type", "moto")
    if data_type not in FILES:
        data_type = "moto"
    df = load_csv(data_type)
    rows = []
    if typ and len(typ) >= 3 and not df.empty:
        typcol = find_typ_col(df)
        if typcol:
            series = df[typcol].fillna("").astype(str)
            upper_typ = typ.upper()
            exact_mask = series.str.upper() == upper_typ
            partial_mask = series.str.upper().str.contains(upper_typ, na=False)
            combined = pd.concat([df[exact_mask], df[partial_mask & ~exact_mask]])
            rows = combined.head(200).to_dict(orient="records")
    return render_template("index.html", rows=rows, typ=typ, bm="", data_type=data_type, last_update=last_update_time)

@app.route("/details")
def details():
    typ = (request.args.get("typ") or "").strip()
    data_type = request.args.get("type", "moto")
    if data_type not in FILES:
        data_type = "moto"
    df = load_csv(data_type)
    if df.empty or not typ:
        return "nicht gefunden", 404
    typcol = find_typ_col(df)
    row = df[df[typcol].fillna("").astype(str).str.upper() == typ.upper()]
    if row.empty:
        return "nicht gefunden", 404
    data = {k: v for k, v in row.iloc[0].items() if pd.notna(v) and str(v).strip() and str(v) != "0"}
    return render_template("details.html", data=data, emissions={}, typ=typ, data_type=data_type)

@app.route("/pdf", methods=["POST"])
def pdf():
    typ = (request.args.get("typ") or "").strip()
    data_type = request.args.get("type", "moto")
    if data_type not in FILES:
        data_type = "moto"
    df = load_csv(data_type)
    if df.empty or not typ:
        return "nicht gefunden", 404
    typcol = find_typ_col(df)
    row = df[df[typcol].fillna("").astype(str).str.upper() == typ.upper()]
    if row.empty:
        return "nicht gefunden", 404
    data = {k: v for k, v in row.iloc[0].items() if pd.notna(v) and str(v).strip() and str(v) != "0"}

    pdf_obj = FPDF()
    pdf_obj.add_page()
    pdf_obj.set_font("Arial", size=8)
    pdf_obj.cell(0, 8, txt=f"Typenschein {typ}", ln=True, align="C")
    pdf_obj.ln(2)
    for key, value in data.items():
        pdf_obj.set_font("Arial", style="B", size=8)
        pdf_obj.cell(60, 6, txt=str(key)[:50], border=1)
        pdf_obj.set_font("Arial", size=8)
        pdf_obj.cell(130, 6, txt=str(value)[:90], border=1, ln=True)
    out_path = os.path.join(DATA_DIR, f"{typ}_typenschein.pdf")
    pdf_obj.output(out_path)
    return send_file(out_path, as_attachment=True)

@app.route("/update")
def update():
    download_if_needed()
    return "OK"

if __name__ == "__main__":
    os.makedirs(DATA_DIR, exist_ok=True)
    download_if_needed()
    Thread(target=periodic_update, daemon=True).start()
    app.run(host="0.0.0.0", port=5000)
EOF

# index.html (ohne Marke/Modell, Hinweis ab 3 Zeichen)
echo "==> Schreibe index.html"
cat > "$TEMPLATES_DIR/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<title>Typenschein Suche</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
<style>
  body { padding: 18px; font-size: 0.9rem; }
  small { color: #555; }
  .table-sm th, .table-sm td { padding: 0.35rem; font-size: 0.75rem; }
  #no-results { display: none; }
</style>
</head>
<body>
  <div class="container-fluid">
    <div class="d-flex flex-wrap align-items-start mb-2 gap-3">
      <div>
        <h1 class="h4 mb-0">Typenschein-Suche</h1>
        <small>Suche ab 3 Zeichen, exakte Treffer zuerst.</small>
      </div>
      <div class="ms-auto text-end">
        <div><a id="update-btn" href="/update" class="btn btn-sm btn-outline-secondary"> Jetzt aktualisieren</a></div>
        {% if last_update %}
          <div><small>Letztes Update: {{ last_update }}</small></div>
        {% endif %}
      </div>
    </div>

    <form id="search-form" class="row g-2 mb-2" onsubmit="event.preventDefault(); applySearch();">
      <div class="col-md-4">
        <label class="form-label">Typenschein-Nr.</label>
        <input name="typ" id="typ" placeholder="z.B. 6TB824" value="{{ typ }}" class="form-control" autocomplete="off" autofocus>
      </div>
      <div class="col-md-2">
        <label class="form-label">Quelle</label>
        <select name="type" id="type" class="form-select">
          <option value="moto" {% if data_type=='moto' %}selected{% endif %}>Moto</option>
          <option value="auto" {% if data_type=='auto' %}selected{% endif %}>Auto</option>
        </select>
      </div>
      <div class="col-md-2 d-flex align-items-end">
        <button id="search-btn" class="btn btn-primary w-100" type="submit">Suchen</button>
      </div>
    </form>

    <div id="no-results" class="alert alert-warning">Keine Ergebnisse für deine Suche.</div>

    <div class="table-responsive">
      <table class="table table-sm table-striped">
        <thead class="table-light">
          <tr>
            <th>Typenschein</th>
            <th>Marke</th>
            <th>Typ</th>
            <th>Fahrzeugart</th>
            <th>Aktion</th>
          </tr>
        </thead>
        <tbody id="results-body">
          {% for row in rows %}
            {% set typnum = (row.get('Typengenehmigungsnummer') or row.get('01 Typengenehmigungsnummer') or '') %}
            <tr>
              <td>{{ typnum }}</td>
              <td>{{ row.get('04 Marke','') }}</td>
              <td>{{ row.get('04 Typ','') }}</td>
              <td>{{ row.get('01 Fahrzeugart','') }}</td>
              <td>
                <a class="btn btn-sm btn-outline-primary" href="/details?typ={{ typnum }}&type={{ data_type }}">Details</a>
              </td>
            </tr>
          {% endfor %}
        </tbody>
      </table>
    </div>
  </div>

<script>
let debounceTimer = null;

function setCursorToEnd(el) {
  const val = el.value;
  el.focus();
  el.value = '';
  el.value = val;
}

function applySearch() {
  const typ = document.getElementById('typ').value;
  const type = document.getElementById('type').value;
  const params = new URLSearchParams();
  if (typ) params.set('typ', typ);
  params.set('type', type);
  history.replaceState(null,'','?'+params.toString());
  window.location.search = params.toString();
}

function liveSearch() {
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => { applySearch(); }, 300);
}

const typInput = document.getElementById('typ');
typInput.addEventListener('input', liveSearch);
document.getElementById('type').addEventListener('change', () => { applySearch(); });

window.addEventListener('DOMContentLoaded', () => {
  setCursorToEnd(typInput);
  const tbody = document.getElementById('results-body');
  const no = document.getElementById('no-results');
  if (tbody.children.length === 0 && (typInput.value.trim() !== '') && typInput.value.trim().length >=3) {
    no.style.display = 'block';
  }
});
</script>
</body>
</html>
EOF

# details.html
echo "==> Schreibe details.html"
cat > "$TEMPLATES_DIR/details.html" <<'EOF'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<title>Details {{ typ }}</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
<style>
  body { padding: 16px; font-size: 0.9rem; }
  .key { width: 35%; }
  .value { width: 65%; }
</style>
</head>
<body>
  <div class="d-flex mb-2">
    <a href="/" class="btn btn-sm btn-link">&larr; Zurück</a>
    <h2 class="ms-2 mb-0">Typenschein: {{ typ }}</h2>
    <div class="ms-auto">
      <form action="/pdf?typ={{ typ }}&type={{ data_type }}" method="post" style="display:inline;">
        <button class="btn btn-sm btn-outline-primary">PDF</button>
      </form>
    </div>
  </div>
  <div class="section">
    <h5>Technische Daten</h5>
    <table class="table table-sm table-bordered">
      <tbody>
        {% for k,v in data.items() %}
          <tr>
            <th class="key">{{ k }}</th>
            <td class="value">{{ v }}</td>
          </tr>
        {% endfor %}
      </tbody>
    </table>
  </div>
</body>
</html>
EOF

# .dockerignore
echo "==> Schreibe .dockerignore"
cat > "$BASE/.dockerignore" <<'EOF'
data/
*.zip
*.bak
EOF

# Image bauen
echo "==> Baue Docker-Image $IMAGE_NAME"
cd "$BASE" || exit 1
docker build -t "$IMAGE_NAME" .

# Alten Container entfernen
if docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME\$"; then
  echo "==> Entferne bestehenden Container"
  docker rm -f "$CONTAINER_NAME"
fi

# Container starten
echo "==> Starte Container $CONTAINER_NAME"
docker run -d \
  --name "$CONTAINER_NAME" \
  -p 5050:5000 \
  -v "$DATA_DIR":/app/data:rw \
  --restart unless-stopped \
  "$IMAGE_NAME"

echo "==> Fertig. Zugriff: http://<deine-synology-ip>:5050"
echo "=> /update aufrufen wenn du sofort neue Daten willst"
