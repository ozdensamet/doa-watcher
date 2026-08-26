# Teknik Notlar

- [Yapılandırma](#yapılandırma)
- [Kullanım](#kullanım)
- [macOS Messages veritabanından OTP okuma](#macos-messages-veritabanından-otp-okuma)
- [Kod imzalama ve Tam Disk Erişimi](#kod-imzalama-ve-tam-disk-erişimi)
- [launchd zamanlaması](#launchd-zamanlaması)
- [Derleme ve dağıtım](#derleme-ve-dağıtım)
- [Sorun giderme](#sorun-giderme)
- [Geliştirme günlüğü](#geliştirme-günlüğü)

## Yapılandırma

Tüm ayarlar arayüzden yönetilir ve `~/doa-watcher/config.json` dosyasına yazılır.
Dosya `.gitignore` içindedir — şifre içerdiği için repoya girmez. Elle düzenlemek
isterseniz şablon: `config.example.json`.

| Anahtar | Tip | Açıklama |
|---|---|---|
| `enabled` | bool | Ana anahtar. `false` ise zamanlanmış kontroller çalışmaz |
| `phone` | string | DOA'ya kayıtlı telefon, başında sıfır olmadan (`5XXXXXXXXX`) |
| `email` | string | Bildirimlerin gideceği Gmail adresi (gönderici de aynı adres) |
| `app_password` | string | Gmail uygulama şifresi (normal şifre değil) |
| `lat` / `lon` | number | Arama merkezinin koordinatları |
| `userLat` / `userLon` | number | Mesafe hesabı için kullanıcı konumu (genelde `lat`/`lon` ile aynı) |
| `distance` | number | Arama yarıçapı, **metre** cinsinden |
| `check_times` | string[] | Günlük kontrol saatleri, `"SS:DD"` biçiminde, ör. `["09:25", "17:40"]` |
| `random_delay_max` | number | Kontrol başına eklenecek azami rastgele gecikme (saniye) |
| `watch_materials` | string[] | İzlenecek malzemeler: `"pet"`, `"glass"`, `"aluminum"` |
| `full_threshold` | number | Bu doluluk yüzdesinin üstü "dolu" sayılır (varsayılan 90) |

`check_times` içindeki her giriş, launchd'ye zamanlanmış bir kontrol olur.
Her kontrol bir OTP SMS'i tetiklediği için makul sayıda tutmakta fayda var.

> Eski biçimdeki (`morning_hours` / `evening_hours` / `check_minutes`)
> `config.json` dosyaları okunurken otomatik olarak `check_times` listesine
> dönüştürülür; ilk Kaydet'te yeni biçimde yazılır.

### Bildirim politikası

E-posta **yalnızca en az bir makinede uygun göz varsa** gönderilir. Durum
"uygun vardı → artık yok" şeklinde değiştiğinde yalnızca macOS bildirimi
gönderilir. Son durum `last-state.json` dosyasında tutulur.

> Her kontrolde SMS gelir çünkü sorgu için giriş şart. SMS gelmesi "makine
> müsait" demek değildir; yalnızca "kontrol yapıldı" demektir.

## Kullanım

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

### Duraklatma

Ana anahtar kapatıldığında üç katmanlı durdurma devreye girer:

1. `launchctl unload` ile iş launchd'den kaldırılır
2. plist dosyası `.disabled` uzantısına taşınır — yeniden başlatmada da yüklenmez
3. Python betiği her çalışmada `enabled` bayrağını kontrol eder, kapalıysa çıkar

Anahtar kapalıyken bile **Şimdi Kontrol Et** çalışmaya devam eder.

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

### İki önemli ayrıntı

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

## Kod imzalama ve Tam Disk Erişimi

> Bu bölüm uygulamayı **kaynaktan derleyenleri** ilgilendirir. Hazır sürümü
> indiren kullanıcının sertifikaya veya geliştirici hesabına ihtiyacı yoktur.

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

Bu durumda Sistem Ayarları'nda uygulama hâlâ listede görünür ve tik işareti
açık kalır; izin fiilen çalışmaz.

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

Uygulamanın ana ekranındaki gösterge, izni Sistem Ayarları'ndaki tike bakarak
değil `chat.db`'yi gerçekten açmayı deneyerek ölçer. Elle doğrulamak isterseniz:

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

`auth_value` değeri `2` ise izin verilmiş, `0` ise reddedilmiş demektir:

```bash
sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT client, auth_value FROM access
   WHERE service='kTCCServiceSystemPolicyAllFiles';"
```

### Alt süreçler izni miras alır

Program Messages veritabanını doğrudan Swift'ten okumuyor; `python3`'ü alt
süreç olarak başlatıyor. Python'a ayrıca izin vermek **gerekmez** — macOS
TCC değerlendirmesinde "sorumlu süreç" olarak üst uygulamayı (imzalı `.app`)
kabul eder.

Bu yüzden `/usr/bin/python3`'ü izin listesine eklemeye çalışmak işe yaramaz;
üstelik oradaki dosya bir yönlendirici (stub), gerçek ikili
`/Library/Developer/CommandLineTools/usr/bin/python3` altındadır.

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
    <dict><key>Hour</key><integer>17</integer><key>Minute</key><integer>40</integer></dict>
    <!-- config.json'daki her kontrol saati için bir giriş -->
</array>
```

Arayüzde **Kaydet**'e basıldığında plist yeniden üretilip `launchctl` ile
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

## Derleme ve dağıtım

```bash
./build.sh
```

Betik dört iş yapar: `.app` paket iskeletini ve `Info.plist`'i üretir,
`logo.jpeg`'den uygulama ikonunu oluşturur (`sips` + `iconutil`), Swift
kaynağını derleyip Developer ID sertifikasıyla imzalar ve imzayı doğrular.
Sertifika otomatik bulunur; birden fazla varsa seçmek için:

```bash
DOA_SIGN_CERT="Developer ID Application: ADINIZ (TEAMID)" ./build.sh
```

Elle derlemek isterseniz:

```bash
swiftc -swift-version 5 -O \
  -o DOAWatcher.app/Contents/MacOS/DOAWatcher \
  DOAWatcher.swift \
  -framework SwiftUI -framework AppKit -framework MapKit

codesign -s "Developer ID Application: ..." -f --timestamp --options runtime DOAWatcher.app
```

> **Ad-hoc imza (`codesign -s -`) kullanmayın** — nedeni
> [yukarıda](#kod-imzalama-ve-tam-disk-erişimi). `--options runtime`
> (hardened runtime) noterleme için zorunludur.

### Dağıtım paketi

```bash
./build.sh --release
```

GitHub Releases'a yüklenecek `DOA-Watcher.zip` paketini üretir: imzalı
`DOAWatcher.app`, `doa-checker.py`, yapılandırma şablonu, README ve LICENSE.

İndirilen uygulamanın Gatekeeper uyarısı olmadan açılması için paketi
noterletin (Apple Developer üyeliği yeterli, kimliği bir kez kaydedin):

```bash
xcrun notarytool store-credentials doa-notary \
  --apple-id APPLE_ID --team-id TEAMID --password UYGULAMAYA_OZEL_SIFRE

NOTARY_PROFILE=doa-notary ./build.sh --release
```

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

Token'ın `Bearer ` önekiyle gönderilmediğinden emin olun. API ham JWT bekliyor
([ayrıntı](api.md#authorization-başlığı)).

## Geliştirme günlüğü

Projenin bugünkü hâline nasıl geldiğinin kısa özeti — denenip bırakılan
yaklaşımlar ve sebepleri.

1. **Playwright ile tarayıcı otomasyonu (bırakıldı)** — Web arayüzünü gerçek
   tarayıcıda sürmek çalışıyordu ama ağır ve kırılgandı. Ağ trafiği incelenip
   API doğrudan çağrılabilir olunca bırakıldı.
2. **Bulut tabanlı zamanlama (bırakıldı)** — OTP okumak için Mac'teki Messages
   veritabanına erişim şart; bulutun böyle bir erişimi yok. İşin tamamı Mac'e
   taşındı.
3. **Kabuk betiği + `launchd` (yetersiz)** — `launchd` doğrudan `python3`
   çağırıyordu; Tam Disk Erişimi verilecek bir uygulama paketi olmadığı için
   çalışmadı.
4. **İmzasız `.app` sarmalayıcı (yetersiz)** — İzin verildi ama imzasız
   paketler TCC tarafından güvenilir kimlik sayılmıyor.
5. **Ad-hoc imzalı SwiftUI uygulaması (kısmen)** — Çalıştı ama her yeniden
   derlemede izin bozuldu (cdhash sorunu).
6. **Developer ID ile imzalama (bugünkü çözüm)** — TCC kuralı kimlik + ekip
   numarasına dayandı, izin kalıcı hâle geldi.

**Çıkarılan ders:** macOS'ta TCC izni gerektiren bir yardımcı araç yazıyorsanız,
işin başında Developer ID ile imzalayın. Ad-hoc imza geliştirme sırasında
sürekli, sessiz ve teşhisi zor kırılmalara yol açar.
