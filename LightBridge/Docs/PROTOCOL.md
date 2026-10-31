# LBOP/1 — Protokol özeti, SDK ve tehdit modeli (M8)

## Paket (28 bayt başlık, big-endian)
`magic "LBOP"(4) | version=1 | type | session_id(8) | block_index u32 | sequence u32 | payload_len u16 | crc32c u32 | payload`
CRC32C: başlık (CRC alanı 0) + payload. Test vektörü: "123456789" → 0xE3069283.
Tipler: 0x01 MANIFEST, 0x02 DATA (sistematik; sequence = blok içi sembol no), 0x03 REPAIR (sequence = seed), 0x04 END (kullanılmaz).

## Manifest
`u64 uzunluk | 32B SHA-256 | u16 sembol baytı | u32 toplam sembol | u16 K (blok sembolü) | u8 bayrak(bit0=şifreli) | [16B salt] | u8 ad uzunluğu | ad`
Uzunluk ve SHA-256, **aktarılan** bayt dizisi içindir (şifreliyse şifreli blob).

## Kaynak bloklama ve FEC
Dosya `symbolBytes` boyutlu sembollere, semboller en çok K'lık bloklara bölünür (son sembol sıfırla doldurulur).
Yayın: (1) tüm sistematik semboller, (2) sonsuz onarım turu. Onarım sembolü = bloğun, `seed`'den türeyen rastgele alt kümesinin XOR'u
(SplitMix64, her bit ½ olasılık; denklem seed+blok+k'den herkesçe yeniden üretilir). Alıcı GF(2) üstünde artımlı Gauss eleme yapar;
blok başına ortalama k+~2 bağımsız sembol yeterlidir. Geç katılan alıcı da tamamlayabilir (simplex, geri bildirim yok).

## Taşıma
- **QR:** LBOP paketi → Base45 (RFC 9285) → QR (ECC M). Bir karede 1×1 / 2×2 / 3×3 kod.
- **Matris (deneysel):** bkz. `Matrix.swift`. N×N hücre, siyah çerçeve, kalibrasyon satırı, 1 bit (mono) ya da 2 bit (4 gri ton, Gray kodu).

## Şifreleme (isteğe bağlı)
PBKDF2-HMAC-SHA256 (200.000 tur, 16B rastgele salt) → AES-256-GCM. Düz metin: `[ad uzunluğu][ad][dosya]`; dosya adı manifestte görünmez ("sifreli.lbx").

## Tehdit modeli (kısa)
- Optik kanalı gören herkes paketleri kaydedebilir → gizlilik yalnızca parolanın gücüne bağlıdır; kısa PIN çevrimdışı denenebilir. Uzun parola kullanın.
- Bütünlük: SHA-256 (+ şifreliyse GCM etiketi). Bozuk/yabancı oturum paketleri CRC, oturum kimliği ve manifest tutarlılığıyla elenir.
- Dosya adı temizlenir (yol ayırıcı, `..`, kontrol karakteri); boyut tavanı 256 MiB; manifest çelişkisi reddedilir.
- Kimlik doğrulama YOK: alıcı, göndericinin kim olduğunu bilmez.

## SDK
`Packages/LightBridgeCore` bağımsız bir Swift Package'tır (macOS 13+/iOS 16+):
`LBOPSender(fileData:fileName:symbolBytes:blockSymbols:passphrase:)` → `nextPacket()`; `LBOPReceiver.ingest(packet:)/ingest(qrString:)`,
`unlock(passphrase:)`, `exportState()/restore(_:)`; `LBMatrix.renderLuma/decode`; `LBCrypto`; `Base45`; `CRC32C`.
