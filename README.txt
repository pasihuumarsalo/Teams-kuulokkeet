TEAMS-KUULOKKEET  -  versio 1.2.0
=================================

Kun Teams-puhelu tulee tai liityt kokoukseen, ohjelma kysyy, yhdistetäänkö
Bluetooth-kuulokkeesi (esim. AirPods) tähän tietokoneeseen. Kuulokkeet saa
yhdistettyä myös milloin tahansa pikanäppäimellä Ctrl+Alt+H.

Hyödyllinen erityisesti AirPodsien kanssa: ne yhdistyvät usein puhelimeen,
eikä Windowsin Bluetooth-valikkoon ehdi puhelun soidessa.


VAATIMUKSET
-----------
- Windows 10 tai 11.
- Kuulokkeet on paritettu tähän koneeseen ainakin kerran:
  Asetukset > Bluetooth ja laitteet > Lisää laite.
- Järjestelmänvalvojan oikeuksia EI tarvita.


ASENNUS
-------
1. Tallenna ZIP-tiedosto koneelle.
2. Klikkaa ZIP-tiedostoa hiiren oikealla > Ominaisuudet. Jos alhaalla on
   valintaruutu "Poista esto" (Unblock), rastita se ja paina OK.
3. Pura ZIP: hiiren oikea > Pura kaikki.
4. Tuplaklikkaa purettua tiedostoa Asenna.cmd.
   - Jos Windows näyttää sinisen "Windows suojasi tietokonettasi" -ikkunan,
     valitse "Lisätietoja" > "Suorita silti".
5. Asennus näyttää koneeseen paritetut kuulokkeet. Kirjoita omien
   kuulokkeidesi numero ja paina Enter.
6. Valmis. Paina Enter sulkeaksesi ikkunan. Purettu kansio ja ZIP-tiedosto
   voidaan nyt poistaa (Poista.cmd kannattaa halutessa säilyttää).

Asennuksen jälkeen ilmaisinalueelle (kellon viereen) tulee sininen
kuulokeikoni. Jos sitä ei näy, se on ^-nuolen takana. Ohjelma käynnistyy
jatkossa automaattisesti, kun kirjaudut Windowsiin.


KÄYTTÖ
------
Teams-puhelu tai kokous
  Kun Teamsista kuuluu ääntä (soittoääni tai kokous) eivätkä kuulokkeet ole
  yhdistettyinä koneeseen, ruudun oikeaan yläkulmaan avautuu kysely:
    Yhdistä     = kuulokkeet yhdistetään tähän koneeseen (Enter)
    Ei          = ei tehdä mitään (Esc), esim. jos olet puhelimessa
    Ei tuntiin  = ei kysytä seuraavaan tuntiin
  Kysely sulkeutuu itsestään 25 sekunnissa. Samaa puhelua kohti kysytään
  vain kerran. Lyhyet Teams-viestien äänet eivät avaa kyselyä.
  Vastaa puheluun Teamsin omasta ilmoituksesta normaalisti.

Pikanäppäin Ctrl+Alt+H
  Yhdistää kuulokkeet heti, esimerkiksi ennen kokoukseen liittymistä.

Kuulokeikonin valikko (hiiren oikea)
  Yhdistä ... nyt            yhdistää kuulokkeet (myös ikonin tuplaklikkaus)
  Irrota ... tästä koneesta  katkaisee kuulokkeiden yhteyden tähän koneeseen.
                             Valitse ne sen jälkeen puhelimesta, jos ne eivät
                             siirry sinne itsestään.
  (Valikossa on käytettävissä vain se näistä kahdesta, joka sopii
  kuulokkeiden nykyiseen tilaan.)
  Kysy Teams-puheluissa      kyselyn saa pois päältä / päälle
  Testaa kysely              näyttää kyselyn kokeeksi
  Vaihda kuulokkeet...       valitse toiset kuulokkeet
  Avaa loki                  tapahtumaloki vianetsintään
  Lopeta                     sulkee ohjelman (käynnistyy taas kirjautuessa)

Käynnistä-valikko > Teams-kuulokkeet
  Yhdistä kuulokkeet, Käynnistä valvonta, Vaihda kuulokkeet, Vianmääritys,
  Poista Teams-kuulokkeet.

