# Buddy

En liten AI-robot som sitter i hörnet av skärmen när du presenterar. Buddy lyssnar i bakgrunden, hoppar in när du säger en triggerfras ("Vad tycker du, Buddy?"), pratar svenska med en mun som rör sig i takt med rösten och drar sig tillbaka när du säger en avslutsfras ("Tack, Buddy").

<img src="Resources/AppIcon.png" width="128" alt="Buddy">

## Funktioner

- Menyradsapp för macOS 13 eller senare (Apple silicon och Intel).
- Lyssnar med Apples taligenkänning, på svenska som standard.
- Flera **moment** per presentation, vart och ett med egna triggerfraser, avslutsfraser och manus.
- Två lägen per moment:
  - **AI**: Claude svarar fritt utifrån ett grovt manus och det du faktiskt säger.
  - **Manus**: Buddy säger dina repliker ordagrant, en per svar. Inget nätverk behövs för AI.
- Animerad robot med läppsynk och textning, ovanpå bildspel i helskärm.
- Röster: ElevenLabs Eleven v4 Turbo för naturligt tal där Buddy kan skratta, sucka och viska, eller macOS inbyggda röster (gratis, fungerar offline).
- Reservrepliker om Claude inte svarar i tid. Fasta repliker kan renderas i förväg.
- Globala kortkommandon för att starta, tysta och avsluta Buddy.

## Installera

**Ladda ner:** hämta `Buddy.zip` från den senaste versionen under [Releases](../../releases), packa upp den och flytta Buddy till Program. Appen är signerad med Developer ID-certifikatet "Developer ID Application: Subtree Communications AB (Q4RJ7389LU)" och notariserad av Apple, så macOS öppnar den utan att blockera den. Första gången frågar macOS bara om du vill öppna en app som hämtats från internet.

Så kontrollerar du signaturen:

```sh
spctl -a -vv /Applications/Buddy.app
# /Applications/Buddy.app: accepted
# source=Notarized Developer ID
# origin=Developer ID Application: Subtree Communications AB (Q4RJ7389LU)
```

**Från källkod:** kräver Xcode eller Command Line Tools.

```sh
git clone https://github.com/pal/buddy.git && cd buddy
make install   # bygger, lägger Buddy i /Applications och startar
```

En app du byggt själv signeras inte med Developer ID, men den har ingen karantänflagga, så macOS öppnar den ändå.

Vid första start: tillåt mikrofon och taligenkänning när macOS frågar. Buddy syns som en ikon i menyraden (ingen ikon i Dock).

## Kom igång

