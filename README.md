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
- Röster: macOS inbyggda (gratis, fungerar offline) eller ElevenLabs.
- Reservrepliker om Claude inte svarar i tid. Fasta repliker kan renderas i förväg.
- Globala kortkommandon för att starta, tysta och avsluta Buddy.

## Installera

**Från källkod (rekommenderas just nu):** kräver Xcode eller Command Line Tools.

```sh
git clone https://github.com/pal/buddy.git && cd buddy
make install   # bygger, lägger Buddy i /Applications och startar
```

En app du byggt själv har ingen karantänflagga, så macOS öppnar den utan varning.

**Nedladdad app:** ladda ner `Buddy.dmg` från [Releases](../../releases). Är versionen signerad och notariserad med ett Developer ID öppnas den direkt. Annars stoppar macOS den ("Apple could not verify …"). Öppna den då via Systeminställningar → Integritet och säkerhet → Öppna ändå, eller ta bort karantänflaggan i Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Buddy.app
```

Vid första start: tillåt mikrofon och taligenkänning när macOS frågar. Buddy syns som en ikon i menyraden (ingen ikon i Dock).

## Kom igång

1. **Inställningar → AI**: klistra in en Anthropic API-nyckel från [console.anthropic.com](https://console.anthropic.com). Standardmodell är Claude Opus 5.5. Sonnet 5.5 och Haiku 5.5 svarar snabbare.
2. **Inställningar → Röst**: välj röst. För bäst svensk macOS-röst: Systeminställningar → Hjälpmedel → Uppläst innehåll → Systemröst → Hantera röster, och ladda ner en svensk röst i premium- eller förbättrad kvalitet.
3. **Redigera presentationer**: en exempelpresentation finns redan. Ändra triggerfraser, avslutsfraser och moment.
4. **Kontrollpanel**: skriv "Vad tycker du, Buddy?" och tryck Skicka för att testa utan mikrofon. Säg det sedan högt.

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
- Tryck "Förbered repliker" i menyn innan du går upp på scen. Fasta repliker spelas då upp direkt.
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
| `moments[].lines` | Repliker: sägs ordagrant i manusläge, reserv i AI-läge |
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

E2E-testerna (`e2e/run_e2e.py`) startar den riktiga `Buddy.app` bredvid en presentation i helskärm och kör alla användningsfall: Buddy i bakgrunden, triggerfraser, dialog med Claude (en lokal låtsasserver som också kontrollerar att varje anrop följer Claude API:t), svenskt tal med munrörelser, avataren ovanpå presentationen, avslutsfraser, flera moment, manusläge, reservrepliker och att Buddy inte hör sig själv. Resultatet hamnar i `build/e2e/<läge>/report.md` tillsammans med skärmdumpar, händelselogg och anropen till Claude.

`make e2e-audio` kräver den virtuella ljudenheten [BlackHole](https://github.com/ExistentialAudio/BlackHole) som standard för in- och utljud, och en svensk röst. På GitHub Actions sätts det upp av `e2e/setup-ci.sh`. Finns repository-hemligheten `ANTHROPIC_API_KEY` körs dessutom ett test mot det riktiga Claude API:t.

## Bygga från källkod

Kräver macOS 13+ och Xcode 15 eller senare.

```sh
make run    # bygger build/Buddy.app och startar den
make zip    # build/Buddy.zip att dela
```

Projektet är ett Swift-paket:

- `Sources/BuddyCore`: plattformsoberoende logik – frasmatchning, dialogmotor, Claude-protokoll. Testas i `Tests/BuddyCoreTests`.
- `Sources/Buddy`: macOS-appen – taligenkänning, röster, overlay med robot, menyrad, fönster.
- `e2e/`: end-to-end-tester av den färdiga appen.
- `scripts/`: bygga, signera, notarisera och kontrollera appen.

## Signera och notarisera (för att dela appen)

Med ett Apple Developer-konto signerar och notariserar CI appen automatiskt, så att nedladdade kopior öppnas utan varning. Lägg in hemligheterna under repots Settings → Secrets and variables → Actions:

| Secret | Innehåll |
|---|---|
| `MACOS_CERTIFICATE_P12` | Base64 av ett exporterat "Developer ID Application"-certifikat med nyckel: `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | Lösenordet du satte när du exporterade .p12-filen |

Och för notarisering, antingen en App Store Connect API-nyckel (rekommenderas):

| Secret | Innehåll |
|---|---|
| `APPLE_API_KEY_P8` | Innehållet i .p8-filen |
| `APPLE_API_KEY_ID` | Nyckelns id |
| `APPLE_API_ISSUER_ID` | Issuer-id |

eller ett Apple-ID: `APPLE_ID`, `APPLE_TEAM_ID` och `APPLE_APP_PASSWORD` (ett appspecifikt lösenord från appleid.apple.com).

Certifikatet skapar du i Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application, och exporterar från Nyckelringsåtkomst som .p12. API-nyckeln skapar du i App Store Connect → Users and Access → Integrations → App Store Connect API.

När hemligheterna finns kontrollerar CI också att Gatekeeper öppnar en nedladdad kopia, och bygget misslyckas annars. Taggar som `v0.1.0` publicerar en release med `Buddy.dmg` och `Buddy.zip`.
