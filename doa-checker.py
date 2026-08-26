#!/usr/bin/env python3
"""
DOA Depozito Makine Durumu Kontrol Scripti
Mac Mini uzerinde launchd ile calisir. Tam otomatik:
1. Rastgele gecikme (0-600s)
2. SMS OTP ister
3. Messages DB'den OTP okur
4. Token alir
5. Makine durumlarini sorgular
6. Uygunsa email + macOS bildirimi gonderir
"""

import json
import uuid
import time
import re
import sqlite3
import sys
import os
import random
import subprocess
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError
from datetime import datetime

# --- Yapilandirma ---
# Kisisel degerler config.json'dan gelir (bkz. config.example.json).
# Buradaki degerler yalnizca varsayilandir, repoya sir girmemesi icin bos birakilmistir.
PHONE = ""
API_BASE = "https://dbysmgw.doa.gov.tr/dbys"
MESSAGES_DB = os.path.expanduser("~/Library/Messages/chat.db")
CHAT_ID = "DOA"
BASE_DIR = os.path.expanduser("~/doa-watcher")
LOG_DIR = os.path.join(BASE_DIR, "logs")
CONFIG_FILE = os.path.join(BASE_DIR, "config.json")
LAST_STATE_FILE = os.path.join(BASE_DIR, "last-state.json")

LOCATION = {
    "lat": 41.0082,
    "lon": 28.9784,
    "distance": 2000,
    "userLat": 41.0082,
    "userLon": 28.9784
}

WATCH_MATERIALS = ["pet", "glass"]
FULL_THRESHOLD = 90
RANDOM_DELAY_MAX = 600
ENABLED = True

# --- config.json'dan ayarlari yukle (varsa ustune yaz) ---
def load_config():
    global PHONE, LOCATION, WATCH_MATERIALS, FULL_THRESHOLD, RANDOM_DELAY_MAX, ENABLED
    if not os.path.exists(CONFIG_FILE):
        return
    try:
        with open(CONFIG_FILE) as f:
            cfg = json.load(f)
        if cfg.get("phone"):
            PHONE = cfg["phone"]
        if cfg.get("lat") and cfg.get("lon"):
            LOCATION["lat"] = cfg["lat"]
            LOCATION["lon"] = cfg["lon"]
        if cfg.get("distance"):
            LOCATION["distance"] = cfg["distance"]
        if cfg.get("userLat") and cfg.get("userLon"):
            LOCATION["userLat"] = cfg["userLat"]
            LOCATION["userLon"] = cfg["userLon"]
        if cfg.get("watch_materials"):
            WATCH_MATERIALS = cfg["watch_materials"]
        if cfg.get("full_threshold"):
            FULL_THRESHOLD = cfg["full_threshold"]
        if cfg.get("random_delay_max") is not None:
            RANDOM_DELAY_MAX = cfg["random_delay_max"]
        if cfg.get("enabled") is not None:
            ENABLED = bool(cfg["enabled"])
    except Exception as e:
        print(f"[UYARI] config.json okunamadi: {e}")

load_config()

def log(msg):
    os.makedirs(LOG_DIR, exist_ok=True)
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    log_line = f"[{timestamp}] {msg}"
    print(log_line)
    log_file = os.path.join(LOG_DIR, datetime.now().strftime("%Y-%m-%d") + ".log")
    with open(log_file, "a") as f:
        f.write(log_line + "\n")

def macos_notify(title, message):
    try:
        msg_escaped = message.replace('"', '\\"')
        title_escaped = title.replace('"', '\\"')
        subprocess.run([
            "osascript", "-e",
            f'display notification "{msg_escaped}" with title "{title_escaped}" sound name "Glass"'
        ], timeout=5, capture_output=True)
        log("macOS bildirimi gonderildi")
    except Exception as e:
        log(f"Bildirim hatasi: {e}")

def send_email(subject, html_body):
    try:
        if not os.path.exists(CONFIG_FILE):
            log("Email config bulunamadi, email atlaniyor")
            return False
        with open(CONFIG_FILE) as f:
            config = json.load(f)
        email_addr = config.get("email", "")
        app_password = config.get("app_password", "")
        if not email_addr or not app_password:
            log("Email veya app_password eksik, email atlaniyor")
            return False
        msg = MIMEMultipart("alternative")
        msg["Subject"] = subject
        msg["From"] = email_addr
        msg["To"] = email_addr
        msg.attach(MIMEText(html_body, "html"))
        with smtplib.SMTP_SSL("smtp.gmail.com", 465, timeout=15) as server:
            server.login(email_addr, app_password)
            server.sendmail(email_addr, email_addr, msg.as_string())
        log("Email gonderildi")
        return True
    except Exception as e:
        log(f"Email hatasi: {e}")
        return False

