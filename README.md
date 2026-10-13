<img src="assets/kuulokeikoni.png" alt="" width="72" align="right">

# Teams-kuulokkeet

Kun Teams-puhelu soi tai liityt kokoukseen, ohjelma kysyy, yhdistetäänkö Bluetooth-kuulokkeesi (esim. AirPods) tähän Windows-koneeseen. Yksi klikkaus, eikä Windowsin Bluetooth-valikkoa tarvitse etsiä puhelun soidessa. Pikanäppäin **Ctrl+Alt+H** yhdistää kuulokkeet milloin tahansa.

*English summary below.*

## Lataus

**[⬇ Lataa uusin versio (TeamsKuulokkeet.zip)](../../releases/latest/download/TeamsKuulokkeet.zip)** · [Kaikki versiot](../../releases)

## Asennus

1. Lataa ZIP yllä olevasta linkistä.
2. Klikkaa ZIP-tiedostoa hiiren oikealla → **Ominaisuudet**. Jos alhaalla on valintaruutu **Poista esto**, rastita se ja paina OK.
3. Pura: hiiren oikea → **Pura kaikki**.
4. Tuplaklikkaa **Asenna.cmd**. Jos Windows näyttää ikkunan "Windows suojasi tietokonettasi", valitse **Lisätietoja → Suorita silti**.
5. Valitse omat kuulokkeesi listasta numerolla ja paina Enter.

Järjestelmänvalvojan oikeuksia ei tarvita. Kuulokkeiden pitää olla paritettuina koneeseen ainakin kerran (Asetukset → Bluetooth ja laitteet → Lisää laite).

## Käyttö

| Tilanne | Mitä tapahtuu |
| --- | --- |
| Teams soi tai kokous alkaa | Ruudun oikeaan yläkulmaan tulee kysymys: **Yhdistä / Ei / Ei tuntiin** |
| Pikanäppäin **Ctrl+Alt+H** | Kuulokkeet yhdistetään heti |
| Ilmaisinalueen kuulokeikoni | Yhdistä, irrota, kyselyn päälle/pois, vaihda kuulokkeet, loki, lopeta |

Kysely tulee vain, kun kuulokkeet eivät jo ole yhdistettyinä koneeseen, ja samaa puhelua kohti vain kerran. Lyhyet viestiäänet eivät avaa kyselyä. Jos olet puhelimessa, valitse **Ei**.

Tarkemmat ohjeet ja vianetsintä: [README.txt](README.txt) (sama tiedosto on paketissa).

## Poisto

Mikä tahansa näistä:

- **Asetukset → Sovellukset → Asennetut sovellukset → Teams-kuulokkeet → Poista asennus**
- Käynnistä-valikko → Teams-kuulokkeet → **Poista Teams-kuulokkeet**
- Paketin **Poista.cmd**

## Mitä asennus tekee koneelle

Kaikki muutokset koskevat vain asentavaa käyttäjää:

- kansio `%LOCALAPPDATA%\TeamsKuulokkeet` (skripti, `asetukset.json`, `loki.txt`)
- Käynnistä-valikon kansio *Teams-kuulokkeet* ja pikakuvake Käynnistys-kansioon (`shell:startup`)
- Asennetut sovellukset -merkintä: `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\TeamsKuulokkeet`

Ohjelma ei asenna palveluita, ei käytä verkkoa eikä lähetä tietoja minnekään.

## Miten se toimii

- **Teams-äänen tunnistus:** Windowsin Core Audio -äänisessioista luetaan neljästi sekunnissa, toistaako Teams (`ms-teams.exe` tai sen WebView2-aliprosessi, tai klassinen `Teams.exe`) ääntä. Noin 1,5 s ääntä kolmen sekunnin ikkunassa avaa kyselyn. Teamsin käyttöliittymää ei lueta, joten Teams-päivitykset eivät riko tunnistusta.
- **Yhdistäminen ja irrotus:** sama mekanismi, jota Windowsin Bluetooth-asetusten Yhdistä-painike käyttää: `IKsControl` + `KSPROPSETID_BtAudio` / `KSPROPERTY_ONESHOT_RECONNECT` ja `KSPROPERTY_ONESHOT_DISCONNECT` kuulokkeiden Bluetooth-äänisuodattimelle.
- Yksi PowerShell-tiedosto (`TeamsKuulokkeet.ps1`), jossa on pieni C#-osa Core Audio -rajapintoja varten. Vaatii Windows PowerShell 5.1:n FullLanguage-tilassa (organisaation AppLocker- tai Constrained Language -asetukset voivat estää sen).

## Kehitys

- `TeamsKuulokkeet.ps1` tallennetaan **UTF-8 BOM** -koodauksella ja **CRLF**-rivinvaihdoilla (Windows PowerShell 5.1 lukee BOM-ittomat tiedostot ANSI-koodauksella). `.gitattributes` pitää rivinvaihdot oikeina.
- **CI** (`.github/workflows/ci.yml`) tarkistaa koodauksen ja rivinvaihdot sekä jäsentää ja kääntää skriptin Windows PowerShell 5.1:llä jokaisessa pushissa.
- **Julkaisu:** päivitä `$script:Version` ja `CHANGELOG.md`, commitoi ja tagaa:
  ```
  git tag v1.2.0
  git push origin v1.2.0
  ```
  `.github/workflows/release.yml` rakentaa `TeamsKuulokkeet.zip`:n (tiedostot juuressa) ja luo GitHub-julkaisun. Latauslinkki `releases/latest/download/TeamsKuulokkeet.zip` osoittaa aina uusimpaan versioon.

## English summary

A small Windows tray tool that asks *"Connect your Bluetooth headset to this PC?"* when a Microsoft Teams call rings or a meeting starts, and connects it with one click (or **Ctrl+Alt+H** at any time). Useful with AirPods, which tend to stay on the phone. Per-user install, no admin rights, no network access. Detection reads Windows Core Audio session levels for the Teams process; connect/disconnect uses the same `KSPROPERTY_ONESHOT_RECONNECT` / `DISCONNECT` mechanism as the Windows Bluetooth settings. UI and docs are in Finnish.

## Lisenssi

[MIT](LICENSE). Ei Microsoftin eikä Applen tuote. Teams, Windows ja AirPods ovat omistajiensa tavaramerkkejä.
