# Kitzi yol haritası

Sıra: birleştirme → pil → kendi Dock'umuz (Pro) → Nashi dosya araçları → Windows'tan geçenler için kolaylıklar → DaisyDisk, Bartender ve Hazel benzeri araçlar → boring.notch benzeri çentik paneli.
Her madde kendi modülü olarak yazılır (`Modules/<Ad>Kit`), ayarları ortak ayar penceresine gelir ve ayarlardan açılıp kapanır.

## 1. Pil (BatteryKit) — yapıldı

- [x] Sağ üst menü çubuğunda ayrı simge: aygıt simgeleri ve yüzdeleri; eşiğin altındakiler kırmızı.
- [x] Tıklayınca açılan liste: aygıt, yüzde ve pil göstergesi.
- [x] Ayarlar › Pil:
  - menü çubuğunda göster aç/kapat
  - yüzdeleri göster
  - bu Mac'i de göster
  - aygıt başına menü çubuğunda göster
  - düşük pil bildirimi ve eşiği
- [x] Veri kaynakları:
  - Mac: `IOPowerSources`.
  - Apple aksesuarları: IORegistry `BatteryPercent`.
  - BLE aygıtlar: CoreBluetooth Battery Service (0x180F/0x2A19). MX Keys Mini ve Pebble M350s ile doğrulandı.
- [ ] AirPods gibi klasik Bluetooth kulaklıklar (IOBluetooth).

## 2. Kendi Dock'umuz (DockDoor Pro özelliklerinin kendi uygulamamız)

DockDoor Pro kapalı kaynak ve ücretli ($20); kodunu kullanmıyoruz, davranışları sıfırdan yazıyoruz. Pro'nun widget SDK'sı BSL lisanslı, ondan da kod alınmaz.
Envanter pro.dockdoor.net sayfalarından, changelog'dan ve bir Reddit incelemesinden çıkarıldı (Kasım 2026, Pro v1.7.6).

### 2.1 Temel — ilk sürüm yapıldı (DockBarKit, "Kitzi Dock")
- [x] Yerleşik Dock'u gizleme:
  - otomatik gizleme + 1000 sn gecikme
  - kullanıcının kendi değerleri saklanıp geri yüklenir
  - çıkışta geri getirme seçeneği
  - (gerçek Dock üzerinde henüz denenmedi)
- [x] Alt, sol ve sağ kenarda yüzen Dock; Liquid Glass zemin (macOS 26), eski sürümlerde buzlu cam.
- [x] Sabitlenen öğeler:
  - ilk açılışta macOS Dock'undan kopyalanır, Finder hep başta
  - uygulama, klasör, dosya ve boşluk
  - Çöp Kutusu
  - açık ama sabitlenmemiş uygulamalar
- [x] Büyütme: yaylı animasyon, yumuşak düşüş, ayarlanabilir en büyük boyut.
- [x] Simgeler ekrana sığmazsa otomatik küçülme.
- [x] İsim balonu, çalışma noktası.
- [x] Tıkla aç/öne getir; sağ tık menüsü:
  - Aç
  - Finder'da Göster
  - Dock'ta Tut / Dock'tan Kaldır
  - Gizle, Çık, Zorla Çık
  - Çöp Kutusu'nu Boşalt
- [x] Sürükle-bırak:
  - dosyayı uygulamayla açma
  - Çöp Kutusu'na atma
  - uygulama sabitleme
  - simgeleri yeniden sıralama
