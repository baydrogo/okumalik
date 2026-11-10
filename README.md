# Okumalık

Sonra oku, RSS okuyucu ve yer imlerini tek pencerede toplayan, bağımlılıksız küçük bir macOS uygulaması (SwiftUI, macOS 14+).

## Derleme

```bash
./build.sh            # build/Okumalık.app oluşturur
./build.sh --install  # /Applications'a da kopyalar
```

Xcode gerekmez; Command Line Tools yeterli.

## Özellikler

**Okuma**
- **Okunacaklar / Arşiv** — bağlantı ekle, okuyunca arşivle (⌘E). Satırda kapak görseli, "site · yazar · süre", okunma çizgisi ve çevrimdışı kopya durumu; kopya alınamadıysa işarete tıklayıp yeniden deneyin. Sağ üstteki menüden sıralama ve okuma süresi süzgeci; Görünüm > Sıkı Liste (⌥⌘L) tek satırlık görünüm.
- **Okuma modu** (⇧⌘L) — yazıyı [Defuddle](https://github.com/kepano/defuddle) ile ayıklar; yazar, tarih ve okuma süresini gösterir. Araçlar yazının üstünde sade bir şeritte durur, aşağı kaydırınca gizlenir. "Aa" ile yazı tipi, boyut (⌘+ / ⌘−) ve arka plan. Yazıyı tekrar açınca kaldığınız yerden devam eder. ⌘F ile sayfada bul. Yazıdaki bağlantılar tarayıcıda açılır; fotoğraflar yazının üstünde büyütülür.
- **Yan panel** (⌥⌘I) — **Bilgi** sekmesinde site, yazar, yayın tarihi, uzunluk, okunan kısım, eklenme tarihi, adres, etiketler ve not; **Vurgular** sekmesinde sayfanın vurguları.
- **Sütunlar** — kenar çubuğu ⌃⌘S ile gizlenir; Odak Modu (⇧⌘F) yalnızca yazıyı bırakır.
- **Çevrimdışı kopya** — Okunacaklar'a eklenen ve okuma modunda açılan yazılar saklanır, anında ve internetsiz açılır. Yazı sitede değiştiyse "…" > "Yazıyı Siteden Yeniden Al".
- **Vurgular ve notlar** — metni seçince beliren araç çubuğundan "Vurgula" (ya da ⇧⌘H). Seçime "Not Ekle" (⇧⌘N) ile doğrudan not yazılır. Vurguya tıklayınca ya da sağ tıklayınca not eklenir, kopyalanır, silinir; notlu vurgular noktalı çizgiyle görünür. Bağlantılara "Düzenle…" ile not yazılır.
- **Alıntı paylaşma** — seçili metin ya da vurgu, menüdeki "Paylaş" ile başlık ve bağlantıyla birlikte WhatsApp ya da başka bir kanala gönderilir; yan paneldeki "Tümünü Paylaş" sayfanın vurgularını tek mesajda paylaşır. Notlar paylaşılmaz.
- **Dışa aktarma** — yazının tamamı (başlık bilgileri, not ve vurgularla) ya da yalnızca vurgular Markdown olarak kopyalanır veya kaydedilir. Ayarlar'da Obsidian klasörü seçilirse "…" > "Obsidian'a Gönder" notu doğrudan kasaya yazar.

**Kaydetme ve düzenleme**
- **Yer İmleri** — Linkding tarzı tam genişlikte liste: site simgesi, başlık, etiketler, açıklama, tarih ve Aç · Düzenle · Okunacaklara Taşı · Sil. Başlığa tıklamak ya da çift tıklamak bağlantıyı tarayıcıda açar.
- **Görseller** — web'deki resimler için kişisel bir pano. Firefox'ta resme sağ tıklayıp "Görseli Okumalık'a gönder", okuyucuda resme sağ tıklayıp "Görsellere Kaydet", ya da resimleri pencereye sürükleyin veya ⌘V ile yapıştırın. Resim bilgisayara indirilir; hangi sayfadan geldiği, etiketler ve not birlikte tutulur. Resme tıklayınca büyür (← → ile gezinme, Esc kapatır); sayfayı açma, kopyalama, Önizleme'de açma ve silme oradan.
- **Etiketler** — okunacaklar, yer imleri, görseller ve akışlar etiketlenir; bir akışın etiketi yazılarını da kapsar. Sağ tık > "Etiketler"; listeyi başlıktaki # düğmesiyle süzme; Ayarlar > Etiketler'den yeniden adlandırma ve silme.
- **Yinelenen kontrolü** — aynı sayfa (izleme parametreleri, `www.` ve sondaki `/` yok sayılarak) bir listeye ikinci kez eklenmez, başa taşınır; ekleme penceresi ve bildirim bunu söyler.
- **Çoklu seçim** — ⌘ ya da ⇧ ile birden fazla satır seçip arşivleme, etiketleme, okundu sayma ya da silme.
- **Arama** — liste sütununun üstündeki kutu (⌥⌘F) tüm kitaplıkta başlık, adres, açıklama, etiket, not, vurgu ve kayıtlı yazının tam metninde arar; `#etiket` etikete göre süzer.
- **Çöp Kutusu ve geri alma** — silince alttaki bildirimde "Geri Al" ya da ⌘Z; silinenler ayrıca 30 gün Çöp Kutusu'nda kalır.

**Akışlar**
- RSS 2.0, RSS 1.0, Atom ve JSON Feed. Site adresi vermek yeterli, akış otomatik bulunur. Değişmeyen akışlar yeniden indirilmez (ETag / Last-Modified).
- Güncellenemeyen akışın yanında uyarı işareti; akış sayfasında son güncelleme ya da hata görünür.
- Okurken "Okunacaklara Ekle" (⌘S). Her akışta en yeni 200 yazı tutulur; okunmuş yazılar ve kayıtlı kopyalar Ayarlar'da seçilen süre sonra silinir (varsayılan 30 gün).

**Veri**
- Kitaplık her gün kendiliğinden yedeklenir (son 10 gün, `Backups` klasörü). Ayarlar'dan yedek dışa aktarılır ve geri yüklenir.
- OPML ile akış, HTML (Firefox, Chrome, Safari, Linkding) ile yer imi içe/dışa aktarma.

**Tarayıcıdan kaydetme** — Firefox eklentisi (aşağıda) ya da Ayarlar'daki yer imcikleri. Ayrıca:
- `okumalik://add?url=…&title=…&tags=a,b` — sonra oku
- `okumalik://bookmark?url=…` — yer imi
- `okumalik://feed?url=…` — akışa abone ol
- `okumalik://image?src=…&page=…&title=…` — görseli kaydet

## Firefox eklentisi

`Extensions/Firefox` klasöründeki eklenti, araç çubuğuna Okumalık düğmesi ekler (⌥⇧O). Açık sayfa başlık ve etiketlerle "Sonra Oku" ya da "Yer İmi" olarak gönderilir, sayfa yerinde kalır. Sayfaya ya da bir bağlantıya sağ tıklayınca da gönderilebilir; bir resme sağ tıklayınca "Görseli Okumalık'a gönder" resmi Görseller'e kaydeder.

- **Denemek için:** Firefox'ta `about:debugging#/runtime/this-firefox` > "Geçici Eklenti Yükle…" > `Extensions/Firefox/manifest.json`. Firefox kapanınca kaldırılır.
- **Kalıcı kurmak için** (yeni sürümde de aynısı; eklentinin sürüm numarası her seferinde artmalı): `scripts/package-firefox.sh` ile `build/okumalik-firefox.zip` oluşturun. [addons.mozilla.org/developers](https://addons.mozilla.org/developers/) adresinde "Submit a New Add-on" > "On your own" seçip zip'i yükleyin. İmzalanan `.xpi` dosyasını indirip Firefox'a sürükleyin.

`okumalik://` bağlantıları `tags=a,b` ile etiket de alır.

Defuddle `Resources/Vendor` klasöründe gelir (MIT lisansı); güncellemek için `scripts/update-defuddle.sh`.

Veriler `~/Library/Application Support/Okumalik/` klasöründe: kitaplık `library.json`, yazı kopyaları `Articles`, görseller `Images`, site simgeleri `Icons`, yedekler `Backups`. Testlerde `OKUMALIK_DATA_DIR` ortam değişkeni başka bir klasör gösterir.
