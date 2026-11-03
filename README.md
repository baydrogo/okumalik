# Okumalık

Sonra oku, RSS okuyucu ve yer imlerini tek pencerede toplayan, bağımlılıksız küçük bir macOS uygulaması (SwiftUI, macOS 14+).

## Derleme

```bash
./build.sh            # build/Okumalık.app oluşturur
./build.sh --install  # /Applications'a da kopyalar
```

Xcode gerekmez; Command Line Tools yeterli.

## Özellikler

- **Okunacaklar / Arşiv** — bağlantı ekle, okuyunca arşivle (⌘E).
- **Yer İmleri** — önizleme yerine sağda düzenleme paneli açılır: başlık, açıklama ve etiketler yerinde değiştirilir. Çift tıklama ya da ⌘O bağlantıyı tarayıcıda açar.
- **Etiketler** — okunacaklar, yer imleri ve akışlar etiketlenebilir; bir akışın etiketi o akışın yazılarını da kapsar. Sağ tık > "Etiketler" menüsünden işaretleyin ya da bağlantıyı veya akışı kenar çubuğundaki etikete sürükleyin. Etiketler kenar çubuğunda listelenir; sağ tıkla yeniden adlandırılır ya da silinir. Sağ tık > "Düzenle…" ile her bağlantının başlığı ve açıklaması değiştirilebilir.
- **Vurgular** — metni seçince beliren araç çubuğundan "Vurgula" (ya da ⇧⌘H, sağ tık > "Vurgula"). Bir vurguya tıklayınca ya da sağ tıklayınca kopyalanabilir veya silinebilir. Vurgular sayfa tekrar açıldığında geri gelir; sağdaki panelden ya da kenar çubuğundaki "Vurgular" bölümünden Markdown olarak kopyalanır veya `.md` dosyası olarak dışa aktarılır.
- **Akışlar** — RSS 2.0, RSS 1.0 ve Atom. Site adresi vermek yeterli, akış otomatik bulunur. OPML içe/dışa aktarma Ayarlar'da.
- **Okuma modu** (⇧⌘L) — yazıyı [Defuddle](https://github.com/kepano/defuddle) ile ayıklar; yazar, tarih ve okuma süresini gösterir. "…" menüsünden yazının tamamı (başlık bilgileri ve vurgularla) Markdown olarak kopyalanır ya da dışa aktarılır. "Aa" menüsünden yazı tipi (New York, Charter, Iowan, Georgia, San Francisco, Avenir), boyut (⌘+ / ⌘−) ve arka plan (Sistem, Kâğıt, Beyaz, Sepya, Gece) seçilir.
- Bağlantıyı pencereye sürükleyip bırakarak ekleme, ⌘N'de panodaki adresi otomatik doldurma.
- **Tarayıcıdan kaydetme** — Ayarlar > "Tarayıcıdan kaydet" bölümündeki yer imciklerini (bookmarklet) tarayıcınıza ekleyin. Ayrıca:
  - `okumalik://add?url=…` — sonra oku
  - `okumalik://bookmark?url=…` — yer imi
  - `okumalik://feed?url=…` — akışa abone ol

- **Çevrimdışı kopya** — Okunacaklar'a eklenen yazılar arka planda ayıklanıp saklanır; okuma modunda internet beklenmeden anında açılır, internetsiz de okunur. Okuma modunda açılan her yazı da saklanır. Yazı sitede değiştiyse "…" > "Yazıyı Siteden Yeniden Al".

## Firefox eklentisi

`Extensions/Firefox` klasöründeki eklenti, araç çubuğuna Okumalık düğmesi ekler (⌥⇧O). Açık sayfa başlık ve etiketlerle "Sonra Oku" ya da "Yer İmi" olarak gönderilir, sayfa yerinde kalır. Sayfaya ya da bir bağlantıya sağ tıklayınca da gönderilebilir.

- **Denemek için:** Firefox'ta `about:debugging#/runtime/this-firefox` > "Geçici Eklenti Yükle…" > `Extensions/Firefox/manifest.json`. Firefox kapanınca kaldırılır.
- **Kalıcı kurmak için:** `scripts/package-firefox.sh` ile `build/okumalik-firefox.zip` oluşturun. [addons.mozilla.org/developers](https://addons.mozilla.org/developers/) adresinde "Submit a New Add-on" > "On your own" seçip zip'i yükleyin. İmzalanan `.xpi` dosyasını indirip Firefox'a sürükleyin.

`okumalik://` bağlantıları `tags=a,b` ile etiket de alır.

Defuddle `Resources/Vendor` klasöründe gelir (MIT lisansı); güncellemek için `scripts/update-defuddle.sh`.

Veriler `~/Library/Application Support/Okumalik/library.json` dosyasında, yazıların kopyaları aynı yerdeki `Articles` klasöründe tutulur.
