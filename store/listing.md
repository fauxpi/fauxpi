# Store listing

The words and pictures for FauxPi's store pages, kept in the repository so
a change is reviewable rather than typed into a web form and forgotten.

## The files

One directory per store, holding exactly what goes into that store's form
and nothing else to go looking for. Text is plain, ready to paste.

| File | Where it goes | Limit |
|---|---|---|
| `snapcraft/title.txt` | Snap Store ▸ Listing ▸ Title | 40 characters |
| `snapcraft/summary.txt` | Snap Store ▸ Listing ▸ Summary | 78 characters |
| `snapcraft/description.txt` | Snap Store ▸ Listing ▸ Description | 4,096 characters |
| `snapcraft/icon.png` | Snap Store ▸ Listing ▸ Icon | 256 × 256 |
| `snapcraft/screenshots/` | Snap Store ▸ Listing ▸ Images | up to 5 |

The lengths are the limits Snapcraft checks in `snapcraft.yaml`. Check the
dashboard for the image rules before uploading new pictures.

## Where it comes from

The Snap Store fills the title, summary and description from the snap the
first time one is uploaded (`snap/snapcraft.yaml`), and the dashboard's
own copy wins after it is edited there. These files are the dashboard's
copy, so they can say more than the snap's one-paragraph description and
the AppStream metadata in `data/`.

`icon.png` is `data/io.github.robert_ancell.FauxPi.svg` drawn at 256 × 256:

```sh
inkscape data/io.github.robert_ancell.FauxPi.svg --export-type=png \
  --export-width=256 --export-height=256 --export-filename=store/snapcraft/icon.png
```

`screenshots/board-sheet.png` is the board sheet, where the board is
plugged together. A second picture of Raspberry Pi OS running on the
simulated display would show the other half of what it does.

## The words

Say what it does for somebody who has never heard of it: it runs Raspberry
Pi software without a Raspberry Pi. The description leads with that, then
the boards, then what is simulated. It claims nothing FauxPi does not do —
every line is a feature in the code today — and stays short of the limit,
because nobody reads 4,000 characters of a store page.
