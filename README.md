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
- **Okunacaklar / Arşiv** — bağlantı ekle, okuyunca arşivle (⌘E). Sağ üstteki menüden sıralama (en yeni, en eski, en kısa) ve okuma süresi süzgeci. Satırda okuma süresi, kaldığınız yer (%) ve çevrimdışı kopya durumu görünür; kopya alınamadıysa işarete tıklayıp yeniden deneyin.
- **Okuma modu** (⇧⌘L) — yazıyı [Defuddle](https://github.com/kepano/defuddle) ile ayıklar; yazar, tarih ve okuma süresini gösterir. "Aa" menüsünden yazı tipi, boyut (⌘+ / ⌘−) ve arka plan. Yazıyı tekrar açınca kaldığınız yerden devam eder. ⌘F ile sayfada bul. Fotoğraflar yazının üstünde büyütülür; yazıdaki bir bağlantıya gidince "Geri" (⌘[) yazıya döndürür.
- **Çevrimdışı kopya** — Okunacaklar'a eklenen ve okuma modunda açılan yazılar saklanır, anında ve internetsiz açılır. Yazı sitede değiştiyse "…" > "Yazıyı Siteden Yeniden Al".
- **Vurgular ve notlar** — metni seçince beliren araç çubuğundan "Vurgula" (ya da ⇧⌘H). Vurguya tıklayınca ya da sağ tıklayınca kopyalanır, silinir; sağdaki panelden vurguya not eklenir. Bağlantılara "Düzenle…" ile not yazılır.
- **Dışa aktarma** — yazının tamamı (başlık bilgileri, not ve vurgularla) ya da yalnızca vurgular Markdown olarak kopyalanır veya kaydedilir. Ayarlar'da Obsidian klasörü seçilirse "…" > "Obsidian'a Gönder" notu doğrudan kasaya yazar.

**Kaydetme ve düzenleme**
- **Yer İmleri** — Linkding tarzı tam genişlikte liste: site simgesi, başlık, etiketler, açıklama, tarih ve Aç · Düzenle · Okunacaklara Taşı · Sil. Başlığa tıklamak ya da çift tıklamak bağlantıyı tarayıcıda açar.
- **Etiketler** — okunacaklar, yer imleri ve akışlar etiketlenir; bir akışın etiketi yazılarını da kapsar. Sağ tık > "Etiketler", sürükle-bırak ya da liste başındaki etiket şeridi. Kenar çubuğundan yeniden adlandırma ve silme.
- **Yinelenen kontrolü** — aynı sayfa (izleme parametreleri, `www.` ve sondaki `/` yok sayılarak) bir listeye ikinci kez eklenmez, başa taşınır; ekleme penceresi ve bildirim bunu söyler.
- **Çoklu seçim** — ⌘ ya da ⇧ ile birden fazla satır seçip arşivleme, etiketleme, okundu sayma ya da silme.
- **Arama** — başlık, adres, açıklama, etiket, not, vurgu ve kayıtlı yazının tam metninde.
- **Çöp Kutusu** — silinen bağlantılar ve vurgular 30 gün burada kalır; geri yüklenebilir.

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

## Firefox eklentisi

`Extensions/Firefox` klasöründeki eklenti, araç çubuğuna Okumalık düğmesi ekler (⌥⇧O). Açık sayfa başlık ve etiketlerle "Sonra Oku" ya da "Yer İmi" olarak gönderilir, sayfa yerinde kalır. Sayfaya ya da bir bağlantıya sağ tıklayınca da gönderilebilir.

- **Denemek için:** Firefox'ta `about:debugging#/runtime/this-firefox` > "Geçici Eklenti Yükle…" > `Extensions/Firefox/manifest.json`. Firefox kapanınca kaldırılır.
- **Kalıcı kurmak için:** `scripts/package-firefox.sh` ile `build/okumalik-firefox.zip` oluşturun. [addons.mozilla.org/developers](https://addons.mozilla.org/developers/) adresinde "Submit a New Add-on" > "On your own" seçip zip'i yükleyin. İmzalanan `.xpi` dosyasını indirip Firefox'a sürükleyin.

`okumalik://` bağlantıları `tags=a,b` ile etiket de alır.

Defuddle `Resources/Vendor` klasöründe gelir (MIT lisansı); güncellemek için `scripts/update-defuddle.sh`.

Veriler `~/Library/Application Support/Okumalik/` klasöründe: kitaplık `library.json`, yazı kopyaları `Articles`, site simgeleri `Icons`, yedekler `Backups`. Testlerde `OKUMALIK_DATA_DIR` ortam değişkeni başka bir klasör gösterir.