def get_headers(auth_token=None):
    h = {
        "Accept": "application/json, text/plain, */*",
        "Content-Type": "application/json",
        "X-Correlation-Id": str(uuid.uuid4()),
        "X-Create-Time": str(int(time.time())),
        "X-Device-Type": "web",
        "Accept-Language": "tr",
        "X-PLATFORM": "web",
        "X-ORIGINAL-DEVICE-ID": "dd3585f2-44ce-4afc-8f05-e33ce37b6cc6",
        "X-DEVICE-ID": "dd3585f2-44ce-4afc-8f05-e33ce37b6cc61",
        "X-SYSTEM-VERSION": "1.0.48",
        "X-DEVICE-MODEL": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36",
        "X-OPERATING-SYSTEM": "MacOS",
        "X-VERSION": "1.0.48",
        "X-CLIENT-VERSION": "1.0.48",
        "X-PARTNER-CODE": "1.0.48",
        "X-Payment-Api-Version": "v7",
    }
    if auth_token:
        h["Authorization"] = auth_token
    return h

def api_post(endpoint, body, auth_token=None):
    url = f"{API_BASE}/{endpoint}"
    headers = get_headers(auth_token)
    data = json.dumps(body).encode("utf-8")
    req = Request(url, data=data, headers=headers, method="POST")
    try:
        with urlopen(req, timeout=15) as resp:
            return {"status": resp.status, "data": json.loads(resp.read().decode())}
    except HTTPError as e:
        body_text = ""
        try:
            body_text = e.read().decode()
        except:
            pass
        return {"status": e.code, "error": body_text}
    except Exception as e:
        return {"status": -1, "error": str(e)}

def send_otp():
    return api_post("v2/auth/send-login-otp", {"username": PHONE})

def read_otp(max_age=90):
    try:
        db = sqlite3.connect(MESSAGES_DB)
        cur = db.cursor()
        cur.execute('''
            SELECT m.date, m.attributedBody
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE c.chat_identifier = ?
            ORDER BY m.date DESC
            LIMIT 1
        ''', (CHAT_ID,))
        row = cur.fetchone()
        db.close()
        if not row or not row[1]:
            return None, "Mesaj bulunamadi"
        apple_epoch = 978307200
        unix_ts = row[0] / 1000000000 + apple_epoch
        age = time.time() - unix_ts
        if age > max_age:
            return None, f"Mesaj cok eski ({int(age)}s)"
        body = row[1]
        text = body.decode("utf-8", errors="ignore")
        codes = re.findall(r'(\d{6})', text)
        if codes:
            return codes[0], f"OK (yas={int(age)}s)"
        return None, "Kod bulunamadi"
    except Exception as e:
        return None, f"DB hatasi: {e}"

def verify_otp(otp_ref_id, otp_code):
    body = {
        "otpReferenceId": otp_ref_id,
        "otpCode": otp_code,
        "msisdn": PHONE,
        "accountType": 0,
        "operationCode": 1,
    }
    return api_post("v2/auth/verify-login-otp", body)

def search_machines(token):
    return api_post("v3/rvm/search?pageNumber=1&pageSize=100", LOCATION, auth_token=token)

def analyze_machines(data):
    rvm_list = data.get("rvmList", [])
    results = []
    any_available = False
    for m in rvm_list:
        name = m.get("definition", {}).get("name", m.get("id", "Bilinmeyen"))
        machine_status = m.get("machineStatus", -1)
        online = machine_status == 0
        address = m.get("address", "")
        dist = m.get("userDistanceKm", 0)
        bins = {}
        for b in m.get("binList", []):
            ct = b.get("contentType", "")
            bins[ct] = {
                "level": b.get("level", 0),
                "state": b.get("state", False),
                "available": online and b.get("state", False) and b.get("level", 100) < FULL_THRESHOLD
            }
        materials_available = {}
        for mat in WATCH_MATERIALS:
            if mat in bins:
                materials_available[mat] = bins[mat]["available"]
            else:
                materials_available[mat] = False
        if any(materials_available.values()):
            any_available = True
        results.append({
            "name": name,
            "online": online,
            "machineStatus": machine_status,
            "address": address,
            "distance_km": round(dist, 2) if dist else 0,
            "bins": bins,
            "materials_available": materials_available,
        })
    return {"machines": results, "any_available": any_available}

EMAIL_MATERIALS = [("pet", "PET"), ("glass", "Cam"), ("aluminum", "Alüminyum")]

