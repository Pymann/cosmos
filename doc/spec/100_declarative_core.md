# 100 — Ein erklärender Kern: Infrastruktur, Konfiguration, Katalog

Status: Entwurf.  Anlass: cosmos braucht das, wofür Jenkins **vier** verschiedene Sprachen hat
(Jenkinsfile, JobDSL, JCasC, Plugin-Konfiguration) und wofür Terraform eine fünfte mitbringt.
Dieses Kapitel sagt, warum cosmos stattdessen **einen** Kern bekommt und wie er aussieht.

## 100.1 Warum nicht drei Sprachen

Die vier Jenkins-Sprachen sind nicht aus Bosheit entstanden, sondern eine nach der anderen, jede
für ein echtes Bedürfnis.  Der Preis ist trotzdem bezahlt worden, und er ist jedes Mal derselbe:

- **vier Grammatiken**, also vier Arten, etwas falsch zu schreiben, und vier Fehlermeldungen in
  verschiedenen Tonlagen;
- **kein gemeinsamer Probelauf**: JobDSL erzeugt Jobs sofort, JCasC wendet beim Start an, ein
  Jenkinsfile merkt seinen Fehler im Lauf.  Man kann nicht fragen „was würde sich ändern?";
- **kein gemeinsames Vorher/Nachher**: was JobDSL anlegt und was JCasC setzt, treffen sich erst im
  laufenden System, und wer gewinnt, hängt von der Startreihenfolge ab.

- **F100-1** cosmos hat **eine** Sprache: aiml.  Erklärende Teile sind aiml-**Daten** (dieselbe
  YAML-Form wie `- pipeline:`, `spec/62` §5), erzeugende Teile sind aiml-**Code** (`spec/62`
  §13.5/§13.6).  Es gibt keinen Grund für eine zweite Grammatik: HCL existiert, weil Go zur
  Konfigurationszeit nicht ausführbar ist — aiml ist beides.
- **F100-2** Jede Domäne hat dieselben **vier Verben**: `declare` (was soll sein), `plan` (was
  würde sich ändern), `apply` (ändern), `read` (was ist).  Wer eine Domäne dazu baut, erbt den
  Probelauf, die Anzeige und die Abweichungsprüfung, statt sie neu zu erfinden.

## 100.2 Der Kern: vier Verben, ein Begriff von Abweichung

```
declare ──► Soll (im Repo, versioniert)
                │
read ───────► Ist (aus dem laufenden System gelesen)
                │
plan  = diff(Soll, Ist)   ── zeigt Hinzufügen / Ändern / Entfernen, ändert NICHTS
apply = plan ausführen    ── idempotent, in Abhängigkeitsreihenfolge, fail closed
```

- **F100-3** `plan` **berührt nichts**.  Dasselbe Prinzip wie die Agent-Einrichtung (`94`:
  `plan(cfg)` baut die Schrittliste und fasst nichts an) — dort hat es sich bewährt, weil man
  prüfen kann, dass das Token in keiner Befehlszeile steht, **ohne** einen Knoten zu haben.
- **F100-4** `apply` ist **idempotent**: zweimal anwenden ändert beim zweiten Mal nichts.  Auch
  das steht schon in `94` (P1) und wird hier zur allgemeinen Auflage.
- **F100-5** `apply` läuft **fail closed**: der erste scheiternde Schritt bricht ab und wird
  benannt; es gibt kein „Rest trotzdem versuchen".  Ein halb angewandter Zustand, der sich als
  Erfolg meldet, ist schlimmer als ein klarer Abbruch.
- **F100-6** **Kein Zustandsspeicher.**  Terraform braucht einen `state`-Datei-Zustand, weil es
  Ressourcen verwaltet, die es sonst nicht wiederfindet — und zahlt dafür mit Sperren, veraltetem
  Zustand, Geheimnissen in der Datei und `terraform import`.  cosmos liest das **Ist aus dem
  laufenden System** (Agenten melden sich, Knoten antworten, der Katalog steht im Repo).  Damit
  entfällt diese ganze Fehlerklasse.  Preis: jede Domäne **muss** ein `read` haben — eine
  Ressource, die man nicht zurücklesen kann, gehört nicht in den Kern.
- **F100-7** **Abweichung** ist `plan` mit leerem Soll-Änderungswunsch: läuft `plan` und zeigt
  Unterschiede, ist das System abgedriftet.  Es braucht keinen eigenen Begriff und keinen eigenen
  Befehl dafür.

## 100.3 Domäne I — Infrastruktur (das Terraform-Stück)

Was: Knoten, ihre Einrichtung, ihre Rücknahme.  **Existiert schon** als `94` (plan/run,
Rückbau, Idempotenz) — hier wird es nur unter den Kern gestellt.

```yaml
- infra:
    nodes:
      - node: { host: builder-1.example, labels: [linux, x86_64], service_user: cosmos }
      - node: { host: builder-arm.example, labels: [linux, arm64],  service_user: cosmos }
```

