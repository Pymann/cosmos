# 97 — Zielbild: die Pipeline als 3D-Szene

Status: Zielbild.  Herkunft: `2026-05-29_rendering_and_sync_direction.md` — dort ist die
GL-Szene als **Hauptoberfläche** von cosmos entschieden, und „Pipeline-Graph als erste
Scene-Struktur modellieren" ist Schritt 2 der dortigen nächsten Schritte.  Dieses Kapitel sagt,
**was** gerendert wird, nachdem `96_layer_cache.md` und aiml `spec/62` festgelegt haben, was eine
Pipeline überhaupt ist.

**Stand, gemessen:** der Client benutzt `gl` bisher nur für 2D-Grundlagen (`gl.init`,
`gl.viewport`, `gl.clear_all`, `gl.enable_blend`, `gl.font`, `gl.tex`) — eine Prefab-Oberfläche,
keine Szene.  Schritt 2 des Richtungspapiers ist also offen, nicht halb erledigt.

## 97.1 Warum 3D hier Sache und nicht Schmuck ist

Eine Matrix ist von sich aus **mehrdimensional**.  `arch × compiler × mode` sind drei Achsen, und
eine Lane ist ein Punkt in diesem Raum (aiml `spec/62` §4.3) — nicht eine Zeile in einer Liste.
Eine Liste oder Tabelle kann zwei Achsen zeigen und muss die dritte falten; drei Raumachsen zeigen
sie unmittelbar.  Das ist das eine Visualisierungs-Argument, das nicht ästhetisch ist: **die Daten
haben diese Form bereits.**

- **F97-1** Der Parameterraum **ist** der Szenenraum.  Bis zu drei deklarierte Parameter-Achsen
  bilden auf x/y/z ab; eine Lane ist eine Zelle an ihrem Punkt.
- **F97-2** Mehr als drei Achsen bilden **nicht** auf Raum ab, und das wird nicht verschleiert.
  Dann greift eines von zwei ehrlichen Mitteln: kleine Vielfache (ein Gitter von Gittern, eine
  Achse je Kachel) oder Aufklappen einer Achse auf Verlangen.  Eine vierte Achse auf Farbe oder
  Größe zu legen ist ausgeschlossen — Farbe trägt schon den Status (F97-4) und Größe wäre nicht
  ablesbar.
- **F97-3** Stufen sind die **Abfolge**, nicht eine weitere Raumachse: eine Stufe ist eine Schicht
  über demselben Lane-Gitter.  Entweder gestapelt (Schicht je Stufe, von unten nach oben) oder als
  Zeitverlauf über dasselbe Gitter.  Beides ist zulässig, die Wahl ist Bedienung, nicht Modell.

## 97.2 Der Status ist schon dafür entworfen

Die sechs Werte aus `96_layer_cache.md` §96.10 (aiml `spec/62` §5.7) sind benannt, wie man sie von
einer Wand abliest.  In der Szene ist das unmittelbar nutzbar.

- **F97-4** Farbe trägt **ausschließlich** den Status.  Sie wird nicht zusätzlich für Parameter,
  Knoten oder Dauer verwendet, sonst ist keine der beiden Bedeutungen mehr lesbar.
- **F97-5** Die wichtigste Ablesung ist, **welcher Teil der Matrix wirklich gelaufen ist** — also
  „Erfolg mit Ausführung" gegen „Erfolg ohne Ausführung".  Genau dafür hat das Enum sechs statt
  drei Werte; ein zweiter Lauf, der überwiegend trifft, muss sich vom ersten auf einen Blick
  unterscheiden.  Das ist die Abnahme A96-1, hier sichtbar statt gemessen.
- **F97-6** Lebenszyklus ist **keine** Farbe (aiml F62-44).  Wartend/laufend/angehalten gehört auf
  einen anderen Kanal — Bewegung, Umriss, Füllgrad —, weil ein laufender Schritt noch kein
  Ergebnis hat.

## 97.3 Die teuren Kanten sichtbar machen

Eine `needs`-Kante **innerhalb** einer Stufe ist gratis: gleiche Maschine, gleiches Verzeichnis.
Eine Kante **über** eine Stufengrenze, deren `runs_on` sich unterscheidet, ist der Punkt, an dem
ein `output_tree` übertragen werden muss (aiml F62-48, §96.11 F96-15).

- **F97-7** Kanten werden nach Kosten unterschieden dargestellt: stufeninterne Übergabe,
  Stufengrenze auf demselben Knoten, Stufengrenze über Knoten.  Damit steht die Kostenstruktur im
  Bild, wie sie nach F62-60 schon im Quelltext steht — und ein Entwurf, der unnötig oft die
  Maschine wechselt, fällt auf, ohne dass jemand Labels vergleicht.

## 97.4 Woher der Zustand kommt

- **F97-8** Die Szene ist eine **Ansicht**, nie eine zweite Quelle der Wahrheit: sie leitet sich
  aus dem Lauf-Modell ab (`01_domain_model.md` §1.5/§1.5a) und speichert keinen Status.
- **F97-9** Live-Zustand kommt über Mirror, wie im Richtungspapier entschieden; der vorhandene
  Live-Push (`sources/server/live_push.aiml`) ist der Transport.  Kein neuer Weg.
- **F97-10** Die Szene ersetzt **keinen** Text.  Ein Fehlschlag wird am Ende an `stderr` gelesen,
  nicht an einer Farbe; Auswahl einer Zelle öffnet das Log ihres Schritts.  Die Szene ist der
  Navigator über einen Raum, der zu groß für eine Liste ist — nicht der Ersatz für die Zeile, in
  der die Ursache steht.
