# `pages/fonts/`

These are the three families the pages use. They are carried here so that
reading a page asks nothing of a third party.

| file | face | used for |
|---|---|---|
| `dela-gothic-one.woff2` | Dela Gothic One | the display face: titles, the wordmark, the contents |
| `zen-maru-gothic-500.woff2` | Zen Maru Gothic Medium | the voice, which is what the pages call normal, and the drawings' labels |
| `zen-maru-gothic-700.woff2` | Zen Maru Gothic Bold | the voice, emphasized, and the speech bubbles |
| `ibm-plex-mono-400.woff2` | IBM Plex Mono Regular | code, the drawings' numbers, the who-line |
| `ibm-plex-mono-500.woff2` | IBM Plex Mono Medium | the keys and the table headings |
| `ibm-plex-mono-600.woff2` | IBM Plex Mono SemiBold | the page line's own name |

## Where they came from

The three IBM Plex Mono files were fetched from Google Fonts on 7 September
2026. They are the `latin` subset as Google Fonts serves it, unmodified, and
every character these pages set in mono is in it. To refresh them, ask Google
Fonts for the same weights and take the faces whose `unicode-range` begins
`U+0000-00FF`.

The other three were cut on 16 September 2026 from the upstream TTFs in
[google/fonts](https://github.com/google/fonts), at commit `92345ac0`:
`ofl/delagothicone/DelaGothicOne-Regular.ttf`, and
`ofl/zenmarugothic/ZenMaruGothic-Medium.ttf` and `ZenMaruGothic-Bold.ttf`.
Both families are Japanese, and the whole of one is megabytes. So each file
keeps only printable ASCII, the Latin-1 supplement, the general punctuation
from `U+2010` to `U+2027` and from `U+2030` to `U+203A`, four arrows, the minus
sign, and the six katakana the front page draws. Each file is about 12 KB.

    pip install fonttools brotli
    pyftsubset DelaGothicOne-Regular.ttf --flavor=woff2 \
        --layout-features+=vert,vrt2 --name-IDs='*' \
        --unicodes=U+0020-007E,U+00A0-00FF,U+2010-2027,U+2030-203A,U+2190-2193,U+2212,U+30A2,U+30AB,U+30D4,U+30DF,U+30E5,U+30FC \
        --output-file=dela-gothic-one.woff2

The two Zen Maru Gothic files are cut the same way. `--name-IDs='*'` keeps
each font's copyright and license in its own name table.

**A character outside that list is drawn in a fallback face**, which is a
different face. Adding one means cutting the three files again, with the new
code point added to `--unicodes`.

## License

None of the three families is this project's work, and none is under its
license. All three are under the **SIL Open Font License, Version 1.1**, which
permits redistribution with or without modification. The files here are
subsets, and each keeps its copyright notice and license in its metadata.

- Dela Gothic One, copyright 2020 The Dela Gothic Project Authors ---
  <https://github.com/syakuzen/DelaGothic>
- Zen Maru Gothic, copyright 2021 The Zen Maru Gothic Authors ---
  <https://github.com/googlefonts/zen-marugothic>
- IBM Plex Mono, copyright 2017 IBM Corp., with Reserved Font Name "Plex"
  --- <https://github.com/IBM/plex>
