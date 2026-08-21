# Feuille de route — Document IR (+ documents Word)

Décidé en discussion (2026-08) : l'app évoluera vers une **représentation
interne indépendante du format** (Document IR), cœur du système :

```
PDF  ─→ Parser/OCR ─→ Document IR ─→ Analyse sémantique ─→ Traduction ─→ Renderer
DOCX ─→ Parser     ─↗                (IR traduit)         ─→ PDF / DOCX / reflow
```

## Principes adoptés

- **Trois couches séparées** : contenu (texte/tableaux/images) / sémantique
  (titre, paragraphe, légende…) / layout (bbox, police, marges).
- Éléments : `TextBlock` (→ `Line` → `Span`), `Table` (→ `Cell`),
  `Image` (+ `caption`), `Header`, `Footer`, `Formula` (stub).
- **Original conservé** + carte de traductions par langue
  (`translations: {en: …, es: …}`) : parser une fois, traduire N langues.
- **Relations** minimales : `caption_of`, `contained_in`.
- IR en **classes Dart typées**, lazy par page (mémoire téléphone) ;
  JSON uniquement comme vue de sérialisation/debug.

## Réalité du parseur (garde-fous)

- PDFium/pdfrx n'expose NI fontFamily/italic NI tables NI structure
  logique : la sémantique PDF est **inférée** (clustering tailles de
  police, répétition inter-pages pour headers/footers, CodeDetector…).
  → champs IR **nullables + scores de confiance**, jamais une vérité.
- PDF réels souvent non tagués : assumer la couche heuristique.
- **Mur des polices** : renderer PDF vectoriel fidèle impossible court
  terme (polices non extrayables, métriques de substitution décalées) →
  l'export « fidèle » image+patchs reste la référence ; l'IR améliore
  l'export « léger ».
- `Formula` : type conservé, zéro investissement v1.

## Phases

1. **IR v1** : classes `IrDocument/IrPage/IrElement` (content/style/
   semantic/layout) ; `PdfBlockExtractor` émet l'IR (lignes/spans existent
   déjà) ; inférence cheap : niveaux de titre, header/footer par
   répétition inter-pages, rôle code. App existante branchée via
   adaptateurs, rien ne casse.
2. **Tables** : détection heuristique de grilles, cellules traduites
   individuellement, géométrie préservée.
3. **Relations** : `caption_of` (proximité + motifs « Figure/Tableau »),
   `contained_in` (hiérarchie de titres) → contexte de traduction +
   assistant.
4. **IR multilingue persisté** + export texte amélioré depuis l'IR.

## Documents Word (.docx) — analyse

Voir réponse en discussion : DOCX = IR quasi natif (style explicite).
Approche retenue :

- **Pas de « superposition » au sens PDF** (pas de géométrie fixe
  on-device) ; UX équivalente : rendu reflow stylé + vue parallèle +
  **export .docx traduit**.
- **Édition XML chirurgicale** : ne modifier que les nœuds `w:t` de
  `document.xml` (+ headers/footers), le reste du package (styles,
  numérotation, relations, images) untouched → mise en forme 100 %
  préservée.
- v1 : paragraphes/runs (style dominant du paragraphe appliqué à la
  traduction), titres via styles, tableaux cellule par cellule, images
  intactes, en-têtes/pieds traduits ; textes dans zones de
  dessin/SmartArt ignorés.
- Le parseur DOCX (archive + xml, pur Dart, hors-ligne) **valide le
  schéma IR avec des données ground-truth** → à mener avec la Phase 1.

Dépendances prévues : `archive`, `xml`.