1. **Inställningar → AI**: klistra in en Anthropic API-nyckel från [console.anthropic.com](https://console.anthropic.com). Standardmodell är Claude Opus 5.5. Sonnet 5.5 och Haiku 5.5 svarar snabbare.
2. **Inställningar → Röst**: välj ElevenLabs, klistra in en API-nyckel från [elevenlabs.io](https://elevenlabs.io) och tryck **Välj röst…**. Där kan du lyssna på svenska röster ur ElevenLabs Voice Library och välja en. Utan ElevenLabs används macOS-rösten; ladda då ner en svensk röst i premium- eller förbättrad kvalitet (Systeminställningar → Hjälpmedel → Uppläst innehåll → Systemröst → Hantera röster).
3. **Redigera presentationer**: en exempelpresentation finns redan. Ändra triggerfraser, avslutsfraser och moment.
4. **Kontrollpanel**: skriv "Vad tycker du, Buddy?" och tryck Skicka för att testa utan mikrofon. Säg det sedan högt.

## Röst

Med ElevenLabs är **Eleven v4 Turbo** förvalt: ElevenLabs mest uttrycksfulla modell som är snabb nog för en dialog live. Ett svar från Buddy kostar ungefär en cent. Välj en röst som är inspelad på svenska; en engelsk röst talar svenska med brytning.

- **Ljudtaggar**: Claude får lägga in `[laughs]`, `[chuckles]`, `[sighs]`, `[whispers]`, `[excited]`, `[curious]`, `[mischievously]` och `[surprised]`, och rösten skrattar, suckar eller viskar. Taggarna syns inte i textningen. Du kan också skriva dem i dina egna repliker.
- **Förbered repliker**: fasta repliker renderas med Eleven v4, den bästa modellen, och spelas sedan upp direkt från datorn.
- Svarar inte ElevenLabs pratar Buddy vidare med macOS-rösten.

Modellerna Eleven v4 (högst kvalitet men långsammare) och Flash v2.5 (snabbast) finns också att välja.

## Uppdateringar

Buddy uppdaterar sig själv. En gång om dygnet frågar Buddy GitHub efter den senaste versionen. En ny version laddas ner och kontrolleras innan den används: den måste vara signerad av samma Developer ID (Subtree Communications AB) och notariserad av Apple. Den installeras när Buddy inte har använts på 20 minuter, eller när du avslutar Buddy, och aldrig mitt i en dialog eller medan ett av Buddys fönster är öppet. Sedan startar Buddy om.

Under Inställningar → Uppdateringar kan du stänga av automatiska uppdateringar, söka efter en ny version direkt och installera en nedladdad version på en gång. Automatiska uppdateringar kräver att Buddy ligger i en mapp du får ändra i, till exempel Program. En kopia du byggt själv uppdateras inte.

## Så fungerar en dialog

1. Buddy lyssnar efter triggerfraser.
2. När en trigger hörs dyker roboten upp och väntar på en kort paus, så att du hinner prata klart.
3. Buddy svarar. Sedan väntar den på ditt svar och svarar igen, tills
   - du säger en avslutsfras (Buddy säger hej då),
   - momentets högsta antal svar är nått,
   - det har varit tyst en stund (inställbart), eller
   - du trycker ⌃⌥⌘B.
4. Mikrofonen stängs av medan Buddy pratar, så att Buddy inte hör sig själv.

**Vilket moment startar?**

- En triggerfras som bara finns i ett moment startar just det momentet.
- En gemensam triggerfras startar nästa moment som inte är gjort, i ordning. Du kan välja nästa moment i menyn (Nästa moment).
- När alla moment är gjorda svarar Buddy kort och improviserat.
- "Börja om" i menyn nollställer alla moment, t.ex. efter en repetition.

Fraserna matchas förlåtande: versaler, skiljetecken och vanliga talspråksformer spelar ingen roll ("va tycker du baddy" räknas som "vad tycker du buddy"). Hur strikt det ska vara ställer du in under Inställningar → Lyssna.

## Kortkommandon

| Kortkommando | Gör |
|---|---|
| ⌃⌥⌘ B | Starta nästa moment nu / avsluta dialogen |
| ⌃⌥⌘ . | Tyst! Avbryt Buddys replik |
| ⌃⌥⌘ L | Slå på/av lyssnandet |

De fungerar även när presentationsprogrammet ligger överst.

## Tips inför scenen

- Repetera med samma mikrofon och högtalare som på scenen. Kontrollpanelen visar vad Buddy hör.
- Välj triggerfraser som du inte säger av misstag, och gör en kort paus efter frågan.
- Tryck "Förbered repliker" i menyn innan du går upp på scen. Fasta repliker spelas då upp direkt, och med ElevenLabs i högsta kvalitet.
- AI-läget kräver nätverk. Manus-läget fungerar utan (taligenkänningen fungerar offline om svenska stöds på datorn).
- Har du en extern skärm eller projektor kan avataren visas på den, på alla skärmar eller bara på huvudskärmen (Inställningar → Avatar).
- Syns inte avataren över Keynote: tillåt andra appar att använda skärmen under bildspel i Keynotes inställningar, eller spela upp bildspelet i ett fönster.

## Presentationsfiler

Presentationer sparas som JSON i `~/Library/Application Support/Buddy/Sessions/` och kan importeras och exporteras i redigeraren. Se [examples/ai-foredrag.json](examples/ai-foredrag.json). Alla fält utom `name` är frivilliga.

| Fält | Betydelse |
|---|---|
| `name` | Presentationens namn |
| `buddyName`, `nameVariants` | Buddys namn och hur taligenkänningen kan stava det |
| `persona`, `context` | Vem Buddy är, och vad presentationen handlar om |
| `triggers`, `endPhrases` | Fraser som gäller alla moment |
| `farewells`, `fallbackLines` | Avskedsrepliker och reservrepliker |
| `maxWordsPerReply` | Ungefärlig längd på AI-svar |
| `moments[].title` | Momentets namn |
| `moments[].triggers`, `moments[].endPhrases` | Momentets egna fraser |
| `moments[].mode` | `"ai"` eller `"scripted"` |
| `moments[].script` | Grovt manus för AI-läget |
| `moments[].lines` | Repliker: sägs ordagrant i manusläge, reserv i AI-läge. Ljudtaggar som `[laughs]` fungerar med ElevenLabs |
| `moments[].maxTurns` | Högsta antal svar (0 = tills en avslutsfras sägs) |
| `moments[].enabled` | `false` hoppar över momentet |

## Integritet

- Taligenkänningen görs av Apple, på datorn om språket stöds, annars hos Apple.
- Under en dialog skickas det du säger, och en del av det du sagt de senaste minuterna, till Anthropic (Claude). Mellan dialogerna skickas inget.
- Med ElevenLabs skickas Buddys repliker dit för att göras om till tal.
- API-nycklarna sparas i macOS nyckelring.

## Testa

```sh
make test       # enhetstester för kärnlogiken
make e2e        # hela appen, end-to-end, med inmatade repliker
make e2e-audio  # hela appen med riktigt tal genom en virtuell mikrofon
```

E2E-testerna (`e2e/run_e2e.py`) startar den riktiga `Buddy.app` bredvid en presentation i helskärm och kör alla användningsfall: Buddy i bakgrunden, triggerfraser, dialog med Claude (en lokal låtsasserver som också kontrollerar att varje anrop följer Claude API:t), svenskt tal med munrörelser, avataren ovanpå presentationen, avslutsfraser, flera moment, manusläge, reservrepliker och att Buddy inte hör sig själv. Sedan startas appen igen med ElevenLabs mot en låtsasserver som kontrollerar varje anrop och svarar med riktigt svenskt tal: en svensk röst väljs ur röstbiblioteket, Eleven v4 Turbo med ljudtaggar, fasta repliker förberedda med Eleven v4 och reserv till macOS-rösten. Resultatet hamnar i `build/e2e/<läge>/report.md` tillsammans med skärmdumpar, händelselogg och anropen till Claude och ElevenLabs.

`make e2e-audio` kräver den virtuella ljudenheten [BlackHole](https://github.com/ExistentialAudio/BlackHole) som standard för in- och utljud, och en svensk röst. I GitHub Actions körs båda varianterna vid varje push, i samma jobb som bygger appen, och `e2e/setup-ci.sh` förbereder maskinen. Resultat, skärmdumpar och loggar laddas upp som artefakten `e2e-results`. Finns repository-hemligheten `ANTHROPIC_API_KEY` körs dessutom ett test mot det riktiga Claude API:t.

## Bygga från källkod

Kräver macOS 13+ och Xcode 15 eller senare.

```sh
make run    # bygger build/Buddy.app och startar den
make zip    # build/Buddy.zip, ad hoc-signerad om inte SIGN_IDENTITY är satt
```

Projektet är ett Swift-paket:

- `Sources/BuddyCore`: plattformsoberoende logik – frasmatchning, dialogmotor, Claude-protokoll. Testas i `Tests/BuddyCoreTests`.
- `Sources/Buddy`: macOS-appen – taligenkänning, röster, overlay med robot, menyrad, fönster.
- `e2e/`: end-to-end-tester av den färdiga appen.
- `scripts/`: bygga, signera, notarisera och kontrollera appen.

## Signering och notarisering

Alla byggen från CI och Releases signeras med "Developer ID Application: Subtree Communications AB (Q4RJ7389LU)" och notariseras av Apple. Notariseringsbeviset häftas fast i appen (stapling), så Gatekeeper godkänner den även utan nätverk. CI kontrollerar vid varje bygge att Gatekeeper öppnar en nedladdad kopia, och bygget misslyckas annars. Den signerade appen laddas också upp som artefakten `Buddy` (sparas i 14 dagar).

### Nya versioner

Varje sammanslagning till `main` där bygget och alla tester går igenom publicerar automatiskt en ny version under Releases, med den testade, signerade och notariserade appen som `Buddy.zip`. Versionsnumret räknas upp från den senaste taggen: v0.1.0, v0.1.1, v0.1.2 och så vidare. Vill du höja huvud- eller delversionen taggar du en commit på `main` själv, till exempel `git tag v0.2.0 && git push origin v0.2.0`; nästa version blir då v0.2.1.

### Signera med ett eget Apple Developer-konto

I en fork signerar och notariserar CI appen med ditt eget konto när hemligheterna finns. Lägg in dem under repots Settings → Secrets and variables → Actions.

**Certifikat.** Ett "Developer ID Application"-certifikat kan bara skapas av kontots Account Holder.

- I Xcode: Settings → Accounts → Manage Certificates → + → Developer ID Application. Xcode måste vara inloggat med Account Holderns Apple-ID. Annars svarar Apple "This operation can only be performed by the Account Holder".
- På webben: öppna Nyckelhanterare (Keychain Access) → Certificate Assistant → Request a Certificate From a Certificate Authority, fyll i e-post och namn och välj "Saved to disk". Logga in som Account Holder på [developer.apple.com](https://developer.apple.com/account/resources/certificates/add), välj Developer ID Application och G2 Sub-CA, ladda upp filen och ladda ner certifikatet. Dubbelklicka på det, så hamnar det i nyckelringen tillsammans med nyckeln.

Exportera sedan certifikatet med nyckel som .p12: Nyckelhanterare → My Certificates → högerklicka på "Developer ID Application: …" → Export. Står det "certificate is not trusted" saknar datorn Apples mellancertifikat [Developer ID - G2](https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer). Det spelar ingen roll för exporten, och CI installerar det själv.

<details>
<summary>Går det inte att välja .p12 vid exporten? Skapa nyckel och .p12 i Terminal i stället.</summary>

Då ligger certifikatets privata nyckel inte i samma nyckelring. Skapa en ny nyckel och förfrågan:

```sh
mkdir -p ~/buddy-signing && cd ~/buddy-signing
/usr/bin/openssl req -new -newkey rsa:2048 -nodes -keyout devid.key -out devid.csr -subj "/CN=Developer ID/C=SE"
```

Ladda upp `devid.csr` på developer.apple.com (Developer ID Application, G2 Sub-CA), spara certifikatet som `devid.cer` i samma mapp och kör:

```sh
/usr/bin/openssl x509 -inform DER -in devid.cer -out devid.pem
/usr/bin/openssl pkcs12 -export -inkey devid.key -in devid.pem -out cert.p12 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
```

Spara `cert.p12` och lösenordet säkert och radera mappen, eftersom den innehåller nyckeln okrypterad.

</details>

| Secret | Innehåll |
|---|---|
| `MACOS_CERTIFICATE_P12` | Base64 av .p12-filen: `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | Lösenordet du satte vid exporten |

**Notarisering**, antingen med en App Store Connect API-nyckel (rekommenderas, skapas i App Store Connect → Users and Access → Integrations → App Store Connect API):

| Secret | Innehåll |
|---|---|
| `APPLE_API_KEY_P8` | Innehållet i .p8-filen |
| `APPLE_API_KEY_ID` | Nyckelns id |
| `APPLE_API_ISSUER_ID` | Issuer-id |

eller med ett Apple-ID: `APPLE_ID`, `APPLE_TEAM_ID` och `APPLE_APP_PASSWORD` (ett appspecifikt lösenord från appleid.apple.com).

CI kontrollerar att Apple godtar notariseringsuppgifterna så snart de finns. Utan certifikat blir appen bara ad hoc-signerad, och macOS stoppar nedladdade kopior ("Apple could not verify …"). De öppnas via Systeminställningar → Integritet och säkerhet → Öppna ändå, eller med `xattr -dr com.apple.quarantine /Applications/Buddy.app`.
