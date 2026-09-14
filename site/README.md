# `site/`

This directory is the project page. The files are hand-written, and there is no
build step and no generator, the same way
[muir's `site/`](https://github.com/metebalci/muir/tree/main/site) has none:

    index.html    the front page. What the project is in a paragraph, then a
                  short standing for each board with a link to its page, and
                  a link to the page on the real machine
    arty-z7-20.html
                  the Arty Z7-20's architecture drawing, and under it two
                  boot sequences: the board on its own from the card, and the
                  development boot from a TFTP server
    cora-z7-07s.html
                  the same three drawings for the Cora Z7-07S, which is a
                  smaller part with no HDMI connector, so the display output
                  block, its port and the USB input program are not on it
    cadr.html     the real CADR's own hardware, board by board, for a reader
                  who has never seen one. Every figure on it comes from a
                  document named at the end of the page
    full-page.html
                  a fuller draft kept for later: the architecture drawing with
                  its caption, the target and its block-RAM budget, the
                  fabric/Linux split, a second drawing of the Xbus address
                  space, and where things stand. Deliberately not committed
                  --- it is in .gitignore with a TEMPORARY marker --- and it
                  is here to be drawn from rather than published as it stands
    style.css     muir's stylesheet, with one change --- see below
    fonts/        Archivo and IBM Plex Mono, so a visitor does not have to
                  ask a third party for the page to be readable
    .nojekyll     keeps GitHub Pages from running Jekyll over it

## The two kinds of page

A **drawing page** is `arty-z7-20.html` or `cora-z7-07s.html`. The drawing is
the page. There is no heading, no caption and no prose on it, and each drawing
carries its own title inside it. The only text outside the drawings is one
faint line at the top saying which board this is and linking the other pages.
Anything that explains a drawing belongs in `full-page.html` or in `docs/`,
not here.

A **prose page** is `index.html` or `cadr.html`. Those carry the topbar, and
they are written in brief full sentences because they are read by people who
did not write the code.

## The drawings

The drawings are inline SVG and use the `d-*` classes the stylesheet defines.
They are hand-placed rather than generated, because nothing here reads the RTL.
So **a change to the architecture is a change to the drawing**, made by hand,
and the drawing can drift from the machine.

There are now two architecture drawings, one per board, and the second was
derived from the first by hand. Nothing joins them mechanically. A change that
is true of both boards has to be made twice, and the two can drift from each
other as well as from the machine.

Everything the drawings assert about the machine comes from `README.md`,
`rtl/machine/cadr_cables.map` and `rtl/machine/cadr_xbus_decode.sv`. The fit
and timing figures under each fabric label come from that board's own place and
route report at the commit its comment names.

A block's colour says how far along it is, and the legend on each drawing
carries the words. Green means the board itself has shown it. Turquoise means
it is built and checked here and has not run on that board. The two boards
differ: a block that is green on one may be turquoise on the other, because the
claim is about a board and not about the code.

## The one change to muir's stylesheet

muir sets `html { font-size: 17px }` and states its type scale as fractions of
that. This copy leaves the root alone and sets the base on `body` instead, with
the scale restated against a 16px root. Pinning the root silently overrides a
reader who has raised their browser's default, and that is the one
accessibility choice that matters. The rendered sizes are identical at a
default root, and they follow the reader when it is not the default. muir took
the narrow-screen step from 17px to 16 in one line. That is still one line
here, as a block of token overrides under `@media (max-width: 720px)`.

`.fig.dense` is added for the architecture drawings. Those drawings carry more
label text than muir's figures, so they scroll sooner rather than shrinking
below legibility. `.crumb` is added for the faint line on the drawing pages.

## Looking at it

    python3 -m http.server -d site 8000

You can also open `index.html` directly. There is no build.

## Publishing

`.github/workflows/pages.yml` uploads this directory to GitHub Pages on every
push that touches it. Nothing is built. The directory goes up as it stands,
which is what `.nojekyll` is for. The one repository setting it needs, Pages ->
Build and deployment -> Source: **GitHub Actions**, is already done.

It lands at <https://metebalci.github.io/muir-fpga/>. A custom domain, if one
is ever wanted, is a `CNAME` record plus the Custom domain field.
`muir.metebalci.com` is set up that way.

One thing to know about what that publishes: **everything committed under
`site/` becomes reachable**, whether it is linked or not. That is why
`full-page.html` is gitignored rather than merely unlinked. It would otherwise
answer at `/full-page.html` with nothing pointing at it.