- **F100-8** `read` ist hier **die Wahrheit vom Knoten**, nicht ein Vermerk: läuft der Dienst,
  passt die Binärdatei (Hash), ist das Profil geladen, hält die Isolation (`94` Schritt 9).  Ein
  Knoten, der „laut Zustandsdatei eingerichtet" ist, aber keinen Dienst hat, ist nicht
  eingerichtet.
- **F100-9** Entfernen heißt **Rückbau**, nicht Vergessen: Dienst stoppen, Profil entladen,
  Binärdatei und Token-Datei löschen, Dienstnutzer entfernen (`94` P9) — in dieser Reihenfolge.

## 100.4 Domäne II — Konfiguration des Controllers (das JCasC-Stück)

Was: Label-Regeln, Kontingente, Rollen, Verweise auf Geheimnisse.

```yaml
- config:
    labels:    { arm64: { max_parallel: 4 } }
    roles:
      - role: { name: operator, may: [run_pipeline, pause_run, resume_run] }
      - role: { name: viewer,   may: [get_cluster, read_run_output] }
    secrets:
      - secret: { name: registry_pull, source: file, path: /etc/cosmos/registry.cred }
```

- **F100-10** **Geheimnisse stehen nie in der Erklärung**, nur ihre **Herkunft**.  Dieselbe Regel
  wie `host:` in Pipelines (`spec/62` F62-17: Namen, nie `name=wert`) und wie das sudo-Passwort
  (`94` §94.3): was in einer versionierten Datei steht, ist veröffentlicht.
- **F100-11** Rollen sind **Listen erlaubter RPCs**, keine Rechte-Bäume.  Die serverseitige Prüfung
  ist ohnehin je RPC (`90` §AP1.2); eine zweite, feinere Beschreibung daneben wäre eine zweite
  Wahrheit.
- **F100-12** Eine Änderung an `config` wird **sofort wirksam und nicht beim Neustart**.  JCasC
  wendet beim Start an — dadurch läuft ein Jenkins monatelang mit einer Konfiguration, die in
  keiner Datei steht.  `apply` ist hier der einzige Weg, und wer ihn nicht ruft, hat nichts
  geändert.

## 100.5 Domäne III — Der Pipeline-Katalog (das JobDSL-Stück)

Was: welche Pipelines es gibt und woher sie kommen.

```yaml
- catalog:
    sources:
      - from_repo: { url: "git@…/platform.git", path: "ci/*.aiml", branch: main }
      - from_code: { generator: "pipelines_for_services" }   # aiml-Funktion
```

- **F100-13** Ein Katalog **erzeugt keine Pipelines, er findet oder baut sie**.  `from_repo`
  liest erklärte Pipelines (`spec/62` §5), `from_code` ruft eine aiml-Funktion, die
  `pipeline`-Werte zurückgibt (`spec/62` §13.5) — genau der dritte Weg aus `spec/62` §13.6.  Es
  gibt **keine** eigene Generator-Grammatik: das ist JobDSLs ganzer Daseinsgrund und in aiml
  gegenstandslos.
- **F100-14** Erzeugte Pipelines werden **geprüft wie eingereichte** (`96` §96.13): Struktur,
  Achsen, `needs`, Eindeutigkeit.  Ein Generator, der Unfug erzeugt, soll am Katalog scheitern und
  nicht beim ersten Lauf.
- **F100-15** Der Katalog ist **die Liste, nicht die Läufe**.  Ein entfernter Eintrag löscht keine
  Historie; `apply` entfernt nur die Definition.  Alles andere wäre ein Löschbefehl, der aussieht
  wie eine Aufräumarbeit.

## 100.6 Was „hochgradig skalierend" hier konkret heißt

Nicht „viele Maschinen", sondern: **welche Größe wächst, und was wird dadurch langsam?**

| Größe | wächst mit | was zuerst weh tut | Antwort im Entwurf |
|---|---|---|---|
| Lanes je Lauf | Achsenprodukt | Ausfaltung + Anzeige | Ausfaltung einmal beim Einreichen (`96` F96-31); Anzeige kachelt (`97` F97-12) |
| Läufe | Zeit | Schnappschuss der Sicht | Sicht zeigt **Fenster**, nicht alles (`99`) |
| Agenten | Knoten | Heartbeat-Verkehr | ein Schnappschuss je Takt, nicht je Sicht (`99` F99-9) |
| Schritte im Cache | Zeit × Lanes | Schlüsselsuche | Schlüssel ist ein Hash, Suche O(1) (`92`) |
| Katalog-Einträge | Teams | `plan` über alles | `plan` je Domäne und je Quelle, nicht global |

- **F100-16** Jede Sicht und jeder `plan` ist **seitenweise**.  Eine Antwort, deren Größe mit dem
  System wächst, ist der zuverlässigste Weg, ein großes System unbedienbar zu machen — und sie
  fällt im Test nie auf, weil Testsysteme klein sind.
- **F100-17** Kein `plan` über **alle** Domänen zugleich als Vorgabe.  Es ist bequem und erzeugt
  genau die Antwort, die niemand liest.

## 100.7 Offene Fragen

Siehe `doc/OPEN_QUESTIONS.md`, Abschnitt C.
