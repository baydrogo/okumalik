# Okumalık

## Çalışma kuralı

- **Soru sorulursa yalnızca cevap ver.** "Nasıl yapabiliriz?", "… olur mu?", "Neden …?" gibi sorularda nasıl yapılacağını anlat, seçenekleri ve önerini söyle; kodu değiştirme, dosya oluşturma, derleme ya da kurma.
- **"Yap", "ekle", "evet, ekle" gibi açık bir talimat gelince uygula.**
- Emin değilsen uygulamadan önce sor.

## GitHub

- Depo: https://github.com/baydrogo/okumalik (herkese açık).
- Her değişiklik bitip derlendikten sonra, sormadan commit atıp `main` dalını GitHub'a gönder (`git push`). Commit mesajları Türkçe ve kısa olsun.
- Bu depoda yazar e-postası GitHub'ın gizli adresi (`134225400+baydrogo@users.noreply.github.com`); değiştirme. Kişisel bilgi, parola ya da anahtar ekleme.

## Proje notları

- Arayüz ve kullanıcıyla yazışma Türkçe.
- Derleme ve kurulum: `./build.sh --install` (Xcode gerekmez; Command Line Tools ve macOS 26 SDK'sı kullanılır).
- Kullanıcı verisi: `~/Library/Application Support/Okumalik/` — testlerde bu dosyalara yazma; test programlarını `OKUMALIK_DATA_DIR=<geçici klasör>` ile çalıştır (veri klasörünü oraya yönlendirir).
- iCloud kullanılmıyor; kullanıcı istemiyor.