def build_email_html(analysis):
    now = datetime.now().strftime("%d.%m.%Y %H:%M")
    machines = sorted(analysis["machines"], key=lambda m: m["distance_km"] or 0)
    available_count = sum(1 for m in machines if any(m["materials_available"].values()))

    cell_base = "padding:10px 8px;border-top:1px solid #f0f0f0;text-align:center;font-size:14px"

    def material_cell(m, key):
        b = m["bins"].get(key)
        if not b:
            return f'<td style="{cell_base};color:#9ca3af">&ndash;</td>'
        if b["available"]:
            return f'<td style="{cell_base};color:#15803d;font-weight:700">%{b["level"]}</td>'
        if b["level"] >= FULL_THRESHOLD:
            return f'<td style="{cell_base};color:#dc2626">%{b["level"]}</td>'
        return f'<td style="{cell_base};color:#9ca3af">%{b["level"]}</td>'

    rows = ""
    for m in machines:
        if m["online"]:
            badge = ('<span style="background:#dcfce7;color:#166534;padding:2px 10px;'
                     'border-radius:999px;font-size:12px;font-weight:600">AÇIK</span>')
        else:
            badge = ('<span style="background:#fee2e2;color:#b91c1c;padding:2px 10px;'
                     'border-radius:999px;font-size:12px;font-weight:600">KAPALI</span>')
        cells = "".join(material_cell(m, key) for key, _ in EMAIL_MATERIALS)
        rows += f'''<tr>
            <td style="padding:10px 8px 10px 20px;border-top:1px solid #f0f0f0">
                <div style="font-size:14px;font-weight:600;color:#111827">{m["name"]}</div>
                <div style="font-size:12px;color:#6b7280;margin-top:2px">{m["distance_km"]} km</div>
            </td>
            <td style="padding:10px 8px;border-top:1px solid #f0f0f0;text-align:center">{badge}</td>
            {cells}
        </tr>'''

    th_base = ("padding:10px 8px;font-size:11px;font-weight:600;color:#6b7280;"
               "text-transform:uppercase;letter-spacing:0.4px")
    material_headers = "".join(
        f'<th style="{th_base};text-align:center">{label}</th>' for _, label in EMAIL_MATERIALS)

    if available_count:
        summary, summary_bg, summary_color = (
            f"{available_count} makinede uygun göz var", "#dcfce7", "#166534")
    else:
        summary, summary_bg, summary_color = ("Şu an uygun göz yok", "#fef3c7", "#92400e")

    html = f'''<html><body style="margin:0;padding:0;background:#f3f4f6">
    <div style="max-width:640px;margin:0 auto;padding:24px 12px;font-family:-apple-system,'Segoe UI',Roboto,Arial,sans-serif">
      <div style="background:#ffffff;border:1px solid #e5e7eb;border-radius:12px;overflow:hidden">
        <div style="background:#166534;padding:18px 24px">
          <div style="color:#ffffff;font-size:19px;font-weight:700">DOA Watcher</div>
          <div style="color:#bbf7d0;font-size:13px;margin-top:2px">Makine durumu &middot; {now}</div>
        </div>
        <div style="margin:16px 20px 0;padding:10px 16px;background:{summary_bg};color:{summary_color};border-radius:8px;font-size:14px;font-weight:600">{summary}</div>
        <table style="width:100%;border-collapse:collapse;margin-top:8px">
          <tr>
            <th style="{th_base};text-align:left;padding-left:20px">Makine</th>
            <th style="{th_base};text-align:center">Durum</th>
            {material_headers}
          </tr>
          {rows}
        </table>
        <div style="padding:12px 20px;border-top:1px solid #f0f0f0;font-size:12px;color:#9ca3af">
          Yeşil: göz uygun &middot; Kırmızı: dolu &middot; Gri: kapalı veya bu makinede yok
        </div>
      </div>
      <div style="text-align:center;color:#9ca3af;font-size:12px;margin-top:12px">Otomatik kontrol &middot; DOA Watcher</div>
    </div>
    </body></html>'''
    return html

def load_last_state():
    try:
        if os.path.exists(LAST_STATE_FILE):
            with open(LAST_STATE_FILE) as f:
                return json.load(f)
    except:
        pass
    return {"any_available": False}

def save_state(analysis):
    try:
        state = {
            "any_available": analysis["any_available"],
            "timestamp": int(time.time()),
            "machines": analysis["machines"]
        }
        with open(LAST_STATE_FILE, "w") as f:
            json.dump(state, f, indent=2)
    except Exception as e:
        log(f"State kayit hatasi: {e}")

