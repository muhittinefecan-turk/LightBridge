# LightBridge ⚡️

[![Swift](https://img.shields.io/badge/Swift-5.9+-FA7343?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2013+%20|%20iOS%2016+-000000?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com)
[![Tests](https://img.shields.io/badge/Tests-14%2F14%20Passed-brightgreen?style=for-the-badge&logo=checkmarx)](https://github.com)
[![Security](https://img.shields.io/badge/Security-Air--Gapped%20%7C%20AES--256--GCM-blueviolet?style=for-the-badge&logo=auth0)](https://github.com)
[![License](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)](LICENSE)

> **Mac Ekranından iPhone Kamerasına Fiziksel Olarak Yalıtılmış (Air-Gapped) Yüksek Hızlı Optik Dosya Aktarım Protokolü ve Ekosistemi.**

Developed with ❤️ by **Muhittin Efecan Türk**

---

## 🌟 Genel Bakış

**LightBridge**, ağ bağlantısı (Wi-Fi, Bluetooth, Hücresel Veri, İnternet) gerektirmeksizin; **yalnızca ışık dalgalarını (fotonları)** kullanarak Mac ekranı ile iPhone kamerası arasında tek yönlü (**Simplex**), güvenli ve yüksek hızlı veri aktarımı sağlayan gelişmiş bir yazılım protokolüdür.

Donanımsal veya yazılımsal dinlemelere karşı tamamen **fiziksel olarak izole (Air-Gapped)** çalışır. Alıcı cihaz hiçbir şekilde ağ yayını yapmaz; yalnızca ekrandan yansıyan ışığı yakalar.

```
+-------------------+                          +---------------------+
|    Mac Ekranı     | ~ ~ ~ [ Işık / QR ] ~ ~ >|   iPhone Kamerası   |
| (LBOPSender / Mac)|     (Optik Simplex)      | (LBOPReceiver / iOS)|
+-------------------+                          +---------------------+
         |                                                |
   Finder / Paylaş                                 Dosyalar / Fotoğraf
```

---

## 🚀 Temel Yetenekler ve Özellikler

### 1. 🛡️ Tamamen Yalıtılmış Güvenlik (Air-Gapped & Zero-Feedback)
- **Tek Yönlü İletişim (Simplex):** Alıcı cihaz (iPhone), vericiye (Mac) hiçbir RF sinyali veya geri bildirim göndermez. Optik bağlantı pasiftir.
- **Uçtan Uca Şifreleme (E2EE):** İsteğe bağlı parola ile `PBKDF2-HMAC-SHA256` (200.000 iterasyon, 16B salt) anahtar türetimi ve `AES-256-GCM` şifreleme.
- **Bütünlük Kontrolü:** Her paket donanımsal `CRC32C` ile denetlenir; aktarım sonunda tüm dosya `SHA-256` kriptografik özeti ile doğrulanır.

### 2. ⚡ Fountain İleri Hata Düzeltme (FEC)
- `Fountain.swift` modülü, Luby Transform / Rastgele Doğrusal Kodlama ilkelerine dayanır.
- Aktarılan dosya bloklara ve sembollere bölünür; standart paketler bittikten sonra SplitMix64 tabanlı sonsuz **onarım paketleri (Repair Symbols)** yayını yapılır.
- Alıcı, $GF(2)$ Galois Alanı üzerinde **artımlı Gauss Elemesi (Incremental Gaussian Elimination)** uygulayarak kayıp paketleri anında kurtarır.
- Kamera bazı kareleri kaçırsa bile akış durmaz; aktarım kesintisiz tamamlanır.

### 3. 🏁 Çoklu Optik Matris & Çok Kodlu Mozaik
- **1×1, 2×2 ve 3×3 Tiled QR:** Tek bir ekranda aynı anda birden çok QR kodu mozaik şeklinde gösterilerek paralel aktarım hızı katlanır.
- **Deneysel Özel Optik Matris (Matrix.swift):** QR protokolünün ötesinde, monokrom (1-bit / 96×96) veya 4-ton Gri (2-bit / 64×64 Gray Kodu) özel ışık matrisi modları.

### 4. 📂 Sistemle Tam Entegre Kullanıcı Deneyimi
- **macOS Finder Paylaşım Eklentisi (MacShare):** Finder'da herhangi bir dosyaya `Sağ Tık → Paylaş → LightBridge` diyerek aktarım tek dokunuşla başlatılabilir.
- **Sürükle-Bırak:** Dosyayı doğrudan Mac penceresine sürükleyip bırakarak yayınlama.
- **iOS Otomatik Ayrıştırma:** Aktarılan görsel ve videolar doğrudan iOS Fotoğraf Arşivi'ne (`PHPhotoLibrary`), diğer dosyalar ise *Dosyalarım → LightBridge* klasörüne kaydedilir.

### 5. 📊 Hız Laboratuvarı (Speed Lab) & Telemetri
- Dahili test laboratuvarı; farklı paket boyutları, kare hızları (FPS) ve mozaik düzenlerini otomatik kıyaslar.
- iPhone tarafında anlık **Goodput (B/s)**, ham kare sayısı, geçerli paket oranı ölçülür ve tek tıkla `lightbridge_lab.csv` formatında dışa aktarılabilir.

---

## 🏗️ Proje Mimarisi

```
LightBridge/
├── Apps/
│   ├── Mac/                  # macOS SwiftUI İstemcisi
│   │   ├── LightBridgeMacApp.swift
│   │   ├── SenderModel.swift # Yayın motoru, QR sentezleyici & Lab denetleyicisi
│   │   ├── SenderView.swift  # Mac kullanıcı arayüzü
│   │   └── SharedInbox.swift # App Group dosya köprüsü
│   ├── MacShare/             # macOS Finder Share Extension
│   │   ├── ShareViewController.swift
│   │   └── SharedInbox.swift
│   └── iOS/                  # iOS SwiftUI İstemcisi
│       ├── LightBridgeIOSApp.swift
│       ├── ScannerView.swift # AVFoundation kamera oturumu & donanımsal okuyucu
│       ├── ReceiverModel.swift# Oturum yönetimi, kalıcılık & PIN doğrulama
│       └── ReceiverView.swift# Kamera vizörü, ilerleme çubuğu & Lab arayüzü
└── Packages/
    └── LightBridgeCore/      # Bağımsız Swift Paketi (macOS & iOS)
        ├── Sources/LightBridgeCore/
        │   ├── Base45.swift     # RFC 9285 Base45 kodlayıcı/çözücü
        │   ├── CRC32C.swift     # Castagnoli CRC32C sağlama
        │   ├── Crypto.swift     # PBKDF2 + AES-256-GCM güvenlik katmanı
        │   ├── Fountain.swift   # GF(2) Gauss eleme & Fountain kodları
        │   ├── Manifest.swift   # Dosya üstverisi ve SHA-256 doğrulama
        │   ├── Matrix.swift     # Özel optik matris (mono96 & gray64)
        │   ├── Packet.swift     # 28-byte ikili LBOP/1 paket başlığı
        │   ├── Receiver.swift   # Durum makinesi ve blok birleştirici
        │   └── Sender.swift     # Akış paketleyicisi
        └── Tests/
            └── CoreTests.swift  # 14 kapsamlı birim testi
```

---

## 📦 LBOP/1 Protokol Özeti

| Alan | Boyut | Açıklama |
| :--- | :--- | :--- |
| `magic` | 4 Bayt | ASCII `"LBOP"` |
| `version` | 1 Bayt | Protokol sürümü (`0x01`) |
| `type` | 1 Bayt | `0x01` Manifest, `0x02` Data, `0x03` Repair |
| `session_id` | 8 Bayt | Rastgele oturum kimliği |
| `block_index`| 4 Bayt | Blok numarası (Big-Endian `UInt32`) |
| `sequence` | 4 Bayt | Sembol sırası veya Repair tohumu (Seed) |
| `payload_len`| 2 Bayt | Yük bayt uzunluğu (`UInt16`) |
| `crc32c` | 4 Bayt | Başlık + Yük Castagnoli CRC sağlama toplamı |
| `payload` | Değişken | Veri yükü |

---

## 🛠️ Kurulum ve Derleme

### Gereksinimler
- **macOS:** macOS 13.0 (Ventura) veya üzeri, Xcode 15+
- **iOS:** iOS 16.0 veya üzeri (Kamera taraması için fiziksel iPhone tavsiye edilir)
- **XcodeGen:** Proje dosyalarını temiz ve çakışmasız üretmek için

### Adım Adım Kurulum

1. **Depoyu Klonlayın:**
   ```bash
   git clone https://github.com/muhittinefecanturk/LightBridge.git
   cd LightBridge
   ```

2. **Xcode Projesini Oluşturun:**
   ```bash
   brew install xcodegen
   xcodegen generate
   ```

3. **Geliştirici İmzası (Signing):**
   - Oluşan `LightBridge.xcodeproj` dosyasını Xcode ile açın.
   - Her üç hedef (`LightBridgeMac`, `LightBridgeIOS`, `LightBridgeShare`) için **Signing & Capabilities** sekmesinden kendi Apple Developer Team'inizi seçin.
   - Mac uygulaması ve Share eklentisinde **App Groups** yeteneğinin açık olduğundan emin olun (`group.com.lightbridge.app`).

4. **Birim Testlerini Doğrulayın:**
   ```bash
   cd Packages/LightBridgeCore
   swift test
   ```
   *(Tüm testlerin başarıyla geçtiğini doğrulayın: `14 passed, 0 failed`)*

---

## 📱 Kullanım Kılavuzu

### Dosya Gönderme (Mac)
1. `LightBridgeMac` uygulamasını açın.
2. Bir dosyayı sürükleyip pencereye bırakın veya **"Dosya seç…"** butonuna tıklayın.
   *(İsteğe bağlı olarak Finder'da dosyaya sağ tıklayıp **Paylaş → LightBridge** seçeneğini de kullanabilirsiniz).*
3. İsteğe bağlı olarak aktarımı şifrelemek için bir **Parola** girin.
4. Kodlar ekranda oynamaya başlayacaktır.

### Dosya Alma (iPhone)
1. `LightBridgeIOS` uygulamasını fiziksel iPhone'unuzda başlatın.
2. Kamerayı Mac ekranındaki koda tutun.
3. İlerleme çubuğu tamamlandığında dosyanız otomatik olarak doğrulanır ve kaydedilir.
   - Görseller ve Videolar doğrudan **Fotoğraflar** uygulamasına aktarılır.
   - Belgeler ve arşivler **Dosyalarım → LightBridge** klasörüne kaydedilir.

---

## 🧪 Birim Testleri & Güvenilirlik

LightBridge çekirdeği tam kapsamlı test güvencesine sahiptir:
- `testBase45RFCVectors` (RFC 9285 standart uyumluluğu)
- `testCRC32CVector` (Donanımsal CRC doğrulama)
- `testEncryptedTransfer` (AES-256-GCM + PBKDF2 şifreleme ve deşifreleme)
- `testLateJoinerStillCompletes` (Yayına sonradan katılan alıcının FEC ile tamamlaması)
- `testTransferWithHeavyLossUsesRepair` (%40+ paket kaybında Gauss elemesi ile kurtarma)
- `testMultiBlockLargeFile` (Çok bloklu büyük dosya akış testleri)
- `testResumeFromSnapshot` (Yarıda kalan aktarımı disktan geri yükleme)
- `testMatrixMono` & `testMatrixGray` (Özel luma matris kodlama/çözme)

---

## 👤 Geliştirici

**Muhittin Efecan Türk**  
*Full Stack & iOS/macOS Developer*  
- **GitHub:** [@muhittinefecanturk](https://github.com/muhittinefecanturk)

---

## 📄 Lisans

Bu proje **MIT Lisansı** altında lisanslanmıştır. Detaylar için [LICENSE](LICENSE) dosyasına göz atabilirsiniz.
