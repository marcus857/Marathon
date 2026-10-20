# Asset provenance

The undocumented raster images have been replaced with three images generated specifically for this project using Codex's built-in image-generation tool. No existing image was supplied as an input reference. This records how the replacement artwork was made; it is not a guarantee of exclusive copyright, public-domain status, or permission for every possible use.

## Replacement artwork

Generated and installed on October 20, 2026:

| Asset under `Marathon/Assets.xcassets` | Intended use | Provenance |
|---|---|---|
| `AppIcon.appiconset/marathon-icon.png` | App icon | New text-prompt generation; no reference image |
| `Lycabettus.imageset/lycabettus-hero.jpg` | Dashboard artwork | New text-prompt generation; no reference image |
| `Athens.imageset/stadium-plan.jpg` | Training-plan artwork | New text-prompt generation; no reference image |

The [generation manifest](assets/prompts.json) records exact prompts, output filenames, SHA-256 hashes, dimensions, and conversion steps. The installed hashes and asset-catalog references match that manifest. These illustrations do not imply endorsement by any venue, brand, or person.

## Removed-material scope

All eight prior raster files were removed from the current checkout, not only those displaying obvious stock-provider markings. Their sources or redistribution permissions were insufficiently documented. The unused `Acropolis Statues`, `Pantheonic Stadium`, and `Sunset` image sets and the empty `School of Athens` set were also removed. Existing asset-set names needed by the app are retained for the replacement images.

The earlier review found source/creator or stock-related metadata in several old images. It did not establish their redistribution rights. Those files must not be copied into the publication snapshot or reintroduced from a local backup.

## Publication-history check

The remote repository was inspected before this publication work and contained only its initial text-only history. The older raster assets were present in unpublished local commits. Replacing files in the current checkout alone would therefore be insufficient if that full local history were pushed.

The clean publication snapshot is based directly on the initial text-only commit (`2d031b4`). The original local history is retained separately and is not part of the publication branch. This allows a normal fast-forward update without a force-push or deletion of the original local history.

October 20, 2026 checks:

- All seven unique old raster blob hashes are absent from the clean snapshot and its ancestor.
- All three replacement hashes, dimensions, and catalog references match the manifest.
- The unsigned Release iPhone build succeeds with the replacement artwork.
- The source scan found no obvious credentials or private health exports. This is a heuristic check, not a complete security audit.

Repository visibility is a separate GitHub setting; these checks do not assert that the repository is public. Do not push all local branches, mirror local refs, or merge the retained pre-publication history: those operations could reintroduce the removed files.

## Reuse and future changes

**No open-source license has been selected.** Public visibility does not itself grant a license to the code or artwork. AI-generation records do not establish exclusivity or supply a legal clearance guarantee. Any later license decision must address the intended code and asset scope explicitly.

For future artwork, keep a source or generation record, record any applicable permissions and attribution requirements, and avoid introducing images with unknown provenance. Do not imply endorsement by depicted or referenced places, people, artists, or brands.