- [x] Üzerine gelince DockDoor pencere önizlemeleri (KitziServices.windowPreviews üzerinden).
- [ ] Bildirim rozetleri; uygulama açılınca zıplama; trackpad titreşimi.
- [x] Pencereler Dock'un altına girmez: büyütülmüş pencereler Dock'ta biter, yeni pencereler üstünde açılır (macOS Dock'undaki iki yan boşluk dahil, erişilebilirlik ile).
- [ ] Otomatik gizleme (her zaman / pencere üstüne gelince), gösterme gecikmesi.
- [ ] Simgeyi Dock dışına sürükleyerek kaldırma.

### 2.2 Çoklu ekran ve profiller
- [x] Ekran seçimi: ana ekran, tüm ekranlar ya da seçilen ekranlar; her ekranda ayrı Dock, sabitlenen öğeler eşitlenir.
- [ ] Her ekrana ayrı kenar ve profil.
- [ ] Profil: kendi uygulamaları, klasörleri, widget'ları, arka planı ve simgesi.
- [ ] Profil değiştirme: düğme, kısayol, profile özel kısayol, kaydırma.
- [ ] Masaüstüne (Space) göre profil; AppSense: bir uygulama öne gelince profil değişir.
- [ ] İlk profili yerleşik Dock'tan kopyalama; JSON dışa ve içe aktarma.

### 2.3 Widget'lar
- [ ] Altyapı: Dock içinde yığınlar (her yanda en çok 3); kaydırarak sayfalama; tek, çift ve üçlü genişlik; üzerine gelince ya da tıklayınca açılan panel.
- [ ] İlk set: saat, hava durumu, takvim ve sıradaki toplantı, şu an çalan medya, CPU, bellek ve ağ, aygıt pilleri (BatteryKit'ten), pano (ClipboardKit'ten), pomodoro ve zamanlayıcı, renk seçici, hesap makinesi.
- [ ] Sonra: hatırlatıcılar, hızlı not, ses aygıtları, mikrofonu sessize alma, ekran görüntüleri, son dosyalar, AirDrop, Masaüstünü Göster.

### 2.4 Klasörler ve dosya rafı
- [ ] Klasör tıklanınca açılan panel: liste (üzerine gelince önizleme), ızgara ya da akordeon görünümü.
- [ ] Sıralama: değiştirilme tarihi, ad, boyut ya da tür; artan ya da azalan; klasör başına saklanır.
- [ ] Öğe sayısı rozeti; alt klasörlere gezinme.
- [ ] Dosya rafı: Dock üzerinde kaydırınca açılır, yeniden başlatmadan sonra korunur, Quick Look küçük resimleri gösterir.

### 2.5 Diğer Pro davranışları
- [ ] Sağ tık menüsü: tüm pencereleri küçült, geri getir ya da kapat; bu masaüstüne getir; yeniden başlat; zorla çık.
- [ ] Sağ tık menüsünde uygulamanın menü çubuğu komutlarında arama.
- [ ] Kontrol Merkezi düğmesi: arama, profiller, ses, kapat ve yeniden başlat, hızlı eylemler.
- [ ] Görünüm: Liquid Glass, buzlu cam, düz renk ya da resim; çalışma göstergesi stilleri; tüm pencereleri küçültülmüş uygulamaları soluklaştırma.
- [ ] Pencereyi Dock simgesine küçültme animasyonu; son penceresi kapanınca uygulamadan otomatik çıkma.

## 3. Dosya dönüştürücü (ConvertKit) — ilk sürüm yapıldı

[Nashi](https://github.com/orkunisitmak/nashi-app) örnek alındı ama kodu alınmadı: Nashi ffmpeg, ImageMagick, pandoc gibi hazır araçları paketliyor. Kural gereği yalnızca macOS çerçeveleri (ImageIO, PDFKit, AVFoundation, Core Image) ve yerleşik komutlar (`textutil`, `afconvert`, `ditto`) kullanılır; hiçbir şey indirilmez.

- [x] Pencere: dosya sürükle-bırak, dosyalara uyan eylemler, eylem ayarları, kayıt klasörü (varsayılan: dosyaların yanı; aynı ad varsa yeni ad verilir), ilerleme, Finder'da göster.
- [x] Finder: sağ tık › Hizmetler › "Kitzi ile Dönüştür" (NSServices) ve ⌥⇧D ile seçili dosyalar.
- [x] Görüntü: JPEG, PNG, HEIC, TIFF, GIF, BMP, PDF; kalite, en uzun kenar, konum ve kamera bilgisini silme; görüntülerden tek PDF; QR kod okuma.
- [x] PDF: birleştirme (görüntülerle birlikte de), sayfalara bölme, sayfaları görüntüye çevirme.
- [x] Video: MP4 (H.264) / MOV (HEVC) ve 1080p/720p/540p sıkıştırma, sesi çıkarma (M4A; sessiz videoda açık hata), sesi silme, GIF, kareleri kaydetme.
- [x] Ses: M4A (AAC, değişken bit hızı), WAV, AIFF.
- [x] Belge: PDF, DOCX, RTF, HTML, TXT, ODT (Türkçe karakterler korunur).
- [x] ZIP oluşturma ve açma.
- [ ] Görüntü kırpma ve döndürme, video kesme (AVFoundation ile yapılabilir).
- [ ] Yerleşik araçlarla yapılamayanlar: WebP/AVIF/MP3 yazma, MKV/WebM okuma, web'den video indirme. Kural gereği şimdilik yok.

## 5. Ekran görüntüsü aracı (CaptureKit) — ilk sürüm yapıldı

- [x] Alan (Boşluk ile pencereye geçiş), pencere ve imlecin olduğu ekran; macOS `screencapture` seçim arayüzüyle.
- [x] Düzenleyici:
  - ok, dikdörtgen, elips, vurgulayıcı, metin, mozaik, numaralı adım ve kırpma
  - 8 renk, 3 kalınlık
  - geri al / yinele
- [x] Kopyala (pano geçmişine de düşer), Kaydet (masaüstü ya da seçilen klasör, PNG/JPEG), sürükleyip bırak.
- [x] Sabitle: üstte yüzen pencere; kaydırarak büyütme, çift tık ya da Esc ile kapatma, sağ tık menüsü.
- [x] Metni Kopyala: Vision ile cihaz üzerinde, tercih edilen diller önce (Türkçe karakterler korunur).
- [x] Kısayollar ⌥⇧4 / ⌥⇧5 / ⌥⇧3 (değiştirilebilir), menü çubuğu simgesi, yakalama sonrası eylem.
- [x] iScreen Shooter tarzı: kendi seçim arayüzümüz (büyüteç, tutamaçlar, satır içi araç çubuğu), birden fazla sabitleme, geçmiş, kayan yakalama, ekran kaydı (MP4/GIF).

## 4. Windows'tan geçenler için kolaylıklar (WindowsKit) — ilk madde yapıldı

Her biri Ayarlar › Windows Alışkanlıkları'ndan ayrı ayrı açılıp kapanır:
- [x] Finder'da ⌘X ile kes, ⌘V ile taşı:
  - ⌘X, Finder'a ⌘C olarak gider; sonraki ⌘V, pano hâlâ o dosyaları tutuyorsa ⌥⌘V ("Öğeyi Buraya Taşı") olur.
  - Kesilen öğe sayısı ekranın altında kısa bir bildirimle gösterilir; Esc kesmeyi iptal eder.
  - Ad değiştirirken ve arama kutusunda tuşlara dokunulmaz.
  - Klavye düzenine göre çalışır (Sauce ile); dinleyici ana iş parçacığından ayrı çalışır.
  - Mantık test programıyla doğrulandı; Finder'da elle henüz denenmedi.
- [ ] Finder'da Enter ile aç, F2 ile yeniden adlandır, Delete ile Çöp'e taşı.
- [ ] Windows kısayolları: Win+E (Finder), Win+D (masaüstü), Win+L (kilit), Win+Shift+S (alan ekran görüntüsünü panoya al), Ctrl+Shift+Esc (Etkinlik İzleyicisi).
- [ ] Pencere yerleştirme: Ctrl+⌥+ok tuşlarıyla yarım ve çeyrek; yeşil düğmeye basınca tam ekran yerine büyütme.
- [ ] Fare ve trackpad için ayrı kaydırma yönü.
- [ ] Home/End tuşları satır başına ve sonuna gitsin.
- [ ] Finder'da sağ tıkla "Yeni metin belgesi"; dosya uzantılarını ve gizli dosyaları gösterme düğmesi.
- [ ] Son penceresi kapanınca uygulamadan çıkma (isteğe bağlı, uygulama başına).

## 6. Disk analizi (DiskKit) — ilk sürüm yapıldı

[DaisyDisk](https://daisydiskapp.com) örnek alındı (ana sayfa, teknik özellikler, v4 kılavuzu ve sürüm notları, Kasım 2026); kodu alınmadı.

**Tarama**
- [x] Bağlı birimler: kapasite çubuğu (kullanılan / temizlenebilir / boş), her birinde Tara düğmesi.
- [x] Klasör tarama: "Klasör Tara…" ve sürükle-bırak.
- [x] Paralel ve iptal edilebilir tarama; ilerlemede öğe sayısı, boyut ve klasör.
- [x] Gerçek (ayrılmış) boyut; sabit bağlar bir kez sayılır; sembolik bağlar ve başka birimler izlenmez.
- [x] Bellek sınırlı: klasör başına en büyük 200 dosya ayrı tutulur, kalanlar "küçük dosyalar" olarak toplanır.
- [ ] APFS klonlarını bir kez sayma.
- [ ] Yönetici olarak tarama, ağ sürücüleri, bulut tarama, HDD için tarama kuyruğu.
- [ ] Bütün disk ("/") taraması henüz uygulamada denenmedi.

**Harita**
- [x] Halka grafik: renk dala göre, derinlikte açılan ton; ince parçalar gri "küçük öğeler"de birleşir.
- [x] Üzerine gelince ad, boyut ve %; tıkla gir, ortaya tıkla çık; yol çubuğu.
- [x] Boyuta göre sıralı yan liste; çift tıkla aç.
- [ ] Geri/ileri geçmişi, ok tuşlarıyla gezinme, "küçük dosyalar"ı açma, dışarıda silinenleri üstü çizili gösterme.

**Gizli alan**
- [x] Gizli ve boş alan gri, tıklanamaz parçalar ve açıklaması; "N klasör okunamadı" + Tam Disk Erişimi düğmesi.
- [ ] Gizli alanın kırılımı (temizlenebilir, diğer APFS birimleri, anlık görüntüler) ve bunları silme.

**Eylemler ve toplayıcı**
- [x] Hızlı Bakış (Boşluk), Finder'da Göster, Aç, Yolu Kopyala, bu klasörü yeniden tara (⌘R).
- [x] Toplayıcı: sürükle ya da sağ tıkla ekle, toplam boyut, korunan konumlar reddedilir; onayla Çöp Kutusu'na taşı, ağaç güncellenir.
- [ ] Kalıcı silme (bilerek Çöp Kutusu kullanılıyor), Terminal'de Aç, bilgi paneli, menü çubuğu, tür filtreleri.

## 7. Menü çubuğu (MenuBarKit) — ilk sürüm yapıldı, varsayılan kapalı

[Bartender](https://www.macbartender.com) örnek alındı (Bartender 4, 5 ve 6 sayfaları ve sürüm notları, Kasım 2026); kodu alınmadı. Gizleme, ayracın uzunluğu büyütülerek yapılır; özel API kullanılmaz.

**Gizleme ve bölümler**
- [x] Kitzi simgesi (‹/›) ve gizli ayraç (|): ayracın solundakiler gizlenir; ⌘-sürükleyerek düzenlenir, konumları macOS hatırlar.
- [x] Hep gizli bölüm (‖), ⌥-tıklayınca görünür.
- [x] İlk açılışta ayraç simgenin yanına konur; sıra yanlışsa gizlemez, uyarır ve "Konumları Sıfırla" düğmesi çıkar.
- [x] Kapatınca ya da uygulamadan çıkınca bütün simgeler geri gelir.
- [ ] Yeni simgelerin hangi bölüme gideceği (şimdilik macOS en sola, yani gizli bölüme koyuyor).
- [ ] Önizlemeli yerleşim sayfası, gruplar, çentik taşması için menü çubuğunun altında ayrı çubuk.

**Gösterme**
- [x] Tıklayınca göster/gizle, ⌥-tık, sağ tık menüsü.
- [x] Boş yere gelince, boş yere tıklayınca ve kaydırınca gösterme (her biri ayrı ayar).
- [x] Yeniden gizleme: 5/10/15/30 sn ya da asla, dışarı tıklayınca; imleç çubuktayken ya da bir menü açıkken bekler.
- [ ] Ayarlanabilir üzerine gelme gecikmesi; güncellenince gösterme; pil, Wi-Fi, konum, zaman tetikleyicileri; profiller.

**Klavye ve arama**
- [x] Kısayollar: gizliler, hep gizliler, arama (varsayılanı yok).
- [x] Arama paneli: yazdıkça süzer, Return ile açar; gizli simgeler de bulunur (Erişilebilirlik ister).
- [ ] Her simgeye ayrı kısayol, klavyeyle simgeler arasında gezinme, Kestirmeler/AppleScript.
- [ ] Görünüm: simge aralığı, renk/gradyan, şekil, kenarlık, gölge.

## 8. Klasör kuralları (RulesKit) — ilk sürüm yapıldı

[Hazel](https://www.noodlesoft.com) örnek alındı (özellikler, kılavuz, Hazel 5/6 notları, Kasım 2026); kodu alınmadı. Klasörler FSEvents ile izlenir; tarih koşulları için 15 dakikada bir ve uyanınca yeniden bakılır.

**Klasörler ve kurallar**
- [x] İzlenen klasörler (aç/kapa, alt klasörleri kapsa), sıralı kurallar, tümü/herhangi biri eşleşmesi.
- [x] İlk eşleşen kural geçerli; "Diğer kurallara da bak" ile devam.
- [x] Değişmemiş dosyada kural yeniden çalışmaz; başarısız dosyayı "Şimdi Çalıştır" yeniden dener.
- [x] Önizleme (hiçbir şeyi değiştirmez), Şimdi Çalıştır, kural çoğaltma, sıralama, aç-kapa, "İşlenen Dosyaları Unut".
- [x] Etkinlik günlüğü (son 200); döngü freni (dakikada 300'den fazla eylemde 10 dk duraklama).
- [ ] Klasör grupları, iç içe koşul grupları, "hiçbiri" eşleşmesi, kural içe/dışa aktarma ve eşitleme.

**Koşullar**
- [x] Ad, tam ad, uzantı, tür, eklenme/değiştirilme/oluşturulma/son açılma tarihi, boyut, etiketler, kaynak URL, herhangi bir dosya.
- [ ] İçerik/OCR, yorum, alt klasör derinliği, Spotlight öznitelikleri, betikle koşul, tarihte "önce/sonra".

**Eylemler**
- [x] Taşı, kopyala, kalıpla yeniden adlandır, alt klasörlere ayır, etiket ekle/kaldır, Çöp Kutusu'na taşı, aç, uygulamayla aç, Finder'da göster, kabuk betiği, bildirim, ZIP, arşivi aç, diğer kurallara bak; ad çakışmasında " 2", " 3".
- [ ] Üzerine yaz/atla, yükleme (FTP/SFTP/WebDAV), takma ad, Fotoğraflar/Müzik'e aktarma, Kestirmeler/AppleScript, bul-değiştir.

**Çöp ve uygulamalar**
- [x] App Sweep: /Applications'tan silinen uygulamanın ~/Library artıklarını listeler, onayla Çöp Kutusu'na taşır.
- [ ] Çöp Kutusu'nu yaşa ya da boyuta göre boşaltma (Tam Disk Erişimi gerekir); kopya dosyaları ve yarım indirmeleri silme.

## 9. Uzak Masaüstü (RemoteKit) — ilk sürüm yapıldı

Microsoft'un [Windows App](https://learn.microsoft.com/windows-app/) uygulaması örnek alındı (Cihazlar sayfası, gruplar, favoriler, kullanıcı hesapları); kodu alınmadı. Bağlantı [FreeRDP](https://www.freerdp.com) 3.33.1 ile Kitzi'nin kendi penceresinde açılır; FreeRDP ile OpenSSL `Vendor/FreeRDP/build.sh` ile kaynaktan derlenir.

**PC'ler**
- [x] Favoriler ve Cihazlar sayfaları; açılıp kapanan gruplar; kutucuk ve liste görünümü; ada ya da son bağlanmaya göre sıralama; arama.
- [x] PC ekleme/düzenleme: adres (`ad:port`), görünen ad, grup, kullanıcı hesabı, RD Ağ Geçidi, çözünürlük, Retina, tam ekran, ses, pano, paylaşılan klasör, yönetici oturumu.
- [x] Paylaşılan kullanıcı hesapları; parolalar giriş anahtar zincirinde.
- [x] Windows App'ten içe aktarma (PC'ler, gruplar, hesap adları, ağ geçitleri, favoriler; parolalar değil), .rdp dosyası içe/dışa aktarma ve sürükle-bırak.
- [x] Oturum kapanınca son görüntü PC'nin küçük resmi olur.
- [ ] Windows App'teki "Uygulamalar" sayfası: çalışma alanı aboneliği ve RemoteApp pencereleri.
- [ ] Bulut PC / Azure Virtual Desktop (Entra ID girişi).

**Oturum**
- [x] TLS ve NLA (NTLM), sertifika onayı ("bir daha sorma" ile), eksik ya da yanlış parolada sorma, Türkçe hata açıklamaları.
- [x] Pencereye uyan çözünürlük (pencere büyüyüp küçülünce masaüstü de değişir), sabit çözünürlükler, Retina, tam ekran.
- [x] Grafik hattı (H.264 VideoToolbox, RemoteFX, progressive), uzak imleç, ses, metin panosu, klasör paylaşma, kendiliğinden yeniden bağlanma, Ctrl+Alt+Del.
- [x] Klavye: tuşlar PC düzeniyle ya da Mac'te yazılan karakterlerle; ⌘C/⌘V gibi Mac kısayolları; PC klavye düzeni Mac'inkinden seçilir.
- [ ] Dosya ve görüntü kopyala-yapıştır; mikrofon, kamera, yazıcı ve akıllı kart yönlendirme; birden çok ekran.
- [ ] Kerberos ile oturum açma (şimdilik NTLM).
- [ ] Gerçek Windows sunucularında elle denenmedi; yerel FreeRDP test sunucusunda bağlantı, görüntü, fare, sertifika ve giriş akışı denendi.

## 10. Çentik (NotchKit) — ilk sürüm yapıldı

[boring.notch](https://github.com/TheBoredTeam/boring.notch) (`b7611bb`, GPL-3.0) örnek alındı. Kod baştan Swift 6 ile yazıldı; açık panel ölçüleri, köşe yarıçapları, pencere seviyesi ve medya tuşu işleme ondan uyarlandı. Adı, logosu ve görünüşü alınmadı.

**Panel**
- [x] Çentikli ekranda çentiğin tam boyunda siyah panel; imleç gelince (0,2 sn) ya da tıklayınca 640×190 açılır, imleç çıkınca ya da dışarı tıklayınca kapanır.
- [x] Ekran seçimi: çentikli ekranlar (varsayılan), ana ekran ya da tüm ekranlar; çentiksiz ekranda menü çubuğunun ortasında hap. Ekran takılıp çıkınca paneller yenilenir.
- [x] Kapalıyken kenarlarda: çalan uygulamanın kapağı/simgesi ve seviye çubukları, ses/parlaklık göstergesi, şarj bildirimi.
- [x] Panel odak almaz (önündeki uygulama etkin kalır); tıklamalar panelin dışında alttaki pencereye gider.
- [ ] Kısayol ile açma, kaydırma hareketiyle açma/kapama, tam ekran uygulamada gizleme, çentik yüksekliği ayarı.

**Şu an çalan**
- [x] Denetim Merkezi'nde görünen her oynatıcı: başlık, sanatçı, kapak, süre, ilerleme (sürükleyerek atlama), önceki/oynat-duraklat/sonraki; kapağa tıklayınca oynatıcı öne gelir.
- [x] macOS 15.4+ kısıtı: bilgi `/usr/bin/osascript` içinde çalışan bir JXA betiğiyle (`MRNowPlayingRequest`) okunur, komutlar uygulama içinden gönderilir; özel API tek dosyada (`NotchMediaRemote.swift`). Kitzi kapanırsa betik de 5 sn içinde kendiliğinden çıkar.
- [x] macOS 26.6'da tarayıcı (Media Session) ve QuickTime ile denendi; oynat/duraklat düğmesi çalışıyor.
- [ ] Karıştırma/tekrar, beğenme, oynatıcı sesi, şarkı sözleri, ses görselleştirici, kapaktan renk alma.

**Raf**
- [x] Dosyayı çentiğe sürükleyince panel raf sekmesinde açılır; bırakılan dosyalar (bookmark ile) yeniden başlatmadan sonra da kalır, taşınan dosyayı izler, silineni düşürür.
- [x] Quick Look küçük resimleri, sürükleyip çıkarma, çift tıkla açma; sağ tık: Aç, Finder'da Göster, Kopyala, Raftan Kaldır; Rafı Temizle.
- [x] Bırakılan metin `~/Library/Application Support/Kitzi/Shelf` altına .txt olarak kaydedilir, raftan kalkınca silinir.
- [ ] AirDrop/paylaşım, çoklu seçim, dışarı sürükleyince raftan kaldırma seçeneği, Quick Look önizlemesi; elle denenmedi: raftan dışarı sürükleme.

**Takvim ve pil**
- [x] Bugünün kalan etkinlikleri (en çok 4, takvim rengiyle); izin yalnızca paneldeki düğmeye basınca istenir.
- [x] Başlıkta pil yüzdesi; prize takınca/çıkarınca ve %20, %10'da çentikte kısa bildirim (bildirimler elle denenmedi).
- [ ] Hatırlatıcılar, takvim seçimi, yarının etkinlikleri.

**Ses ve parlaklık göstergesi (varsayılan kapalı)**
- [x] Ses, sessiz ve parlaklık tuşlarını devralır (Erişilebilirlik ister); değişikliği Core Audio ve DisplayServices ile kendisi uygular, seviyeyi çentikte gösterir. ⌥ ile macOS davranışı, ⌥⇧ ile ince adım; uygulayamadığı tuş (ses denetimi olmayan çıkış, harici ekran) macOS'a geçer.
- [ ] Gerçek tuşlarla elle denenmedi (otomatik denemede sentetik tuş olayları macOS'a ulaşmadı).
- [ ] Klavye arka ışığı, mikrofon, harici ekran parlaklığı (DDC; ekran yönetimi modülüyle birlikte düşünülmeli).

**Sonraya kalanlar**
- [ ] Kamera aynası, indirme ilerlemesi, zamanlayıcı/pomodoro, hava durumu, bildirim yansıtma, menü çubuğu modülüyle çentik taşması.

## 11. Ekranlar (DisplayKit) — ilk sürüm yapıldı

[BetterDisplay](https://github.com/waydabber/BetterDisplay) örnek alındı (özellik listesi ve belgeleri, Kasım 2026); kapalı kaynak, yalnızca özellikleri esas alındı, kodu alınmadı. macOS'in yayımlamadığı arayüzler (DisplayServices, IOAVService, CGVirtualDisplay) tek dosyada (`DisplayPrivateAPI.swift`) ve çalışma anında aranır: macOS birini kaldırırsa o özellik kapanır, uygulama çökmez. Bir ekranı değiştiren hiçbir şey kullanıcı istemeden çalışmaz.

**Çözünürlük ve yerleşim**
- [x] Menü çubuğunda bütün ekranlar: çözünürlük (HiDPI dahil) ve yenileme hızı; masaüstünde kullanılamayan ve düşük çözünürlüklü kopya modlar "Diğer Çözünürlükler" altında.
- [x] Çözünürlük, yansıtma ve ana ekran değişikliği "Bu ekran ayarları kalsın mı?" diye sorar; panel her ekranda çıkar, 15 sn içinde yanıt yoksa geri alınır.
- [x] Yansıtma (bir ekran başka birinin görüntüsünü gösterir) ve ana ekran seçimi.
- [ ] Döndürme, ekranı kapatma/bağlantısını kesme, renk profili, HDR aç/kapa, çözünürlük kısayolları.
- [ ] Ön ayarlar/profiller: ekran düzenini kaydedip tek tıkla geri getirme.

**Parlaklık**
- [x] Yerleşik ekran ve Apple ekranları: DisplayServices.
- [x] Harici monitörler: Apple silicon'da IOAVService üzerinden DDC/CI (parlaklık, karşıtlık, ses, sessize alma). Yanıt vermeyen monitörde yazılımsal karartma (gamma tablosu, en az %12); ayarlardan monitör başına Otomatik / DDC/CI / yazılımsal karartma. DDC/CI seçilip monitör yanıt vermezse komutlar yine gönderilir.
- [x] Parlaklık tuşları imlecin altındaki harici monitöre gider (⌥⇧ ile küçük adımlar), seviye ekranda gösterilir; macOS'in kendi denetlediği ekranlarda tuşlara dokunulmaz.
- [ ] Intel Mac'lerde DDC/CI (IOFramebuffer I²C); şimdilik yazılımsal karartma.
- [ ] Bütün ekranları birlikte ayarlama, otomatik karartma, XDR/HDR ekranlarda fazladan parlaklık, yazılımsal karartmayı açılışta geri getirme, DDC ile giriş kaynağı seçimi.

**Sanal ekranlar**
- [x] CGVirtualDisplay: en-boy oranı, en büyük çözünürlük, HiDPI ve yenileme hızı seçilerek sanal ekran; bağla/ayır/sil. Bağlı olanlar Kitzi açılınca geri gelir; HiDPI olanlar en büyük HiDPI boyutla açılır.
- [x] Monitörü sanal ekrana yansıtarak monitörün sunmadığı HiDPI boyutları kullanma.
- [ ] Sanal ekranı pencerede gösterme (yayın, ekran paylaşımı), resim içinde resim.

**Denendi** (M5 Pro MacBook Pro, Samsung LC32G5xT DisplayPort ile; Debug derlemesindeki test kancasıyla):
- Ekranlar ve modları listelendi; yerleşik ekranın parlaklığı değişti ve geri alındı.
- Samsung DDC/CI'ye yanıt vermedi (EDID okunuyor, VCP okuması zaman aşımına uğruyor), bu yüzden kendiliğinden yazılımsal karartmaya geçti; karartma ve parlaklık tuşlarının imleç bu monitördeyken ona gitmesi denendi. Gerçek bir monitörde DDC/CI ile parlaklık değiştirme henüz denenmedi.
- Sanal ekran oluşturma, silme ve açılışta geri gelme; sanal ekranda çözünürlük değiştirme (koru, geri al ve süre dolunca geri alma), iki sanal ekran arasında yansıtma ve sanal ekranı ana ekran yapıp geri alma denendi. Gerçek ekranların çözünürlüğü değiştirilerek denenmedi.

## Bilinen eksikler (birleştirme sonrası)

- Dock ayarlarındaki "Tüm ayarları sıfırla", pano ayarlarını da sıfırlıyor. İki modül aynı `UserDefaults` alanını kullanıyor; pano geçmişi etkilenmiyor.
- Dock'taki "Şu an çalan" medya widget'ı boş. Upstream ayrı bir dylib kullanıyordu; yerine kendi çözümümüz gerekiyor. Okuma yolu NotchKit'te hazır (`osascript` + MediaRemote, `NotchMediaRemote.swift`), Dock'a henüz bağlanmadı.
- DockDoor'un ayar arama kutusu ortak ayar penceresine taşınmadı.
- Maccy'nin Kestirmeler (App Intents) eylemleri derleniyor ama denenmedi.
- Elle denenmedi:
  - ⇧⌘C pano paneli: Maccy aynı kısayolu kullanırken denenemedi.
  - Dock önizlemeleri: Erişilebilirlik ve Ekran Kaydı izni gerekiyor.
