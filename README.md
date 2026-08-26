# DOA Watcher

Türkiye'deki **DOA (Depozito İade Sistemi)** otomatlarının doluluk durumunu takip eden,
macOS üzerinde tamamen otomatik çalışan bir izleme sistemi.

Belirlediğiniz konumun çevresindeki iade makinelerini düzenli aralıklarla sorgular;
PET veya cam gözü boş ve makine açıksa size e-posta ve macOS bildirimi gönderir.
Boşuna yola çıkmamak için tasarlandı.

```
┌──────────────┐   zamanlanmış    ┌───────────────┐    alt süreç    ┌─────────────────┐
│   launchd    │ ───────────────► │ DOAWatcher.app│ ──────────────► │ doa-checker.py  │
│ (macOS)      │   --check        │ (Swift/SwiftUI)│                │ (Python 3)      │
└──────────────┘                  └───────────────┘                 └────────┬────────┘
                                          │                                  │
                                    ayar arayüzü                             │
                                          │                    ┌─────────────┼─────────────┐
                                          ▼                    ▼             ▼             ▼
                                    config.json          DOA API      Messages DB      Gmail
                                                       (REST/JWT)    (OTP okuma)      (SMTP)
```

---

## İçindekiler

- [Nasıl çalışır](#nasıl-çalışır)
- [Gereksinimler](#gereksinimler)
- [Kurulum](#kurulum)
- [Yapılandırma](#yapılandırma)
- [Kullanım](#kullanım)
- [Derleme](#derleme)
- [DOA API notları](#doa-api-notları)
- [macOS Messages veritabanından OTP okuma](#macos-messages-veritabanından-otp-okuma)
- [Kod imzalama ve Tam Disk Erişimi](#kod-imzalama-ve-tam-disk-erişimi)
- [launchd zamanlaması](#launchd-zamanlaması)
- [Dosya yapısı](#dosya-yapısı)
- [Sorun giderme](#sorun-giderme)
- [Geliştirme günlüğü](#geliştirme-günlüğü)

---

## Nasıl çalışır

DOA API'si kimlik doğrulaması istiyor ve bu doğrulama SMS ile gelen 6 haneli OTP koduna
dayanıyor. Yani her sorgu için giriş yapmak, her giriş için de SMS okumak gerekiyor.
Sistemin tamamen otomatik olabilmesinin anahtarı bu: Mac'inizde iMessage/SMS
senkronizasyonu açıksa gelen SMS yerel bir SQLite veritabanına düşer ve program
kodu oradan okur.

Bir kontrol turunun adımları:

1. **Rastgele gecikme** — 0-600 saniye arası. Sorguların saat başı gibi sabit bir
   düzende gitmemesi için.
2. **OTP iste** — `send-login-otp` çağrılır, dönen `otpReferenceId` saklanır.
3. **SMS'i bekle** — 18 saniye beklenir, sonra Messages veritabanı okunur.
   Kod bulunamazsa 5 saniye arayla 4 kez daha denenir.
4. **Doğrula** — OTP ve referans ile `verify-login-otp` çağrılır, JWT alınır.
5. **Sorgula** — `v3/rvm/search` ile konum çevresindeki makineler listelenir.
6. **Değerlendir** — her makinenin her gözü için uygunluk hesaplanır.
7. **Bildir** — uygun göz varsa e-posta + macOS bildirimi gönderilir.

### Uygunluk kuralı

Bir göz şu üç şart birden sağlanırsa "uygun" sayılır:

```python
uygun = (machineStatus == 0)          # makine çevrimiçi
        and bin["state"] is True       # göz aktif
        and bin["level"] < full_threshold   # doluluk eşiğin altında (varsayılan %90)
```

### Bildirim politikası

E-posta **yalnızca en az bir makinede uygun göz varsa** gönderilir. Tüm makineler
dolu veya kapalıysa mail gitmez — bu kasıtlı bir tercih, "gidebileceğin bir durum
varsa haber ver" mantığı.

Durum "uygun vardı → artık yok" şeklinde değiştiğinde yalnızca macOS bildirimi
gönderilir, e-posta gönderilmez. Son durum `last-state.json` dosyasında tutulur.

> **Not:** Her kontrolde SMS gelir çünkü sorgu için giriş şart. SMS gelmesi
> "makine müsait" demek değildir; yalnızca "kontrol yapıldı" demektir.

---

## Gereksinimler

| Gereksinim | Not |
|---|---|
| macOS 14+ | SwiftUI arayüzü ve `launchd` için |
| Swift derleyici | Xcode veya Command Line Tools (`xcode-select --install`) |
| Python 3 | macOS ile birlikte gelir, ek paket gerekmez |
| DOA hesabı | Telefon numarasıyla kayıtlı olmalı |
| Mac'te SMS senkronizasyonu | iPhone'daki SMS'ler Mac'e düşmeli (Mesajlar → Metin Mesajı Yönlendirme) |
| Gmail hesabı + uygulama şifresi | Bildirim e-postaları için |
| Apple Developer sertifikası | Zorunlu değil ama şiddetle önerilir ([nedeni](#kod-imzalama-ve-tam-disk-erişimi)) |

Python tarafında harici bağımlılık yok — yalnızca standart kütüphane
(`urllib`, `sqlite3`, `smtplib`, `json`) kullanılıyor.

### Gmail uygulama şifresi alma

Normal Gmail şifreniz çalışmaz, "uygulama şifresi" gerekir:

1. Google Hesabı → Güvenlik → 2 Adımlı Doğrulama'yı açın
2. Güvenlik → Uygulama şifreleri → yeni şifre oluşturun
3. Çıkan 16 karakterlik kodu (`xxxx xxxx xxxx xxxx`) yapılandırmaya girin

---

## Kurulum

```bash
git clone https://github.com/<kullanici>/doa-watcher.git ~/doa-watcher
cd ~/doa-watcher

# Yapılandırmayı oluşturun
cp config.example.json config.json
# config.json'u kendi bilgilerinizle doldurun (veya uygulamanın arayüzünden girin)

# Derleyin ve imzalayın
./build.sh

# Uygulamayı açın, ayarları girip Kaydet'e basın
open DOAWatcher.app
```

> **Önemli:** Proje `~/doa-watcher` dizininde olmak zorunda. Yollar hem Swift hem
> Python tarafında bu dizine göre sabitlenmiş durumda.

Kurulumdan sonra **Tam Disk Erişimi** vermeniz gerekir, aksi halde OTP okunamaz:

**Sistem Ayarları → Gizlilik ve Güvenlik → Tam Disk Erişimi → `+` → `~/doa-watcher/DOAWatcher.app`**

---

## Yapılandırma

Tüm ayarlar `config.json` dosyasında. Bu dosya `.gitignore` içinde — şifre içerdiği
için repoya girmez. Şablon olarak `config.example.json` kullanın.

| Anahtar | Tip | Açıklama |
|---|---|---|
| `enabled` | bool | Ana anahtar. `false` ise zamanlanmış kontroller çalışmaz |
| `phone` | string | DOA'ya kayıtlı telefon, başında sıfır olmadan (`5XXXXXXXXX`) |
| `email` | string | Bildirimlerin gideceği Gmail adresi (gönderici de aynı adres) |
| `app_password` | string | Gmail uygulama şifresi (normal şifre değil) |
| `lat` / `lon` | number | Arama merkezinin koordinatları |
| `userLat` / `userLon` | number | Mesafe hesabı için kullanıcı konumu (genelde `lat`/`lon` ile aynı) |
| `distance` | number | Arama yarıçapı, **metre** cinsinden |
| `morning_hours` | int[] | Sabah kontrol saatleri, ör. `[9, 10, 11]` |
| `evening_hours` | int[] | Akşam kontrol saatleri, ör. `[17, 18, 19]` |
| `check_minutes` | int[] | Her saatte hangi dakikalarda, ör. `[25, 55]` |
| `random_delay_max` | number | Kontrol başına eklenecek azami rastgele gecikme (saniye) |
| `watch_materials` | string[] | İzlenecek malzemeler: `"pet"`, `"glass"` |
| `full_threshold` | number | Bu doluluk yüzdesinin üstü "dolu" sayılır (varsayılan 90) |

Kontrol saatleri `morning_hours × check_minutes` ve `evening_hours × check_minutes`
şeklinde çarpılır. Örnek: `[9,10,11] × [25,55]` → günde 6 kontrol (09:25, 09:55,
10:25, 10:55, 11:25, 11:55).

### Koordinat bulma

Google Maps'te istediğiniz noktaya sağ tıklayın, en üstteki koordinat çiftine
tıklayınca panoya kopyalanır. Uygulamadaki **Haritada Göster** butonu da mevcut
koordinatı haritada açar.

`distance` alanı, girdiğiniz merkez noktadan kaç metre uzağa kadar makine
aranacağını belirler. 2000-3000 metre çoğu ilçe merkezi için makul bir değerdir.

---

## Kullanım

### Arayüz

`DOAWatcher.app`'i açtığınızda ayar penceresi gelir:

- **Ana anahtar** — otomatik takibi açıp kapatır. Anında uygulanır, Kaydet'e
  basmaya gerek yok. Açıkken bir sonraki kontrol saatini gösterir.
- **Hesap** — telefon, e-posta, Gmail uygulama şifresi
- **Konum** — enlem, boylam, arama yarıçapı
- **Zamanlama** — sabah/akşam saatleri, dakikalar, azami gecikme
- **Şimdi Kontrol Et** — anında bir kontrol başlatır (gecikmesiz). Her adım
  canlı olarak ekranda ikonlarla akar: OTP gönderildi → okundu → token alındı →
  makineler sorgulandı → e-posta gönderildi.

Uygulamanın **açık kalmasına gerek yoktur.** Zamanlanmış kontroller `launchd`
tarafından yürütülür; Mac açık olduğu sürece uygulama kapalıyken de çalışır.

### Duraklatma

Ana anahtarı kapattığınızda üç katmanlı durdurma devreye girer:

1. `launchctl unload` ile iş launchd'den kaldırılır
2. plist dosyası `.disabled` uzantısına taşınır — yeniden başlatmada da yüklenmez
3. Python betiği her çalışmada `enabled` bayrağını kontrol eder, kapalıysa çıkar

Anahtar kapalıyken bile **Şimdi Kontrol Et** çalışmaya devam eder.

### Komut satırından

```bash
python3 doa-checker.py           # zamanlanmış mod (gecikmeli, enabled'a saygılı)
python3 doa-checker.py --now     # anında çalıştır, gecikme yok, enabled'ı yok say

./DOAWatcher.app/Contents/MacOS/DOAWatcher --check   # arka plan modu (launchd'nin çağırdığı)
./DOAWatcher.app/Contents/MacOS/DOAWatcher           # ayar arayüzü
```

### Loglar

```bash
tail -f ~/doa-watcher/logs/$(date +%Y-%m-%d).log   # günlük log
cat ~/doa-watcher/logs/launchd-stderr.log          # launchd hataları
```

---

## Derleme

```bash
./build.sh
```

Betik üç iş yapar: Swift kaynağını derler, Developer ID sertifikanızla imzalar,
imzayı doğrular. Sertifika otomatik bulunur; birden fazla varsa seçmek için:

```bash
DOA_SIGN_CERT="Developer ID Application: ADINIZ (TEAMID)" ./build.sh
```

Kurulu sertifikaları görmek için:

```bash
security find-identity -v -p codesigning
```

Elle derlemek isterseniz:

```bash
swiftc -swift-version 5 -O \
  -o DOAWatcher.app/Contents/MacOS/DOAWatcher \
  DOAWatcher.swift \
  -framework SwiftUI -framework AppKit

codesign -s "Developer ID Application: ..." -f --timestamp DOAWatcher.app
```

> **Ad-hoc imza (`codesign -s -`) kullanmayın.** Nedeni aşağıda.

---

## DOA API notları

Resmî bir dokümantasyon yok; aşağıdakiler web arayüzünün ağ trafiği incelenerek
çıkarıldı. API değişirse burası güncellenmelidir.

**Taban adres:** `https://dbysmgw.doa.gov.tr/dbys`

### Ortak başlıklar

Tüm isteklerde şu başlıklar bekleniyor:

```
Accept:                application/json, text/plain, */*
Content-Type:          application/json
Accept-Language:       tr
X-Correlation-Id:      <her istekte yeni UUID>
X-Create-Time:         <unix zaman damgası, saniye>
X-Device-Type:         web
X-PLATFORM:            web
X-DEVICE-ID:           <sabit UUID>
X-ORIGINAL-DEVICE-ID:  <sabit UUID>
X-OPERATING-SYSTEM:    MacOS
X-DEVICE-MODEL:        <tarayıcı user-agent dizesi>
X-VERSION:             1.0.48
X-CLIENT-VERSION:      1.0.48
X-SYSTEM-VERSION:      1.0.48
X-PARTNER-CODE:        1.0.48
X-Payment-Api-Version: v7
```

`X-DEVICE-ID` ve `X-ORIGINAL-DEVICE-ID` kaynak kodda sabit UUID olarak duruyor.
Kendi kurulumunuzda değiştirmek isterseniz `get_headers()` içinden düzenleyin.

### ⚠️ En kritik ayrıntı: Authorization başlığı

Token **`Bearer ` öneki olmadan**, ham JWT olarak gönderilir:

```python
headers["Authorization"] = token          # ✅ doğru
headers["Authorization"] = f"Bearer {token}"   # ❌ 401 döner
```

Bu, standart dışı bir davranış ve entegrasyonda en çok vakit kaybettiren nokta.

### 1. OTP gönder

```http
POST /v2/auth/send-login-otp
```

```json
{ "username": "5XXXXXXXXX" }
```

Yanıtta `otpReferenceId` (UUID) döner. Alan bazen doğrudan kökte, bazen bir alt
nesnede geliyor; kod her iki durumu da tarıyor.

### 2. OTP doğrula

```http
POST /v2/auth/verify-login-otp
```

```json
{
  "otpReferenceId": "<önceki adımdan>",
  "otpCode": "123456",
  "msisdn": "5XXXXXXXXX",
  "accountType": 0,
  "operationCode": 1
}
```

Token yanıtta `tokenResource.access_token` içinde. Kod yedek olarak
`accessToken`, `data.access_token` gibi varyasyonları da deniyor.

Token ömrü kısa (~10 dakika), yenileme akışı kullanılmıyor — her kontrol
turunda sıfırdan giriş yapılıyor.

### 3. Makine sorgula

```http
POST /v3/rvm/search?pageNumber=1&pageSize=100
Authorization: <ham JWT>
```

```json
{
  "lat": 41.0082,
  "lon": 28.9784,
  "distance": 2000,
  "userLat": 41.0082,
  "userLon": 28.9784
}
```

### Yanıt yapısı

```jsonc
{
  "rvmList": [
    {
      "id": "...",
      "definition": { "name": "MARKET ADI - ŞUBE" },
      "machineStatus": 0,          // 0 = çevrimiçi, diğer değerler = kapalı
      "address": "...",
      "userDistanceKm": 1.24,
      "binList": [
        {
          "contentType": "pet",    // "pet" | "glass" | "aluminum" ...
          "level": 45,             // doluluk yüzdesi (0-100)
          "state": true            // göz aktif mi
        }
      ]
    }
  ]
}
```

| Alan | Anlamı |
|---|---|
| `machineStatus` | `0` çevrimiçi, diğer her değer kapalı sayılır |
| `binList[].contentType` | Göz türü — `pet` (plastik), `glass` (cam) |
| `binList[].level` | Doluluk yüzdesi; `full_threshold` üstü "dolu" |
| `binList[].state` | Gözün aktif olup olmadığı |
| `userDistanceKm` | `userLat`/`userLon` noktasına uzaklık |

---

## macOS Messages veritabanından OTP okuma

Mac'inize düşen SMS'ler şurada bir SQLite veritabanında tutulur:

```
~/Library/Messages/chat.db
```

DOA'nın SMS'leri `chat_identifier = 'DOA'` olan sohbete düşer:

```sql
SELECT m.date, m.attributedBody
FROM message m
JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
JOIN chat c ON cmj.chat_id = c.ROWID
WHERE c.chat_identifier = 'DOA'
ORDER BY m.date DESC
LIMIT 1;
```

### İki tuzak

**1. Mesaj metni `text` sütununda olmayabilir.** Modern macOS sürümlerinde metin
`attributedBody` adlı ikili (NSAttributedString arşivi) sütunda saklanıyor.
Tam ayrıştırma yerine pratik çözüm: baytları hatalar yok sayılarak çöz ve
6 haneli sayıyı yakala.

```python
text = attributed_body.decode("utf-8", errors="ignore")
codes = re.findall(r"(\d{6})", text)
```

**2. Zaman damgası Unix değil, Apple epoch.** Referans 1 Ocak 2001 ve değer
nanosaniye cinsinden:

```python
APPLE_EPOCH = 978307200          # 2001-01-01 ile 1970-01-01 arası saniye
unix_ts = apple_date / 1_000_000_000 + APPLE_EPOCH
```

Kod, okuduğu mesajın 90 saniyeden eski olmamasını şart koşuyor — böylece
önceki turdan kalma bir kodu yanlışlıkla kullanmıyor.

> Bu sorgunun çalışabilmesi için okuyan sürecin **Tam Disk Erişimi** olması şart.

---

## Kod imzalama ve Tam Disk Erişimi

Bu projedeki en sinsi sorun buydu; ayrıntısıyla yazıyorum çünkü benzer bir işe
girişen herkes aynı duvara toslar.

### Sorun

Messages veritabanını okumak Tam Disk Erişimi (Full Disk Access) gerektirir.
macOS bu izinleri **TCC** adlı bir veritabanında tutar ve her kayıt, uygulamayı
tanımlayan bir *code signing requirement* ile eşleşir.

Uygulama **ad-hoc** imzalanırsa (`codesign -s -`) TCC'nin kaydettiği kural şu
şekilde olur:

```
cdhash H"fa3df386409564b94936551439e355bf149c5592"
```

`cdhash`, derlenmiş ikili dosyanın özetidir — **her yeni derlemede değişir.**
Sonuç: kodda tek satır değiştirip yeniden derlediğinizde TCC kaydı artık
eşleşmez ve izin sessizce çalışmaz hâle gelir. Loglarda şöyle görünür:

```
OTP deneme 1/4: DB hatasi: authorization denied
```

Sistem Ayarları'nda uygulama hâlâ listede ve tik işareti duruyor olur — bu
yüzden hata çok kafa karıştırıcıdır.

### Çözüm

Apple Developer hesabınızdaki **Developer ID** sertifikasıyla imzalayın. O zaman
TCC'nin kaydettiği kural kimliğe dayalı olur:

```
identifier "com.ozden.doa-watcher" and anchor apple generic
  and certificate leaf[subject.OU] = "TEAMID"
```

Bu kuralda `cdhash` yok — paket kimliği ve ekip numarası derlemeden derlemeye
değişmediği için **izin bir kez verilir ve kalıcı olur.**

### İzin durumunu doğrulama

TCC'nin gerçekte hangi kuralı sakladığını görmek için:

```bash
# Kaydı diske çıkar
sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT writefile('/tmp/doa.csreq', csreq)
   FROM access
   WHERE service='kTCCServiceSystemPolicyAllFiles'
     AND client='com.ozden.doa-watcher';"

# Kuralı okunabilir hâle getir
csreq -r /tmp/doa.csreq -t

# Uygulama bu kuralı karşılıyor mu?
codesign -v -R /tmp/doa.csreq DOAWatcher.app && echo "eşleşiyor" || echo "eşleşmiyor"
```

Tam Disk Erişimi listesinin tamamını görmek için:

```bash
sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT client, auth_value FROM access
   WHERE service='kTCCServiceSystemPolicyAllFiles';"
```

`auth_value` değeri `2` ise izin verilmiş, `0` ise reddedilmiş demektir.

### Alt süreçler izni miras alır

Program Messages veritabanını doğrudan Swift'ten okumuyor; `python3`'ü alt
süreç olarak başlatıyor. Python'a ayrıca izin vermek **gerekmez** — macOS
TCC değerlendirmesinde "sorumlu süreç" olarak üst uygulamayı (imzalı `.app`)
kabul eder.

Bu yüzden `/usr/bin/python3`'ü izin listesine eklemeye çalışmak işe yaramaz;
üstelik oradaki dosya bir yönlendirici (stub), gerçek ikili
`/Library/Developer/CommandLineTools/usr/bin/python3` altındadır.

---

## launchd zamanlaması

Zamanlama dosyası uygulama tarafından üretilir:

```
~/Library/LaunchAgents/com.ozden.doa-watcher.plist
```

İçeriği özetle:

```xml
<key>ProgramArguments</key>
<array>
    <string>/Users/<kullanici>/doa-watcher/DOAWatcher.app/Contents/MacOS/DOAWatcher</string>
    <string>--check</string>
</array>
<key>StartCalendarInterval</key>
<array>
    <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>25</integer></dict>
    <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>55</integer></dict>
    <!-- config.json'daki saat × dakika çarpımı kadar giriş -->
</array>
```

Arayüzde **Kaydet**'e bastığınızda plist yeniden üretilip `launchctl` ile
yeniden yüklenir; elle düzenlemeye gerek yok.

### Faydalı komutlar

```bash
launchctl list | grep doa-watcher       # yüklü mü?
launchctl unload ~/Library/LaunchAgents/com.ozden.doa-watcher.plist
launchctl load -w ~/Library/LaunchAgents/com.ozden.doa-watcher.plist
launchctl kickstart -k gui/$UID/com.ozden.doa-watcher   # hemen tetikle
```

> `launchctl kickstart` gerçek zamanlama yolunu taklit ettiği için izin
> sorunlarını test etmenin en güvenilir yoludur. Terminalden elle çalıştırmak
> yanıltıcı olabilir: terminalin kendi Tam Disk Erişimi devreye girip sorunu
> gizleyebilir.

### Bilinen sınır

`launchd`, tetiklenme saatinde Mac uykudaysa işi kaçırır ve uyanışta telafi
eder. Mac'in sürekli açık olduğu bir kurulum (ör. Mac Mini) varsayılmıştır.

---

## Dosya yapısı

```
doa-watcher/
├── README.md               # bu dosya - tüm proje dokümantasyonu
├── .gitignore
├── build.sh                # derleme + imzalama
├── config.example.json     # yapılandırma şablonu
├── DOAWatcher.swift        # SwiftUI arayüz + launchd yönetimi + arka plan modu
├── doa-checker.py          # API istemcisi, OTP okuma, e-posta gönderimi
│
├── config.json             # (git dışı) gerçek ayarlar - ŞİFRE İÇERİR
├── last-state.json         # (git dışı) son bilinen durum
├── logs/                   # (git dışı) günlük loglar
├── DOAWatcher.app/         # (git dışı) derleme çıktısı
└── archive/                # (git dışı) ilk denemeler - Playwright tabanlı yaklaşım
```

### Kaynak dosyalar

**`doa-checker.py`** — işin motoru. Yapılandırmayı okur, OTP akışını yürütür,
API'yi sorgular, sonucu değerlendirir, bildirimleri gönderir. Harici bağımlılığı
yoktur.

Önemli fonksiyonlar: `load_config()`, `send_otp()`, `read_otp()`, `verify_otp()`,
`search_machines()`, `analyze_machines()`, `send_email()`, `main()`.

**`DOAWatcher.swift`** — tek dosyalık SwiftUI uygulaması. İki modda çalışır:

| Çalıştırma | Davranış |
|---|---|
| `DOAWatcher` | Ayar penceresini açar |
| `DOAWatcher --check` | Pencere açmadan `doa-checker.py`'yi çalıştırır, biter |

`--check` modunun varlık sebebi izin devri: `launchd` imzalı uygulamayı
çalıştırır, o da Python'u başlatır ve Tam Disk Erişimi zincir boyunca geçerli olur.

`DOAConfig` yapısı özel bir `init(from:)` kullanır — eksik anahtarlar varsayılana
düşer. Bu sayede yapılandırmaya yeni alan eklendiğinde eski `config.json`
dosyaları bozulmaz.

---

## Sorun giderme

### `DB hatasi: authorization denied`

Tam Disk Erişimi eşleşmiyor. Uygulamayı yeniden derlediyseniz ve ad-hoc
imzalıysa beklenen durum — [ilgili bölüme](#kod-imzalama-ve-tam-disk-erişimi)
bakın. Çözüm: Developer ID ile imzalayın, sonra Sistem Ayarları'ndaki eski
kaydı `−` ile silip `+` ile yeniden ekleyin.

### `OTP okunamadi: Mesaj bulunamadi`

Mac'e SMS düşmüyor olabilir. iPhone'da **Ayarlar → Mesajlar → Metin Mesajı
Yönlendirme** altında Mac'in açık olduğunu doğrulayın. Sohbet kimliğinin `DOA`
olduğunu şuradan kontrol edebilirsiniz:

```sql
SELECT DISTINCT chat_identifier FROM chat;
```

### `OTP okunamadi: Mesaj cok eski`

Yeni SMS gelmemiş, kod eski mesajı okumuş. OTP gönderimi başarısız olmuş
olabilir; loglarda `OTP gonderildi` satırının varlığına bakın.

### E-posta gitmiyor

Önce logu okuyun — büyük ihtimalle hata yoktur, sadece uygun makine
bulunamamıştır (`Uygun makine yok, bildirim atlaniyor`). Gerçek bir hata varsa
`Email hatasi:` satırı görünür. En sık sebep normal Gmail şifresinin uygulama
şifresi yerine kullanılmasıdır.

### Zamanlanmış kontroller hiç çalışmıyor

```bash
launchctl list | grep doa-watcher
ls -la ~/Library/LaunchAgents/ | grep doa
```

`.plist.disabled` görüyorsanız ana anahtar kapalıdır. Hiçbiri yoksa uygulamayı
açıp **Kaydet**'e basın; plist yeniden üretilir.

### HTTP 401

Token'ın `Bearer ` önekiyle gönderilmediğinden emin olun. API ham JWT bekliyor.

---

## Geliştirme günlüğü

Projenin bugünkü hâline nasıl geldiğinin kısa özeti — denenip bırakılan
yaklaşımlar ve sebepleri.

### 1. Playwright ile tarayıcı otomasyonu (bırakıldı)

İlk yaklaşım, web arayüzünü gerçek bir tarayıcıda sürmekti. Kalıntıları
`archive/` altında (`watch.js`, `login-capture.js`, `refresh-probe.js`).
Çalışıyordu ama ağırdı, kırılgandı ve sürekli açık bir tarayıcı profili
gerektiriyordu. Ağ trafiği incelenip API doğrudan çağrılabilir olunca bırakıldı.

### 2. Bulut tabanlı zamanlama (bırakıldı)

Kontroller bir bulut oturumunda zamanlanmıştı. Çalışmadı: OTP okumak için
Mac'teki Messages veritabanına erişim şart ve bulut oturumunun böyle bir
erişimi yok. Bu, işin tamamının Mac'e taşınmasının sebebi oldu.

### 3. Kabuk betiği + `launchd` (yetersiz)

`launchd` doğrudan `python3` çağırıyordu. Tam Disk Erişimi çalışmadı: izin
vermek için gösterilecek bir uygulama paketi yok, `/usr/bin/python3` ise
yönlendirici olduğu için listeye eklenmesi işe yaramıyor.

### 4. İmzasız `.app` sarmalayıcı (yetersiz)

İçinde kabuk betiği olan bir `.app` paketi denendi. İzin verildi ama çalışmadı —
imzasız paketler TCC tarafından güvenilir kimlik olarak kabul edilmiyor.

### 5. Ad-hoc imzalı SwiftUI uygulaması (kısmen)

Gerçek bir SwiftUI uygulaması yazıldı ve `codesign -s -` ile imzalandı. Çalıştı,
ama **her yeniden derlemede izin bozuldu.** Sebep uzun süre anlaşılamadı çünkü
Sistem Ayarları'nda izin verilmiş görünmeye devam ediyordu.

### 6. Developer ID ile imzalama (bugünkü çözüm)

Apple Developer sertifikasıyla imzalandığında TCC kuralı `cdhash` yerine
kimlik + ekip numarasına dayandı ve izin kalıcı hâle geldi. Yeniden derlemeler
artık izni bozmuyor.

**Çıkarılan ders:** macOS'ta TCC izni gerektiren bir yardımcı araç yazıyorsanız,
işin başında Developer ID ile imzalayın. Ad-hoc imza geliştirme sırasında
sürekli, sessiz ve teşhisi zor kırılmalara yol açar.

---

## Güvenlik notları

- `config.json` **Gmail uygulama şifrenizi düz metin olarak** içerir ve
  `.gitignore` ile korunmaktadır. Repoyu paylaşmadan önce bu dosyanın
  izlenmediğini doğrulayın:

  ```bash
  git status --porcelain --ignored | grep config.json   # "!!" ile başlamalı
  git ls-files | grep config.json                        # boş dönmeli
  ```

- Uygulama şifresini sızdırdıysanız Google Hesabı → Güvenlik → Uygulama
  şifreleri altından iptal edin.

- `archive/` klasöründe eski JWT token'ları ve şifre kopyaları bulunabilir;
  bu klasör de `.gitignore` kapsamındadır.

- Kaynak dosyalardaki telefon/e-posta varsayılanları bilerek boş bırakılmıştır;
  gerçek değerler yalnızca `config.json` içinde durur.

---

## Yol haritası fikirleri

- Bildirim tercihleri: yalnızca durum değişiminde, günlük özet, veya her kontrolde
- Menü çubuğu simgesi ile durum göstergesi
- Birden fazla konum takibi
- Makine bazlı filtre (belirli bir makineyi yok say)
- Doluluk geçmişini kaydedip yoğunluk saatlerini çıkarma
- Telegram / Slack bildirim kanalları

---

## Lisans

Kişisel kullanım için yazılmıştır. DOA API'si resmî olarak belgelenmiş bir
arayüz değildir; kullanım sorumluluğu size aittir.