Vinkki: Valitse Teamsin asetuksista (Asetukset > Laitteet) äänilaitteeksi
"Oletus" tai omat kuulokkeesi, jotta Teams ottaa ne käyttöön heti kun ne
yhdistyvät.


ONGELMIA?
---------
Kuulokkeet eivät yhdisty
  - Ota kuulokkeet korviin tai avaa kotelon kansi.
  - Jos puhelimessa on puhelu kesken, kuulokkeet eivät välttämättä vaihda
    koneelle.
  - Tarkista, että kuulokkeet näkyvät Windowsissa: Asetukset > Bluetooth ja
    laitteet. Jos eivät, parita ne uudelleen ja valitse sitten
    Käynnistä-valikko > Teams-kuulokkeet > Vaihda kuulokkeet.

Kuulokkeet eivät irtoa koneesta
  - Osa kuulokkeista (myös AirPods) voi yhdistyä heti takaisin viimeksi
    käytettyyn laitteeseen. Valitse kuulokkeet tällöin puhelimen
    Bluetooth-asetuksista tai irrota ne Windowsin Bluetooth-asetuksista.
  - Lokiin kirjataan jokaisen irrotusyrityksen tulos (Avaa loki).

Kysely ei tule, kun Teams soi
  - Tarkista, että ikoni näkyy ilmaisinalueella ja että valikossa
    "Kysy Teams-puheluissa" on valittuna.
  - Käynnistä-valikko > Teams-kuulokkeet > Vianmääritys. Pyydä joku
    soittamaan sinulle Teamsilla: rivillä pitäisi näkyä teams=True ja
    huippuarvo yli 0.010. Lähetä tarvittaessa kuvakaappaus ylläpitäjälle.

Asennus ei käynnisty tai näyttää virheen
  - Jos virheessä mainitaan "FullLanguage" tai "Add-Type", koneen
    tietoturva-asetukset estävät PowerShell-skriptit. Ota yhteys IT-tukeen.
  - Tietoturvaohjelmisto voi pysäyttää skriptin, koska se lukee, mikä
    ohjelma toistaa ääntä. Ota tällöin yhteys IT-tukeen.

Loki: %LOCALAPPDATA%\TeamsKuulokkeet\loki.txt
(kopioi polku Resurssienhallinnan osoiteriville)


POISTO
------
Mikä tahansa näistä poistaa ohjelman kokonaan:
  a) Asetukset > Sovellukset > Asennetut sovellukset > Teams-kuulokkeet
     > ... > Poista asennus
  b) Käynnistä-valikko > Teams-kuulokkeet > Poista Teams-kuulokkeet
  c) Tuplaklikkaa paketin Poista.cmd-tiedostoa

Poisto pysäyttää ohjelman ja poistaa kaikki sen tiedostot, pikakuvakkeet ja
asetukset. Koneen uudelleenkäynnistystä ei tarvita.


MITÄ ASENNUS TEKEE KONEELLE
---------------------------
Kaikki muutokset koskevat vain omaa käyttäjätiliäsi:
  - Kansio %LOCALAPPDATA%\TeamsKuulokkeet
    (skripti, asetukset.json ja loki.txt)
  - Käynnistä-valikkoon kansio "Teams-kuulokkeet"
  - Pikakuvake "Teams-kuulokevalvonta" Käynnistys-kansioon
    (shell:startup), jotta ohjelma käynnistyy kirjautuessa
  - Merkintä Asennetut sovellukset -listaan (rekisteriavain
    HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\TeamsKuulokkeet)

Ohjelma ei asenna palveluita, ei muuta järjestelmän asetuksia, ei käytä
verkkoa eikä lähetä tietoja minnekään. Se lukee vain Windowsin
äänilaitteiden ja äänisessioiden tilaa. Lokiin kirjataan vain tapahtumat
(esim. "kysely: Yhdistä") ja kuulokkeiden nimi, joka voi sisältää
omistajan etunimen (esim. "Matin AirPods").

Ohjelma on PowerShell-skripti (TeamsKuulokkeet.ps1), jonka koodin voi
tarkistaa millä tahansa tekstieditorilla.
