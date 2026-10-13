# A MI IDŐNK — Redmi Pad 2 Android APK

Ez a Flutter projekt a https://www.amiidonk.hu/ WordPress REST API-jából olvas híreket.

## APK készítése GitHubon

1. Hozz létre egy **privát** GitHub repositoryt.
2. Töltsd fel a csomagban található fájlokat, a rejtett `.github/workflows/android-apk.yml` fájlt is.
3. GitHub → Actions → **Android APK - A MI IDONK** → **Run workflow**.
4. A sikeres futás végén az **Artifacts** részből töltsd le az `A_MI_IDONK_Redmi_Pad_2_APK` csomagot.
5. Csomagold ki, és az `app-release.apk` fájlt nyisd meg a Redmi Pad 2-n. Szükség esetén engedélyezd a telepítést az adott fájlkezelőből.

A GitHub-fiók és Actions-futtatás szükséges. A munkafolyamat **itt nem lett lefuttatva**, ezért a sikeres fordítás még nem igazolt.

## Funkciók és korlátok

Hírolvasás, WordPress-kategóriák, keresés, sötét mód, mentett cikkek és magyar TTS felolvasás kódja szerepel.

**NEM kész**: push értesítések (Firebase szerveroldali összekötés hiányzik), éles hírlevél-feliratkozás (jelenleg csak weboldal-link), hivatalos arculati logó. A WordPress REST API elérhetőségét éles készüléken ellenőrizni kell. Az APK még nem tesztelt.

Ne adj meg WordPress jelszót vagy Apple-azonosítót a repositoryban.
