# `site/`

The project page. Hand-written files, no build step and no generator, the same
way [muir's `site/`](https://github.com/metebalci/muir/tree/main/site) is:

    index.html    the architecture drawing, and under it two boot
                  sequences, the board on its own from the card and
                  the development boot from a TFTP server --- no
                  heading, no caption, no prose. Each drawing carries
                  its own title inside it
    full-page.html
                  a fuller draft kept for later: the same drawing with its
                  caption, the target and its block-RAM budget, the
                  fabric/Linux split, a second drawing of the Xbus address
                  space, and where things stand. Deliberately not committed
                  --- it is in .gitignore with a TEMPORARY marker --- and it
                  is here to be drawn from rather than published as it
                  stands. Anything explaining the drawing belongs here, not
                  on index.html
    style.css     muir's stylesheet, with one change --- see below
    fonts/        Archivo and IBM Plex Mono, so a visitor does not have to
                  ask a third party for the page to be readable
    .nojekyll     keeps GitHub Pages from running Jekyll over it

The drawings are inline SVG, using the `d-*` classes the stylesheet defines,
and the architecture drawing is byte for byte the same in both files. They are
hand-placed rather than generated: nothing here reads the RTL, so **a change to
the architecture is a change to the drawing**, by hand, and the two can drift.
Everything they assert about the machine comes from `README.md`,
`rtl/machine/cadr_cables.map` and `rtl/machine/cadr_xbus_decode.sv`; every number on the fuller
page was re-derived from those before it was written down.

## The one change to muir's stylesheet

muir sets `html { font-size: 17px }` and states its type scale as fractions of
that. This copy leaves the root alone and sets the base on `body` instead, with
the scale restated against a 16px root, because pinning the root silently
overrides a reader who has raised their browser's default --- which is the one
accessibility choice that matters. The rendered sizes are identical at a
default root; they follow the reader when it is not. The narrow-screen step
from 17px to 16 that muir did in one line is still one line, as a block of
token overrides under `@media (max-width: 720px)`.

`.fig.dense` is added for the architecture drawing, which carries more label
text than muir's figures and scrolls sooner rather than shrinking below
legibility.

## Looking at it

    python3 -m http.server -d site 8000

or open `index.html` directly. There is no build.

## Publishing

`.github/workflows/pages.yml` uploads this directory to GitHub Pages on every
push that touches it. Nothing is built --- the directory goes up as it stands,
which is what `.nojekyll` is for. The repository setting it needs, Pages ->
Build and deployment -> Source: **GitHub Actions**, is already done.

It lands at <https://metebalci.github.io/muir-fpga/>. A custom domain, if one
is ever wanted, is a `CNAME` record plus the Custom domain field, the way
`muir.metebalci.com` is set up.

Two things to know about what that publishes:

- **Everything committed under `site/` becomes reachable**, linked or not.
  That is why `full-page.html` is gitignored rather than merely unlinked: it
  would otherwise answer at `/full-page.html` with nothing pointing at it.
- The workflow triggers on `main` **and** `master`, because the local branch is
  `master` today while muir publishes from `main`. Renaming the branch is the
  tidier end state, and then the trigger loses its second entry.
