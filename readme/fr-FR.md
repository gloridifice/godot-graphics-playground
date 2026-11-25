<div align="center">

# Godot Graphics Playground

</div>

<div align="center">

[English](../README.md) | [简体中文](zh-CN.md) | [日本語](ja-JP.md) | Français

</div>

Des scènes Godot 4.7.2 pour expérimenter avec l’éclairage en temps réel, la brume au sol et les mouvements d’un personnage dans le moteur de rendu Forward+.

![Quatre vues de Sponza : la nef, les arcades, la galerie supérieure et la cour aux tentures colorées](images/sponza-restir.jpg)

*Intel Sponza 2022 · Vulkan · éclairage direct par ReSTIR DI · éclairage indirect à deux rebonds par Split Radiance Cascades. Les vues du bas utilisent 12 lumières ponctuelles aux tons pastel réparties sur deux niveaux, avec une énergie indirecte six fois supérieure à la valeur par défaut. La lumière ambiante du ciel est désactivée en bas à gauche et activée en bas à droite.*

**Éclairage direct (DI) :** ReSTIR DI réutilise les échantillons de lumières ponctuelles de l’image précédente et des pixels voisins, les pondère selon leur contribution à la surface courante et teste leur visibilité pour calculer les ombres.
**Éclairage indirect (GI) :** Split Radiance Cascades trace des rayons dans l’espace monde, stocke la lumière incidente par direction dans une hiérarchie de sondes et la réutilise pour calculer un second rebond diffus.

## Démarrage rapide

### Installation

Installez Godot 4.7.2 et Git LFS, puis clonez le projet avec ses ressources :

```sh
git lfs install
git clone https://github.com/gloridifice/godot-graphics-playground.git
cd godot-graphics-playground
```

Ouvrez `project.godot`. Une fois les ressources importées, appuyez sur **F5** pour lancer la scène de brume.

### Mise à jour

Depuis le répertoire du projet, exécutez `git pull --ff-only`, puis `git lfs pull`.

## Expériences

- Comparez ReSTIR DI à un rendu de référence qui évalue chacune des 12 lumières ponctuelles de la galerie de Sponza.
- Passez d’un à deux rebonds diffus pour observer comment la lumière atteint les voûtes.
- Marchez et sautez dans la brume pour comparer deux simulations : les équations en eau peu profonde et Stable Fluids.
- Observez la sélection des animations par *motion matching*, le verrouillage des pieds et l’escalade dans la [démo du personnage](../addons/motion/demo.tscn).

## Temps GPU sous Vulkan

**RTX 5070 Ti Laptop GPU** (pilote 621.01), Godot 4.7.2 Forward+, résolution native de 1600 × 900. La caméra reste sous les arcades (en haut à droite sur la couverture), avec 12 lumières ponctuelles, ReSTIR DI et deux rebonds de GI. L’affichage de diagnostic et la synchronisation verticale sont désactivés.

| Temps GPU par image (ms) | Médiane | P95 |
|---|---:|---:|
| Rendu complet de la vue | 2,927 | 4,635 |
| GI : de Prepare à Merge | 0,584 | 0,639 |
| DI : réutilisation temporelle et ombrage | 1,059 | 2,643 |
| Passes communes : Receiver et Apply | 0,454 | 0,660 |

Après 240 images de chauffe, le [script de mesure](../tools/profile_sponza_restir.gd) a relevé 4 413 temps de rendu complet et 64 échantillons par passe. Le total inclut le reste du rendu de Godot. Les lignes GI et DI mesurent leurs passes respectives, et non une image entière avec un seul effet actif.

## Lancer la scène de couverture depuis les sources

Après l’importation, vérifiez que l’exécutable Godot figure dans votre `PATH`, puis lancez la scène depuis le répertoire du projet :

```sh
godot --rendering-driver vulkan scenes/sponza_restir_di.tscn
```

ReSTIR DI est actif au démarrage. Appuyez une fois sur **B** pour activer le second rebond de lumière indirecte, puis laissez l’éclairage se stabiliser.

## Licences et crédits

Consultez les [mentions et conditions d’utilisation des ressources tierces](../THIRD_PARTY.md), notamment les [crédits et la licence d’Intel Sponza](../assets/sponza/credits_license.txt).

## Développement

- [Architecture](../doco/architecture.md)
- [Split Radiance Cascades et ReSTIR DI](../addons/split_radiance_cascades/USAGE.md)
- [Brume sur champ de hauteur](../addons/heightfield_fog/README.md)