- **F97-11** Sie muss bei 6 Lanes und bei 600 lesbar sein.  Dafür gilt die Rangfolge aus F96-9
  auch räumlich: eine zusammengefasste Zelle zeigt den Status ihrer Gruppe nach derselben
  Rangfolge, nicht einen Durchschnitt.  Ein Durchschnitt von Farben wäre genau der siebte Wert,
  den F96-9 vermeidet.

## 97.5 Abnahme

- **A97-1** Eine laufende Matrix mit drei Achsen ist als Gitter sichtbar, jede Lane mit ihrem
  Status, und die Achsen sind beschriftet mit Parametername und Wert.
- **A97-2** Ein zweiter Lauf derselben unveränderten Matrix ist vom ersten **auf einen Blick**
  unterscheidbar (F97-5, zusammen mit A96-9).
- **A97-3** Eine Matrix, in der ein Compiler fehlschlägt, zeigt den Fehlschlag als **Spalte** —
  nicht als Streuung einzelner Zellen.  Das ist der Punkt aus aiml F62-12 („bei einer Matrix ist
  das *Muster* der Fehlschläge die Information"), hier wörtlich.
- **A97-4** Auswahl einer Zelle öffnet Log und `stderr` des zugehörigen Schritts (F97-10).
- **A97-5** Eine Lane, deren Stufen auf zwei Knoten liegen, zeigt die Knotengrenze als
  unterschiedene Kante (F97-7).
- **A97-6** Vier Parameter-Achsen werden als kleine Vielfache dargestellt, nicht auf Farbe oder
  Größe gelegt (F97-2).

## 97.6 Was zuerst

1. Lauf-Modell um Stufe/Schritt je Lane erweitern (`01_domain_model.md` §1.5/§1.5a, offener
   Punkt 7) — ohne das hat die Szene nichts anzuzeigen.
2. Statisches Gitter aus einem abgeschlossenen Lauf: Achsen, Zellen, Farben.  Kein Live, keine
   Animation (A97-1, A97-3).
3. Auswahl → Log (A97-4).  Ab hier ist es für einen Menschen benutzbar.
4. Live über Mirror (F97-9), dann Stufen als Schichten bzw. Verlauf (F97-3).
5. Kanten mit Kostenunterscheidung (F97-7), kleine Vielfache (F97-2).

Punkt 2 und 3 sind dabei das Wesentliche; Animation ist das Letzte, nicht das Erste — eine
Pipeline, deren Fehlschlag man nicht findet, wird durch Bewegung nicht besser.

## 97.7 Zwischenschritt: dasselbe Gitter in 2D

3D kostet Kamera, Projektion, Beleuchtung und Mauswahl im Raum — und beantwortet dabei **nicht**
die erste Frage: zeigt die Darstellung die Matrix richtig?  Diese Frage ist in 2D vollständig
beantwortbar, und zwar mit denselben Abbildungsregeln.

- **F97-12** Die Regeln F97-1 bis F97-4 gelten in 2D **unverändert**.  Zwei Achsen bilden auf
  Spalten und Zeilen ab; **jede weitere** Achse wird zu kleinen Vielfachen (eine Kachel je
  Wertkombination der übrigen Achsen), nie auf Farbe oder Größe (F97-2).  Was wegfällt, ist allein
  die Kamera — nicht die Abbildung.  Damit ist der Schritt nach 3D später ein Austausch des
  Zeichners, keine Neuinterpretation der Daten.
- **F97-13** Stufen bleiben die **Abfolge** (F97-3): ein Reiter oder eine Schicht über demselben
  Gitter, keine zusätzlichen Spalten.  Stufen als Spalten zu zeichnen wäre die bequeme Lösung und
  die falsche: sie macht aus einer Abfolge eine Achse und lässt zwei Stufen aussehen wie zwei
  Werte derselben Dimension.
- **F97-14** Das Gitter wird **allein aus dem Lauf-Datensatz** berechnet, nicht aus den
  Beschriftungen.  Die Achsen samt Werten und die Bindungen jedes Eintrags stehen im Datensatz
  (`96` §96.13, F96-34).  Begründung: eine Beschriftung ist für Menschen; Struktur daraus
  zurückzulesen heißt, Anzeigetext zu parsen — das bricht, sobald jemand das Format ändert, und
  zwar still.
- **F97-15** **Eine** Achse ergibt **eine Zeile**, **keine** Achse ergibt **eine** Zelle.  Steht
  hier, weil der achsenlose Fall real ist (eine Pipeline aus `per: once`-Schritten, aiml §5.5) und
  sonst als leeres Gitter erscheint — also wie „nichts zu tun" statt wie „ein Lauf".
- **F97-16** Eine Lane, die `exclude` entfernt hat, ist eine **Lücke**, keine Zelle in neutraler
  Farbe.  Eine neutrale Zelle sieht aus wie ein ausstehender Schritt; die Lücke sagt „gibt es
  nicht".  Der Unterschied ist der ganze Zweck von `exclude` (aiml §4.2) — wer ihn verwischt,
  macht aus einer bewussten Auslassung einen scheinbar hängenden Lauf.
- **F97-17** Die Farbe trägt den **Status des Eintrags** (F97-4) und sonst nichts.  Solange die
  Bedeutung der sechs aiml-Farben offen ist (`spec/62` §16 Punkt 6), bildet die Oberfläche die
  **Lebenszyklus**-Zustände ab, die entschieden sind: `pending`, `running`, `done`, `failed` —
  und benennt sie im Text daneben, damit die Darstellung nicht allein von Farbe abhängt.

