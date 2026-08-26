# DOA API Notları

Resmî bir dokümantasyon yok; aşağıdakiler web arayüzünün ağ trafiği incelenerek
çıkarıldı. API değişirse burası güncellenmelidir.

**Taban adres:** `https://dbysmgw.doa.gov.tr/dbys`

## Ortak başlıklar

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

## Authorization başlığı

Token **`Bearer ` öneki olmadan**, ham JWT olarak gönderilir. Bu davranış
standart dışıdır:

```python
headers["Authorization"] = token          # dogru
headers["Authorization"] = f"Bearer {token}"   # 401 doner
```

## 1. OTP gönder

```http
POST /v2/auth/send-login-otp
```

```json
{ "username": "5XXXXXXXXX" }
```

Yanıtta `otpReferenceId` (UUID) döner. Alan bazen doğrudan kökte, bazen bir alt
nesnede geliyor; kod her iki durumu da tarıyor.

## 2. OTP doğrula

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

Token ömrü kısa (~10 dakika), yenileme akışı kullanılmıyor - her kontrol
turunda sıfırdan giriş yapılıyor.

## 3. Makine sorgula

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

## Yanıt yapısı

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
| `binList[].contentType` | Göz türü - `pet`, `glass`, `aluminum` |
| `binList[].level` | Doluluk yüzdesi; eşiğin üstü "dolu" |
| `binList[].state` | Gözün aktif olup olmadığı |
| `userDistanceKm` | `userLat`/`userLon` noktasına uzaklık |

## Uygunluk kuralı

Bir göz şu üç şart birden sağlanırsa "uygun" sayılır:

```python
uygun = (machineStatus == 0)               # makine çevrimiçi
        and bin["state"] is True           # göz aktif
        and bin["level"] < full_threshold  # doluluk eşiğin altında (varsayılan %90)
```