def main():
    global RANDOM_DELAY_MAX
    # --now parametresi: gecikme olmadan hemen calistir (UI'dan tetiklenince)
    manual = "--now" in sys.argv
    if manual:
        RANDOM_DELAY_MAX = 0
    # Zamanlanmis calismalarda otomatik takip kapaliysa hicbir sey yapma
    if not manual and not ENABLED:
        log("Otomatik takip kapali (enabled=false), kontrol atlandi")
        return
    # Zorunlu ayarlar var mi?
    if not PHONE:
        log("HATA: Telefon numarasi tanimli degil. config.json olusturun "
            "(config.example.json dosyasini kopyalayin) veya uygulamadan girin.")
        return
    log("=== DOA Kontrol basliyor ===")
    # Rastgele gecikme
    delay = random.randint(0, RANDOM_DELAY_MAX)
    log(f"Rastgele gecikme: {delay} saniye")
    time.sleep(delay)

    # 1. OTP gonder
    log("OTP gonderiliyor...")
    resp = send_otp()
    if resp["status"] != 200:
        log(f"OTP gonderilemedi: HTTP {resp['status']} - {resp.get('error','')}")
        return

    resp_data = resp.get("data", {})
    otp_ref_id = resp_data.get("otpReferenceId") or resp_data.get("data", {}).get("otpReferenceId")
    if not otp_ref_id:
        for key in resp_data:
            val = resp_data[key]
            if isinstance(val, str) and len(val) == 36 and "-" in val:
                otp_ref_id = val
                break
            if isinstance(val, dict):
                for k2 in val:
                    v2 = val[k2]
                    if isinstance(v2, str) and len(v2) == 36 and "-" in v2:
                        otp_ref_id = v2
                        break
    if not otp_ref_id:
        log(f"otpReferenceId bulunamadi. Keys: {list(resp_data.keys())}")
        return
    log(f"OTP gonderildi, ref: {otp_ref_id[:8]}...")

    # 2. OTP bekle
    log("OTP bekleniyor (18s)...")
    time.sleep(18)

    # 3. Messages'tan OTP oku
    otp_code = None
    for attempt in range(4):
        otp_code, msg = read_otp(max_age=90)
        if otp_code:
            log(f"OTP okundu: {otp_code} ({msg})")
            break
        log(f"OTP deneme {attempt+1}/4: {msg}")
        time.sleep(5)
    if not otp_code:
        log(f"OTP okunamadi: {msg}")
        return

    # 4. OTP dogrula
    log("OTP dogrulaniyor...")
    resp = verify_otp(otp_ref_id, otp_code)
    if resp["status"] != 200:
        log(f"OTP dogrulanamadi: HTTP {resp['status']} - {resp.get('error','')}")
        return

    verify_data = resp.get("data", {})
    token = (
        verify_data.get("tokenResource", {}).get("access_token")
        or verify_data.get("tokenResource", {}).get("accessToken")
        or verify_data.get("access_token")
        or verify_data.get("accessToken")
        or verify_data.get("data", {}).get("access_token")
        or verify_data.get("data", {}).get("accessToken")
    )
    if not token:
        log(f"Token bulunamadi. Keys: {list(verify_data.keys())}")
        return
    log("Token alindi")

    # 5. Makine sorgula
    log("Makineler sorgulanyor...")
    resp = search_machines(token)
    if resp["status"] != 200:
        log(f"Sorgu basarisiz: HTTP {resp['status']} - {resp.get('error','')}")
        return

    # 6. Analiz
    analysis = analyze_machines(resp.get("data", {}))
    last_state = load_last_state()
    save_state(analysis)

    for m in analysis["machines"]:
        status = "ACIK" if m["online"] else "KAPALI"
        pet = m["materials_available"].get("pet", False)
        glass = m["materials_available"].get("glass", False)
        log(f"  {m['name']}: {status} | PET={'OK' if pet else 'X'} | Cam={'OK' if glass else 'X'}")

    # 7. Bildirim gonder (uygun makine varsa)
    state_changed = last_state.get("any_available", False) != analysis["any_available"]

    if analysis["any_available"]:
        available_names = [m["name"] for m in analysis["machines"] if any(m["materials_available"].values())]
        notify_msg = f"Uygun makine: {', '.join(available_names)}"
        macos_notify("DOA - Makine Uygun!", notify_msg)
        subject = "DOA - Makine Musait!"
        html = build_email_html(analysis)
        send_email(subject, html)
        log("Bildirimler gonderildi (uygun makine var)")
    elif state_changed:
        macos_notify("DOA - Durum Degisti", "Tum makineler dolu veya kapali")
        log("Durum degisti: artik uygun makine yok")
    else:
        log("Uygun makine yok, bildirim atlaniyor")

    log("=== DOA Kontrol tamamlandi ===")

if __name__ == "__main__":
    main()
